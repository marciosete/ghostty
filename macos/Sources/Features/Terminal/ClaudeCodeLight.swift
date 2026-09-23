import AppKit
import Foundation

/// What the Claude Code session in a tab is doing, shown as the tab's color when the tab's
/// color is `auto`.
enum ClaudeCodeLight: CaseIterable {
    /// Claude Code is working on a request.
    case working

    /// Claude Code isn't working, and files it edited have changes that aren't committed:
    /// they are waiting to be reviewed and committed.
    case pending

    /// Claude Code needs an answer: a permission, a question or a dialog.
    case waiting

    /// Claude Code isn't working in its own worktree, and everything there is committed,
    /// but the commits haven't landed on the main checkout's branch yet.
    case unlanded

    /// Claude Code isn't working, and every file it edited is committed (and, in a
    /// worktree, landed).
    case clean

    var tabColor: TerminalTabColor {
        switch self {
        case .working: return .blue
        case .pending: return .yellow
        case .unlanded: return .purple
        case .waiting: return .red
        case .clean: return .green
        }
    }

    /// A tab with several sessions shows the one that needs attention most.
    private var urgency: Int {
        switch self {
        case .waiting: return 4
        case .working: return 3
        case .pending: return 2
        case .unlanded: return 1
        case .clean: return 0
        }
    }

    static func mostUrgent(_ lights: [ClaudeCodeLight]) -> ClaudeCodeLight? {
        lights.max { $0.urgency < $1.urgency }
    }

    /// The light for a session in `status`, the value Claude Code writes to its registry
    /// entry. Unknown values show nothing, so a new state isn't shown as the wrong one.
    init?(status: String, pending: Bool, unlanded: Bool = false) {
        switch status {
        case "busy": self = .working
        case "waiting": self = .waiting
        case "idle": self = pending ? .pending : unlanded ? .unlanded : .clean
        default: return nil
        }
    }
}

/// What an `auto` tab shows of the Claude Code sessions in its terminals: its color, and
/// while it is yellow, how many files are waiting to be committed, or while it is purple,
/// how many commits are waiting to land.
struct ClaudeCodeTabState: Equatable {
    let light: ClaudeCodeLight

    /// Files the sessions edited that have changes not committed. Only counted once a
    /// session stops working. In a worktree, every file with changes counts.
    let pendingFiles: Int

    /// Files the sessions edited that are in a git repository.
    let editedFiles: Int

    /// Commits in the sessions' worktrees that aren't on the main checkout's branch.
    let unlandedCommits: Int

    /// The worktrees of the sessions that run in one, once they stop working.
    let worktrees: [Git.Worktree]

    init(
        light: ClaudeCodeLight,
        pendingFiles: Int = 0,
        editedFiles: Int = 0,
        unlandedCommits: Int = 0,
        worktrees: [Git.Worktree] = []
    ) {
        self.light = light
        self.pendingFiles = pendingFiles
        self.editedFiles = editedFiles
        self.unlandedCommits = unlandedCommits
        self.worktrees = worktrees
    }

    /// The tab of several sessions shows the one that needs attention most, and the files
    /// and commits all of them have left.
    static func combined(_ states: [ClaudeCodeTabState]) -> ClaudeCodeTabState? {
        guard let light = ClaudeCodeLight.mostUrgent(states.map(\.light)) else { return nil }
        return ClaudeCodeTabState(
            light: light,
            pendingFiles: states.reduce(0) { $0 + $1.pendingFiles },
            editedFiles: states.reduce(0) { $0 + $1.editedFiles },
            unlandedCommits: states.reduce(0) { $0 + $1.unlandedCommits },
            worktrees: states.flatMap(\.worktrees))
    }

    /// The number shown on the tab: the files waiting to be committed while it is yellow,
    /// and the commits waiting to land while it is purple.
    var badge: Int? {
        switch light {
        case .pending: return pendingFiles > 0 ? pendingFiles : nil
        case .unlanded: return unlandedCommits > 0 ? unlandedCommits : nil
        default: return nil
        }
    }

    /// Says what the badge counts.
    var badgeHelp: String? {
        guard let badge else { return nil }
        if light == .unlanded {
            let commits = badge == 1 ? "commit" : "commits"
            return "\(badge) \(commits) not on \(landingBranch ?? "the main checkout's branch") yet"
        }
        let files = editedFiles == 1 ? "file" : "files"
        if editedFiles > badge {
            return "\(badge) of \(editedFiles) edited \(files) not committed"
        }
        return "\(badge) \(badge == 1 ? "file" : "files") not committed"
    }

