import Foundation
import Network

/// Who sent a request through the proxy, from the headers Claude Code puts on every
/// request to its API base URL.
struct ClaudeStreamRequest: Equatable {
    let id: UUID
    let sessionID: UUID?

    /// Set on requests from a subagent Claude Code spawned in the session.
    let agentID: String?

    /// `main`, `subagent`, `compaction` or `auxiliary`, when Claude Code sends its gateway
    /// hint headers.
    let requestClass: String?
    let promptID: String?

    /// Whether the request is a turn of the conversation the user sees. Without the class
    /// header, a request from no subagent is taken as one.
    var isMainConversation: Bool {
        if let requestClass { return requestClass == "main" }
        return agentID == nil
    }

    init(head: HTTPRequestHead) {
        id = UUID()
        sessionID = head.value(of: "x-claude-code-session-id").flatMap(UUID.init(uuidString:))
        agentID = head.value(of: "x-claude-code-agent-id")
        requestClass = head.value(of: "x-claude-code-request-class")
        promptID = head.value(of: "x-claude-code-prompt-id")
    }

    init(id: UUID = UUID(), sessionID: UUID?, agentID: String? = nil, requestClass: String? = nil, promptID: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.agentID = agentID
        self.requestClass = requestClass
        self.promptID = promptID
    }
}

/// A local HTTP proxy in front of the Anthropic API. Claude Code is pointed at it with
/// `ANTHROPIC_BASE_URL`, and it forwards every request to the upstream untouched while it
/// reads the streamed responses as they pass, to time the first token and the tokens per
/// second of each reply.
///
/// It speaks HTTP/1.1 on the loopback interface. Requests and responses go through whole,
/// headers included, except for the ones that describe the connection itself. Responses
/// are relayed as they arrive, since Claude Code reads them as they stream and aborts a
/// stream that goes silent.
final class ClaudeStreamProxy: NSObject {
    static let defaultUpstream = URL(string: "https://api.anthropic.com")!

    /// Where requests are forwarded. A path in it is kept in front of the request's path.
    let upstream: URL

    /// Called on the proxy's queue whenever the timing of a streamed reply changes.
    var onUpdate: ((ClaudeStreamRequest, ClaudeStreamSample) -> Void)?

    /// The port the proxy listens on, once started.
    private(set) var port: UInt16?

    /// The URL Claude Code is given as its API base URL.
    var baseURL: String? {
        port.map { "http://127.0.0.1:\($0)" }
    }

    /// The main thread waits on this queue while the listener starts, so it runs at a
    /// quality of service that doesn't make that wait a priority inversion.
    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.claude-stream-proxy", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ProxyConnection] = [:]
    private var tasks: [Int: ProxyConnection] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // Replies stream for as long as the model works; the idle timeout only has to
        // outlast the pauses between the upstream's keep-alive pings.
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = 32
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false

        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    init(upstream: URL = defaultUpstream) {
        self.upstream = upstream
    }

    enum StartError: Error {
        case listenFailed(Error?)
        case timedOut
    }

    /// Starts listening on a free loopback port and returns it. Waits up to `timeout` for
    /// the port, so callers can hand out the base URL right away.
    @discardableResult
    func start(timeout: TimeInterval = 2) throws -> UInt16 {
        if let port { return port }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)

        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failure = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + timeout) == .success else {
            listener.cancel()
            throw StartError.timedOut
        }
        guard failure == nil, let port = listener.port?.rawValue else {
            listener.cancel()
            throw StartError.listenFailed(failure)
        }
        self.listener = listener
        self.port = port
        return port
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            port = nil
            for connection in connections.values {
                connection.close()
            }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        let proxyConnection = ProxyConnection(connection, proxy: self)
        connections[ObjectIdentifier(proxyConnection)] = proxyConnection
        proxyConnection.start(on: queue)
    }

    // MARK: Connections

    fileprivate func forget(_ connection: ProxyConnection) {
        connections[ObjectIdentifier(connection)] = nil
    }

    /// The upstream URL of a request for `target`, the path and query the client sent.
    func upstreamURL(for target: String) -> URL? {
        guard target.hasPrefix("/") else { return nil }
        var base = upstream.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + target)
    }

    fileprivate func forward(_ request: URLRequest, for connection: ProxyConnection) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        tasks[task.taskIdentifier] = connection
        task.resume()
        return task
    }

    fileprivate func report(_ request: ClaudeStreamRequest, _ sample: ClaudeStreamSample) {
        onUpdate?(request, sample)
    }
}

