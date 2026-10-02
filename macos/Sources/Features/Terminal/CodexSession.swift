import Darwin
import Foundation

/// A Codex session running in a terminal, the Codex counterpart of `ClaudeCodeSession`.
///
/// Codex keeps no registry of its processes. It does keep the session's rollout file,
/// `sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`, open for as long as it runs, so the
/// session of a process is read off the files it has open. That works for a resumed
/// session too, whose rollout is older than the process.
struct CodexSession: Codable, Equatable {
    /// The thread id, a UUID (version 7, so it starts with the time the session was
    /// created). Being a UUID, it is safe to type into a shell.
    let id: UUID

    /// The directory the session works in. Codex looks for the session from anywhere,
    /// but this is where the terminal opens again.
    let cwd: String

    init(id: UUID, cwd: String) {
        self.id = id
        self.cwd = cwd
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        cwd = try container.decode(String.self, forKey: .cwd)
        guard cwd.hasPrefix("/") else {
            throw DecodingError.dataCorruptedError(
                forKey: .cwd, in: container, debugDescription: "not an absolute path")
        }
    }

    // MARK: Running sessions

    /// The session of process `pid`, if it is Codex running interactively.
    static func running(pid: Int) -> CodexSession? {
        running(pid: pid, codexHome: codexHome)
    }

    static func running(pid: Int, codexHome: URL) -> CodexSession? {
        guard let pid = pid_t(exactly: pid), pid > 0 else { return nil }
        // Codex installed with npm is a node script that runs the real binary as its
        // child, so the terminal's foreground process is node.
        let candidates = [pid] + RunningProcess.children(pid)
        for candidate in candidates where RunningProcess.name(candidate) == "codex" {
            guard let rollout = RunningProcess.openFiles(candidate).first(where: { Self.isRollout($0, in: codexHome) }),
                  let header = Rollout.header(of: URL(fileURLWithPath: rollout)),
                  header.isInteractive else { continue }
            Self.remember(rollout: URL(fileURLWithPath: rollout), of: header.id)
            return CodexSession(id: header.id, cwd: header.cwd)
        }
        return nil
    }

    /// Where Codex writes the session, if it has started writing it. A session that
    /// hasn't been given a prompt yet has no rollout, and can't be resumed.
    var rollout: URL? {
        rollout(in: Self.codexHome)
    }

    func rollout(in codexHome: URL) -> URL? {
        if let known = Self.knownRollouts[id], FileManager.default.fileExists(atPath: known.path) {
            return known
        }
        guard let found = Self.findRollout(of: id, in: codexHome) else { return nil }
        Self.remember(rollout: found, of: id)
        return found
    }

    /// What the session is doing, from the end of its rollout: "busy" while a turn runs,
    /// "idle" between turns, nil before the first turn.
    var status: String? {
        rollout.flatMap(Rollout.status(of:))
    }

    /// The model the session is using, from its last turn.
    var model: String? {
        rollout.flatMap(Rollout.model(of:))
    }

    // MARK: Rollout files

    private static let rolloutPattern = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"^rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-([0-9a-fA-F-]{36})(_[0-9a-fA-F-]{36})?\.jsonl$"#)

    /// The thread id in a rollout's file name, `rollout-<time>-<id>.jsonl`, or
    /// `rollout-<time>-<id>_<rollout>.jsonl` for a rollout rewritten by a revert.
    static func threadID(ofRollout name: String) -> UUID? {
        let range = NSRange(name.startIndex..., in: name)
        guard let match = rolloutPattern.firstMatch(in: name, range: range),
              let idRange = Range(match.range(at: 1), in: name) else { return nil }
        return UUID(uuidString: String(name[idRange]))
    }

    /// The kernel reports a file's real path, so the home's symlinks are resolved too.
    private static func isRollout(_ path: String, in codexHome: URL) -> Bool {
        let sessions = codexHome.appendingPathComponent("sessions").standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(sessions + "/") else { return false }
        return threadID(ofRollout: (resolved as NSString).lastPathComponent) != nil
    }

    /// Rollouts found by thread id, so a session's file isn't searched for again. Read
    /// from several queues.
    private static var knownRolloutsStorage: [UUID: URL] = [:]
    private static let knownRolloutsLock = NSLock()

    private static var knownRollouts: [UUID: URL] {
        knownRolloutsLock.lock()
        defer { knownRolloutsLock.unlock() }
        return knownRolloutsStorage
    }

    private static func remember(rollout: URL, of id: UUID) {
        knownRolloutsLock.lock()
        defer { knownRolloutsLock.unlock() }
        knownRolloutsStorage[id] = rollout
    }

    /// The rollout of thread `id`. Rollouts are filed by the local date they were
    /// created, which the id, a version 7 UUID, carries, give or take a day for the
    /// time zone and a session created at midnight. The newest file is the live one when
    /// a revert has written more than one.
    static func findRollout(of id: UUID, in codexHome: URL) -> URL? {
        let fileManager = FileManager.default
        let sessions = codexHome.appendingPathComponent("sessions")
        var days: [URL] = []
        if let created = creationDate(ofUUIDv7: id) {
            let calendar = Calendar.current
            for offset in [0, -1, 1] {
                guard let day = calendar.date(byAdding: .day, value: offset, to: created) else { continue }
                let parts = calendar.dateComponents([.year, .month, .day], from: day)
                guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { continue }
                days.append(sessions
                    .appendingPathComponent(String(year))
                    .appendingPathComponent(String(format: "%02d", month))
                    .appendingPathComponent(String(format: "%02d", dayOfMonth)))
            }
        }

        var matches: [(url: URL, modified: Date)] = []
        for day in days {
            let names = (try? fileManager.contentsOfDirectory(atPath: day.path)) ?? []
            for name in names where threadID(ofRollout: name) == id {
                let url = day.appendingPathComponent(name)
                let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                matches.append((url, modified ?? .distantPast))
            }
        }
        return matches.max { $0.modified < $1.modified }?.url
    }

