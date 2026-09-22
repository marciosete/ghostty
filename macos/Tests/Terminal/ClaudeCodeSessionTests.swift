import Foundation
import Testing
@testable import Ghostty

@Suite
struct ClaudeCodeSessionTests {
    private static let sessionID = "2f19b620-e06f-43d9-9cfe-fc93924c3c2d"
    private static let pid = 44848

    /// When the registry entry was written, in milliseconds since 1970.
    private static let startedAt: Double = 1_790_078_346_221
    private static let written = Date(timeIntervalSince1970: startedAt / 1000)

    /// Claude Code starts a moment before it registers.
    private static let processStarted = written.addingTimeInterval(-1.2)

    private static let session = ClaudeCodeSession(
        id: UUID(uuidString: sessionID)!,
        cwd: "/Users/me/project")

    /// A registry entry like the ones Claude Code writes to `sessions/<pid>.json`.
    private static func registry(
        pid: Int = pid,
        sessionID: String = sessionID,
        cwd: String = "/Users/me/project",
        startedAt: Double = startedAt,
        kind: String? = "interactive"
    ) throws -> Data {
        var entry: [String: Any] = [
            "pid": pid,
            "sessionId": sessionID,
            "cwd": cwd,
            "startedAt": startedAt,
            "name": "riverbed-demo",
            "status": "idle",
            "version": "2.1.278",
        ]
        entry["kind"] = kind
        return try JSONSerialization.data(withJSONObject: entry)
    }

    // MARK: Registry

    @Test func interactiveSession() throws {
        let found = ClaudeCodeSession.session(
            registry: try Self.registry(), pid: Self.pid, processStarted: Self.processStarted)
        #expect(found == Self.session)
    }

    @Test func otherPid() throws {
        let found = ClaudeCodeSession.session(
            registry: try Self.registry(pid: 98399), pid: Self.pid, processStarted: Self.processStarted)
        #expect(found == nil)
    }

    @Test func nonInteractiveKind() throws {
        let found = ClaudeCodeSession.session(
            registry: try Self.registry(kind: "sdk-cli"), pid: Self.pid, processStarted: Self.processStarted)
        #expect(found == nil)
    }

    /// Older versions of Claude Code don't write a kind.
    @Test func missingKind() throws {
        let found = ClaudeCodeSession.session(
            registry: try Self.registry(kind: nil), pid: Self.pid, processStarted: Self.processStarted)
        #expect(found == Self.session)
    }

    /// The session id is typed into a shell, so nothing but a UUID is accepted.
    @Test func sessionIDThatIsNotUUID() throws {
        let found = ClaudeCodeSession.session(
            registry: try Self.registry(sessionID: "\(Self.sessionID); rm -rf ~"),
            pid: Self.pid,
            processStarted: Self.processStarted)
        #expect(found == nil)
    }

    @Test func relativeCwd() throws {
        let found = ClaudeCodeSession.session(
            registry: try Self.registry(cwd: "projects/app"), pid: Self.pid, processStarted: Self.processStarted)
        #expect(found == nil)
    }

    /// A process that dies without cleaning up leaves its entry behind, and another
    /// program can get its pid. That program started after the entry was written.
    @Test func staleEntry() throws {
        let registry = try Self.registry()
        let reused = ClaudeCodeSession.session(
            registry: registry, pid: Self.pid, processStarted: Self.written.addingTimeInterval(5))
        #expect(reused == nil)

        // Clocks are read at different precisions, so a start within a second still counts.
        let sameTime = ClaudeCodeSession.session(
            registry: registry, pid: Self.pid, processStarted: Self.written.addingTimeInterval(0.5))
        #expect(sameTime == Self.session)
    }

    /// Reads a real Claude Code directory, with a registry entry for this test process, whose
    /// start time comes from the kernel.
    @Test func runningProcess() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("ClaudeCodeSessionTests-\(UUID().uuidString)")
        let sessions = directory.appendingPathComponent("sessions")
        let projects = directory.appendingPathComponent("projects")
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let pid = Int(getpid())
        let entry = sessions.appendingPathComponent("\(pid).json")
        try Self.registry(pid: pid, startedAt: Date().timeIntervalSince1970 * 1000).write(to: entry)

