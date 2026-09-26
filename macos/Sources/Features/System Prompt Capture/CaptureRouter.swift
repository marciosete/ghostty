import CryptoKit
import Foundation

/// Sorts the requests of one Claude Code session into threads, each kept in its own folder
/// inside the session's folder:
///
/// - the main conversation, at the top of the folder;
/// - each subagent's conversation, in `agents/NN-<first words of its prompt>`;
/// - side calls, which Claude Code makes around the conversation (checking the quota,
///   naming the session, suggesting a next prompt), in `side-calls/<kind>`.
///
/// All of them send the session's ID. A conversation carries tools and a side call
/// doesn't, except the prompt suggestion, which is the main conversation plus a last message
/// asking for the suggestion.
struct CaptureRouter {
    typealias JSON = [String: Any]

    /// The main conversation's system prompt and first message. The first message stays
    /// the same for every turn; after a compaction it changes, but the system prompt doesn't.
    private var mainSystem: String?
    private var mainOpening: String?

    /// Each subagent's folder, by its first message.
    private var agents: [String: String] = [:]

    /// The folder for `request` relative to the session's folder, empty for the main
    /// conversation.
    mutating func folder(for request: JSON, path: String) -> String {
        guard path == "/v1/messages" else {
            return "side-calls/" + Self.slug(path, words: 6)
        }

        let tools = request["tools"] as? [Any] ?? []
        let messages = request["messages"] as? [JSON] ?? []
        if tools.isEmpty || Self.text(of: messages.last).hasPrefix("[SUGGESTION MODE") {
            return "side-calls/" + Self.sideCallName(request, messages: messages)
        }

        let system = Self.fingerprint(request["system"] ?? "")
        let opening = Self.fingerprint(messages.first ?? [:])

        // The same system prompt with a new first message is the main conversation
        // compacted. Subagents have system prompts of their own.
        if mainSystem == nil || opening == mainOpening || (system == mainSystem && agents[opening] == nil) {
            mainSystem = system
            mainOpening = opening
            return ""
        }
        if let folder = agents[opening] {
            return folder
        }

        let prompt = Self.prompt(of: messages.first)
        let folder = "agents/\(String(format: "%02d", agents.count + 1))-\(Self.slug(prompt, words: 6))"
        agents[opening] = folder
        return folder
    }

    private static func sideCallName(_ request: JSON, messages: [JSON]) -> String {
        if text(of: messages.last).hasPrefix("[SUGGESTION MODE") { return "suggestion-mode" }
        let opening = text(of: messages.first)
        if request["system"] == nil { return slug(opening, words: 4) }

        // Side calls with the same instructions are one kind; name it after them.
        let system: [String]
        if let text = request["system"] as? String {
            system = [text]
        } else {
            system = (request["system"] as? [JSON] ?? []).compactMap { $0["text"] as? String }
        }
        let instructions = system.last { !$0.hasPrefix("x-anthropic-billing-header") } ?? opening
        return slug(instructions, words: 6)
    }

    /// The text of a message: its string content, or its text blocks joined.
    private static func text(of message: JSON?) -> String {
        guard let message else { return "" }
        if let text = message["content"] as? String { return text }
        return (message["content"] as? [JSON] ?? [])
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
    }

    /// What a first message asks for: its last text block that isn't context Claude Code
    /// added.
    private static func prompt(of message: JSON?) -> String {
        guard let message else { return "" }
        if let text = message["content"] as? String { return text }
        return (message["content"] as? [JSON] ?? [])
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .last { !$0.hasPrefix("<system-reminder>") } ?? ""
    }

    private static func fingerprint(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase words joined by dashes, for a file name.
    static func slug(_ text: String, words: Int) -> String {
        let slug = text.lowercased()
            .split { !(("a"..."z").contains($0) || ("0"..."9").contains($0)) }
            .prefix(words)
            .joined(separator: "-")
        return slug.isEmpty ? "unnamed" : slug
    }
}
