import Foundation

/// Carries a session's conversation over to the other agent. Neither agent can read the
/// other's transcript, but both take a prompt to start with, so the conversation is
/// written out as Markdown and the new agent is told to read it and carry on.
enum AgentHandoff {
    /// One thing said or done in a session.
    enum Entry: Equatable {
        case user(String)
        case assistant(String)
        case tool(name: String, input: String)
        case toolResult(String)
    }

    /// Tool inputs and results are cut to this many characters: what was done matters
    /// more than every byte of what came back.
    static let toolTextLimit = 400

    /// The handoff keeps this much of the end of a long conversation.
    static let documentLimit = 200_000

    // MARK: Reading transcripts

    /// The conversation in the transcript at `url`, as `agent` wrote it.
    static func entries(inTranscript url: URL, of agent: CodingAgent) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var entries: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch agent {
            case .claude: entries += claudeEntries(entry)
            case .codex: entries += codexEntries(entry)
            }
        }
        return entries
    }

    /// Claude Code writes one line per message, or per content block of a message:
    /// text, tool calls and tool results. Subagent lines and the lines it writes for
    /// itself (commands, reminders) are skipped.
    static func claudeEntries(_ entry: [String: Any]) -> [Entry] {
        guard entry["isSidechain"] as? Bool != true,
              entry["isMeta"] as? Bool != true,
              let type = entry["type"] as? String, type == "user" || type == "assistant",
              let message = entry["message"] as? [String: Any] else { return [] }

        if let text = message["content"] as? String {
            return conversational(text).map { [type == "user" ? .user($0) : .assistant($0)] } ?? []
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }

        var entries: [Entry] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = conversational(block["text"] as? String ?? "") {
                    entries.append(type == "user" ? .user(text) : .assistant(text))
                }
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                entries.append(.tool(name: name, input: summary(ofToolInput: block["input"])))
            case "tool_result":
                let text: String
                if let content = block["content"] as? String {
                    text = content
                } else if let parts = block["content"] as? [[String: Any]] {
                    text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                } else {
                    text = ""
                }
                entries.append(.toolResult(trimmed(text)))
            default:
                break
            }
        }
        return entries
    }

    /// Codex writes the model's own view of the conversation as `response_item` lines:
    /// messages, function calls and their outputs. (It writes the messages again as
    /// `event_msg` lines, which are skipped so nothing is said twice.)
    static func codexEntries(_ entry: [String: Any]) -> [Entry] {
        guard entry["type"] as? String == "response_item",
              let payload = entry["payload"] as? [String: Any] else { return [] }

        switch payload["type"] as? String {
        case "message":
            let role = payload["role"] as? String
            guard role == "user" || role == "assistant",
                  let parts = payload["content"] as? [[String: Any]] else { return [] }
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard let spoken = conversational(text) else { return [] }
            return [role == "user" ? .user(spoken) : .assistant(spoken)]

        case "function_call", "custom_tool_call":
            let name = payload["name"] as? String ?? "tool"
            let input = payload["arguments"] ?? payload["input"]
            return [.tool(name: name, input: summary(ofToolInput: input))]

        case "function_call_output", "custom_tool_call_output":
            return [.toolResult(trimmed(payload["output"] as? String ?? ""))]

        default:
            return []
        }
    }

    /// Text a person or the agent actually said, or nil for the context both agents
    /// wrap in tags and the text of a cancelled turn.
    private static func conversational(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Claude Code appends reminders to what the person typed.
        if let range = text.range(of: "<system-reminder>") {
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty, !text.hasPrefix("<") else { return nil }
        return text
    }

    private static func summary(ofToolInput input: Any?) -> String {
        switch input {
        case let text as String:
            return trimmed(text)
        case let object as [String: Any]:
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return trimmed(data.map { String(decoding: $0, as: UTF8.self) } ?? "")
        default:
            return ""
        }
    }

    private static func trimmed(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > toolTextLimit else { return text }
        return String(text.prefix(toolTextLimit)) + "…"
    }

    // MARK: Writing the handoff

    /// The handoff document: the conversation `entries` from a session of `from`,
    /// headed for `to`, after `earlier`, the handoff that session itself started from.
    static func markdown(entries: [Entry], from: CodingAgent, to: CodingAgent, earlier: String? = nil) -> String {
        var sections: [String] = []
        if let earlier {
            sections.append(earlier)
        }

        var body = ""
        for entry in entries {
            switch entry {
            case .user(let text): body += "**User:**\n\n\(text)\n\n"
            case .assistant(let text): body += "**\(from.displayName):**\n\n\(text)\n\n"
            case .tool(let name, let input): body += "> `\(name)` \(input.isEmpty ? "" : "`\(input)`")\n\n"
            case .toolResult(let text): body += text.isEmpty ? "" : "> ↳ \(text.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
            }
        }
        if body.count > documentLimit {
            let kept = body.suffix(documentLimit)
            // Start at a message boundary.
            let start = kept.range(of: "\n**").map { kept.index(after: $0.lowerBound) } ?? kept.startIndex
            body = "_(The start of the conversation is left out for length.)_\n\n" + kept[start...]
        }
        sections.append("## Conversation with \(from.displayName)\n\n" + body)

        let header = """
            # Handoff to \(to.displayName)

            This is the conversation so far of a coding session, which is being handed over from \
            \(from.displayName) to \(to.displayName), in the same working directory. The files are \
            exactly as the previous agent left them. Read this, then carry on from where it stops: \
            don't redo work that is done, and ask before changing course.


            """
        return header + sections.joined(separator: "\n\n")
    }

    /// Where handoffs are kept: with the app's other data, out of the repository.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty")
            .appendingPathComponent("Handoffs")
    }

    /// Writes `markdown` as the handoff of session `id`, and returns the file.
    static func write(_ markdown: String, from: CodingAgent, session id: UUID) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "\(formatter.string(from: Date())) \(from.displayName) \(id.uuidString.lowercased().prefix(8)).md"
        let url = directory.appendingPathComponent(name)
        try Data(markdown.utf8).write(to: url)
        return url
    }

    // MARK: Starting the next agent

    /// What the new agent is told to begin with.
    static func prompt(from: CodingAgent, handoff: URL) -> String {
        "You are taking over a coding session from \(from.displayName), in this working directory. " +
            "The conversation so far is in \(handoff.path). Read that file first, then carry on from where it stops."
    }

    /// The command that starts `agent` with `prompt`, quoted for the shell. Without a
    /// prompt, a plain start in the session's directory: the worktree is the one being
    /// continued, so no new one is made.
    static func command(for agent: CodingAgent, prompt: String?) -> String {
        guard let prompt else { return agent.command }
        return "\(agent.command) \(shellQuoted(prompt))"
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
