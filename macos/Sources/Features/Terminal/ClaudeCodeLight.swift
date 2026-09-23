import AppKit
import Foundation

/// What the Claude Code session in a tab is doing, shown as the tab's color when the tab's
/// color is `auto`.
enum ClaudeCodeLight: CaseIterable {
    /// Claude Code is working on a request.
    case working

    /// Claude Code finished and is waiting for the next request.
    case finished

    /// Claude Code needs an answer: a permission, a question or a dialog.
    case waiting

    /// Claude Code finished, and nothing it changed since its last commit is left.
    case committed

    var tabColor: TerminalTabColor {
        switch self {
        case .working: return .blue
        case .finished: return .yellow
        case .waiting: return .red
        case .committed: return .green
        }
    }

    /// A tab with several sessions shows the one that needs attention most.
    private var urgency: Int {
        switch self {
        case .waiting: return 3
        case .working: return 2
        case .finished: return 1
        case .committed: return 0
        }
    }

    static func mostUrgent(_ lights: [ClaudeCodeLight]) -> ClaudeCodeLight? {
        lights.max { $0.urgency < $1.urgency }
    }

    /// The light for a session in `status`, the value Claude Code writes to its registry
    /// entry. Unknown values show nothing, so a new state isn't shown as the wrong one.
    init?(status: String, committed: Bool) {
        switch status {
        case "busy": self = .working
        case "waiting": self = .waiting
        case "idle": self = committed ? .committed : .finished
        default: return nil
        }
    }
}

/// Follows a transcript to tell whether the session's last change was committed: a
/// `git commit` that succeeded, with no file edited after it. Only what was added to the
/// transcript since the last read is read.
final class ClaudeCodeCommitTracker {
    private(set) var committed = false

    /// Where the next read starts: just after the last complete line.
    private var offset: UInt64 = 0

    /// Commits started whose result hasn't been read yet, by tool use id.
    private var pendingCommits: Set<String> = []

    private static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    /// `git commit`, also with git's own options before `commit` such as `git -C dir commit`.
    private static let commitCommand = try? NSRegularExpression(
        pattern: #"\bgit(\s+-[Cc]\s+\S+|\s+--?[\w-]+(=\S+)?)*\s+commit\b"#)

    /// How much of the transcript is read at a time. A transcript read for the first time
    /// can be many megabytes.
    private static let chunkSize = 1 << 20

    /// Reads what was added to the transcript at `url` since the last call.
    func update(from url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return }
        if end < offset {
            // The transcript was replaced; read it again from the start.
            offset = 0
            committed = false
            pendingCommits = []
        }
        guard end > offset else { return }
        try? handle.seek(toOffset: offset)

        var partial = Data()
        while let chunk = try? handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
            partial.append(chunk)
            guard let lastNewline = partial.lastIndex(of: UInt8(ascii: "\n")) else { continue }

            let complete = partial[partial.startIndex...lastNewline]
            for line in complete.split(separator: UInt8(ascii: "\n")) {
                consume(line: Data(line))
            }
            offset += UInt64(complete.count)
            partial = Data(partial[partial.index(after: lastNewline)...])
        }
    }

    /// Reads one transcript line.
    func consume(line: Data) {
        guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              entry["isSidechain"] as? Bool != true,
              let message = entry["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return }

        for block in content {
            switch block["type"] as? String {
            case "tool_use":
                guard let name = block["name"] as? String else { continue }
                if Self.editTools.contains(name) {
                    committed = false
                } else if name == "Bash",
                          let id = block["id"] as? String,
                          let input = block["input"] as? [String: Any],
                          let command = input["command"] as? String,
                          Self.isCommit(command) {
                    pendingCommits.insert(id)
                }

            case "tool_result":
                guard let id = block["tool_use_id"] as? String,
                      pendingCommits.remove(id) != nil else { continue }
                if block["is_error"] as? Bool != true {
                    committed = true
                }

            default:
                continue
            }
        }
    }

    static func isCommit(_ command: String) -> Bool {
        guard let commitCommand else { return false }
        let range = NSRange(command.startIndex..., in: command)
        return commitCommand.firstMatch(in: command, range: range) != nil
    }
}

/// Keeps the lights of tabs whose color is `auto` up to date.
///
/// Claude Code rewrites its registry entry only when the session's status changes, so the
/// entry of each session shown in an `auto` tab is watched, and read only when it changes.
/// The transcript, which changes all the time while Claude Code works, isn't watched: it is
/// read when the session finishes, from where the last read stopped.
///
/// Which terminals run Claude Code is checked when an entry is added or removed (Claude
/// Code starting or exiting) and every few seconds, which catches the rest.
@MainActor
final class ClaudeCodeLights {
    static let shared = ClaudeCodeLights()

    private static let rescanInterval: TimeInterval = 5

    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.claude-code-lights", qos: .utility)
    private let reader = ClaudeCodeLightReader()

    private var windows: [ObjectIdentifier: WeakWindow] = [:]

