import AppKit
import Foundation
import OSLog

/// Opt-in snapshots of the context Codex records locally. Unlike Claude's request
/// proxy, this leaves the API connection alone and does not claim to capture a request.
/// UI state is main-actor confined, snapshots are serial-queue confined, and the
/// cross-queue enable flag is protected by `lock`.
final class CodexContextCapture: @unchecked Sendable {
    static let shared = CodexContextCapture()

    static var defaultDirectory: URL {
        SystemPromptCapture.defaultDirectory.deletingLastPathComponent()
            .appendingPathComponent("Codex Context", isDirectory: true)
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty", category: "codex-context-capture")

    let directory: URL
    private(set) var isEnabled = false
    private var timer: Timer?
    private var reading = false

    private struct Terminal {
        weak var surface: Ghostty.SurfaceView?
    }

    /// Only terminals opened with capture enabled are eligible, matching request capture.
    private var terminals: [ObjectIdentifier: Terminal] = [:]
    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.codex-context-capture", qos: .utility)
    private let lock = NSLock()
    private var saving = false

    private struct Stamp: Equatable {
        let modified: Date?
        let size: UInt64?
        let model: String?
    }

    /// Only accessed on `queue`.
    private var captured: [URL: Stamp] = [:]

    init(directory: URL = CodexContextCapture.defaultDirectory) {
        self.directory = directory
    }

    @MainActor
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        lock.withLock { saving = enabled }
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    @MainActor
    func track(_ surface: Ghostty.SurfaceView) {
        guard isEnabled else { return }
        terminals[ObjectIdentifier(surface)] = Terminal(surface: surface)
        poll()
    }

    @MainActor
    private func poll() {
        guard isEnabled, !reading else { return }
        terminals = terminals.filter { $0.value.surface != nil }
        let pids = Set(terminals.values.compactMap { $0.surface?.surfaceModel?.foregroundPID })
        guard !pids.isEmpty else { return }
        reading = true
        queue.async { [weak self] in
            guard let self else { return }
            defer { DispatchQueue.main.async { self.reading = false } }
            guard self.lock.withLock({ self.saving }) else { return }
            for pid in pids {
                guard let session = CodexSession.running(pid: pid), let rollout = session.rollout,
                      self.lock.withLock({ self.saving }) else { continue }
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: rollout.path)
                    let model = session.model
                    let stamp = Stamp(
                        modified: attributes[.modificationDate] as? Date,
                        size: (attributes[.size] as? NSNumber)?.uint64Value,
                        model: model)
                    guard self.captured[rollout] != stamp else { continue }
                    let data = try Data(contentsOf: rollout)
                    guard self.lock.withLock({ self.saving }) else { return }
                    try CaptureFolder.sync(
                        Self.files(rollout: data, session: session, model: model),
                        into: self.directory.appendingPathComponent(session.id.uuidString.lowercased()))
                    self.captured[rollout] = stamp
                } catch {
                    Self.logger.error("couldn't save Codex context: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// The source history remains byte-for-byte intact. The filtered file keeps each
    /// context/history record intact too, including fields this version does not know.
    static func files(rollout: Data, session: CodexSession, model: String?) -> [String: Data] {
        let contextTypes: Set<String> = [
            "session_meta", "turn_context", "response_item", "compacted", "world_state", "retained_context",
        ]
        var context = Data()
        var recordCount = 0
        for line in rollout.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = entry["type"] as? String else { continue }
            let settings = type == "event_msg" &&
                (entry["payload"] as? [String: Any])?["type"] as? String == "thread_settings_applied"
            guard contextTypes.contains(type) || settings else { continue }
            context.append(line)
            context.append(UInt8(ascii: "\n"))
            recordCount += 1
        }
        let metadata: [String: Any] = [
            "capture_kind": "codex_saved_session_context",
            "session_id": session.id.uuidString.lowercased(),
            "cwd": session.cwd,
            "model": model as Any? ?? NSNull(),
            "context_records": recordCount,
        ]
        let readme = """
            # Codex session context

            This is a snapshot of Codex's saved local session, updated while capture is enabled.

            - `rollout.jsonl` preserves the original session history as read from disk.
            - `context.jsonl` contains the original session metadata, turn context, response items,
              compaction records, world state, retained context, and applied thread settings,
              without rewriting their fields.
            - `session.json` identifies the session, working directory, and selected model.

            This is not an exact API request. Codex can assemble additional instructions and tool
            definitions in memory, compact history, or omit records from its saved history. Those
            details, live network traffic, and request headers are not reconstructed here. A final
            rollout line may be incomplete if Codex was writing it during the snapshot.

            Session: \(session.id.uuidString.lowercased())
            Working directory: \(session.cwd)
            Model: \(model ?? "not recorded")

            """
        return [
            "00-README.md": Data(readme.utf8),
            "rollout.jsonl": rollout,
            "context.jsonl": context,
            "session.json": (try? JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])) ?? Data(),
        ]
    }

    @MainActor
    func revealInFinder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}
