import Foundation

/// A file with changes in a git repository, as reported by `git status`.
struct GitFileChange: Hashable {
    enum Kind: Hashable {
        case modified
        case added
        case deleted
        case renamed
        case copied
        case typeChanged
        case untracked
        case conflicted

        init(code: Character) {
            switch code {
            case "A": self = .added
            case "D": self = .deleted
            case "R": self = .renamed
            case "C": self = .copied
            case "T": self = .typeChanged
            default: self = .modified
            }
        }
    }

    /// The path relative to the repository root.
    let path: String

    /// For renames and copies, the path the file came from.
    let originalPath: String?

    let kind: Kind
}

/// The state of a repository's working tree and index.
struct GitStatus: Equatable {
    /// The checked out branch, or nil when HEAD is detached.
    var branch: String?

    /// The checked out commit, or nil before the first commit.
    var commit: String?

    /// The branch's upstream (e.g. `origin/main`), if it has one.
    var upstream: String?

    /// Commits on the branch that aren't on its upstream, i.e. to push.
    var ahead = 0

    /// Commits on the upstream that aren't on the branch, i.e. to pull. This is only
    /// as current as the last fetch.
    var behind = 0

    /// Changes in the index, i.e. what will be committed.
    var staged: [GitFileChange] = []

    /// Changes in the working tree that aren't staged, including untracked files.
    var unstaged: [GitFileChange] = []
}

enum Git {
    struct Repository: Hashable {
        /// The top level directory of the working tree.
        let root: URL

        /// The repository's git directory (usually `<root>/.git`).
        let gitDir: URL
    }

    /// The git executable. GUI apps get a minimal PATH, so look in the usual places.
    static let executableURL: URL? = {
        ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }()

    /// Finds the repository containing `directory`, or nil if it isn't in one.
    static func repository(containing directory: URL) -> Repository? {
        guard let output = run(["rev-parse", "--show-toplevel", "--absolute-git-dir"], in: directory) else {
            return nil
        }

        let lines = output.split(separator: "\n")
        guard lines.count >= 2 else { return nil }
        return Repository(root: realPath(String(lines[0])), gitDir: realPath(String(lines[1])))
    }

    /// Resolves symlinks the same way file system events report paths. Unlike
    /// `resolvingSymlinksInPath`, this keeps the `/private` prefix of `/tmp` and `/var`.
    private static func realPath(_ path: String) -> URL {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// Reads the status of a repository. Returns nil if git fails.
    static func status(of repository: Repository) -> GitStatus? {
        guard let output = run(
            ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"],
            in: repository.root
        ) else { return nil }

        return parseStatus(output)
    }

    /// Parses `git status --porcelain=v2 --branch -z`.
    static func parseStatus(_ output: String) -> GitStatus {
        var status = GitStatus()
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: false)

        func add(xy: Substring, path: String, originalPath: String?) {
            guard let index = xy.first, let worktree = xy.dropFirst().first else { return }
            if index != "." {
                status.staged.append(.init(path: path, originalPath: originalPath, kind: .init(code: index)))
            }
            if worktree != "." {
                status.unstaged.append(.init(path: path, originalPath: nil, kind: .init(code: worktree)))
            }
        }

        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            i += 1

            switch token.first {
            case "#":
                // # branch.oid <commit> | (initial)
                // # branch.head <branch> | (detached)
                // # branch.upstream <upstream>
                // # branch.ab +<ahead> -<behind>
                let fields = token.split(separator: " ", maxSplits: 2)
                guard fields.count == 3 else { continue }
                let value = String(fields[2])
                switch fields[1] {
                case "branch.oid":
                    status.commit = value == "(initial)" ? nil : value
                case "branch.head":
                    status.branch = value == "(detached)" ? nil : value
                case "branch.upstream":
                    status.upstream = value
                case "branch.ab":
                    for count in value.split(separator: " ") {
                        if count.hasPrefix("+") { status.ahead = Int(count.dropFirst()) ?? 0 }
                        if count.hasPrefix("-") { status.behind = Int(count.dropFirst()) ?? 0 }
                    }
                default:
                    break
                }

            case "1":
                // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                let fields = token.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                add(xy: fields[1], path: String(fields[8]), originalPath: nil)

            case "2":
                // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>, then <origPath>
                let fields = token.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                let originalPath = i < tokens.count ? String(tokens[i]) : nil
                i += 1
                guard fields.count == 10 else { continue }
                add(xy: fields[1], path: String(fields[9]), originalPath: originalPath)

            case "u":
                // u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
                let fields = token.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                status.unstaged.append(.init(path: String(fields[10]), originalPath: nil, kind: .conflicted))

            case "?":
                status.unstaged.append(.init(path: String(token.dropFirst(2)), originalPath: nil, kind: .untracked))

            default:
                break
            }
        }

