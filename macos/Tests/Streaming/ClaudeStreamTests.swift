import Foundation
import Network
import Testing
@testable import Ghostty

@Suite
struct SSEParserTests {
    @Test func splitsEventsHoweverChunked() {
        var parser = SSEParser()
        let stream = "event: message_start\ndata: {\"a\":1}\n\nevent: ping\ndata: {\"type\": \"ping\"}\n\n"
        var events: [SSEEvent] = []
        // One byte at a time is the worst case.
        for byte in stream.utf8 {
            events.append(contentsOf: parser.feed(Data([byte])))
        }
        #expect(events == [
            SSEEvent(name: "message_start", data: "{\"a\":1}"),
            SSEEvent(name: "ping", data: "{\"type\": \"ping\"}"),
        ])
    }

    @Test func joinsDataLinesAndSkipsComments() {
        var parser = SSEParser()
        let events = parser.feed(Data(": keep-alive\r\ndata: one\r\ndata: two\r\n\r\n".utf8))
        #expect(events == [SSEEvent(name: nil, data: "one\ntwo")])
    }

    @Test func keepsAnIncompleteEvent() {
        var parser = SSEParser()
        #expect(parser.feed(Data("event: x\ndata: 1\n".utf8)).isEmpty)
        #expect(parser.feed(Data("\n".utf8)) == [SSEEvent(name: "x", data: "1")])
    }
}

@Suite
struct ClaudeStreamTrackerTests {
    private static let start = Date(timeIntervalSince1970: 1_790_000_000)

    private static func delta(_ text: String, kind: String = "text") -> SSEEvent {
        SSEEvent(name: "content_block_delta", data: "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"\(kind)_delta\",\"\(kind == "input_json" ? "partial_json" : kind)\":\"\(text)\"}}")
    }

    @Test func timesFirstTokenAndRate() {
        var tracker = ClaudeStreamTracker(startedAt: Self.start)
        tracker.apply(SSEEvent(name: "message_start", data: "{\"type\":\"message_start\",\"message\":{\"usage\":{\"output_tokens\":1}}}"), at: Self.start + 0.5)
        #expect(tracker.sample.firstTokenAt == nil)

        tracker.apply(Self.delta("Hello"), at: Self.start + 1.2)
        tracker.apply(Self.delta("hmm", kind: "thinking"), at: Self.start + 2)
        tracker.apply(Self.delta("{\\\"a\\\":", kind: "input_json"), at: Self.start + 3)
        tracker.apply(Self.delta(" world"), at: Self.start + 11.2)
        // Dates this far from 1970 carry a rounding error in the last decimals.
        #expect(abs((tracker.sample.timeToFirstToken ?? 0) - 1.2) < 0.001)
        #expect(tracker.sample.characters == 5 + 3 + 5 + 6)
        #expect(!tracker.sample.hasExactRate)

        // Too few characters arrived in the last moments for a live rate.
        #expect(tracker.sample.liveTokensPerSecond(at: Self.start + 11.2) == nil)

        tracker.apply(SSEEvent(name: "message_delta", data: "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":700}}"), at: Self.start + 11.3)
        tracker.apply(SSEEvent(name: "message_stop", data: "{\"type\":\"message_stop\"}"), at: Self.start + 11.3)

        #expect(tracker.sample.outputTokens == 700)
        #expect(tracker.sample.hasExactRate)
        #expect(!tracker.sample.isStreaming)
        #expect(!tracker.sample.failed)
        // 700 tokens from the first token at 1.2s to the last at 11.2s.
        #expect(abs((tracker.sample.averageTokensPerSecond ?? 0) - 70) < 0.001)
        #expect(tracker.sample.liveTokensPerSecond(at: Self.start + 11.3) == nil, "a finished reply has no live rate")
    }

    @Test func liveRateFollowsTheLastMoments() {
        var tracker = ClaudeStreamTracker(startedAt: Self.start)
        tracker.apply(Self.delta(String(repeating: "x", count: 400)), at: Self.start + 1)
        tracker.apply(Self.delta(String(repeating: "x", count: 400)), at: Self.start + 2)
        // Both pieces are within the window: 800 characters, about 200 tokens, over the 1.5
        // seconds since the first token.
        #expect(abs((tracker.sample.liveTokensPerSecond(at: Self.start + 2.5) ?? 0) - 200 / 1.5) < 0.01)
        // Only the second piece is left in the window.
        #expect(tracker.sample.liveTokensPerSecond(at: Self.start + 3.5) == 50)
        // The stream went quiet.
        #expect(tracker.sample.liveTokensPerSecond(at: Self.start + 5) == nil)

        // Without the API's count, the average is estimated from the characters.
        tracker.finish(at: Self.start + 5)
        #expect(!tracker.sample.hasExactRate)
        #expect(tracker.sample.averageTokensPerSecond == 200)
    }

