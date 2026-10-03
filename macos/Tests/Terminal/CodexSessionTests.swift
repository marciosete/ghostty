import Darwin
import Foundation
import SQLite3
import Testing
@testable import Ghostty

@Suite
struct CodexSessionTests {
    private static let threadID = UUID(uuidString: "01a0b160-4a3f-76f3-8ebb-6c2151615b9a")!

    /// A rollout file in a Codex home made for the test, removed after `body`.
    private func withRollout(_ lines: [String], _ body: (_ codexHome: URL, _ rollout: URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("maggie-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        // Filed under the local date the thread was created, as Codex files it.
        let created = CodexSession.creationDate(ofUUIDv7: Self.threadID)!
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: created)
        let day = home
            .appendingPathComponent("sessions")
            .appendingPathComponent(String(parts.year!))
            .appendingPathComponent(String(format: "%02d", parts.month!))
            .appendingPathComponent(String(format: "%02d", parts.day!))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let rollout = day.appendingPathComponent("rollout-2026-09-18T07-57-52-\(Self.threadID.uuidString.lowercased()).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: rollout)

        try body(home, rollout)
    }

    private static let meta = """
        {"timestamp":"2026-09-17T21:57:52.831Z","type":"session_meta","payload":{"id":"01a0b160-4a3f-76f3-8ebb-6c2151615b9a","timestamp":"2026-09-17T21:57:52.831Z","cwd":"/Users/me/project","originator":"codex_cli_rs","cli_version":"0.155.1","source":"cli"}}
        """

    private static func turnContext(model: String) -> String {
        """
        {"timestamp":"2026-09-17T21:58:00.000Z","type":"turn_context","payload":{"cwd":"/Users/me/project","model":"\(model)","approval_policy":"on-request"}}
        """
    }

    private static let started = """
        {"timestamp":"2026-09-17T21:58:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
        """
    private static let completed = """
        {"timestamp":"2026-09-17T21:58:09.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"Done."}}
        """

    private func writeState(in home: URL, rollout: URL, model: String?, cwd: String? = nil) throws {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        try #require(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &database) == SQLITE_OK)
        try #require(sqlite3_exec(database,
                                 "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, model TEXT, cwd TEXT)",
                                 nil, nil, nil) == SQLITE_OK)
        func quoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }
        let values = [quoted(Self.threadID.uuidString.lowercased()), quoted(rollout.path),
                      model.map(quoted) ?? "NULL", cwd.map(quoted) ?? "NULL"]
        try #require(sqlite3_exec(database, "INSERT INTO threads VALUES (\(values.joined(separator: ",")))",
                                 nil, nil, nil) == SQLITE_OK)
    }

    /// A fake Codex process with one or two session files held open.
    private func withProcess(
        in home: URL,
        input: URL,
        output: URL? = nil,
        _ body: (Process) throws -> Void
    ) throws {
        let binary = home.appendingPathComponent("codex")
        try CodexTestProcess.copyExecutable("/bin/sleep", to: binary)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["30"]
        process.standardInput = try FileHandle(forReadingFrom: input)
        process.standardOutput = try output.map(FileHandle.init(forReadingFrom:)) ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        try body(process)
    }

    // MARK: Files

    @Test func threadIDIsReadOffTheFileName() {
        #expect(CodexSession.threadID(ofRollout: "rollout-2026-09-18T07-57-52-01a0b160-4a3f-76f3-8ebb-6c2151615b9a.jsonl") == Self.threadID)
        // A rollout rewritten by a revert carries its own id after the thread's.
        #expect(CodexSession.threadID(ofRollout: "rollout-2026-09-18T07-57-52-01a0b160-4a3f-76f3-8ebb-6c2151615b9a_01a0b161-0000-7000-8000-000000000000.jsonl") == Self.threadID)
        #expect(CodexSession.threadID(ofRollout: "rollout-2025-04-20-0ecc1b67-d4c6-4e27-a2ff-40c449d4e1ab.json") == nil)
        #expect(CodexSession.threadID(ofRollout: "notes.jsonl") == nil)
    }

    @Test func aVersion7UUIDCarriesItsCreationTime() {
        let created = CodexSession.creationDate(ofUUIDv7: Self.threadID)
        #expect(created?.timeIntervalSince1970 == 1_789_682_272.831)
        // Version 4 ids carry no time.
        #expect(CodexSession.creationDate(ofUUIDv7: UUID(uuidString: "2f19b620-e06f-43d9-9cfe-fc93924c3c2d")!) == nil)
    }

    @Test func findsASavedSessionsRolloutByItsID() throws {
        try withRollout([Self.meta]) { home, rollout in
            let session = CodexSession(id: Self.threadID, cwd: "/Users/me/project")
            #expect(session.rollout(in: home) == rollout)
            #expect(CodexSession.findRollout(of: UUID(), in: home) == nil)
        }
    }

    // MARK: Reading

    @Test func readsTheHeader() {
        let header = CodexSession.Rollout.header(line: Data(Self.meta.utf8))
        #expect(header?.id == Self.threadID)
        #expect(header?.cwd == "/Users/me/project")
        #expect(header?.isInteractive == true)

        let exec = Self.meta.replacingOccurrences(of: "\"source\":\"cli\"", with: "\"source\":\"exec\"")
        #expect(CodexSession.Rollout.header(line: Data(exec.utf8))?.isInteractive == false)
        #expect(CodexSession.Rollout.header(line: Data(Self.started.utf8)) == nil)
    }

    @Test func identifiesTerminalSessionsWithoutClaimingOtherClientsOrSubagents() {
        let vscode = Self.meta.replacingOccurrences(of: "\"source\":\"cli\"", with: "\"source\":\"vscode\"")
        #expect(CodexSession.Rollout.header(line: Data(vscode.utf8))?.isInteractive == false)
        let tui = vscode.replacingOccurrences(of: "codex_cli_rs", with: "codex-tui")
        #expect(CodexSession.Rollout.header(line: Data(tui.utf8))?.isInteractive == true)
        let subagent = tui.replacingOccurrences(
            of: "\"source\":\"vscode\"", with: "\"source\":{\"subagent\":{\"other\":\"guardian\"}}")
        #expect(CodexSession.Rollout.header(line: Data(subagent.utf8))?.isInteractive == false)
        let legacy = Self.meta.replacingOccurrences(of: ",\"source\":\"cli\"", with: "")
        #expect(CodexSession.Rollout.header(line: Data(legacy.utf8))?.isInteractive == true)
    }

    @Test func statusFollowsTheLastTurnEvent() throws {
        try withRollout([Self.meta, Self.turnContext(model: "gpt-5-codex")], { _, rollout in
            #expect(CodexSession.Rollout.status(of: rollout) == nil)
        })
        try withRollout([Self.meta, Self.turnContext(model: "gpt-5-codex"), Self.started], { _, rollout in
            #expect(CodexSession.Rollout.status(of: rollout) == "busy")
        })
        try withRollout([Self.meta, Self.turnContext(model: "gpt-5-codex"), Self.started, Self.completed], { _, rollout in
            #expect(CodexSession.Rollout.status(of: rollout) == "idle")
        })
        // A second turn after the first finished.
        try withRollout([Self.meta, Self.started, Self.completed, Self.turnContext(model: "gpt-5-codex"), Self.started], { _, rollout in
            #expect(CodexSession.Rollout.status(of: rollout) == "busy")
        })
    }

    @Test func modelIsTheLastTurns() throws {
        try withRollout([Self.meta, Self.turnContext(model: "gpt-5-codex"), Self.started, Self.completed, Self.turnContext(model: "gpt-6-astra"), Self.started], { _, rollout in
            #expect(CodexSession.Rollout.model(of: rollout) == "gpt-6-astra")
        })
        try withRollout([Self.meta], { _, rollout in
            #expect(CodexSession.Rollout.model(of: rollout) == nil)
        })
    }

    @Test func statusIsFoundBehindALongTail() throws {
        // A big tool output after the last turn event, longer than one chunk read.
        let filler = """
            {"timestamp":"2026-09-17T21:58:05.000Z","type":"response_item","payload":{"type":"function_call_output","output":"\(String(repeating: "x", count: 600_000))"}}
            """
        try withRollout([Self.meta, Self.turnContext(model: "gpt-5-codex"), Self.started, filler], { _, rollout in
            #expect(CodexSession.Rollout.status(of: rollout) == "busy")
            #expect(CodexSession.Rollout.model(of: rollout) == "gpt-5-codex")
        })
    }

    @Test func readsLargeSessionInstructions() throws {
        let meta = Self.meta.replacingOccurrences(of: "\"cli_version\":", with: "\"instructions\":\"\(String(repeating: "x", count: 150_000))\",\"cli_version\":")
        try withRollout([meta]) { _, rollout in
            #expect(CodexSession.Rollout.header(of: rollout)?.id == Self.threadID)
        }
    }

    @Test func rolloutStateRequiresAnActualEventEnvelope() throws {
        let misleading = #"{"type":"response_item","payload":{"type":"function_call_output","output":{"type":"event_msg","payload":{"type":"task_complete"}}}}"#
        try withRollout([Self.meta, Self.started, misleading]) { _, rollout in
            #expect(CodexSession.Rollout.status(of: rollout) == "busy")
        }
        let aborted = #"{"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#
        try withRollout([Self.meta, Self.started, aborted]) { _, rollout in
            #expect(CodexSession.Rollout.status(of: rollout) == "idle")
        }
        // Current protocol aliases and events crossing the reverse-reader boundary.
        let completed = #"{"type":"event_msg","payload":{"type":"turn_complete","last_agent_message":""# +
            String(repeating: "x", count: 600_000) + #""}}"#
        try withRollout([Self.meta, Self.started, completed]) { _, rollout in
            #expect(CodexSession.Rollout.status(of: rollout) == "idle")
        }
    }

    // MARK: Live titles

    @Test func readsTheInstalledCLIsPrepromptTitles() throws {
        // Captured from Codex 0.160.0 with the configured title items, without a prompt.
        let first = try #require(CodexSession.TerminalTitle("codex | codex-session-probe | Ready"))
        #expect(first.model == "codex-session-probe")
        #expect(first.status == "idle")
        #expect(first.threadPrefix == nil)
        #expect(first.displayTitle == "Codex")
        #expect(first.glyph == "✳")
        let configured = try #require(CodexSession.TerminalTitle(
            "codex | codex-session-probe | Ready | 01a0ff3e-497b-7c50-872b-383c4... | 01a0ff3e-497b-7c50-872b-383c458b8a9f"))
        #expect(configured.matches(UUID(uuidString: "01a0ff3e-497b-7c50-872b-383c458b8a9f")!))
        #expect(!configured.matches(Self.threadID))
        #expect(configured.displayTitle == "Codex")
    }

    @Test func titleDistinguishesUserAttentionFromBackgroundCommands() throws {
        let thread = "01a0b160-4a3f-76f3-8ebb-6c215..."
        for state in ["Starting", "Working", "Thinking", "Waiting"] {
            let title = try #require(CodexSession.TerminalTitle("⠋ codex | gpt-6-astra | \(state) | \(thread) ⠙ | Fix colours ⠋"))
            #expect(title.status == "busy")
            #expect(title.displayTitle == "Fix colours")
            #expect(title.matches(Self.threadID))
            #expect(title.glyph == "◐")
        }
        // The glyph turns with Codex's spinner, as Claude Code's does, without the
        // title counting as changed.
        let turning = try #require(CodexSession.TerminalTitle("⠹ codex | gpt-6-astra | Working | \(thread) | Fix colours"))
        #expect(turning.glyph == "◒")
        #expect(turning == CodexSession.TerminalTitle("⠋ codex | gpt-6-astra | Working | \(thread) | Fix colours"))
        for activity in ["[ ! ] Action Required", "[ . ] Action Required", "● [ ! ] Action Required"] {
            let title = try #require(CodexSession.TerminalTitle("\(activity) | codex | gpt-6-astra | \(thread) | Fix colours"))
            #expect(title.status == "waiting")
            #expect(title.model == "gpt-6-astra")
            #expect(title.glyph == "✳")
        }
        #expect(CodexSession.TerminalTitle("codex | gpt-6-astra | Unknown") == nil)
        #expect(CodexSession.TerminalTitle("project | gpt-6-astra | Ready") == nil)
        #expect(CodexSession.TerminalTitle("codex | gpt-6-astra | Ready | not-a-thread | project") == nil)
    }

    @Test func liveTitlesSelectTheCurrentThreadAndClearOnExit() throws {
        try withRollout([Self.meta, Self.started]) { home, rollout in
            let secondID = UUID(uuidString: "01a0b161-0000-7000-8000-000000000000")!
            let second = rollout.deletingLastPathComponent().appendingPathComponent(
                "rollout-2026-09-18T07-57-52-\(secondID.uuidString.lowercased()).jsonl")
            let meta = Self.meta.replacingOccurrences(of: Self.threadID.uuidString.lowercased(), with: secondID.uuidString.lowercased())
            try Data((meta + "\n").utf8).write(to: second)
            try withProcess(in: home, input: rollout, output: second) { process in
                let pid = Int(process.processIdentifier)
                defer { CodexSession.forget(pid: pid) }
                #expect(CodexSession.running(pid: pid) == nil)
                #expect(CodexSession.observe(title: "codex | selected-model | Ready | \(Self.threadID) | First", pid: pid) == "✳ First")
                let first = try #require(CodexSession.running(pid: pid))
                #expect(first.id == Self.threadID)
                #expect(first.model == "selected-model")
                #expect(first.status == "idle")
                #expect(first.resumeEnvironment["CODEX_HOME"] == home.resolvingSymlinksInPath().path)

                // /resume and /new keep the same process alive while the selected thread changes.
                #expect(CodexSession.observe(title: "[ ! ] Action Required | codex | another-model | \(secondID) | Second", pid: pid) == "✳ Second")
                let resumed = try #require(CodexSession.running(pid: pid))
                #expect(resumed.id == secondID)
                #expect(resumed.status == "waiting")
                #expect(resumed.model == "another-model")
                #expect(first.status == "busy") // A stale session cannot take the other thread's live status.
                #expect(CodexSession.observe(title: "codex | another-model | Ready", pid: pid) == "✳ Codex")
                #expect(CodexSession.running(pid: pid) == nil)
                #expect(CodexSession.liveStatus(pid: pid) == "idle")

                #expect(CodexSession.observe(title: "shell in project", pid: pid) == nil)
                #expect(CodexSession.liveModel(pid: pid) == nil)
                #expect(CodexSession.observe(title: "codex | selected-model | Ready", pid: pid) == "✳ Codex")
                process.terminate()
                process.waitUntilExit()
                #expect(CodexSession.liveStatus(pid: pid) == nil)
            }
        }
    }

    @Test func paginatedHistoryReadsTheModelFromItsOwnStateDatabase() throws {
        try withRollout([Self.meta, Self.started, Self.completed]) { home, rollout in
            try writeState(in: home, rollout: rollout, model: "gpt-6-astra")
            let session = CodexSession(id: Self.threadID, cwd: "/Users/me/project", codexHome: home)
            #expect(session.model == "gpt-6-astra")
            #expect(CodexSession.State.model(of: UUID(), in: home) == nil)

            // Runtime metadata doesn't change the persisted session identity.
            let encoded = try JSONEncoder().encode(session)
            let values = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(Set(values.keys) == ["id", "cwd", "codexHome"])
            let decoded = try JSONDecoder().decode(CodexSession.self, from: encoded)
            #expect(decoded == session)
            #expect(decoded.resumeEnvironment["CODEX_HOME"] == home.path)
            #expect(decoded.model == "gpt-6-astra")

            // Homes can contain copies of the same thread without sharing caches.
            try withRollout([Self.meta]) { otherHome, otherRollout in
                try writeState(in: otherHome, rollout: otherRollout, model: "gpt-5-codex")
                let other = CodexSession(id: Self.threadID, cwd: session.cwd, codexHome: otherHome)
                #expect(other.model == "gpt-5-codex")
                #expect(other.rollout == otherRollout)
                #expect(session.rollout == rollout)
                #expect(session.model == "gpt-6-astra")
            }
        }
    }

    @Test func currentModelTakesPrecedenceOverLegacyTurnContext() throws {
        try withRollout([Self.meta, Self.turnContext(model: "gpt-5-codex")]) { home, rollout in
            try writeState(in: home, rollout: rollout, model: "gpt-6-astra")
            let session = CodexSession(id: Self.threadID, cwd: "/Users/me/project", codexHome: home)
            #expect(session.model == "gpt-6-astra")
        }
        try withRollout([Self.meta, Self.turnContext(model: "gpt-5-codex")]) { home, _ in
            let session = CodexSession(id: Self.threadID, cwd: "/Users/me/project", codexHome: home)
            #expect(session.model == "gpt-5-codex")
        }
    }

    @Test func missingMetadataStaysUnknown() throws {
        try withRollout([Self.meta]) { home, rollout in
            let session = CodexSession(id: Self.threadID, cwd: "/Users/me/project", codexHome: home)
            #expect(session.model == nil)
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("state_5.sqlite").path))
            try writeState(in: home, rollout: rollout, model: nil)
            #expect(session.model == nil)
        }
    }

    @Test func stateDatabaseLocatesTheExactRolloutOutsideTheUUIDDate() throws {
        try withRollout([Self.meta]) { home, rollout in
            let directory = home.appendingPathComponent("sessions/2026/10/03")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let moved = directory.appendingPathComponent(rollout.lastPathComponent)
            try FileManager.default.moveItem(at: rollout, to: moved)
            #expect(CodexSession.findRollout(of: Self.threadID, in: home) == nil)
            try writeState(in: home, rollout: moved, model: nil)
            #expect(CodexSession.findRollout(of: Self.threadID, in: home) == moved)
        }
    }

    // MARK: Edits

    @Test func editsAreTheFileChangeItems() {
        let tracker = ClaudeCodeEditTracker(agent: .codex)
        let change = """
            {"timestamp":"2026-09-17T21:58:05.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","id":"e1","changes":{"/Users/me/project/src/b.swift":{"type":"update"},"/Users/me/project/src/a.swift":{"type":"add"}}}}}
            """
        tracker.consume(line: Data(change.utf8))
        tracker.consume(line: Data(change.utf8))
        tracker.consume(line: Data(Self.started.utf8))
        #expect(tracker.files == ["/Users/me/project/src/a.swift", "/Users/me/project/src/b.swift"])
    }

    // MARK: Sessions

    /// A process named `codex` with the rollout open (here, as its input).
    @Test func aRunningSessionIsFoundByTheRolloutItHoldsOpen() throws {
        try withRollout([Self.meta, Self.started]) { home, rollout in
            let binary = home.appendingPathComponent("codex")
            try CodexTestProcess.copyExecutable("/bin/sleep", to: binary)
            let process = Process()
            process.executableURL = binary
            process.arguments = ["30"]
            process.standardInput = try FileHandle(forReadingFrom: rollout)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            defer { if process.isRunning { process.terminate() } }

            let pid = Int(process.processIdentifier)
            #expect(RunningProcess.name(process.processIdentifier) == "codex")
            let session = CodexSession.running(pid: pid, codexHome: home)
            #expect(session == CodexSession(id: Self.threadID, cwd: "/Users/me/project"))
            // The kernel names the file by its real path.
            #expect(session?.rollout(in: home)?.resolvingSymlinksInPath() == rollout.resolvingSymlinksInPath())
            // Another Codex home doesn't claim it.
            #expect(CodexSession.running(pid: pid, codexHome: home.appendingPathComponent("other")) == nil)
        }
    }

    @Test func runningSessionSkipsASubagentsRollout() throws {
        try withRollout([Self.meta]) { home, rollout in
            let subagent = rollout.deletingLastPathComponent().appendingPathComponent(
                "rollout-2026-09-18T07-57-52-01a0b161-0000-7000-8000-000000000000.jsonl")
            let meta = Self.meta.replacingOccurrences(
                of: "\"source\":\"cli\"", with: "\"source\":{\"subagent\":{\"other\":\"guardian\"}}")
            try Data((meta + "\n").utf8).write(to: subagent)
            try withProcess(in: home, input: subagent, output: rollout) { process in
                let session = CodexSession.running(pid: Int(process.processIdentifier), codexHome: home)
                #expect(session?.rollout?.resolvingSymlinksInPath() == rollout.resolvingSymlinksInPath())
            }
        }
    }

    @Test func runningSessionCanOwnOnlyAWriterLock() throws {
        try withRollout([Self.meta, Self.started]) { home, rollout in
            try writeState(in: home, rollout: rollout, model: "gpt-6-astra")
            let directory = home.appendingPathComponent("thread-writer-locks")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let lock = directory.appendingPathComponent("\(Self.threadID.uuidString.lowercased()).lock")
            try Data().write(to: lock)
            try withProcess(in: home, input: lock) { process in
                let session = CodexSession.running(pid: Int(process.processIdentifier), codexHome: home)
                #expect(session == CodexSession(id: Self.threadID, cwd: "/Users/me/project"))
                #expect(session?.model == "gpt-6-astra")
                #expect(session?.status == "busy")
                #expect(CodexSession.running(pid: Int(process.processIdentifier),
                                            codexHome: home.appendingPathComponent("other")) == nil)
            }
        }
    }

    @Test func resumedDirectoryUsesCurrentMetadataWithAValidatedFallback() throws {
        for cwd in ["/Users/me/new-worktree", "relative"] {
            try withRollout([Self.meta]) { home, rollout in
                try writeState(in: home, rollout: rollout, model: nil, cwd: cwd)
                try withProcess(in: home, input: rollout) { process in
                    let session = try #require(CodexSession.running(pid: Int(process.processIdentifier)))
                    #expect(session.cwd == (cwd.hasPrefix("/") ? cwd : "/Users/me/project"))
                }
            }
        }
    }

    @Test func findsCodexBehindMoreThanOneWrapper() throws {
        try withRollout([Self.meta]) { home, rollout in
            let binary = home.appendingPathComponent("codex")
            try CodexTestProcess.copyExecutable("/bin/sleep", to: binary)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                "-c", "exec 3<&0; /bin/sh -c '\"$1\" 30 <&3 & wait' nested \"$1\" <&3 & wait", "wrapper", binary.path,
            ]
            process.standardInput = try FileHandle(forReadingFrom: rollout)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            defer {
                for child in RunningProcess.children(process.processIdentifier) {
                    for grandchild in RunningProcess.children(child) { kill(grandchild, SIGTERM) }
                    kill(child, SIGTERM)
                }
                if process.isRunning { process.terminate() }
            }

            var session: CodexSession?
            let deadline = Date().addingTimeInterval(2)
            repeat {
                session = CodexSession.running(pid: Int(process.processIdentifier), codexHome: home)
                if session != nil { break }
                Thread.sleep(forTimeInterval: 0.01)
            } while Date() < deadline
            #expect(session == CodexSession(id: Self.threadID, cwd: "/Users/me/project"))
        }
    }

    @Test func sharedDaemonDoesNotClaimItsLaunchersSession() throws {
        try withRollout([Self.meta]) { home, rollout in
            let binary = home.appendingPathComponent("codex")
            try CodexTestProcess.copyExecutable("/bin/sh", to: binary)
            let process = Process()
            process.executableURL = binary
            // The shell accepts the daemon marker as its argument zero, keeping a
            // fake daemon alive with a rollout that belongs to another terminal.
            process.arguments = ["-c", "sleep 30 & wait", "--managed-daemon"]
            process.standardInput = try FileHandle(forReadingFrom: rollout)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            defer {
                for child in RunningProcess.children(process.processIdentifier) { kill(child, SIGTERM) }
                if process.isRunning { process.terminate() }
            }
            #expect(CodexSession.running(pid: Int(process.processIdentifier), codexHome: home) == nil)
        }
    }

    @Test func resumeInput() {
        let session = AgentSession.codex(CodexSession(id: Self.threadID, cwd: "/Users/me/project"))
        #expect(session.resumeInput == "\(CodingAgent.codex.launchCommand) resume 01a0b160-4a3f-76f3-8ebb-6c2151615b9a\n")
        #expect(session.resumeEnvironment["MAGGIE_AGENT"] == "codex")
        #expect(session.resumeEnvironment["MAGGIE_CLAUDE_CODE_START"] == "1")
    }

    @Test func savedSessionsRoundTrip() throws {
        let session = AgentSession.codex(CodexSession(id: Self.threadID, cwd: "/Users/me/project"))
        let data = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(AgentSession.self, from: data) == session)

        // A relative directory can't be opened again.
        let bad = Data(#"{"agent":"codex","codex":{"id":"01a0b160-4a3f-76f3-8ebb-6c2151615b9a","cwd":"project"}}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(AgentSession.self, from: bad) }
        let badHome = Data(#"{"id":"01a0b160-4a3f-76f3-8ebb-6c2151615b9a","cwd":"/project","codexHome":"relative"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(CodexSession.self, from: badHome) }
    }
}

enum CodexTestProcess {
    /// A copied Apple platform binary can be killed after exec when its original
    /// signature is checked. An ad-hoc signature makes the renamed fixture stable.
    static func copyExecutable(_ source: String, to destination: URL) throws {
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: destination)
        let signing = Process()
        signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signing.arguments = ["--force", "--sign", "-", destination.path]
        signing.standardOutput = FileHandle.nullDevice
        signing.standardError = FileHandle.nullDevice
        try signing.run()
        signing.waitUntilExit()
        try #require(signing.terminationStatus == 0)
    }
}