extension ClaudeStreamProxy: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let connection = tasks[dataTask.taskIdentifier], let response = response as? HTTPURLResponse {
            connection.upstreamDidRespond(response)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        tasks[dataTask.taskIdentifier]?.upstreamDidSend(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let connection = tasks.removeValue(forKey: task.taskIdentifier) else { return }
        connection.upstreamDidFinish(error: error)
    }

    /// Redirects are the client's to follow, not the proxy's.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// One client connection: reads its requests one after the other, forwards each and relays
/// the response before reading the next.
private final class ProxyConnection {
    private let connection: NWConnection
    private unowned let proxy: ClaudeStreamProxy
    private var buffer = Data()
    private var closed = false

    private enum State {
        case readingHead
        case readingBody(HTTPRequestHead, sentContinue: Bool)
        case forwarding(Forward)
    }

    private final class Forward {
        let head: HTTPRequestHead
        var task: URLSessionDataTask?
        var wroteHead = false

        /// Whether the response has no body to frame: a reply to HEAD, or a status without one.
        var bodyless = false

        /// Set for a Messages API request, to time its reply.
        var request: ClaudeStreamRequest?
        var tracker: ClaudeStreamTracker?

        init(head: HTTPRequestHead) {
            self.head = head
        }
    }

    private var state: State = .readingHead

    /// A request body larger than this can't be Claude Code's; the connection is dropped.
    private static let maximumBodySize = 256 << 20

