import Foundation
import Testing
@testable import Ghostty

private func request(_ head: String, body: String = "") -> Data {
    Data((head.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\n" + body).utf8)
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

struct SystemPromptCaptureTests {
    /// Keys out of order and odd spacing, which re-encoding would change.
    private let body = #"{"system":[{"type":"text","text":"You are Claude Code."}],  "model":"m","messages":[]}"#

    private func capture(_ head: String) throws -> (directory: URL, request: ProxyRequest) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let parsed = try #require(try ProxyRequest.parse(request(
            head + "\nContent-Length: \(body.utf8.count)", body: body)))
        return (directory, parsed)
    }

    private func files(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    @Test func savesTheBodyByteForByte() throws {
        let (directory, request) = try capture(
            "POST /v1/messages?beta=true HTTP/1.1\nContent-Type: application/json")
        defer { try? FileManager.default.removeItem(at: directory) }

        try SystemPromptCapture(directory: directory).save(request, capturedAt: Date())

        let names = try files(in: directory)
        let json = try #require(names.first { $0.hasSuffix("-1-POST-v1-messages.json") })
        #expect(try Data(contentsOf: directory.appendingPathComponent(json)) == Data(body.utf8))
        #expect(names.contains { $0.hasSuffix("-1-POST-v1-messages.http") })
    }

    @Test func savesTheHeadersWithoutCredentials() throws {
        let (directory, request) = try capture(
            "POST /v1/messages?beta=true HTTP/1.1\nAuthorization: Bearer sk-ant-oat-secret\nX-Api-Key: sk-ant-secret\nanthropic-beta: oauth-2025-04-20\nContent-Type: application/json")
        defer { try? FileManager.default.removeItem(at: directory) }

        try SystemPromptCapture(directory: directory).save(request, capturedAt: Date())

        let http = try #require(try files(in: directory).first { $0.hasSuffix(".http") })
        let head = try String(contentsOf: directory.appendingPathComponent(http), encoding: .utf8)
        #expect(!head.contains("secret"))
        #expect(head.hasPrefix(
            "POST /v1/messages?beta=true HTTP/1.1\r\nAuthorization: [redacted]\r\nX-Api-Key: [redacted]\r\nanthropic-beta: oauth-2025-04-20\r\n"))
    }

    @Test func savesEveryRequest() throws {
        let (directory, request) = try capture("POST /v1/messages HTTP/1.1\nContent-Type: application/json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = SystemPromptCapture(directory: directory)
        let now = Date()
        try capture.save(request, capturedAt: now)
        try capture.save(request, capturedAt: now)

        #expect(try files(in: directory).count == 4)
    }
}
