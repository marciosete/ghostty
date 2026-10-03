import Darwin
import Foundation
import SQLite3

/// A Codex session running in a terminal, the Codex counterpart of `ClaudeCodeSession`.
///
/// A local Codex process owns its session's rollout or writer lock. A shared daemon
/// owns several terminals' sessions, so its files cannot identify a terminal's session.
struct CodexSession: Codable, Equatable {
    /// The thread id, a UUID (version 7, so it starts with the time the session was
    /// created). Being a UUID, it is safe to type into a shell.
    let id: UUID

    /// The directory the session works in. Codex looks for the session from anywhere,
    /// but this is where the terminal opens again.
    let cwd: String

    /// Custom homes are saved so reopening a session uses the same Codex history.
    private let sessionHome: URL?
    private let processID: Int?
    private enum CodingKeys: String, CodingKey { case id, cwd, codexHome }

    init(id: UUID, cwd: String, codexHome: URL? = nil, pid: Int? = nil) {
        self.id = id
        self.cwd = cwd
        self.sessionHome = codexHome
        self.processID = pid
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        cwd = try container.decode(String.self, forKey: .cwd)
        let home = try container.decodeIfPresent(String.self, forKey: .codexHome)
        guard home == nil || home?.hasPrefix("/") == true else {
            throw DecodingError.dataCorruptedError(
                forKey: .codexHome, in: container, debugDescription: "not an absolute path")
        }
        sessionHome = home.map(URL.init(fileURLWithPath:))
        processID = nil
        guard cwd.hasPrefix("/") else {
            throw DecodingError.dataCorruptedError(
                forKey: .cwd, in: container, debugDescription: "not an absolute path")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(cwd, forKey: .cwd)
        if let sessionHome {
            try container.encode(sessionHome.path, forKey: .codexHome)
        }
    }

    var resumeEnvironment: [String: String] {
        sessionHome.map { ["CODEX_HOME": $0.path] } ?? [:]
    }

    private var terminalTitle: TerminalTitle? {
        guard let processID, let title = Self.liveTitle(pid: processID), title.matches(id) else { return nil }
        return title
    }

    static func == (lhs: CodexSession, rhs: CodexSession) -> Bool {
        lhs.id == rhs.id && lhs.cwd == rhs.cwd
    }

    // MARK: Running sessions

    /// The session of process `pid`, if it is Codex running interactively.
    static func running(pid: Int) -> CodexSession? {
        running(pid: pid, restrictedHome: nil)
    }

    static func running(pid: Int, codexHome: URL) -> CodexSession? {
        running(pid: pid, restrictedHome: codexHome)
    }

    private static func running(pid: Int, restrictedHome: URL?) -> CodexSession? {
        let foregroundPID = pid
        let title = liveTitle(pid: pid)
        guard let pid = pid_t(exactly: pid), pid > 0 else { return nil }
        // npm adds a node wrapper, and a local app server may add another process.
        // Never descend into the shared daemon: it can be a child of the first TUI
        // that launched it, while serving unrelated terminals too.
        var candidates = [pid]
        var visited: Set<pid_t> = []
        while !candidates.isEmpty {
            let candidate = candidates.removeFirst()
            guard visited.insert(candidate).inserted else { continue }
            let name = RunningProcess.name(candidate)
            let processArguments = RunningProcess.arguments(candidate)
            // If a Codex process's arguments are unreadable, we cannot establish
            // that it isn't the shared daemon.
            guard name != "codex" || processArguments != nil else { continue }
            let arguments = processArguments ?? []
            guard !arguments.contains("--managed-daemon") else { continue }
            candidates.append(contentsOf: RunningProcess.children(candidate))
            guard name == "codex" else { continue }

            let files = RunningProcess.openFiles(candidate)
            // The terminal's shell may set CODEX_HOME without the app inheriting it.
            // Owned paths identify that home without reading the process environment.
            let homes = restrictedHome.map { [$0] } ?? Array(Set(files.compactMap(home(ofOwnedFile:))))
            var sessions: [UUID: CodexSession] = [:]
            for home in homes {
                var rollouts = files.filter { isRollout($0, in: home) }.map(URL.init(fileURLWithPath:))
                rollouts += files.compactMap { threadID(ofWriterLock: $0, in: home) }
                    .compactMap { findRollout(of: $0, in: home) }
                for rollout in rollouts {
                    guard let header = Rollout.header(of: rollout), header.isInteractive,
                          title == nil || title?.matches(header.id) == true else { continue }
                    remember(rollout: rollout, of: header.id, in: home)
                    let cwd = State.cwd(of: header.id, in: home) ?? header.cwd
                    sessions[header.id] = CodexSession(id: header.id, cwd: cwd, codexHome: home, pid: foregroundPID)
                }
            }
            // A TUI can keep several threads loaded. Without an identifying title,
            // assigning the first open file would show another thread's information.
            if sessions.count == 1 { return sessions.values.first }
        }
        return nil
    }

    /// Where Codex writes the session, if it has started writing it. A session that
    /// hasn't been given a prompt yet has no rollout, and can't be resumed.
    var rollout: URL? {
        rollout(in: sessionHome ?? Self.codexHome)
    }

    func rollout(in codexHome: URL) -> URL? {
        let key = RolloutKey(id: id, home: codexHome)
        if let known = Self.knownRollouts[key], FileManager.default.fileExists(atPath: known.path) {
            return known
        }
        guard let found = Self.findRollout(of: id, in: codexHome) else { return nil }
        Self.remember(rollout: found, of: id, in: codexHome)
        return found
    }

    /// What the session is doing, from the end of its rollout: "busy" while a turn runs,
    /// "idle" between turns, nil before the first turn.
    var status: String? {
        terminalTitle?.status ?? rollout.flatMap(Rollout.status(of:))
    }

    /// Codex's selected model, or the last turn's model in older versions. Checking
    /// the database first also avoids scanning paginated history without turn contexts.
    var model: String? {
        terminalTitle?.model ?? State.model(of: id, in: sessionHome ?? Self.codexHome) ?? rollout.flatMap(Rollout.model(of:))
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

    private static func threadID(ofWriterLock path: String, in codexHome: URL) -> UUID? {
        let directory = codexHome.appendingPathComponent("thread-writer-locks")
            .standardizedFileURL.resolvingSymlinksInPath()
        let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.deletingLastPathComponent() == directory, file.pathExtension == "lock" else { return nil }
        return UUID(uuidString: file.deletingPathExtension().lastPathComponent)
    }

    static func home(ofOwnedFile path: String) -> URL? {
        let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let parent = file.deletingLastPathComponent()
        if parent.lastPathComponent == "thread-writer-locks", file.pathExtension == "lock",
           UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
            return parent.deletingLastPathComponent()
        }
        guard threadID(ofRollout: file.lastPathComponent) != nil else { return nil }
        let sessions = parent.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard sessions.lastPathComponent == "sessions" else { return nil }
        return sessions.deletingLastPathComponent()
    }

    private struct RolloutKey: Hashable {
        let id: UUID
        let home: URL

        init(id: UUID, home: URL) {
            self.id = id
            self.home = home.standardizedFileURL.resolvingSymlinksInPath()
        }
    }

    /// Rollouts found by thread id, so a session's file isn't searched for again. Read
    /// from several queues.
    private static var knownRolloutsStorage: [RolloutKey: URL] = [:]
    private static let knownRolloutsLock = NSLock()

    private static var knownRollouts: [RolloutKey: URL] {
        knownRolloutsLock.lock()
        defer { knownRolloutsLock.unlock() }
        return knownRolloutsStorage
    }

    private static func remember(rollout: URL, of id: UUID, in codexHome: URL) {
        knownRolloutsLock.lock()
        defer { knownRolloutsLock.unlock() }
        knownRolloutsStorage[RolloutKey(id: id, home: codexHome)] = rollout
    }

    /// The rollout of thread `id`. Rollouts are filed by the local date they were
    /// created, which the id, a version 7 UUID, carries, give or take a day for the
    /// time zone and a session created at midnight. The newest file is the live one when
    /// a revert has written more than one.
    static func findRollout(of id: UUID, in codexHome: URL) -> URL? {
        let fileManager = FileManager.default
        if let path = State.rollout(of: id, in: codexHome),
           isRollout(path, in: codexHome),
           threadID(ofRollout: (path as NSString).lastPathComponent) == id,
           fileManager.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
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

    // MARK: Paginated history metadata

    /// Exact thread lookups only. Opening read-only never creates or migrates Codex's
    /// database, and an unavailable database/column simply leaves the metadata unknown.
    enum State {
        static func model(of id: UUID, in home: URL) -> String? {
            value("model", of: id, in: home)
        }

        static func rollout(of id: UUID, in home: URL) -> String? {
            value("rollout_path", of: id, in: home)
        }

        static func cwd(of id: UUID, in home: URL) -> String? {
            guard let path = value("cwd", of: id, in: home), path.hasPrefix("/") else { return nil }
            return path
        }

        private static func value(_ column: String, of id: UUID, in home: URL) -> String? {
            var database: OpaquePointer?
            let result = sqlite3_open_v2(
                home.appendingPathComponent("state_5.sqlite").path,
                &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
            defer { sqlite3_close(database) }
            guard result == SQLITE_OK else { return nil }

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, "SELECT \(column) FROM threads WHERE id = ? LIMIT 1", -1,
                                    &statement, nil) == SQLITE_OK else { return nil }
            return id.uuidString.lowercased().withCString { identifier in
                guard sqlite3_bind_text(statement, 1, identifier, -1, nil) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_ROW,
                      let value = sqlite3_column_text(statement, 0) else { return nil }
                let text = String(cString: value)
                return text.isEmpty ? nil : text
            }
        }
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

            /// New TUI app-server sessions use "vscode" with originator "codex-tui".
            /// A structured source identifies a subagent, not a missing source.
            let source: String?
            let originator: String?
            let isSubagent: Bool

            /// A session that can be resumed in a terminal.
            var isInteractive: Bool {
                !isSubagent && (source == nil || source == "cli" ||
                    (source == "vscode" && originator == "codex-tui"))
            }
        }

        /// Session metadata can include large instructions, so read through its newline.
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
            var data = Data()
            while let chunk = try? handle.read(upToCount: headerLength), !chunk.isEmpty {
                data.append(chunk)
                if data.contains(UInt8(ascii: "\n")) { break }
            }
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
                  let header = header(line: data[data.startIndex..<newline]) else { return nil }

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
            return Header(
                id: id, cwd: cwd, source: payload["source"] as? String,
                originator: payload["originator"] as? String,
                isSubagent: payload["source"] is [String: Any])
        }

        /// "busy" while the last turn started hasn't finished, "idle" once it has, nil for
        /// a session without a turn yet.
        static func status(of url: URL) -> String? {
            var status: String?
            scanBackwards(url) { line in
                guard line.range(of: Data("\"event_msg\"".utf8)) != nil,
                      let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      entry["type"] as? String == "event_msg",
                      let payload = entry["payload"] as? [String: Any] else { return false }
                switch payload["type"] as? String {
                case "task_started", "turn_started": status = "busy"
                case "task_complete", "turn_complete", "turn_aborted": status = "idle"
                default: break
                }
                return status != nil
            }
            return status
        }

        /// The model of the last turn, from its `turn_context`.
        static func model(of url: URL) -> String? {
            let needle = Data("\"turn_context\"".utf8)
            var model: String?
            scanBackwards(url) { line in
                guard line.range(of: needle) != nil,
                      let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      entry["type"] as? String == "turn_context",
                      let payload = entry["payload"] as? [String: Any],
                      let name = payload["model"] as? String, !name.isEmpty else { return false }
                model = name
                return true
            }
            return model
        }

        /// Reads whole JSONL records backwards, including records spanning chunks.
        /// Parsing the envelope avoids interpreting tool output as session events.
        private static func scanBackwards(_ url: URL, _ body: (Data) -> Bool) {
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let size = try? handle.seekToEnd() else { return }
            defer { try? handle.close() }

            var end = Int(size)
            var partial = Data()
            while end > 0 {
                let start = max(0, end - tailChunk)
                try? handle.seek(toOffset: UInt64(start))
                guard var chunk = try? handle.read(upToCount: end - start), !chunk.isEmpty else { return }
                chunk.append(partial)
                let lines = chunk.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
                let whole = start == 0 ? lines[...] : lines.dropFirst()
                for line in whole.reversed() where !line.isEmpty {
                    if body(Data(line)) { return }
                }
                partial = start == 0 ? Data() : Data(lines.first ?? Data.SubSequence())
                end = start
            }
        }
    }
}