    /// The worktrees that can land now: everything in them is committed and some of it
    /// isn't on the base branch yet. Only offered while the tab is purple, so no session
    /// of the tab is working or has files to commit.
    var landableWorktrees: [Git.Worktree] {
        guard light == .unlanded else { return [] }
        return worktrees.filter { $0.baseBranch != nil }
    }

    /// The branch the worktrees land on, when they all land on the same one.
    var landingBranch: String? {
        let branches = Set(worktrees.compactMap(\.baseBranch))
        return branches.count == 1 ? branches.first : nil
    }
}

/// Follows a transcript to collect the files the session edited. Only what was added to
/// the transcript since the last read is read.
final class ClaudeCodeEditTracker {
    /// Absolute paths of the files the session edited, in the order first edited.
    private(set) var files: [String] = []
    private var seen: Set<String> = []

    /// Where the next read starts: just after the last complete line.
    private var offset: UInt64 = 0

    /// The tools that edit files, and the input naming the file.
    private static let editTools: [String: String] = [
        "Edit": "file_path",
        "MultiEdit": "file_path",
        "Write": "file_path",
        "NotebookEdit": "notebook_path",
    ]

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
            files = []
            seen = []
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

        for block in content where block["type"] as? String == "tool_use" {
            guard let name = block["name"] as? String,
                  let key = Self.editTools[name],
                  let input = block["input"] as? [String: Any],
                  let path = input[key] as? String,
                  path.hasPrefix("/"),
                  seen.insert(path).inserted else { continue }
            files.append(path)
        }
    }
}

/// Keeps the lights of tabs whose color is `auto` up to date.
///
/// Claude Code rewrites its registry entry only when the session's status changes, so the
/// entry of each session shown in an `auto` tab is watched, and read only when it changes.
/// Nothing else is looked at while a session works. Once it stops, whether the files it
/// edited are committed is checked with `git status` on those files alone, and checked
/// again when its transcript changes (Claude Code can save its last lines after it says
/// it stopped) or when the git directory of one of those files changes (a commit).
///
/// Which terminals run Claude Code is checked when an entry is added or removed (Claude
/// Code starting or exiting) and every few seconds, which catches the rest.
@MainActor
final class ClaudeCodeLights {
    static let shared = ClaudeCodeLights()

    private static let rescanInterval: TimeInterval = 5

    /// Claude Code rewrites its registry entry in place, so it can be read half written.
    /// It is read again after this long, a few times, before the session is given up on.
    private static let retryDelay: TimeInterval = 0.2
    private static let retries = 5

    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.claude-code-lights", qos: .utility)
    private let reader = ClaudeCodeLightReader()

    private var windows: [ObjectIdentifier: WeakWindow] = [:]

    /// The foreground process of each terminal of each `auto` tab.
    private var pids: [ObjectIdentifier: [Int]] = [:]

    /// The state of each watched session, by process.
    private var states: [Int: ClaudeCodeTabState] = [:]

    /// A watch on the registry entry of each session shown in an `auto` tab, by process.
    private var entryWatches: [Int: DispatchSourceFileSystemObject] = [:]

