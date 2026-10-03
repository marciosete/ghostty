import Foundation

extension CodexSession {
    /// Codex's configured OSC title is the live source for states that it deliberately
    /// omits from rollouts: approval prompts, questions, and the selected model before
    /// the first turn. It is display metadata, never a command or a resumable identity.
    struct TerminalTitle: Equatable {
        let model: String
        let status: String
        let threadPrefix: String?
        let displayTitle: String

        /// The frame of Codex's spinner in the title, if any. Not part of equality: it
        /// turns several times a second without the session changing.
        let activity: Character?

        private static let activityCharacters = Set("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏●")
        private static let spinnerFrames: [Character] = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

        /// What Claude Code puts in front of its title, so a Codex session reads the same
        /// way in a tab or a renamed session (`BaseTerminalController.claudeCodeStatus`):
        /// a turning quarter while it works, keeping step with Codex's own spinner, and
        /// ✳ once it stops or waits.
        var glyph: String {
            guard status == "busy" else { return "✳" }
            let frame = activity.flatMap { Self.spinnerFrames.firstIndex(of: $0) } ?? 0
            return ["◐", "◑", "◒", "◓"][frame % 4]
        }

        static func == (lhs: TerminalTitle, rhs: TerminalTitle) -> Bool {
            lhs.model == rhs.model && lhs.status == rhs.status &&
                lhs.threadPrefix == rhs.threadPrefix && lhs.displayTitle == rhs.displayTitle
        }

        init?(_ title: String) {
            activity = title.first { Self.activityCharacters.contains($0) }
            var parts = title.components(separatedBy: " | ")
            guard var first = parts.first else { return nil }
            if first.hasPrefix("● ") { first.removeFirst(2) }
            let requiresAction = first == "[ ! ] Action Required" || first == "[ . ] Action Required"
            if requiresAction {
                parts.removeFirst()
                guard let next = parts.first else { return nil }
                first = next
            }
            let prefix = first.split(separator: " ")
            guard prefix.last == "codex",
                  prefix.dropLast().allSatisfy({ $0.count == 1 && $0.first.map(Self.activityCharacters.contains) == true }),
                  parts.count >= (requiresAction ? 2 : 3), !parts[1].isEmpty else { return nil }

            model = parts[1]
            let identityIndex: Int
            if requiresAction {
                status = "waiting"
                identityIndex = 2
            } else {
                switch parts[2] {
                case "Ready": status = "idle"
                // "Waiting" means a background terminal is running, not user input.
                case "Starting", "Working", "Thinking", "Waiting": status = "busy"
                default: return nil
                }
                identityIndex = 3
            }

            if parts.count > identityIndex {
                let token = parts[identityIndex].split(separator: " ").first.map(String.init) ?? ""
                if let id = UUID(uuidString: token) {
                    threadPrefix = id.uuidString.lowercased()
                } else if token.count == 32, token.hasSuffix("..."),
                          token.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{5}\.\.\.$"#,
                                      options: .regularExpression) != nil {
                    // Codex truncates this item to 32 characters, including "...".
                    threadPrefix = String(token.dropLast(3)).lowercased()
                } else {
                    return nil
                }
            } else {
                threadPrefix = nil
            }

            let name = parts.dropFirst(identityIndex + 1).joined(separator: " | ")
                .trimmingCharacters(in: .whitespaces)
            let clean = Self.removingActivitySuffix(name)
            // An unnamed thread uses its UUID as its title; keep that out of the UI.
            if clean.isEmpty || UUID(uuidString: clean) != nil ||
                (threadPrefix.map { clean.lowercased().hasPrefix($0) } ?? false) {
                displayTitle = "Codex"
            } else {
                displayTitle = clean
            }
        }

        func matches(_ id: UUID) -> Bool {
            threadPrefix.map { id.uuidString.lowercased().hasPrefix($0) } ?? false
        }

