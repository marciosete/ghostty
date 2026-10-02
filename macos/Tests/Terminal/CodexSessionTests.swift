import Foundation
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
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: binary)
            let process = Process()
            process.executableURL = binary
            process.arguments = ["30"]
            process.standardInput = try FileHandle(forReadingFrom: rollout)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            defer { process.terminate() }

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

    @Test func resumeInput() {
        let session = AgentSession.codex(CodexSession(id: Self.threadID, cwd: "/Users/me/project"))
        #expect(session.resumeInput == "codex resume 01a0b160-4a3f-76f3-8ebb-6c2151615b9a\n")
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
    }
}