        // Claude Code writes the transcript with the first message. Until then there is
        // nothing to resume.
        #expect(ClaudeCodeSession.running(pid: pid, configDirectory: directory) == nil)

        let transcripts = projects.appendingPathComponent("-Users-me-project")
        try fileManager.createDirectory(at: transcripts, withIntermediateDirectories: true)
        let transcript = transcripts.appendingPathComponent("\(Self.sessionID).jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        #expect(ClaudeCodeSession.running(pid: pid, configDirectory: directory) == Self.session)

        // Folders of long paths are shortened, so the others are searched too.
        let shortened = projects.appendingPathComponent("-Users-me-pro-1a2b3c")
        try fileManager.createDirectory(at: shortened, withIntermediateDirectories: true)
        try fileManager.moveItem(at: transcript, to: shortened.appendingPathComponent("\(Self.sessionID).jsonl"))
        #expect(ClaudeCodeSession.running(pid: pid, configDirectory: directory) == Self.session)

        // Written before this process started, so it belonged to an earlier process with the same pid.
        try Self.registry(pid: pid, startedAt: 1_000_000).write(to: entry)
        #expect(ClaudeCodeSession.running(pid: pid, configDirectory: directory) == nil)

        #expect(ClaudeCodeSession.running(pid: pid + 1, configDirectory: directory) == nil)
    }

    @Test func resumeInput() {
        #expect(Self.session.resumeInput == "claude --resume 2f19b620-e06f-43d9-9cfe-fc93924c3c2d\n")
    }

    // MARK: Saved surfaces

    @Test func savedSurfaceWithSession() throws {
        let state = Ghostty.SurfaceView.RestorableState(
            pwd: "/Users/me/project/src",
            uuid: UUID(uuidString: "926F3F2A-824C-40C9-87CA-2CDCA4E11049"),
            title: "✳ riverbed-demo",
            isUserSetTitle: false,
            claudeCodeSession: Self.session)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(Ghostty.SurfaceView.RestorableState.self, from: data)

        #expect(decoded.claudeCodeSession == Self.session)
        #expect(decoded.pwd == "/Users/me/project/src")
        #expect(decoded.uuid == state.uuid)
        #expect(decoded.title == "✳ riverbed-demo")

        // The pane opens where Claude Code was started, since it looks for the session there.
        let config = decoded.surfaceConfiguration
        #expect(config.workingDirectory == "/Users/me/project")
        #expect(config.initialInput == "claude --resume 2f19b620-e06f-43d9-9cfe-fc93924c3c2d\n")
        #expect(config.command == nil)

        // Shell startup files that start Claude Code in every new terminal can skip it.
        #expect(config.environmentVariables == ["GHOSTTY_CLAUDE_CODE_RESUME": "2f19b620-e06f-43d9-9cfe-fc93924c3c2d"])
    }

    /// A surface saved by an earlier build.
    @Test func savedSurfaceWithoutSession() throws {
        let json = """
            {"isUserSetTitle":true,"pwd":"/Users/me/project","title":"notes","uuid":"926F3F2A-824C-40C9-87CA-2CDCA4E11049"}
            """
        let decoded = try JSONDecoder().decode(Ghostty.SurfaceView.RestorableState.self, from: Data(json.utf8))

        #expect(decoded.claudeCodeSession == nil)
        #expect(decoded.title == "notes")
        #expect(decoded.isUserSetTitle)

        let config = decoded.surfaceConfiguration
        #expect(config.workingDirectory == "/Users/me/project")
        #expect(config.initialInput == nil)
        #expect(config.environmentVariables.isEmpty)
    }

    /// A session that can't be read is dropped instead of failing the whole restore.
    @Test func savedSurfaceWithUnreadableSession() throws {
        let json = """
            {"claudeCodeSession":{"cwd":"project","id":"\(Self.sessionID)"},"isUserSetTitle":false,"pwd":"/Users/me/project","title":"✳ Claude Code","uuid":"926F3F2A-824C-40C9-87CA-2CDCA4E11049"}
            """
        let decoded = try JSONDecoder().decode(Ghostty.SurfaceView.RestorableState.self, from: Data(json.utf8))

        #expect(decoded.claudeCodeSession == nil)
        #expect(decoded.surfaceConfiguration.workingDirectory == "/Users/me/project")
        #expect(decoded.surfaceConfiguration.initialInput == nil)
    }
}
