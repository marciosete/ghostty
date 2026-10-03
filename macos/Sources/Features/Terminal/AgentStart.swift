import AppKit
import Combine
import Foundation

/// Starts the chosen coding agent, Claude Code or Codex, in every new terminal, so a new
/// session is an agent session without a shell startup file arranging it. The command is
/// typed into the shell at its first prompt, the way a restored session's resume command
/// is, so `/exit` drops back to the shell and the terminal stays. A startup file that
/// starts an agent itself never sees the command: the core holds it for the prompt and
/// drops it when the prompt is late (see `input` in `Config.zig`).
///
/// In a git repository each session gets its own worktree (`claude -w`, `codex
/// --worktree`), so what it changes is its own and the sidebar can show and land it. A
/// session opened from a worktree starts from the main checkout, so two sessions never
/// share one. `claude -w` refuses a folder whose trust dialog hasn't been accepted, and a
/// plain start, which asks, follows it then.
///
/// The terminal's environment says it is one of these, and which agent, so a shell
/// startup file that starts an agent itself can stand down.
@MainActor
final class AgentStart: ObservableObject {
    static let shared = AgentStart()

    /// Set to "1" in a terminal this starts an agent in, or that resumes one. The name
    /// is from when Claude Code was the only agent; shell startup files check it.
    nonisolated static let environmentVariable = "MAGGIE_CLAUDE_CODE_START"

    /// Set to the agent's name, `claude` or `codex`, next to `environmentVariable`.
    nonisolated static let agentEnvironmentVariable = "MAGGIE_AGENT"

    private static let enabledKey = "ClaudeCodeStartsInNewSessions"

    private weak var menuItem: NSMenuItem?

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.ghostty.set(isEnabled, forKey: Self.enabledKey)
            updateMenuItem()
        }
    }

    /// The agent started, from Settings: the primary of the enabled ones, if any.
    var agent: CodingAgent? {
        CodingAgentSettings.shared.primary
    }

    private init() {
        // On for Maggie, whose sessions are agent sessions; off for a build that isn't,
        // which keeps Ghostty's terminals plain.
        isEnabled = UserDefaults.ghostty.object(forKey: Self.enabledKey) as? Bool ?? Maggie.isMaggie
    }

    // MARK: Surfaces

    /// Gives `config` the start command and the marker, unless it already has input
    /// (a restored session resuming) or this is off.
    func apply(to config: inout Ghostty.SurfaceConfiguration) {
        guard isEnabled, let agent, config.initialInput == nil else { return }
        config.initialInput = Self.command(for: agent, in: config.workingDirectory) + "\n"
        config.environmentVariables[Self.environmentVariable] = "1"
        config.environmentVariables[Self.agentEnvironmentVariable] = agent.rawValue
    }

    /// The command for a terminal starting `agent` in `directory` (the shell's default
    /// when nil).
    nonisolated static func command(for agent: CodingAgent, in directory: String?) -> String {
        guard let directory else {
            // Claude's registry identifies the foreground process directly. Keep its
            // plain launch when the directory is unknown instead of adding a wrapper.
            return agent == .codex ? commandInShellDirectory(for: agent) : agent.launchCommand
        }
        guard let main = mainCheckout(of: directory) else { return agent.launchCommand }
        let here = URL(fileURLWithPath: directory).standardizedFileURL.path
        if URL(fileURLWithPath: main).standardizedFileURL.path == here {
            return "\(agent.worktreeCommand) || \(agent.launchCommand)"
        }
        return "(cd \(AgentHandoff.shellQuoted(main)) && \(agent.worktreeCommand)) || \(agent.launchCommand)"
    }

    /// The first terminal can inherit its directory from Ghostty's configuration or
    /// the shell profile after this command is prepared. Resolve Git in that shell's
    /// actual directory instead of treating an unspecified directory as non-repository.
    /// A POSIX shell keeps this independent of the user's interactive shell syntax.
    nonisolated private static func commandInShellDirectory(for agent: CodingAgent) -> String {
        let script = [
            "maggie_common=$(/usr/bin/git rev-parse --path-format=absolute --git-common-dir 2>/dev/null);",
            "if [ -n \"$maggie_common\" ]; then",
            "case \"$maggie_common\" in */.git) maggie_main=${maggie_common%/.git} ;; " +
                "*) maggie_main=$(/usr/bin/git rev-parse --show-toplevel 2>/dev/null) ;; esac;",
            "if [ -n \"$maggie_main\" ]; then",
            "(cd \"$maggie_main\" && \(agent.worktreeCommand)) && exit 0;",
            "fi;",
            "fi;",
            "exec \(agent.launchCommand)",
        ].joined(separator: " ")
        return "/bin/sh -c \(AgentHandoff.shellQuoted(script))"
    }

    /// The main checkout of the repository `directory` is in: the worktree the others
    /// hang off, or `directory`'s own if it isn't a worktree. Nil outside a repository.
    nonisolated static func mainCheckout(of directory: String) -> String? {
        guard let common = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory) else {
            return nil
        }
        let commonURL = URL(fileURLWithPath: common)
        if commonURL.lastPathComponent == ".git" {
            return commonURL.deletingLastPathComponent().path
        }
        // A bare or unusual layout: the top level of this checkout is the best there is.
        return git(["rev-parse", "--show-toplevel"], in: directory)
    }

    nonisolated private static func git(_ arguments: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
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
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    // MARK: Menu

    func installMenuItem(in menu: NSMenu, at index: Int) {
        let item = NSMenuItem(title: "", action: #selector(toggle(_:)), keyEquivalent: "")
        item.target = self
        item.setImageIfDesired(systemSymbolName: "sparkles")
        menu.insertItem(item, at: index)
        menuItem = item
        updateMenuItem()
    }

    /// The menu item names the agent Settings chose, so it is called again when that
    /// changes. With no agent enabled there is nothing to start, and it says so.
    func updateMenuItem() {
        menuItem?.title = "Start \(agent?.displayName ?? "an Agent") in New Sessions"
        menuItem?.state = isEnabled ? .on : .off
        menuItem?.isEnabled = agent != nil
    }

    @objc private func toggle(_ sender: Any?) {
        isEnabled.toggle()
    }
}