    /// The foreground process of each terminal of each `auto` tab.
    private var pids: [ObjectIdentifier: [Int]] = [:]

    /// The light of each watched session, by process.
    private var lights: [Int: ClaudeCodeLight] = [:]

    /// A watch on the registry entry of each session shown in an `auto` tab, by process.
    private var entryWatches: [Int: DispatchSourceFileSystemObject] = [:]

    /// A watch on the registry directory, while any tab is `auto`.
    private var directoryWatch: DispatchSourceFileSystemObject?
    private var rescanTimer: Timer?

    private struct WeakWindow {
        weak var window: TerminalWindow?
    }

    private init() {}

    /// Starts or stops following `window`, as its color becomes or stops being `auto`.
    func follow(_ window: TerminalWindow) {
        let id = ObjectIdentifier(window)
        if window.tabColor == .auto {
            windows[id] = WeakWindow(window: window)
        } else {
            windows[id] = nil
            window.claudeCodeLight = nil
        }
        rescan()
    }

    // MARK: Terminals

    private func rescan() {
        windows = windows.filter { $0.value.window?.tabColor == .auto }
        pids = windows.mapValues { entry in
            let surfaces = entry.window?.terminalController?.surfaceTree.root?.leaves() ?? []
            return surfaces.compactMap { $0.surfaceModel?.foregroundPID }
        }

        let shown = Set(pids.values.joined())
        for (pid, watch) in entryWatches where !shown.contains(pid) {
            watch.cancel()
            entryWatches[pid] = nil
            lights[pid] = nil
        }
        for pid in shown where entryWatches[pid] == nil {
            watchEntry(of: pid)
        }

        if windows.isEmpty {
            stopWatchingDirectory()
        } else {
            startWatchingDirectory()
        }
        show()
    }

    private func show() {
        for (id, entry) in windows {
            guard let window = entry.window else { continue }
            window.claudeCodeLight = ClaudeCodeLight.mostUrgent((pids[id] ?? []).compactMap { lights[$0] })
        }
    }

    // MARK: Registry entries

    /// Watches the registry entry of process `pid`, if it has one, and reads it.
    private func watchEntry(of pid: Int) {
        let fd = open(ClaudeCodeSession.registryFile(pid: pid).path, O_EVTONLY)
        guard fd >= 0 else { return }

        let watch = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        watch.setEventHandler { [weak self, weak watch] in
            MainActor.assumeIsolated {
                guard let self, let watch else { return }
                if watch.data.contains(.delete) || watch.data.contains(.rename) {
                    // Claude Code exited. The entry may come back under the same process, so
                    // it is looked for again.
                    watch.cancel()
                    self.entryWatches[pid] = nil
                    self.lights[pid] = nil
                    self.rescan()
                } else {
                    self.read(pid)
                }
            }
        }
        watch.setCancelHandler { close(fd) }
        entryWatches[pid] = watch
        watch.resume()
        read(pid)
    }

    private func read(_ pid: Int) {
        let reader = reader
        queue.async {
            let light = reader.light(pid: pid)
            DispatchQueue.main.async {
                guard self.entryWatches[pid] != nil else { return }
                self.lights[pid] = light
                self.show()
            }
        }
    }

    // MARK: Registry directory

    private func startWatchingDirectory() {
        if rescanTimer == nil {
            rescanTimer = Timer.scheduledTimer(withTimeInterval: Self.rescanInterval, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { self?.rescan() }
            }
            rescanTimer?.tolerance = 1
        }

        guard directoryWatch == nil else { return }
        let fd = open(ClaudeCodeSession.registryDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        watch.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
        watch.setCancelHandler { close(fd) }
        directoryWatch = watch
        watch.resume()
    }

    private func stopWatchingDirectory() {
        rescanTimer?.invalidate()
        rescanTimer = nil
        directoryWatch?.cancel()
        directoryWatch = nil
    }
}

/// Reads registry entries and transcripts off the main thread. Only used on the queue of
/// `ClaudeCodeLights`.
private final class ClaudeCodeLightReader: @unchecked Sendable {
    /// Per session: its transcript, once found, and what has been read of it.
    private var transcripts: [UUID: (url: URL, tracker: ClaudeCodeCommitTracker)] = [:]

    func light(pid: Int) -> ClaudeCodeLight? {
        guard let (session, status) = ClaudeCodeSession.activity(pid: pid) else { return nil }

        // Whether the last change was committed only matters once the session finishes.
        guard status == "idle" else { return ClaudeCodeLight(status: status, committed: false) }

        if transcripts[session.id] == nil, let url = session.transcript {
            transcripts[session.id] = (url, ClaudeCodeCommitTracker())
        }
        guard let transcript = transcripts[session.id] else {
            return ClaudeCodeLight(status: status, committed: false)
        }
        transcript.tracker.update(from: transcript.url)
        return ClaudeCodeLight(status: status, committed: transcript.tracker.committed)
    }
}
