import AppKit
import Combine
import Foundation

/// A coding agent Maggie can run in its terminals: started in new sessions, found in
/// running ones, and resumed in restored ones.
enum CodingAgent: String, CaseIterable, Codable {
    case claude
    case codex

    /// The name shown in menus and settings.
    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// The command that starts the agent.
    var command: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        }
    }

    /// The command that starts the agent in its own worktree of the repository it is
    /// started in. Both agents keep their worktrees as linked worktrees of the main
    /// checkout, which is what the sidebar lands.
    var worktreeCommand: String {
        switch self {
        case .claude: return "claude -w"
        case .codex: return "codex --worktree"
        }
    }

    /// The command that resumes session `id` of the agent.
    func resumeCommand(_ id: UUID) -> String {
        switch self {
        case .claude: return "claude --resume \(id.uuidString.lowercased())"
        case .codex: return "codex resume \(id.uuidString.lowercased())"
        }
    }

    /// Where the agent's command is looked for, besides `PATH`: the places its installer
    /// puts it, which an app opened from the Dock doesn't have on its `PATH`.
    var installDirectories: [String] {
        let home = NSHomeDirectory() as NSString
        switch self {
        case .claude:
            return [home.appendingPathComponent(".local/bin"), home.appendingPathComponent(".claude/local")]
        case .codex:
            return [home.appendingPathComponent(".local/bin"), home.appendingPathComponent(".codex/bin")]
        }
    }

    /// The `PATH` the agents are looked for on: the login shell's, which has what the
    /// user's profile adds (Homebrew, a node version manager, the agents' own bins),
    /// then the app's own, then the install directories.
    static var searchPath: [String] {
        var directories = loginShellPath ?? []
        directories += ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for agent in allCases { directories += agent.installDirectories }
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var seen: Set<String> = []
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The `PATH` of an interactive login shell, read once. An app opened from the Dock
    /// doesn't see the variables of a shell profile, and Codex installed with npm is a
    /// script that needs `node` on its `PATH`. The shell is given no terminal, so a
    /// profile that starts an agent in Maggie's terminals doesn't start one here.
    private static let loginShellPath: [String]? = {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printenv PATH"]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM_PROGRAM"] = nil
        environment["TERM"] = "dumb"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        do {
            try process.run()
        } catch {
            return nil
        }
        // A profile that hangs mustn't hang the app. The output is one line, which fits
        // the pipe, so the shell exits without being read first.
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: .now() + .seconds(5)) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return path.isEmpty ? nil : path.split(separator: ":").map(String.init)
    }()

    /// The agent's command, if it is installed.
    func executableURL() -> URL? {
        let fileManager = FileManager.default
        for directory in Self.searchPath {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(command)
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// The version the agent's command reports, or nil when it isn't installed or
    /// doesn't answer quickly.
    func installedVersion() -> String? {
        guard let executable = executableURL() else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "NO_COLOR": "1",
            "PATH": Self.searchPath.joined(separator: ":"),
        ]) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Which agent Maggie starts in new sessions. Settings has the switch; the View menu
/// shows which one is on.
@MainActor
final class CodingAgentSettings: ObservableObject {
    static let shared = CodingAgentSettings()

    private static let agentKey = "CodingAgent"

    @Published var agent: CodingAgent {
        didSet {
            UserDefaults.ghostty.set(agent.rawValue, forKey: Self.agentKey)
            AgentStart.shared.updateMenuItem()
        }
    }

    private init() {
        agent = UserDefaults.ghostty.string(forKey: Self.agentKey).flatMap(CodingAgent.init(rawValue:)) ?? .claude
    }
}

/// A coding agent's session running in a terminal, whichever agent it is. It is saved
/// with the terminal and resumed when the terminal opens again, so each terminal gets its
/// own session back.
enum AgentSession: Equatable {
    case claude(ClaudeCodeSession)
    case codex(CodexSession)

    var agent: CodingAgent {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        }
    }

    var id: UUID {
        switch self {
        case .claude(let session): return session.id
        case .codex(let session): return session.id
        }
    }

    /// The directory the agent was started in, or moved to for its worktree.
    var cwd: String {
        switch self {
        case .claude(let session): return session.cwd
        case .codex(let session): return session.cwd
        }
    }

    /// The file the agent writes the session to, if it has one yet.
    var transcript: URL? {
        switch self {
        case .claude(let session): return session.transcript
        case .codex(let session): return session.rollout
        }
    }

    /// The command typed into the shell to resume the session. Typing it, rather than
    /// running it as the terminal's command, leaves the shell open when the agent exits.
    var resumeInput: String {
        agent.resumeCommand(id) + "\n"
    }

    /// The environment of a terminal that resumes the session. Shell startup files that
    /// start an agent in every new terminal need to skip it there, or the resume command
    /// would be typed into that agent instead of the shell.
    var resumeEnvironment: [String: String] {
        var environment = [
            AgentStart.environmentVariable: "1",
            AgentStart.agentEnvironmentVariable: agent.rawValue,
        ]
        if case .claude(let session) = self {
            environment.merge(session.resumeEnvironment) { _, new in new }
        }
        return environment
    }

    /// The session of process `pid`, if it is an agent running interactively in a session
    /// that can be resumed.
    static func running(pid: Int) -> AgentSession? {
        if let session = ClaudeCodeSession.running(pid: pid) { return .claude(session) }
        if let session = CodexSession.running(pid: pid) { return .codex(session) }
        return nil
    }

    /// The directory the agent of process `pid` runs in, if it is one.
    static func directory(ofRunning pid: Int) -> String? {
        ClaudeCodeSession.directory(ofRunning: pid) ?? CodexSession.running(pid: pid)?.cwd
    }
}

extension AgentSession: Codable {
    private enum CodingKeys: String, CodingKey {
        case agent
        case claude
        case codex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(CodingAgent.self, forKey: .agent) {
        case .claude: self = .claude(try container.decode(ClaudeCodeSession.self, forKey: .claude))
        case .codex: self = .codex(try container.decode(CodexSession.self, forKey: .codex))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agent, forKey: .agent)
        switch self {
        case .claude(let session): try container.encode(session, forKey: .claude)
        case .codex(let session): try container.encode(session, forKey: .codex)
        }
    }
}
