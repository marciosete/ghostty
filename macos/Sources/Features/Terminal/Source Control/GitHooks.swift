import Foundation

/// A pre-commit or pre-push hook of a repository, and the steps it announces.
///
/// A hook announces its steps by printing markers such as `[3/8] Type-check…`, one as each
/// step starts. The script is read for them, so the steps are known before the hook runs,
/// and its output is read for them while it runs. When its output can't be read, such as
/// when it goes through a pipe, the commands it runs say which step it is on instead.
struct GitHookScript: Equatable {
    /// The hooks the source control panel follows, in the order they run.
    static let names = ["pre-commit", "pre-push"]

    /// The hook's name, such as `pre-push`.
    let name: String

    /// The script that does the hook's work. For Husky it is `.husky/pre-push`, which the
    /// hook git runs, `.husky/_/pre-push`, runs with `sh -e`.
    let path: URL

    /// Husky runs the script, and prints `husky - pre-push script failed (code 1)` when it
    /// fails.
    let isHusky: Bool

    /// The titles of the steps the script announces, in order.
    let steps: [String]

    /// The step counts the markers give, such as 8 for `[3/8]`.
    let totals: Set<Int>

    /// The commands each step runs, each as the words that name it, such as
    /// `["pnpm", "lint"]` for `pnpm -r --if-present lint || exit 1`.
    let commands: [[[String]]]

    /// The pre-commit and pre-push hooks of `repository` that git would run.
    static func scripts(of repository: Git.Repository) -> [GitHookScript] {
        guard let hooks = Git.hooksDirectory(of: repository) else { return [] }
        return names.compactMap { script(named: $0, in: hooks) }
    }

    static func script(named name: String, in hooks: URL) -> GitHookScript? {
        let hook = hooks.appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: hook.path),
              let text = try? String(contentsOf: hook, encoding: .utf8) else { return nil }

