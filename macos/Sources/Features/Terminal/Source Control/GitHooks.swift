import Foundation

/// A pre-commit or pre-push hook of a repository, and the steps it announces.
///
/// A hook announces its steps by printing markers such as `[3/8] Type-check…`, one as each
/// step starts. The script is read for them, so the steps are known before the hook runs,
/// and its output is read for them while it runs.
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

        var steps: [String] = []
        var totals = Set<Int>()
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Only what the script prints, not comments that mention a step.
            guard trimmed.hasPrefix("echo") || trimmed.hasPrefix("printf"),
                  let marker = Self.marker(in: String(trimmed)) else { continue }
            steps.append(marker.title)
            totals.insert(marker.total)
        }
        self.steps = steps
        self.totals = totals
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