    init(_ connection: NWConnection, proxy: ClaudeStreamProxy) {
        self.connection = connection
        self.proxy = proxy
    }

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.clientClosed()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.process()
            }
            if isComplete || error != nil {
                self.clientClosed()
            } else if !self.closed {
                self.receive()
            }
        }
    }

    /// Reads as much of the next request as the buffer holds, and forwards it once whole.
    private func process() {
        guard !closed else { return }
        switch state {
        case .readingHead:
            do {
                guard let (head, length) = try HTTPParsing.parseRequestHead(buffer) else { return }
                buffer = Data(buffer.dropFirst(length))
                state = .readingBody(head, sentContinue: false)
            } catch {
                close()
                return
            }
            process()

        case .readingBody(let head, let sentContinue):
            if head.expectsContinue && !sentContinue {
                state = .readingBody(head, sentContinue: true)
                send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
            }

            let body: Data
            if head.isChunked {
                do {
                    guard let (decoded, length) = try HTTPParsing.decodeChunkedBody(buffer) else {
                        if buffer.count > Self.maximumBodySize { close() }
                        return
                    }
                    body = decoded
                    buffer = Data(buffer.dropFirst(length))
                } catch {
                    close()
                    return
                }
            } else if let length = head.contentLength {
                guard length <= Self.maximumBodySize else {
                    close()
                    return
                }
                guard buffer.count >= length else { return }
                body = buffer.prefix(length)
                buffer = Data(buffer.dropFirst(length))
            } else {
                body = Data()
            }
            forward(head, body: body)

        case .forwarding:
            // The next request waits in the buffer until this response is through.
            return
        }
    }

    // MARK: Upstream

    private func forward(_ head: HTTPRequestHead, body: Data) {
        guard let url = proxy.upstreamURL(for: head.target) else {
            respondWithError(status: 400, message: "Ghostty couldn't forward the request target \(head.target)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = head.method
        for header in head.headers {
            let name = header.name.lowercased()
            guard !HTTPParsing.hopByHopHeaders.contains(name), name != "accept-encoding" else { continue }
            request.addValue(header.value, forHTTPHeaderField: header.name)
        }
        // The response is relayed byte for byte, so it can't be compressed in between.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if !body.isEmpty || head.method == "POST" || head.method == "PUT" {
            request.httpBody = body
        }

        let forward = Forward(head: head)
        if head.method == "POST", Self.isMessagesPath(head.target) {
            let now = Date()
            forward.request = ClaudeStreamRequest(head: head)
            forward.tracker = ClaudeStreamTracker(startedAt: now)
            report(forward)
        }
        state = .forwarding(forward)
        forward.task = proxy.forward(request, for: self)
    }

    /// Whether `target` is the Messages endpoint, whose replies are timed. Token counting
    /// lives under the same path but isn't a reply.
    static func isMessagesPath(_ target: String) -> Bool {
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return path == "/v1/messages" || path.hasSuffix("/v1/messages")
    }

    func upstreamDidRespond(_ response: HTTPURLResponse) {
        guard case .forwarding(let forward) = state, !forward.wroteHead else { return }
        forward.wroteHead = true

        let status = response.statusCode
        forward.bodyless = forward.head.method == "HEAD" || status == 204 || status == 304 || (100..<200).contains(status)

        var lines = ["HTTP/1.1 \(status) \(HTTPParsing.reasonPhrase(for: status))"]
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            let lowered = name.lowercased()
            guard !HTTPParsing.hopByHopHeaders.contains(lowered), lowered != "content-encoding" else { continue }
            lines.append("\(name): \(value)")
        }
        if !forward.bodyless {
            lines.append("Transfer-Encoding: chunked")
        }
        lines.append("Connection: \(forward.head.wantsClose ? "close" : "keep-alive")")
        send(Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8))

        if forward.tracker != nil {
            let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
            if status != 200 || !contentType.lowercased().contains("text/event-stream") {
                // A rejected request, or an unstreamed reply: nothing to time.
                forward.tracker?.fail(at: Date())
                report(forward)
                forward.tracker = nil
            }
        }
    }

    func upstreamDidSend(_ data: Data) {
        guard case .forwarding(let forward) = state, forward.wroteHead, !forward.bodyless else { return }
        send(Data(String(data.count, radix: 16).utf8) + Data("\r\n".utf8) + data + Data("\r\n".utf8))

        if forward.tracker != nil {
            forward.tracker?.feed(data, at: Date())
            report(forward)
        }
    }

    func upstreamDidFinish(error: Error?) {
        guard case .forwarding(let forward) = state else { return }

        if let error {
            if forward.tracker != nil {
                forward.tracker?.fail(at: Date())
                report(forward)
            }
            if forward.wroteHead {
                // The client already has part of the response; ending the connection tells
                // it the rest never came, and Claude Code retries from there.
                close()
            } else {
                let host = proxy.upstream.host ?? proxy.upstream.absoluteString
                respondWithError(status: 502, message: "Ghostty couldn't reach \(host): \(error.localizedDescription)")
            }
            return
        }

        if !forward.bodyless {
            send(Data("0\r\n\r\n".utf8))
        }
        if forward.tracker != nil {
            forward.tracker?.finish(at: Date())
            report(forward)
        }

        if forward.head.wantsClose {
            close()
        } else {
            state = .readingHead
            process()
        }
    }

    private func report(_ forward: Forward) {
        guard let request = forward.request, let tracker = forward.tracker else { return }
        proxy.report(request, tracker.sample)
    }

    // MARK: Client

    private func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    /// Answers the pending request with an error of the proxy's own, in the API's error
    /// shape so Claude Code shows it, then closes the connection.
    private func respondWithError(status: Int, message: String) {
        let body = (try? JSONSerialization.data(withJSONObject: [
            "type": "error",
            "error": ["type": "api_error", "message": message],
        ])) ?? Data()
        let head = [
            "HTTP/1.1 \(status) \(HTTPParsing.reasonPhrase(for: status))",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Connection: close",
        ].joined(separator: "\r\n") + "\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private func clientClosed() {
        guard !closed else { return }
        if case .forwarding(let forward) = state {
            forward.task?.cancel()
        }
        close()
    }

    func close() {
        guard !closed else { return }
        closed = true
        if case .forwarding(let forward) = state {
            forward.task?.cancel()
        }
        connection.cancel()
        proxy.forget(self)
    }
}