    @Test func feedsBytesAcrossEvents() {
        var tracker = ClaudeStreamTracker(startedAt: Self.start)
        let body = "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        tracker.feed(Data(body.utf8), at: Self.start + 2)
        #expect(tracker.sample.timeToFirstToken == 2)
        #expect(tracker.sample.finishedAt == Self.start + 2)
    }

    @Test func errorEventFails() {
        var tracker = ClaudeStreamTracker(startedAt: Self.start)
        tracker.apply(SSEEvent(name: "error", data: "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\"}}"), at: Self.start + 1)
        #expect(tracker.sample.failed)
        #expect(!tracker.sample.isStreaming)
    }

    @Test func bodyEndingEarlyFails() {
        var tracker = ClaudeStreamTracker(startedAt: Self.start)
        tracker.apply(Self.delta("partial"), at: Self.start + 1)
        tracker.finish(at: Self.start + 2)
        #expect(tracker.sample.failed)
        #expect(tracker.sample.timeToFirstToken == 1, "what did arrive is still timed")
    }
}

@Suite
struct ClaudeStreamStateTests {
    private static let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func labelWhileWaiting() {
        let state = ClaudeStreamState(sample: ClaudeStreamSample(startedAt: Self.start), asOf: Self.start + 1.26)
        #expect(state.label == "ttft 1.3s…")
    }

    @Test func labelWhileStreamingIsTheLiveRate() {
        var sample = ClaudeStreamSample(startedAt: Self.start)
        sample.firstTokenAt = Self.start + 0.8
        sample.lastTokenAt = Self.start + 4
        sample.characters = 1200
        sample.recentDeltas = [.init(at: Self.start + 3.5, characters: 600), .init(at: Self.start + 4, characters: 600)]
        // 1,200 characters, about 300 tokens, in the two-second window.
        #expect(ClaudeStreamState(sample: sample, asOf: Self.start + 4.8).label == "ttft 0.8s · ~150 tok/s")
        // Nothing arrived lately.
        #expect(ClaudeStreamState(sample: sample, asOf: Self.start + 7).label == "ttft 0.8s · …")
    }

    @Test func labelWhenDone() {
        var sample = ClaudeStreamSample(startedAt: Self.start)
        sample.firstTokenAt = Self.start + 12
        sample.lastTokenAt = Self.start + 32
        sample.outputTokens = 1500
        sample.finishedAt = Self.start + 32
        let state = ClaudeStreamState(sample: sample, asOf: Self.start + 100)
        #expect(state.label == "ttft 12s · avg 75 tok/s")
        #expect(state.help == "First token after 12s. 1,500 output tokens in 20s, 75 tokens per second on average.")
    }

    @Test func nothingForAFailureWithoutTokens() {
        var sample = ClaudeStreamSample(startedAt: Self.start)
        sample.failed = true
        sample.finishedAt = Self.start + 1
        #expect(ClaudeStreamState(sample: sample, asOf: Self.start + 2).label == nil)
    }
}

@Suite
struct HTTPParsingTests {
    @Test func parsesARequestHead() throws {
        let raw = "POST /v1/messages?beta=true HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nContent-Length: 5\r\nX-Claude-Code-Session-Id: abc\r\n\r\nhelloNEXT"
        let parsed = try #require(try HTTPParsing.parseRequestHead(Data(raw.utf8)))
        #expect(parsed.head.method == "POST")
        #expect(parsed.head.target == "/v1/messages?beta=true")
        #expect(parsed.head.contentLength == 5)
        #expect(parsed.head.value(of: "x-claude-code-session-id") == "abc")
        #expect(!parsed.head.isChunked)
        #expect(!parsed.head.wantsClose)
        #expect(parsed.length == raw.utf8.count - "helloNEXT".utf8.count)
    }

    @Test func incompleteHeadIsNil() throws {
        #expect(try HTTPParsing.parseRequestHead(Data("GET /api/hello HTTP/1.1\r\nHost: x\r\n".utf8)) == nil)
    }

