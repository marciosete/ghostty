import Foundation

/// One event of a server-sent event stream.
struct SSEEvent: Equatable {
    var name: String?
    var data: String
}

/// Splits a server-sent event stream into events, however the bytes are chunked.
struct SSEParser {
    private var pending = Data()
    private var name: String?
    private var dataLines: [String] = []

    /// Feeds bytes of the stream, and returns the events they complete.
    mutating func feed(_ bytes: Data) -> [SSEEvent] {
        pending.append(bytes)
        var events: [SSEEvent] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            pending.removeSubrange(pending.startIndex...newline)
            if let event = consume(line: String(decoding: line, as: UTF8.self)) {
                events.append(event)
            }
        }
        return events
    }

    /// Handles one line; a blank line ends the event being collected.
    private mutating func consume(line: String) -> SSEEvent? {
        if line.isEmpty {
            guard name != nil || !dataLines.isEmpty else { return nil }
            let event = SSEEvent(name: name, data: dataLines.joined(separator: "\n"))
            name = nil
            dataLines = []
            return event
        }
        if line.hasPrefix(":") { return nil }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[line.startIndex..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = line[...]
            value = ""
        }
        switch field {
        case "event": name = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }
}

/// The timing of one streamed Messages API response, as seen on the wire.
struct ClaudeStreamSample: Equatable {
    /// When the request was forwarded upstream.
    let startedAt: Date

    /// When the first piece of content arrived.
    var firstTokenAt: Date?

    /// When the latest piece of content arrived.
    var lastTokenAt: Date?

    /// Characters of text, thinking and tool input streamed so far.
    var characters = 0

    /// One piece of content, for the live rate.
    struct Delta: Equatable {
        let at: Date
        let characters: Int
    }

    /// The pieces of content that arrived in the last `liveWindow`.
    var recentDeltas: [Delta] = []

    /// The output tokens the API reported at the end of the message.
    var outputTokens: Int?

    /// When the response ended, complete or not.
    var finishedAt: Date?

    /// Whether the response failed: an HTTP error, an error event or a dropped connection.
    var failed = false

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    /// Anthropic's tokens run about four characters of English or code each.
    static let charactersPerToken = 4.0

    /// An average needs a few tokens over a little time to mean anything.
    static let minimumTokensForRate = 8
    static let minimumSecondsForRate: TimeInterval = 0.25

    /// How far back the live rate looks.
    static let liveWindow: TimeInterval = 2

    /// The live rate needs a few tokens in its window, or it's noise.
    static let minimumTokensForLiveRate = 4.0

    var isStreaming: Bool { finishedAt == nil && !failed }

    /// How long the first content took to arrive after the request was sent.
    var timeToFirstToken: TimeInterval? {
        firstTokenAt.map { $0.timeIntervalSince(startedAt) }
    }

    /// Whether the average is from the API's own token count rather than an estimate from
    /// the characters seen.
    var hasExactRate: Bool { outputTokens != nil }

    /// Output tokens per second over the last `liveWindow`, while the reply streams. The
    /// tokens are estimated from the characters that arrived in the window, so the rate
    /// follows the stream as it speeds up and slows down.
    func liveTokensPerSecond(at now: Date) -> Double? {
        guard isStreaming, let firstTokenAt else { return nil }
        let windowStart = now.addingTimeInterval(-Self.liveWindow)
        let characters = recentDeltas.filter { $0.at > windowStart }.reduce(0) { $0 + $1.characters }
        let tokens = Double(characters) / Self.charactersPerToken
        let seconds = max(min(Self.liveWindow, now.timeIntervalSince(firstTokenAt)), Self.minimumSecondsForRate)
        guard tokens >= Self.minimumTokensForLiveRate else { return nil }
        return tokens / seconds
    }

    /// Output tokens per second over the whole reply, from the first to the last piece of
    /// content. The API's own token count when it reported one, otherwise an estimate from
    /// the characters seen.
    var averageTokensPerSecond: Double? {
        guard let firstTokenAt, let lastTokenAt else { return nil }
        let tokens = outputTokens.map(Double.init) ?? Double(characters) / Self.charactersPerToken
        let seconds = lastTokenAt.timeIntervalSince(firstTokenAt)
        guard tokens >= Double(Self.minimumTokensForRate), seconds >= Self.minimumSecondsForRate else { return nil }
        return tokens / seconds
    }
}

/// Follows the events of one streamed response to time its tokens.
struct ClaudeStreamTracker {
    private(set) var sample: ClaudeStreamSample
    private var parser = SSEParser()

    init(startedAt: Date) {
        sample = ClaudeStreamSample(startedAt: startedAt)
    }

    /// Feeds bytes of the response body.
    mutating func feed(_ bytes: Data, at now: Date) {
        for event in parser.feed(bytes) {
            apply(event, at: now)
        }
    }

