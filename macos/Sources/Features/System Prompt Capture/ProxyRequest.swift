import Foundation

/// An HTTP/1.1 request read off a proxy connection.
struct ProxyRequest: Equatable {
    let method: String

    /// The path and query, such as `/v1/messages?beta=true`.
    let target: String

    /// Such as `HTTP/1.1`.
    let version: String

    /// In the order they were sent. Names keep their case.
    let headers: [(name: String, value: String)]

    let body: Data

    enum ParseError: Error {
        case malformed
    }

    /// The path without its query.
    var path: String {
        target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? target
    }

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func == (lhs: ProxyRequest, rhs: ProxyRequest) -> Bool {
        lhs.method == rhs.method
            && lhs.target == rhs.target
            && lhs.version == rhs.version
            && lhs.headers.map(\.name) == rhs.headers.map(\.name)
            && lhs.headers.map(\.value) == rhs.headers.map(\.value)
            && lhs.body == rhs.body
    }

    /// The request line and headers as they were sent, with the values of the headers in
    /// `redacting` masked.
    func head(redacting redacted: Set<String>) -> String {
        var lines = ["\(method) \(target) \(version)"]
        for (name, value) in headers {
            lines.append("\(name): \(redacted.contains(name.lowercased()) ? "[redacted]" : value)")
        }
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    private static let headerEnd = Data("\r\n\r\n".utf8)
    private static let lineEnd = Data("\r\n".utf8)

    /// Reads a whole request from the start of `data`. Returns nil while more bytes are needed.
    static func parse(_ data: Data) throws -> ProxyRequest? {
        guard let end = data.range(of: headerEnd) else { return nil }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            throw ParseError.malformed
        }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { throw ParseError.malformed }

        let headers: [(name: String, value: String)] = try lines.map { line in
            guard let colon = line.firstIndex(of: ":") else { throw ParseError.malformed }
            return (
                String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }

        let rest = data[end.upperBound...]
        let body: Data
        let transferEncoding = headers.first { $0.name.lowercased() == "transfer-encoding" }?.value
        if transferEncoding?.lowercased().contains("chunked") == true {
            guard let chunked = try decodeChunked(rest) else { return nil }
            body = chunked
        } else if let lengthHeader = headers.first(where: { $0.name.lowercased() == "content-length" }) {
            guard let length = Int(lengthHeader.value), length >= 0 else { throw ParseError.malformed }
            guard rest.count >= length else { return nil }
            body = Data(rest.prefix(length))
        } else {
            body = Data()
        }

        return ProxyRequest(
            method: String(requestLine[0]),
            target: String(requestLine[1]),
            version: String(requestLine[2]),
            headers: headers,
            body: body)
    }

    /// Joins the chunks of a chunked body. Returns nil until the last chunk has arrived.
    private static func decodeChunked(_ data: Data) throws -> Data? {
        var body = Data()
        var index = data.startIndex
        while true {
            guard let sizeEnd = data.range(of: lineEnd, in: index..<data.endIndex) else { return nil }
            guard let sizeLine = String(data: data[index..<sizeEnd.lowerBound], encoding: .ascii),
                  let size = Int(sizeLine.split(separator: ";").first ?? "", radix: 16) else {
                throw ParseError.malformed
            }
            let chunkStart = sizeEnd.upperBound
            guard data.distance(from: chunkStart, to: data.endIndex) >= size + 2 else { return nil }
            let chunkEnd = data.index(chunkStart, offsetBy: size)
            if size == 0 { return body }
            body.append(data[chunkStart..<chunkEnd])
            index = data.index(chunkEnd, offsetBy: 2)
        }
    }
}