        private static func removingActivitySuffix(_ title: String) -> String {
            var words = title.split(separator: " ")
            while let last = words.last, last.count == 1, let character = last.first,
                  activityCharacters.contains(character) {
                words.removeLast()
            }
            return words.joined(separator: " ")
        }
    }

    static let titleDidChange = Notification.Name("com.mitchellh.ghostty.codex-title-changed")

    private struct TitleObservation {
        let started: Date
        let title: TerminalTitle
    }

    private static let titlesLock = NSLock()
    private static var titles: [Int: TitleObservation] = [:]

    /// Returns the title to show, the way Claude Code titles its sessions: a status glyph
    /// and the thread's name. The live metadata is kept for this exact process lifetime;
    /// an ordinary shell title clears it when Codex exits.
    static func observe(title: String, pid: Int) -> String? {
        guard let parsed = TerminalTitle(title), let process = pid_t(exactly: pid), process > 0,
              let started = RunningProcess.startTime(process), containsCodex(process) else {
            forget(pid: pid)
            return nil
        }
        titlesLock.lock()
        let changed = titles[pid]?.started != started || titles[pid]?.title != parsed
        titles[pid] = TitleObservation(started: started, title: parsed)
        titlesLock.unlock()
        if changed { NotificationCenter.default.post(name: titleDidChange, object: pid) }
        return "\(parsed.glyph) \(parsed.displayTitle)"
    }

    static func forget(pid: Int) {
        titlesLock.lock()
        let removed = titles.removeValue(forKey: pid) != nil
        titlesLock.unlock()
        if removed { NotificationCenter.default.post(name: titleDidChange, object: pid) }
    }

    static func liveTitle(pid: Int) -> TerminalTitle? {
        titlesLock.lock()
        let observation = titles[pid]
        titlesLock.unlock()
        guard let observation else { return nil }
        guard let process = pid_t(exactly: pid), RunningProcess.startTime(process) == observation.started else {
            forget(pid: pid)
            return nil
        }
        return observation.title
    }

    static func liveStatus(pid: Int) -> String? { liveTitle(pid: pid)?.status }
    static func liveModel(pid: Int) -> String? { liveTitle(pid: pid)?.model }

    /// A native --worktree checkout is created before its first durable turn. The
    /// process still has the source checkout as its kernel cwd; only Codex's exact
    /// thread ownership record can identify the destination at this point.
    static func liveDirectory(pid: Int) -> String? {
        guard let title = liveTitle(pid: pid), let process = pid_t(exactly: pid), process > 0 else { return nil }
        var pending = [process]
        var visited: Set<pid_t> = []
        var ids: Set<UUID> = []
        var sources: Set<String> = []
        while !pending.isEmpty {
            let candidate = pending.removeFirst()
            guard visited.insert(candidate).inserted else { continue }
            let name = RunningProcess.name(candidate)
            let arguments = RunningProcess.arguments(candidate)
            guard name != "codex" || arguments != nil,
                  arguments?.contains("--managed-daemon") != true else { continue }
            pending += RunningProcess.children(candidate)
            guard name == "codex" else { continue }
            for path in RunningProcess.openFiles(candidate) {
                let file = URL(fileURLWithPath: path)
                guard file.deletingLastPathComponent().lastPathComponent == "thread-writer-locks",
                      file.pathExtension == "lock",
                      let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), title.matches(id),
                      let source = RunningProcess.directory(candidate) else { continue }
                ids.insert(id)
                sources.insert(source)
            }
        }
        guard ids.count == 1, let id = ids.first else { return nil }
        let directories = Set(sources.compactMap { source -> String? in
            guard let repository = Git.repository(containing: URL(fileURLWithPath: source)) else { return nil }
            return worktreeDirectory(of: id, in: repository.commonDir)
        })
        return directories.count == 1 ? directories.first : nil
    }

    static func worktreeDirectory(of id: UUID, in commonDir: URL) -> String? {
        let directory = commonDir.appendingPathComponent("worktrees")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        let matches = entries.compactMap { entry -> String? in
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("codex-thread.json")),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  record["version"] as? Int == 1,
                  let owner = record["ownerThreadId"] as? String, UUID(uuidString: owner) == id,
                  let gitfile = try? String(contentsOf: entry.appendingPathComponent("gitdir"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines), gitfile.hasPrefix("/") else { return nil }
            let root = URL(fileURLWithPath: gitfile).deletingLastPathComponent()
            guard let repository = Git.repository(containing: root), repository.isLinkedWorktree,
                  repository.gitDir.path == Git.realPath(entry.path).path,
                  repository.commonDir.path == Git.realPath(commonDir.path).path else { return nil }
            return repository.root.path
        }
        // Ownership ambiguity must not display an unrelated checkout.
        return matches.count == 1 ? matches.first : nil
    }

    private static func containsCodex(_ root: pid_t) -> Bool {
        var pending = [root]
        var visited: Set<pid_t> = []
        while !pending.isEmpty {
            let pid = pending.removeFirst()
            guard visited.insert(pid).inserted else { continue }
            if RunningProcess.name(pid) == "codex" {
                guard let arguments = RunningProcess.arguments(pid), !arguments.contains("--managed-daemon") else { continue }
                return true
            }
            pending += RunningProcess.children(pid)
        }
        return false
    }
}