    /// The time a version 7 UUID was made, from its first 48 bits, in milliseconds.
    static func creationDate(ofUUIDv7 id: UUID) -> Date? {
        let bytes = id.uuid
        guard bytes.6 >> 4 == 7 else { return nil }
        var ms: UInt64 = 0
        for byte in [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5] {
            ms = ms << 8 | UInt64(byte)
        }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    /// Where Codex keeps its data. An app opened from the Dock doesn't see the variables
    /// of a shell profile, so the default is what usually applies.
    static var codexHome: URL {
        let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespaces)
        let path = configured.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
        return URL(fileURLWithPath: path)
    }

    // MARK: Reading rollouts

    /// Reads what a tab needs from a rollout: its header, and the last turn's state and
    /// model, which are near its end. A rollout can be many megabytes, so the end is read
    /// backwards, a chunk at a time, until what is wanted is found.
    enum Rollout {
        /// The first line of a rollout, `session_meta`.
        struct Header: Equatable {
            let id: UUID
            let cwd: String

            /// "cli" for a session in a terminal; "exec" for `codex exec`, "vscode" and
            /// others for sessions of other apps.
            let source: String?

            /// A session that can be resumed in a terminal.
            var isInteractive: Bool { source == nil || source == "cli" }
        }

        /// A rollout's first line is written whole, and small.
        private static let headerLength = 64 << 10

        /// How much of the end is read at a time.
        private static let tailChunk = 256 << 10

        /// Headers read, by file. The first line never changes.
        private static var headers: [URL: Header] = [:]
        private static let headersLock = NSLock()

        static func header(of url: URL) -> Header? {
            headersLock.lock()
            if let known = headers[url] {
                headersLock.unlock()
                return known
            }
            headersLock.unlock()

            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: headerLength),
                  let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
            guard let header = header(line: data[data.startIndex..<newline]) else { return nil }

            headersLock.lock()
            headers[url] = header
            headersLock.unlock()
            return header
        }

        static func header(line: Data) -> Header? {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  entry["type"] as? String == "session_meta",
                  let payload = entry["payload"] as? [String: Any],
                  let id = ((payload["id"] ?? payload["session_id"]) as? String).flatMap(UUID.init(uuidString:)),
                  let cwd = payload["cwd"] as? String, cwd.hasPrefix("/") else { return nil }
            return Header(id: id, cwd: cwd, source: payload["source"] as? String)
        }

        /// The events that say whether a turn is running.
        private static let turnEvents: [(needle: String, status: String)] = [
            ("\"type\":\"task_started\"", "busy"),
            ("\"type\":\"task_complete\"", "idle"),
            ("\"type\":\"turn_aborted\"", "idle"),
        ]

        /// "busy" while the last turn started hasn't finished, "idle" once it has, nil for
        /// a session without a turn yet.
        static func status(of url: URL) -> String? {
            var found: (offset: Int, status: String)?
            scanBackwards(url) { chunk, base in
                for event in turnEvents {
                    guard let range = chunk.range(of: Data(event.needle.utf8), options: .backwards) else { continue }
                    let offset = base + range.lowerBound - chunk.startIndex
                    if let current = found, current.offset >= offset { continue }
                    found = (offset, event.status)
                }
                return found != nil
            }
            return found?.status
        }

        /// The model of the last turn, from its `turn_context`.
        static func model(of url: URL) -> String? {
            let needle = Data("\"type\":\"turn_context\"".utf8)
            var model: String?
            scanBackwards(url) { chunk, _ in
                var searchEnd = chunk.endIndex
                while let range = chunk[chunk.startIndex..<searchEnd].range(of: needle, options: .backwards) {
                    let lineStart = chunk[chunk.startIndex..<range.lowerBound].lastIndex(of: UInt8(ascii: "\n"))
                        .map { chunk.index(after: $0) } ?? chunk.startIndex
                    let lineEnd = chunk[range.upperBound...].firstIndex(of: UInt8(ascii: "\n")) ?? chunk.endIndex
                    if let entry = try? JSONSerialization.jsonObject(with: chunk[lineStart..<lineEnd]) as? [String: Any],
                       entry["type"] as? String == "turn_context",
                       let payload = entry["payload"] as? [String: Any],
                       let name = payload["model"] as? String, !name.isEmpty {
                        model = name
                        return true
                    }
                    searchEnd = range.lowerBound
                }
                return false
            }
            return model
        }

        /// Calls `body` with chunks of the file from its end back to its start, each
        /// overlapping the one before by a line's worth, until `body` returns true.
        private static func scanBackwards(_ url: URL, _ body: (Data, Int) -> Bool) {
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let size = try? handle.seekToEnd() else { return }
            defer { try? handle.close() }

            // Chunks overlap by this much, so an event split across two is seen whole.
            let overlap = 1024
            var end = Int(size)
            while end > 0 {
                let start = max(0, end - tailChunk)
                try? handle.seek(toOffset: UInt64(start))
                guard let chunk = try? handle.read(upToCount: end - start), !chunk.isEmpty else { return }
                if body(chunk, start) || start == 0 { return }
                end = start + overlap
            }
        }
    }
}