    /// Applies one event of the stream. The event's name and its JSON `type` are the same,
    /// so either serves.
    mutating func apply(_ event: SSEEvent, at now: Date) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else { return }
        let type = event.name ?? object["type"] as? String
        switch type {
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any] else { return }
            let text = (delta["text"] as? String) ?? (delta["thinking"] as? String) ?? (delta["partial_json"] as? String)
            guard let text else { return }
            if sample.firstTokenAt == nil { sample.firstTokenAt = now }
            sample.lastTokenAt = now
            sample.characters += text.count
            let windowStart = now.addingTimeInterval(-ClaudeStreamSample.liveWindow)
            sample.recentDeltas.removeAll { $0.at <= windowStart }
            sample.recentDeltas.append(.init(at: now, characters: text.count))

        case "message_delta":
            if let usage = object["usage"] as? [String: Any],
               let tokens = usage["output_tokens"] as? NSNumber {
                sample.outputTokens = tokens.intValue
            }

        case "message_stop":
            sample.finishedAt = now

        case "error":
            sample.failed = true
            sample.finishedAt = now

        default:
            break
        }
    }

    /// The response body ended. A body that ended without `message_stop` was cut short.
    mutating func finish(at now: Date) {
        guard sample.finishedAt == nil else { return }
        sample.finishedAt = now
        if sample.outputTokens == nil { sample.failed = true }
    }

    mutating func fail(at now: Date) {
        sample.failed = true
        if sample.finishedAt == nil { sample.finishedAt = now }
    }
}

// MARK: HTTP/1.1 parsing

/// The request line and headers of an HTTP/1.1 request.
struct HTTPRequestHead: Equatable {
    let method: String

    /// The path and query, as sent.
    let target: String
    let headers: [(name: String, value: String)]

    static func == (lhs: HTTPRequestHead, rhs: HTTPRequestHead) -> Bool {
        lhs.method == rhs.method && lhs.target == rhs.target &&
            lhs.headers.map(\.name) == rhs.headers.map(\.name) &&
            lhs.headers.map(\.value) == rhs.headers.map(\.value)
    }

    /// The first value of header `name`, compared without case.
    func value(of name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var contentLength: Int? {
        value(of: "Content-Length").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    var isChunked: Bool {
        value(of: "Transfer-Encoding")?.lowercased().contains("chunked") ?? false
    }

    var wantsClose: Bool {
        value(of: "Connection")?.lowercased().split(separator: ",")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "close" } ?? false
    }

    var expectsContinue: Bool {
        value(of: "Expect")?.lowercased() == "100-continue"
    }
}

enum HTTPParseError: Error, Equatable {
    case malformedRequestLine
    case malformedHeader
    case malformedChunk
}

enum HTTPParsing {
    private static let headEnd = Data("\r\n\r\n".utf8)

    /// Parses the request head at the start of `buffer`: the head and how many bytes it took,
    /// or nil when the head isn't complete yet.
    static func parseRequestHead(_ buffer: Data) throws -> (head: HTTPRequestHead, length: Int)? {
        guard let end = buffer.range(of: headEnd) else { return nil }
        let text = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")[...]
        guard let requestLine = lines.popFirst() else { throw HTTPParseError.malformedRequestLine }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { throw HTTPParseError.malformedRequestLine }

        var headers: [(name: String, value: String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError.malformedHeader }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw HTTPParseError.malformedHeader }
            headers.append((name, value))
        }
        let head = HTTPRequestHead(method: String(parts[0]), target: String(parts[1]), headers: headers)
        return (head, end.upperBound - buffer.startIndex)
    }

    /// Decodes a chunked body at the start of `buffer`: the body and how many bytes it took,
    /// including the trailers, or nil when it isn't complete yet.
    static func decodeChunkedBody(_ buffer: Data) throws -> (body: Data, length: Int)? {
        var body = Data()
        var offset = buffer.startIndex
        while true {
            guard let lineEnd = buffer[offset...].range(of: Data("\r\n".utf8)) else { return nil }
            let sizeText = String(decoding: buffer[offset..<lineEnd.lowerBound], as: UTF8.self)
            let sizeField = sizeText.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard let size = Int(sizeField.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw HTTPParseError.malformedChunk
            }
            offset = lineEnd.upperBound
            if size == 0 {
                // Trailers, if any, end with an empty line.
                while true {
                    guard let trailerEnd = buffer[offset...].range(of: Data("\r\n".utf8)) else { return nil }
                    let empty = trailerEnd.lowerBound == offset
                    offset = trailerEnd.upperBound
                    if empty { return (body, offset - buffer.startIndex) }
                }
            }
            guard buffer.endIndex - offset >= size + 2 else { return nil }
            body.append(buffer[offset..<offset + size])
            offset += size
            guard buffer[offset] == 0x0D, buffer[offset + 1] == 0x0A else { throw HTTPParseError.malformedChunk }
            offset += 2
        }
    }

    /// Headers that describe the connection or the framing rather than the message. They
    /// are set again for each hop instead of copied.
    static let hopByHopHeaders: Set<String> = [
        "connection", "keep-alive", "transfer-encoding", "content-length", "te", "trailer",
        "upgrade", "proxy-connection", "proxy-authenticate", "proxy-authorization", "host",
    ]

    /// A reason phrase for the status line. Clients don't read it, but it keeps the line
    /// well-formed.
    static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 413: return "Payload Too Large"
        case 422: return "Unprocessable Entity"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        case 529: return "Overloaded"
        default: return "Status"
        }
    }
}
