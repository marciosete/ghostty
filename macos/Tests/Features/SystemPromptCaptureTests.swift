import Foundation
import Testing
@testable import Ghostty

private func request(_ head: String, body: String = "") -> Data {
    Data((head.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\n" + body).utf8)
}

private func messagesRequest(_ body: [String: Any]) throws -> ProxyRequest {
    let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    let data = request(
        "POST /v1/messages?beta=true HTTP/1.1\nHost: 127.0.0.1\nUser-Agent: claude-cli/2.1.0\nContent-Length: \(json.utf8.count)",
        body: json)
    return try #require(try ProxyRequest.parse(data))
}

struct ProxyRequestTests {
    @Test func readsARequestWithALength() throws {
        let parsed = try #require(try ProxyRequest.parse(request(
            "POST /v1/messages?beta=true HTTP/1.1\nHost: 127.0.0.1:1234\nContent-Length: 5",
            body: "hello")))

        #expect(parsed.method == "POST")
        #expect(parsed.target == "/v1/messages?beta=true")
        #expect(parsed.path == "/v1/messages")
        #expect(parsed.header("host") == "127.0.0.1:1234")
        #expect(parsed.body == Data("hello".utf8))
    }

    @Test func waitsForTheWholeBody() throws {
        #expect(try ProxyRequest.parse(request("POST / HTTP/1.1\nContent-Length: 10", body: "hello")) == nil)
        #expect(try ProxyRequest.parse(Data("POST / HTTP/1.1\r\nContent-".utf8)) == nil)
    }

    @Test func joinsAChunkedBody() throws {
        let head = "POST / HTTP/1.1\nTransfer-Encoding: chunked"
        #expect(try ProxyRequest.parse(request(head, body: "5\r\nhello\r\n")) == nil)

        let parsed = try #require(try ProxyRequest.parse(request(head, body: "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")))
        #expect(parsed.body == Data("hello world".utf8))
    }

    @Test func readsARequestWithoutABody() throws {
        let parsed = try #require(try ProxyRequest.parse(request("GET /v1/models HTTP/1.1\nHost: x")))
        #expect(parsed.body.isEmpty)
    }

    @Test func rejectsAMalformedRequest() {
        #expect(throws: ProxyRequest.ParseError.self) {
            try ProxyRequest.parse(request("nonsense"))
        }
    }
}

struct SystemPromptSampleTests {
    @Test func readsTheSystemPromptAndTools() throws {
        let sample = try #require(SystemPromptSample(try messagesRequest([
            "model": "claude-opus-5-5",
            "system": [["type": "text", "text": "You are Claude Code."], ["type": "text", "text": "Be brief."]],
            "tools": [["name": "Bash"]],
            "messages": [["role": "user", "content": "secret"]],
        ])))

        #expect(sample.model == "claude-opus-5-5")
        #expect(sample.systemText == "You are Claude Code.\n\nBe brief.")
        #expect(sample.userAgent == "claude-cli/2.1.0")

        let saved = try #require(
            try JSONSerialization.jsonObject(with: sample.json(capturedAt: Date())) as? [String: Any])
        #expect(saved["messages"] == nil)
        #expect(saved["tools"] != nil)
    }

    @Test func skipsRequestsWithoutASystemPrompt() throws {
        #expect(SystemPromptSample(try messagesRequest(["model": "m", "messages": []])) == nil)

        let count = try #require(try ProxyRequest.parse(request(
            "POST /v1/messages/count_tokens HTTP/1.1\nContent-Length: 13", body: "{\"system\":\"\"}")))
        #expect(SystemPromptSample(count) == nil)
    }

    @Test func theSameSystemPromptHasTheSameFingerprint() throws {
        let body: [String: Any] = ["model": "m", "system": "a", "messages": [["role": "user", "content": "1"]]]
        var later = body
        later["messages"] = [["role": "user", "content": "2"]]
        var other = body
        other["system"] = "b"

        let first = try #require(SystemPromptSample(try messagesRequest(body)))
        #expect(SystemPromptSample(try messagesRequest(later))?.fingerprint == first.fingerprint)
        #expect(SystemPromptSample(try messagesRequest(other))?.fingerprint != first.fingerprint)
    }

    @Test func savesEachSystemPromptOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sample = try #require(SystemPromptSample(try messagesRequest(["model": "m", "system": "a"])))
        try SystemPromptCapture(directory: directory).save(sample, capturedAt: Date())
        try SystemPromptCapture(directory: directory).save(sample, capturedAt: Date().addingTimeInterval(5))

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names.count == 2)
        #expect(names.allSatisfy { $0.contains(sample.fingerprint) })
    }
}