    @Test func malformedRequestLineThrows() {
        #expect(throws: HTTPParseError.malformedRequestLine) {
            try HTTPParsing.parseRequestHead(Data("nonsense\r\n\r\n".utf8))
        }
    }

    @Test func parsesASlicedBuffer() throws {
        // Buffers left over from an earlier request don't start at index zero.
        let raw = Data("XXXHEAD /api/hello HTTP/1.1\r\nConnection: close\r\n\r\n".utf8)
        let parsed = try #require(try HTTPParsing.parseRequestHead(raw.dropFirst(3)))
        #expect(parsed.head.method == "HEAD")
        #expect(parsed.head.wantsClose)
        #expect(parsed.length == raw.count - 3)
    }

    @Test func decodesChunkedBodies() throws {
        let raw = Data("5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nTrailer: x\r\n\r\nrest".utf8)
        let decoded = try #require(try HTTPParsing.decodeChunkedBody(raw))
        #expect(String(decoding: decoded.body, as: UTF8.self) == "hello world")
        #expect(decoded.length == raw.count - 4)

        #expect(try HTTPParsing.decodeChunkedBody(Data("5\r\nhel".utf8)) == nil)
        #expect(throws: HTTPParseError.malformedChunk) {
            try HTTPParsing.decodeChunkedBody(Data("zz\r\n".utf8))
        }
    }

    @Test func upstreamURLKeepsAPathPrefix() {
        let proxy = ClaudeStreamProxy(upstream: URL(string: "https://gateway.example.com/anthropic/")!)
        #expect(proxy.upstreamURL(for: "/v1/messages?beta=true")?.absoluteString == "https://gateway.example.com/anthropic/v1/messages?beta=true")
        #expect(proxy.upstreamURL(for: "*") == nil)
    }
}

/// The proxy in front of a fake API on another loopback port.
@Suite(.serialized)
struct ClaudeStreamProxyTests {
    private static let sessionID = UUID()

    /// A streamed reply, in the pieces the API would send it in.
    private static let replyChunks: [String] = [
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":10,\"output_tokens\":1}}}\n\n",
        "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
        "event: ping\ndata: {\"type\": \"ping\"}\n\n",
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello, \"}}\n\n",
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"world.\"}}\n\n",
        "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":12}}\n\n",
        "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
    ]

    @Test func relaysAStreamedReplyAndTimesIt() async throws {
        let upstream = try FakeUpstream { request in
            #expect(request.head.method == "POST")
            #expect(request.head.target == "/v1/messages?beta=true")
            #expect(request.head.value(of: "anthropic-beta") == "oauth-2025-04-20")
            #expect(request.head.value(of: "Accept-Encoding") == "identity")
            #expect(String(decoding: request.body, as: UTF8.self) == "{\"model\":\"claude\"}")
            return .stream(
                status: 200,
                headers: ["Content-Type": "text/event-stream", "anthropic-ratelimit-unified-status": "allowed"],
                chunks: Self.replyChunks, delay: 0.05)
        }
        defer { upstream.stop() }

        let proxy = ClaudeStreamProxy(upstream: upstream.url)
        let samples = Samples()
        proxy.onUpdate = { request, sample in samples.add(request, sample) }
        let port = try proxy.start()
        defer { proxy.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages?beta=true")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{\"model\":\"claude\"}".utf8)
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.sessionID.uuidString.lowercased(), forHTTPHeaderField: "x-claude-code-session-id")
        request.setValue("main", forHTTPHeaderField: "x-claude-code-request-class")
        let (body, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")
        #expect(http.value(forHTTPHeaderField: "anthropic-ratelimit-unified-status") == "allowed")
        #expect(String(decoding: body, as: UTF8.self) == Self.replyChunks.joined())

        let (lastRequest, last) = try #require(samples.last)
        #expect(lastRequest.sessionID == Self.sessionID)
        #expect(lastRequest.requestClass == "main")
        #expect(lastRequest.isMainConversation)
        #expect(last.outputTokens == 12)
        #expect(!last.failed)
        #expect(!last.isStreaming)
        let ttft = try #require(last.timeToFirstToken)
        // Three chunks were sent before the first token, a little apart.
        #expect(ttft > 0.1 && ttft < 2)
        #expect(last.characters == "Hello, world.".count)
        #expect(samples.count >= 3, "the start, the tokens and the end were each reported")
        #expect(samples.all.allSatisfy { $0.0.id == lastRequest.id })
    }

    @Test func relaysErrorsUnchanged() async throws {
        let upstream = try FakeUpstream { _ in
            .stream(
                status: 429,
                headers: ["Content-Type": "application/json", "retry-after": "7", "x-should-retry": "true"],
                chunks: ["{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}"], delay: 0)
        }
        defer { upstream.stop() }
        let proxy = ClaudeStreamProxy(upstream: upstream.url)
        let samples = Samples()
        proxy.onUpdate = { request, sample in samples.add(request, sample) }
        let port = try proxy.start()
        defer { proxy.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages?beta=true")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue(Self.sessionID.uuidString, forHTTPHeaderField: "x-claude-code-session-id")
        let (body, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 429)
        #expect(http.value(forHTTPHeaderField: "retry-after") == "7")
        #expect(http.value(forHTTPHeaderField: "x-should-retry") == "true")
        #expect(String(decoding: body, as: UTF8.self).contains("slow down"))

        let (_, last) = try #require(samples.last)
        #expect(last.failed)
        #expect(last.timeToFirstToken == nil)
    }

    @Test func answersHeadAndKeepsTheConnection() async throws {
        let upstream = try FakeUpstream { request in
            .stream(status: request.head.method == "HEAD" ? 200 : 404, headers: ["Content-Length": "0"], chunks: [], delay: 0)
        }
        defer { upstream.stop() }
        let proxy = ClaudeStreamProxy(upstream: upstream.url)
        let port = try proxy.start()
        defer { proxy.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/hello")!)
        request.httpMethod = "HEAD"
        let session = URLSession(configuration: .ephemeral)
        for _ in 0..<3 {
            let (_, response) = try await session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
        }
    }

    @Test func reportsAnUnreachableUpstream() async throws {
        // A port nothing listens on.
        let closed = try FakeUpstream { _ in .stream(status: 200, headers: [:], chunks: [], delay: 0) }
        let url = closed.url
        closed.stop()

        let proxy = ClaudeStreamProxy(upstream: url)
        let port = try proxy.start()
        defer { proxy.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        let (body, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 502)
        let error = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(error["type"] as? String == "error")
    }
}

/// Collects what the proxy reports, from its queue.
private final class Samples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(ClaudeStreamRequest, ClaudeStreamSample)] = []

    func add(_ request: ClaudeStreamRequest, _ sample: ClaudeStreamSample) {
        lock.lock()
        defer { lock.unlock() }
        samples.append((request, sample))
    }

    var all: [(ClaudeStreamRequest, ClaudeStreamSample)] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    var last: (ClaudeStreamRequest, ClaudeStreamSample)? { all.last }
    var count: Int { all.count }
}

