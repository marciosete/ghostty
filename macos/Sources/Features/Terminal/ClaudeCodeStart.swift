import AppKit
import Foundation

/// Starts Claude Code in every new terminal, so a new session is a Claude Code session
/// without a shell startup file arranging it. The command is typed into the shell once
/// it is up, the way a restored session's `claude --resume` is, so `/exit` drops back
/// to the shell and the terminal stays.
///
/// In a git repository each session gets its own worktree, `claude -w`, so what it
/// changes is its own and the sidebar can show and land it. A session opened from a
/// worktree starts from the main checkout, so two sessions never share one. `claude -w`
/// refuses a folder whose trust dialog hasn't been accepted, and a plain `claude`,
/// which asks, follows it then.
///
/// The terminal's environment says it is one of these, so a shell startup file that
/// starts Claude Code itself can stand down.
@MainActor
final class ClaudeCodeStart {
    static let shared = ClaudeCodeStart()

    /// Set in a terminal this starts Claude Code in.
    static let environmentVariable = "MAGGIE_CLAUDE_CODE_START"

    private static let enabledKey = "ClaudeCodeStartsInNewSessions"

    private weak var menuItem: NSMenuItem?

    var isEnabled: Bool {
        didSet {
            UserDefaults.ghostty.set(isEnabled, forKey: Self.enabledKey)
            menuItem?.state = isEnabled ? .on : .off
        }
    }

    private init() {
        // On for Maggie, whose sessions are Claude Code sessions; off for a build that
        // isn't, which keeps Ghostty's terminals plain.
        isEnabled = UserDefaults.ghostty.object(forKey: Self.enabledKey) as? Bool ?? Maggie.isMaggie
    }

    // MARK: Surfaces

    /// Gives `config` the start command and the marker, unless it already has input
    /// (a restored session resuming) or this is off.
    func apply(to config: inout Ghostty.SurfaceConfiguration) {
        guard isEnabled, config.initialInput == nil else { return }
        config.initialInput = Self.command(in: config.workingDirectory) + "\n"
        config.environmentVariables[Self.environmentVariable] = "1"
    }

    /// The command for a terminal starting in `directory` (the shell's default when nil).
    nonisolated static func command(in directory: String?) -> String {
        guard let directory, let main = mainCheckout(of: directory) else { return "claude" }
        let here = URL(fileURLWithPath: directory).standardizedFileURL.path
        if URL(fileURLWithPath: main).standardizedFileURL.path == here {
            return "claude -w || claude"
        }
        return "(cd '\(main)' && claude -w) || claude"
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
        let item = NSMenuItem(title: "Start Claude Code in New Sessions", action: #selector(toggle(_:)), keyEquivalent: "")
        item.target = self
        item.state = isEnabled ? .on : .off
        item.setImageIfDesired(systemSymbolName: "sparkles")
        menu.insertItem(item, at: index)
        menuItem = item
    }

    @objc private func toggle(_ sender: Any?) {
        isEnabled.toggle()
    }
}