        return status
    }

    /// How many of `files` (absolute paths inside `repository`) have changes that aren't
    /// committed: modified, staged, added or deleted. Returns nil if git fails.
    static func uncommittedFileCount(_ files: [String], in repository: Repository) -> Int? {
        let root = repository.root.path + "/"
        let pathspecs = files.compactMap { file -> String? in
            guard file.hasPrefix(root) else { return nil }
            // Literal, so a name with glob characters only matches itself.
            return ":(literal)" + file.dropFirst(root.count)
        }
        guard !pathspecs.isEmpty else { return 0 }

        guard let output = run(
            ["status", "--porcelain", "-z", "--untracked-files=all", "--"] + pathspecs,
            in: repository.root
        ) else { return nil }
        return changedPaths(porcelain: output).count
    }

    /// The paths in `git status --porcelain -z` output. A rename or copy is followed by the
    /// path it came from, which isn't counted again.
    static func changedPaths(porcelain output: String) -> Set<String> {
        var paths: Set<String> = []
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let field = fields.next() {
            guard field.count > 3 else { continue }
            paths.insert(String(field.dropFirst(3)))
            if field.first == "R" || field.first == "C" {
                _ = fields.next()
            }
        }
        return paths
    }

    // MARK: Worktrees

    /// A linked worktree (`git worktree add`), such as the one `claude --worktree` gives a
    /// session, and the main checkout its branch lands on.
    struct Worktree: Hashable {
        /// The top level directory of the worktree.
        let root: URL

        /// The worktree's own git directory (`<main>/.git/worktrees/<name>`), which holds
        /// its HEAD and index.
        let gitDir: URL

        /// The git directory shared by every worktree of the repository.
        let commonDir: URL

        /// The worktree's branch, or nil when HEAD is detached.
        let branch: String?

        /// The main checkout of the repository.
        let mainRoot: URL

        /// The branch checked out in the main checkout, which the worktree's commits land
        /// on, or nil when it is detached.
        let baseBranch: String?
    }

    /// The linked worktree containing `directory`, or nil if it is in the main checkout or
    /// not in a repository.
    static func linkedWorktree(containing directory: URL) -> Worktree? {
        guard let output = run(
            ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"],
            in: directory
        ) else { return nil }
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.count >= 3 else { return nil }

        let gitDir = realPath(lines[1])
        let commonDir = realPath(lines[2])
        guard gitDir != commonDir else { return nil }

        guard let list = run(["worktree", "list", "--porcelain", "-z"], in: directory),
              let main = parseWorktreeList(list).first else { return nil }
        let branch = run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Worktree(
            root: realPath(lines[0]),
            gitDir: gitDir,
            commonDir: commonDir,
            branch: branch.flatMap { $0.isEmpty ? nil : $0 },
            mainRoot: realPath(main.path),
            baseBranch: main.branch)
    }

    /// The worktrees in `git worktree list --porcelain -z`, main checkout first, with
    /// their branches as short names.
    static func parseWorktreeList(_ output: String) -> [(path: String, branch: String?)] {
        var worktrees: [(path: String, branch: String?)] = []
        for field in output.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.hasPrefix("worktree ") {
                worktrees.append((String(field.dropFirst("worktree ".count)), nil))
            } else if field.hasPrefix("branch "), !worktrees.isEmpty {
                let ref = field.dropFirst("branch ".count)
                worktrees[worktrees.count - 1].branch = String(ref.hasPrefix("refs/heads/") ? ref.dropFirst(11) : ref)
            }
        }
        return worktrees
    }

    /// Where a worktree stands: files with changes not committed, and commits on its
    /// branch that aren't on the base branch yet. Returns nil if git fails.
    static func progress(of worktree: Worktree) -> (uncommittedFiles: Int, unlandedCommits: Int)? {
        guard let status = run(["status", "--porcelain", "-z", "--untracked-files=all"], in: worktree.root) else {
            return nil
        }
        var unlanded = 0
        if let base = worktree.baseBranch {
            guard let count = run(["rev-list", "--count", "refs/heads/\(base)..HEAD"], in: worktree.root)
                .flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else { return nil }
            unlanded = count
        }
        return (changedPaths(porcelain: status).count, unlanded)
    }

    enum LandError: Error {
        /// The worktree has changes that aren't committed.
        case uncommittedChanges

        /// The main checkout has no branch checked out to land on.
        case noBaseBranch

        /// Replaying the worktree's commits on the base branch hit conflicts. The rebase
        /// was undone.
        case conflicts(String)

        /// The base branch couldn't be moved to the worktree's commits.
        case fastForwardFailed(String)
    }

    /// Lands a worktree's commits on the base branch without a merge commit: rebases them
    /// onto the base branch, then fast-forwards the base branch in the main checkout.
    static func land(_ worktree: Worktree) -> Result<Void, LandError> {
        guard let base = worktree.baseBranch else { return .failure(.noBaseBranch) }
        guard let progress = progress(of: worktree), progress.uncommittedFiles == 0 else {
            return .failure(.uncommittedChanges)
        }

        let rebase = execute(["rebase", "refs/heads/\(base)"], in: worktree.root, writes: true)
        guard rebase.succeeded else {
            _ = execute(["rebase", "--abort"], in: worktree.root, writes: true)
            return .failure(.conflicts(rebase.message))
        }

        let target = worktree.branch.map { "refs/heads/\($0)" } ?? "HEAD"
        let head = execute(["rev-parse", target], in: worktree.root, writes: false)
        guard head.succeeded else { return .failure(.fastForwardFailed(head.message)) }
        let commit = head.output.trimmingCharacters(in: .whitespacesAndNewlines)

        let merge = execute(["merge", "--ff-only", commit], in: worktree.mainRoot, writes: true)
        guard merge.succeeded else { return .failure(.fastForwardFailed(merge.message)) }
        return .success(())
    }

    // MARK: Running git

    /// Runs git and returns its output, or nil if it fails.
    ///
    /// `--no-optional-locks` stops `git status` from rewriting the index, so reading
    /// the status never changes the repository (and never triggers our own watcher).
    private static func run(_ arguments: [String], in directory: URL) -> String? {
        let result = execute(arguments, in: directory, writes: false)
        return result.succeeded ? result.output : nil
    }

    private struct Execution {
        let succeeded: Bool
        let output: String
        let error: String

        /// What git said about a failure, for showing to the user.
        var message: String {
            let text = error.isEmpty ? output : error
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Runs git. A command that `writes` may take locks and changes the repository, and
    /// never waits on an editor.
    private static func execute(_ arguments: [String], in directory: URL, writes: Bool) -> Execution {
        guard let executableURL else { return Execution(succeeded: false, output: "", error: "git not found") }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = (writes ? [] : ["--no-optional-locks"]) + arguments
        process.currentDirectoryURL = directory

        var environment = ProcessInfo.processInfo.environment
        if writes {
            environment["GIT_EDITOR"] = "true"
            environment["GIT_TERMINAL_PROMPT"] = "0"
        } else {
            environment["GIT_OPTIONAL_LOCKS"] = "0"
        }
        environment["LC_ALL"] = "C"
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"] {
            environment[key] = nil
        }
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        // What a write says when it fails is shown to the user. It goes to a file, as a
        // second pipe could fill up while the first is read.
        let errorFile = writes
            ? FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-git-\(UUID().uuidString).err")
            : nil
        defer { errorFile.map { try? FileManager.default.removeItem(at: $0) } }
        let errorHandle = errorFile.flatMap { file -> FileHandle? in
            FileManager.default.createFile(atPath: file.path, contents: nil)
            return try? FileHandle(forWritingTo: file)
        }
        process.standardError = errorHandle ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? errorHandle?.close()
            return Execution(succeeded: false, output: "", error: error.localizedDescription)
        }

        // Read before waiting so a large output can't fill the pipe and block git.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? errorHandle?.close()
        let errorText = errorFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return Execution(
            succeeded: process.terminationStatus == 0,
            output: String(decoding: data, as: UTF8.self),
            error: errorText)
    }
}