/// A one-request-at-a-time HTTP/1.1 server standing in for the API.
private final class FakeUpstream: @unchecked Sendable {
    struct Request {
        let head: HTTPRequestHead
        let body: Data
    }

    enum Response {
        /// A response whose body is written in `chunks`, `delay` seconds apart.
        case stream(status: Int, headers: [String: String], chunks: [String], delay: TimeInterval)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-upstream")
    private let handler: (Request) -> Response
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    var url: URL { URL(string: "http://127.0.0.1:\(port)")! }

    init(handler: @escaping (Request) -> Response) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 2)
        guard let port = listener.port?.rawValue else { throw ClaudeStreamProxy.StartError.timedOut }
        self.port = port
    }

    func stop() {
        listener.cancel()
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func serve(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self, error == nil, !isComplete || data != nil else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let (head, length) = try? HTTPParsing.parseRequestHead(buffer) else {
                if !isComplete { self.read(connection, buffer: buffer) }
                return
            }
            let bodyLength = head.contentLength ?? 0
            guard buffer.count - length >= bodyLength else {
                if !isComplete { self.read(connection, buffer: buffer) }
                return
            }
            let body = Data(buffer.dropFirst(length).prefix(bodyLength))
            let rest = Data(buffer.dropFirst(length + bodyLength))
            self.respond(connection, to: Request(head: head, body: body), then: rest)
        }
    }

    private func respond(_ connection: NWConnection, to request: Request, then rest: Data) {
        switch handler(request) {
        case .stream(let status, let headers, let chunks, let delay):
            let bodyless = request.head.method == "HEAD"
            var lines = ["HTTP/1.1 \(status) \(HTTPParsing.reasonPhrase(for: status))"]
            for (name, value) in headers where !(bodyless && name.lowercased() == "content-length") {
                lines.append("\(name): \(value)")
            }
            if !bodyless && headers["Content-Length"] == nil {
                lines.append("Transfer-Encoding: chunked")
            }
            if bodyless && headers["Content-Length"] == nil {
                lines.append("Content-Length: 0")
            }
            connection.send(content: Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8), completion: .idempotent)

            for (index, chunk) in chunks.enumerated() {
                queue.asyncAfter(deadline: .now() + delay * Double(index + 1)) {
                    let data = Data(chunk.utf8)
                    connection.send(content: Data("\(String(data.count, radix: 16))\r\n".utf8) + data + Data("\r\n".utf8), completion: .idempotent)
                }
            }
            if !bodyless && headers["Content-Length"] == nil {
                queue.asyncAfter(deadline: .now() + delay * Double(chunks.count + 1)) {
                    connection.send(content: Data("0\r\n\r\n".utf8), completion: .idempotent)
                }
            }
        }
        read(connection, buffer: rest)
    }
}
