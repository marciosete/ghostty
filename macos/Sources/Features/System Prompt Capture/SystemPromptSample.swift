import CryptoKit
import Foundation

/// The system prompt and tools of one Messages API request. The conversation itself is left
/// out: a sample is about what Claude Code tells the model, not what was said in the session.
struct SystemPromptSample {
    let model: String
    let system: Any
    let tools: Any?
    let userAgent: String?
    let betas: String?

    /// Identifies the prompt and tools, so a prompt repeated on every turn is saved once.
    let fingerprint: String

    /// Reads a sample out of a request to the Messages API. Other requests, and requests
    /// without a system prompt, give nil.
    init?(_ request: ProxyRequest) {
        guard request.method == "POST", request.path == "/v1/messages",
              let object = try? JSONSerialization.jsonObject(with: request.body),
              let body = object as? [String: Any],
              let system = body["system"] else { return nil }

        self.model = body["model"] as? String ?? "unknown"
        self.system = system
        self.tools = body["tools"]
        self.userAgent = request.header("User-Agent")
        self.betas = request.header("anthropic-beta")

        var hashed: [String: Any] = ["model": model, "system": system]
        hashed["tools"] = tools
        let canonical = (try? JSONSerialization.data(withJSONObject: hashed, options: [.sortedKeys])) ?? Data()
        self.fingerprint = SHA256.hash(data: canonical)
            .prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The system prompt as text, its blocks separated by blank lines.
    var systemText: String {
        if let text = system as? String { return text }
        guard let blocks = system as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
    }

    /// The JSON saved for the sample.
    func json(capturedAt: Date) throws -> Data {
        var object: [String: Any] = [
            "capturedAt": ISO8601DateFormatter().string(from: capturedAt),
            "model": model,
            "system": system,
        ]
        object["tools"] = tools
        object["userAgent"] = userAgent
        object["anthropicBeta"] = betas
        return try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