    /// While a session isn't working: watches on its transcript and on the git directories
    /// of the files it edited, by process.
    private var idleWatches: [Int: [DispatchSourceFileSystemObject]] = [:]

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
            window.claudeCodeState = nil
        }
        rescan()
    }

    // MARK: Landing

    /// Lands the commits of the worktrees of `window`'s sessions on their base branch,
    /// then reads the sessions again. Failures are shown in an alert on the window.
    func land(_ window: TerminalWindow) {
        let worktrees = window.claudeCodeState?.landableWorktrees ?? []
        guard !worktrees.isEmpty else { return }

        queue.async {
            let failures = worktrees.compactMap { worktree -> (Git.Worktree, Git.LandError)? in
                if case .failure(let error) = Git.land(worktree) { return (worktree, error) }
                return nil
            }
            DispatchQueue.main.async {
                for pid in self.pids[ObjectIdentifier(window)] ?? [] {
                    self.read(pid)
                }
                if let (worktree, error) = failures.first {
                    Self.showLandingFailure(error, of: worktree, in: window)
                }
            }
        }
    }

    private static func showLandingFailure(_ error: Git.LandError, of worktree: Git.Worktree, in window: NSWindow) {
        let name = worktree.branch ?? worktree.root.lastPathComponent
        let base = worktree.baseBranch ?? "the main checkout"
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch error {
        case .uncommittedChanges:
            alert.messageText = "\(name) has changes that aren't committed"
            alert.informativeText = "Commit them, then land again."
        case .noBaseBranch:
            alert.messageText = "There's no branch to land \(name) on"
            alert.informativeText = "The main checkout at \(worktree.mainRoot.path) has no branch checked out."
        case .conflicts(let message):
            alert.messageText = "\(name) conflicts with \(base)"
            alert.informativeText = "Nothing was changed. Ask the session to rebase onto \(base) and resolve the conflicts, then land again.\n\n\(message)"
        case .fastForwardFailed(let message):
            alert.messageText = "\(base) couldn't be moved to \(name)"
            alert.informativeText = "\(name) was rebased onto \(base), but \(base) wasn't changed. It may have changes in the main checkout that the commits would overwrite.\n\n\(message)"
        }
        alert.beginSheetModal(for: window)
    }

    // MARK: Terminals

    private func rescan() {
        windows = windows.filter { $0.value.window?.tabColor == .auto }
        pids = windows.mapValues { entry in
            let surfaces = entry.window?.terminalController?.surfaceTree.root?.leaves() ?? []
            return surfaces.compactMap { $0.surfaceModel?.foregroundPID }
        }

        let shown = Set(pids.values.joined())
        for pid in entryWatches.keys where !shown.contains(pid) {
            forget(pid)
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
            window.claudeCodeState = ClaudeCodeTabState.combined((pids[id] ?? []).compactMap { states[$0] })
        }
    }

    private func forget(_ pid: Int) {
        entryWatches[pid]?.cancel()
        entryWatches[pid] = nil
        setIdleWatches([], for: pid)
        states[pid] = nil
    }

    // MARK: Sessions

    /// Watches the registry entry of process `pid`, if it has one, and reads it.
    private func watchEntry(of pid: Int) {
        guard let watch = Self.watch(ClaudeCodeSession.registryFile(pid: pid), events: [.write, .extend, .delete, .rename], handler: { [weak self] watch in
            guard let self else { return }
            if watch.data.contains(.delete) || watch.data.contains(.rename) {
                // Claude Code exited. The entry may come back under the same process, so it
                // is looked for again.
                self.forget(pid)
                self.rescan()
            } else {
                self.read(pid)
            }
        }) else { return }
        entryWatches[pid] = watch
        read(pid)
    }

    private func read(_ pid: Int, retriesLeft: Int = ClaudeCodeLights.retries) {
        let reader = reader
        queue.async {
            let reading = reader.read(pid: pid)
            DispatchQueue.main.async {
                guard self.entryWatches[pid] != nil else { return }
                switch reading {
                case .unreadable where retriesLeft > 0:
                    // Keep what is shown until the entry reads whole.
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) {
                        self.read(pid, retriesLeft: retriesLeft - 1)
                    }
                    return

                case .unreadable:
                    self.states[pid] = nil
                    self.setIdleWatches([], for: pid)

                case .session(let state, let watchWhileIdle):
                    self.states[pid] = state
                    self.setIdleWatches(watchWhileIdle, for: pid)
                }
                self.show()
            }
        }
    }

    /// Watches `urls` for process `pid` in place of what was watched before. Any change to
    /// them reads the session again.
    private func setIdleWatches(_ urls: [URL], for pid: Int) {
        idleWatches[pid]?.forEach { $0.cancel() }
        idleWatches[pid] = nil
        guard !urls.isEmpty else { return }

        idleWatches[pid] = urls.compactMap { url in
            Self.watch(url, events: [.write, .extend]) { [weak self] _ in self?.read(pid) }
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
        directoryWatch = Self.watch(ClaudeCodeSession.registryDirectory, events: .write) { [weak self] _ in
            self?.rescan()
        }
    }

    private func stopWatchingDirectory() {
        rescanTimer?.invalidate()
        rescanTimer = nil
        directoryWatch?.cancel()
        directoryWatch = nil
    }

    /// Watches a file or directory. A directory's `.write` means an entry in it was added,
    /// removed or renamed.
    private static func watch(
        _ url: URL,
        events: DispatchSource.FileSystemEvent,
        handler: @escaping @MainActor (DispatchSourceFileSystemObject) -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        watch.setEventHandler { [weak watch] in
            MainActor.assumeIsolated {
                guard let watch else { return }
                handler(watch)
            }
        }
        watch.setCancelHandler { close(fd) }
        watch.resume()
        return watch
    }
}

/// Reads registry entries, transcripts and git off the main thread. Only used on the queue
/// of `ClaudeCodeLights`.
private final class ClaudeCodeLightReader: @unchecked Sendable {
    enum Reading {
        /// The registry entry exists but couldn't be read, perhaps because it is being
        /// written.
        case unreadable

