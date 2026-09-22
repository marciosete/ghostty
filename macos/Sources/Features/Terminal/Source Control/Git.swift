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
    var branch: String?

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
                let prefix = "# branch.head "
                if token.hasPrefix(prefix) {
                    status.branch = String(token.dropFirst(prefix.count))
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

    /// Runs git and returns its output, or nil if it fails.
    ///
    /// `--no-optional-locks` stops `git status` from rewriting the index, so reading
    /// the status never changes the repository (and never triggers our own watcher).
    private static func run(_ arguments: [String], in directory: URL) -> String? {
        guard let executableURL else { return nil }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--no-optional-locks"] + arguments
        process.currentDirectoryURL = directory

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"] {
            environment[key] = nil
        }
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read before waiting so a large output can't fill the pipe and block git.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
