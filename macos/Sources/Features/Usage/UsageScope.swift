import Foundation

/// Which usage the panel counts: the work part, the rest (your own projects), or all.
enum UsageScope: String, CaseIterable {
    case work
    case projects
    case all

    var title: String {
        switch self {
        case .work: return "Work"
        case .projects: return "Projects"
        case .all: return "All"
        }
    }
}

/// Tells work usage from the rest by the folder a session started in. Usage in a work
/// folder, or anywhere below one, is work, and everything else is your own projects.
///
/// Claude Code keeps a session's transcript in a folder named after the directory it
/// started in, with every character other than a letter or digit replaced by `-`, so
/// `/Users/me/projects/KIT` becomes `-Users-me-projects-KIT`. Transcripts are matched
/// by that folder, which also covers sessions whose transcripts Claude Code has since
/// deleted but whose usage is still cached. Sessions in a repository's worktrees
/// (`.claude/worktrees/…`) are below the repository, so they count with it.
///
/// Codex records its working directory in the transcript. Linked worktrees are matched
/// to their source checkout. Grok's sessions have no directory and count as projects.
struct UsageScopeFilter: Equatable {
    let scope: UsageScope

    /// Claude Code's folder names of the work folders.
    private let workFolderNames: [String]
    private let workDirectories: [String]

    init(scope: UsageScope, workFolders: [String]) {
        self.scope = scope
        workFolderNames = workFolders.map(Self.claudeFolderName(of:)).filter { $0.count > 1 }
        workDirectories = workFolders.map { (($0 as NSString).expandingTildeInPath as NSString).standardizingPath }
    }

    /// Whether the usage in the transcript at `path`, found under `sourceDirectory`, counts.
    func includes(path: String, in sourceDirectory: String, provider: UsageProvider, directory: String? = nil) -> Bool {
        guard scope != .all else { return true }
        let isWork: Bool
        switch provider {
        case .claude: isWork = isWorkTranscript(path: path, in: sourceDirectory)
        case .codex:
            isWork = directory.map { directory in
                workDirectories.contains { directory == $0 || directory.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            } ?? false
        case .grok: isWork = false
        }
        return scope == .work ? isWork : !isWork
    }

    /// Codex's managed worktrees live outside the source repository. Resolve their
    /// gitdir/commondir pointers while the checkout exists, then cache this directory
    /// with the usage so deleting the worktree doesn't change the report's scope.
    static func projectDirectory(for directory: String) -> String {
        let original = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        var current = original
        while current.path != "/" {
            let marker = current.appendingPathComponent(".git")
            if let data = try? Data(contentsOf: marker), data.count < 65_536,
               let text = String(data: data, encoding: .utf8), text.hasPrefix("gitdir: ") {
                let gitPath = String(text.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                let git = URL(fileURLWithPath: gitPath, isDirectory: true, relativeTo: current).standardizedFileURL
                if let commonText = try? String(contentsOf: git.appendingPathComponent("commondir"), encoding: .utf8) {
                    let common = commonText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !common.isEmpty else { break }
                    return URL(fileURLWithPath: common, isDirectory: true, relativeTo: git)
                        .standardizedFileURL.deletingLastPathComponent().path
                }
                break
            }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return original.path
    }

    private func isWorkTranscript(path: String, in sourceDirectory: String) -> Bool {
        let prefix = sourceDirectory.hasSuffix("/") ? sourceDirectory : sourceDirectory + "/"
        guard path.hasPrefix(prefix) else { return false }
        // The first folder under the projects directory names the session's folder, for
        // subagent transcripts in `<folder>/<session>/subagents/` too.
        guard let folder = path.dropFirst(prefix.count).split(separator: "/").first else { return false }
        return workFolderNames.contains { folder == $0 || folder.hasPrefix($0 + "-") }
    }

    /// The name Claude Code gives the transcript folder of sessions started in `directory`.
    static func claudeFolderName(of directory: String) -> String {
        var path = ((directory as NSString).expandingTildeInPath as NSString).standardizingPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }
}