        /// The session's state, if it has one, and what to watch while it isn't working.
        case session(ClaudeCodeTabState?, watchWhileIdle: [URL])
    }

    /// Per session: its transcript, once found, and the files it edited.
    private var transcripts: [UUID: (url: URL, edits: ClaudeCodeEditTracker)] = [:]

    /// The repository of each directory looked up, or nil for a directory outside one.
    private var repositories: [String: Git.Repository?] = [:]

    func read(pid: Int) -> Reading {
        guard let (session, status) = ClaudeCodeSession.activity(pid: pid) else {
            let exists = FileManager.default.fileExists(atPath: ClaudeCodeSession.registryFile(pid: pid).path)
            return exists ? .unreadable : .session(nil, watchWhileIdle: [])
        }

        // What the session changed only matters once it stops working.
        guard status == "idle" else {
            return .session(Self.state(status: status), watchWhileIdle: [])
        }

        if transcripts[session.id] == nil, let url = session.transcript {
            transcripts[session.id] = (url, ClaudeCodeEditTracker())
        }

        // A session in its own worktree owns every change there, however it made them, so
        // the worktree's status stands in for the files the transcript names.
        if let worktree = Git.linkedWorktree(containing: URL(fileURLWithPath: session.cwd)) {
            return read(worktree, status: status, transcript: transcripts[session.id]?.url)
        }

        guard let transcript = transcripts[session.id] else {
            return .session(Self.state(status: status), watchWhileIdle: [])
        }
        transcript.edits.update(from: transcript.url)

        var byRepository: [Git.Repository: [String]] = [:]
        for file in transcript.edits.files {
            let resolved = Self.resolve(file)
            guard let repository = repository(containing: resolved) else { continue }
            byRepository[repository, default: []].append(resolved)
        }

        // Files whose status can't be read count as pending, so they're never shown as done.
        let pending = byRepository.reduce(0) { count, entry in
            count + (Git.uncommittedFileCount(entry.value, in: entry.key) ?? entry.value.count)
        }
        let edited = byRepository.values.reduce(0) { $0 + $1.count }
        let watch = [transcript.url] + byRepository.keys.map(\.gitDir)
        return .session(Self.state(status: status, pendingFiles: pending, editedFiles: edited), watchWhileIdle: watch)
    }

    /// The state of an idle session running in `worktree`. Watches the worktree's git
    /// directory (a commit) and the shared branches (landing moves the base branch), as well
    /// as the transcript.
    private func read(_ worktree: Git.Worktree, status: String, transcript: URL?) -> Reading {
        let watch = [transcript, worktree.gitDir, worktree.commonDir.appendingPathComponent("refs/heads")]
            .compactMap { $0 }
        guard let progress = Git.progress(of: worktree) else {
            return .session(Self.state(status: status), watchWhileIdle: watch)
        }
        let state = Self.state(
            status: status,
            pendingFiles: progress.uncommittedFiles,
            editedFiles: progress.uncommittedFiles,
            unlandedCommits: progress.unlandedCommits,
            worktree: worktree)
        return .session(state, watchWhileIdle: watch)
    }

    private static func state(
        status: String,
        pendingFiles: Int = 0,
        editedFiles: Int = 0,
        unlandedCommits: Int = 0,
        worktree: Git.Worktree? = nil
    ) -> ClaudeCodeTabState? {
        guard let light = ClaudeCodeLight(status: status, pending: pendingFiles > 0, unlanded: unlandedCommits > 0) else {
            return nil
        }
        return ClaudeCodeTabState(
            light: light,
            pendingFiles: pendingFiles,
            editedFiles: editedFiles,
            unlandedCommits: unlandedCommits,
            worktrees: worktree.map { [$0] } ?? [])
    }

    /// The repository containing `file`, looked up from its nearest existing directory,
    /// since the file or its directory may have been deleted since.
    private func repository(containing file: String) -> Git.Repository? {
        var directory = (file as NSString).deletingLastPathComponent
        while !FileManager.default.fileExists(atPath: directory), directory != "/" {
            directory = (directory as NSString).deletingLastPathComponent
        }
        if let known = repositories[directory] { return known }

        let repository = Git.repository(containing: URL(fileURLWithPath: directory))
        repositories[directory] = repository
        return repository
    }

    /// `file` with symlinks in its existing directories resolved, the way git reports the
    /// repository root (`/tmp` is `/private/tmp`).
    private static func resolve(_ file: String) -> String {
        var existing = file
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing), existing != "/" {
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let resolved = realpath(existing, nil) else { return file }
        defer { free(resolved) }
        return ([String(cString: resolved)] + rest).joined(separator: "/")
    }
}