        // Husky's hooks in `.husky/_` all run `.husky/_/h`, which runs the script of the
        // same name in `.husky`, if there is one.
        let isHusky = text.contains("/h\"") || text.contains("husky.sh")
        guard isHusky else {
            return GitHookScript(name: name, path: hook, isHusky: false, text: text)
        }
        let script = hooks.deletingLastPathComponent().appendingPathComponent(name)
        guard let text = try? String(contentsOf: script, encoding: .utf8) else { return nil }
        return GitHookScript(name: name, path: Git.realPath(script.path), isHusky: true, text: text)
    }

    init(name: String, path: URL, isHusky: Bool, text: String) {
        self.name = name
        self.path = path
        self.isHusky = isHusky

        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

        // The script's own functions, such as `require_tool`, aren't commands it runs.
        let functions = Set(lines.compactMap { line -> String? in
            guard let match = line.firstMatch(of: #/^(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)/#) else { return nil }
            return String(match.1)
        })

        var steps: [String] = []
        var totals = Set<Int>()
        var commands: [[[String]]] = []
        for line in lines where !line.hasPrefix("#") {
            // Only what the script prints, not comments that mention a step.
            if line.hasPrefix("echo") || line.hasPrefix("printf"), let marker = Self.marker(in: line) {
                steps.append(marker.title)
                totals.insert(marker.total)
                commands.append([])
            } else if !commands.isEmpty {
                commands[commands.count - 1] += Self.commands(in: line, functions: functions)
            }
        }
        self.steps = steps
        self.totals = totals
        self.commands = commands
    }

    /// Commands too common to tell a step by: the script's plumbing, and the shell's.
    private static let plumbing: Set<String> = [
        "echo", "printf", "exit", "return", "true", "false", "test", "[", "[[", "read", "local",
        "export", "set", "cd", "command", "grep", "sed", "awk", "head", "tail", "cat", "wc",
        "sort", "uniq", "tr", "basename", "dirname", "sleep",
    ]

    /// Words that start a command without naming it.
    private static let prefixes: Set<String> = [
        "if", "then", "else", "elif", "while", "until", "do", "done", "fi", "!", "time", "exec",
        "xargs", "env", "nice",
    ]

    /// The commands a line of shell runs, each as the words that name it: the command and
    /// its first arguments that aren't options, variables or quoted.
    static func commands(in line: String, functions: Set<String> = []) -> [[String]] {
        let separators = ["||", "&&", "$(", "|", ";", "(", ")", "{", "}", "`"]
        // What is quoted is text, even when it reads like commands.
        var segments = [line.replacing(#/"[^"]*"|'[^']*'/#, with: "\"\"")]
        for separator in separators {
            segments = segments.flatMap { $0.components(separatedBy: separator) }
        }

        return segments.compactMap { segment in
            var words: [String] = []
            for token in segment.split(separator: " ") {
                let token = String(token)
                if words.isEmpty {
                    // Leading assignments and keywords.
                    if token.firstMatch(of: #/^[A-Za-z_][A-Za-z0-9_]*=/#) != nil || prefixes.contains(token) { continue }
                }
                // Options are skipped, since the same command runs with different ones. What
                // follows quotes, variables and redirects is their argument.
                if token.hasPrefix("-") { continue }
                guard !"\"'$<>&0123456789".contains(token.first ?? "\"") else {
                    if words.isEmpty { return nil }
                    break
                }
                words.append((token as NSString).lastPathComponent)
                if words.count == 3 { break }
            }
            guard let command = words.first, !plumbing.contains(command), !functions.contains(command) else { return nil }
            return words
        }
    }

    /// The step a running command belongs to, or nil if it names none of them. It is
    /// the step with the command that names it most closely, the last such step when
    /// several do.
    func step(running arguments: [String]) -> Int? {
        let words = arguments.filter { !$0.hasPrefix("-") }.map(Self.word)
        var best: (step: Int, length: Int)?
        for (step, stepCommands) in commands.enumerated() {
            for command in stepCommands where Self.words(words, contain: command.map(Self.word)) {
                if best == nil || command.count >= best!.length {
                    best = (step, command.count)
                }
            }
        }
        return best?.step
    }

    /// A word of a command, as a path or the script `node` runs is named: `pnpm` for
    /// `/opt/homebrew/lib/node_modules/pnpm/bin/pnpm.cjs`.
    private static func word(_ argument: String) -> String {
        let name = (argument as NSString).lastPathComponent
        for suffix in [".cjs", ".mjs", ".js"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// `words` has every one of `command`, in order.
    private static func words(_ words: [String], contain command: [String]) -> Bool {
        var remaining = command[...]
        for word in words where word == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }

    /// A step's marker in a line, such as `[3/8] Type-check…`, with its title cleaned of
    /// the quotes and ellipsis around it.
    static func marker(in line: String) -> (number: Int, total: Int, title: String)? {
        guard let match = line.firstMatch(of: #/\[(\d+)/(\d+)\]\s*(.*)/#),
              let number = Int(match.1), let total = Int(match.2) else { return nil }
        var title = String(match.3).trimmingCharacters(in: .whitespaces)
        while let last = title.last, "\"';".contains(last) { title.removeLast() }
        for suffix in ["…", "..."] where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
        }
        return (number, total, title.trimmingCharacters(in: .whitespaces))
    }
}

/// Follows a hook's steps through its output as it is written.
struct GitHookOutputParser {
    let script: GitHookScript

    /// The steps the latest run reached, in the order it reached them.
    private(set) var reached: [Int] = []

    /// Husky said the script failed after the last step started.
    private(set) var failed = false

    /// The script said it passed after the last step started.
    private(set) var passed = false

    /// The end of the output, after its last complete line.
    private var partialLine = Data()

    init(script: GitHookScript) {
        self.script = script
    }

    /// Reads more of the output.
    mutating func feed(_ data: Data) {
        partialLine.append(data)
        guard let lastNewline = partialLine.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = partialLine[..<lastNewline]
        partialLine = Data(partialLine[partialLine.index(after: lastNewline)...])
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            read(String(decoding: line, as: UTF8.self))
        }
    }

    /// Reads the last line, which has no newline after it, once the output is complete.
    mutating func finish() {
        guard !partialLine.isEmpty else { return }
        read(String(decoding: partialLine, as: UTF8.self))
        partialLine = Data()
    }

    private mutating func read(_ line: String) {
        if let marker = GitHookScript.marker(in: line), let step = step(of: marker) {
            // A step that doesn't come after the last is the start of another run.
            if let last = reached.last, step <= last { reached = [] }
            reached.append(step)
            failed = false
            passed = false
        } else if !reached.isEmpty {
            if line.contains("husky - \(script.name) script failed") { failed = true }
            if line.contains("PASSED") { passed = true }
        }
    }

    /// The step a marker announces: the one with its title, or else its number, if it
    /// counts the steps like this hook does. Another hook's markers, written to the same
    /// output, are neither.
    private func step(of marker: (number: Int, total: Int, title: String)) -> Int? {
        if let index = script.steps.firstIndex(of: marker.title) { return index }
        guard script.totals.contains(marker.total), script.steps.indices.contains(marker.number - 1) else { return nil }
        return marker.number - 1
    }
}
