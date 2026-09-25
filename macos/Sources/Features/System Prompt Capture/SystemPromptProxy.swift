import Foundation
import Network

/// A local HTTP proxy for the Anthropic API. Claude Code sends its requests here when
/// `ANTHROPIC_BASE_URL` points at it; each one is shown to `onRequest` and passed on to the
/// real API, and the answer is streamed back as it arrives.
///
/// Each connection carries one request and is closed after the answer, which marks where the
/// answer ends. That leaves no lengths or chunking to rewrite after URLSession has unpacked a
/// compressed answer.
final class SystemPromptProxy {
    private let upstream: String
    private let onRequest: (ProxyRequest) -> Void
    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.system-prompt-proxy")
    private var listener: NWListener?

    /// Request headers that describe this hop rather than the request, so URLSession sets
    /// its own.
    private static let hopRequestHeaders: Set<String> = [
        "host", "content-length", "connection", "keep-alive", "proxy-connection",
        "transfer-encoding", "accept-encoding", "upgrade",
    ]

    /// Answer headers that no longer hold once URLSession has unpacked the body.
    private static let hopResponseHeaders: Set<String> = [
        "content-length", "content-encoding", "connection", "keep-alive", "transfer-encoding",
    ]

    init(upstream: String, onRequest: @escaping (ProxyRequest) -> Void) {
        self.upstream = upstream.hasSuffix("/") ? String(upstream.dropLast()) : upstream
        self.onRequest = onRequest
    }

    /// Listens on a free loopback port and calls `ready` on the main queue with the port, or
    /// with nil if the proxy couldn't start.
    func start(ready: @escaping (UInt16?) -> Void) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else {
            ready(nil)
            return
        }
        self.listener = listener

        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                let port = listener?.port?.rawValue
                DispatchQueue.main.async { ready(port) }
            case .failed:
                DispatchQueue.main.async { ready(nil) }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var buffer = buffer
            if let data { buffer.append(data) }

            let request: ProxyRequest?
            do {
                request = try ProxyRequest.parse(buffer)
            } catch {
                Self.fail(connection, status: 400)
                return
            }

            if let request {
                self.onRequest(request)
                self.forward(request, over: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func forward(_ request: ProxyRequest, over connection: NWConnection) {
        guard let url = URL(string: upstream + request.target) else {
            Self.fail(connection, status: 400)
            return
        }

        var upstreamRequest = URLRequest(url: url)
        upstreamRequest.httpMethod = request.method
        upstreamRequest.httpBody = request.body.isEmpty ? nil : request.body
        for (name, value) in request.headers where !Self.hopRequestHeaders.contains(name.lowercased()) {
            upstreamRequest.addValue(value, forHTTPHeaderField: name)
        }

        ProxyExchange(connection: connection).start(upstreamRequest)
    }

    fileprivate static func fail(_ connection: NWConnection, status: Int) {
        let head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
            + "Content-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Passes one answer from the API back over the connection its request came in on.
    private final class ProxyExchange: NSObject, URLSessionDataDelegate {
        private let connection: NWConnection
        private var responded = false

        init(connection: NWConnection) {
            self.connection = connection
        }

        func start(_ request: URLRequest) {
            let configuration = URLSessionConfiguration.ephemeral
            // Long thinking can leave a stream quiet for a while.
            configuration.timeoutIntervalForRequest = 600
            // The session holds the exchange until the answer is passed on.
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.dataTask(with: request)

            // Claude Code hangs up when a request is interrupted; stop asking the API then.
            connection.stateUpdateHandler = { state in
                switch state {
                case .failed, .cancelled: task.cancel()
                default: break
                }
            }
            task.resume()
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let response = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                return
            }

            var head = "HTTP/1.1 \(response.statusCode) "
                + "\(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))\r\n"
            for case let (name as String, value as String) in response.allHeaderFields
            where !SystemPromptProxy.hopResponseHeaders.contains(name.lowercased()) {
                head += "\(name): \(value)\r\n"
            }
            head += "Connection: close\r\n\r\n"

            responded = true
            connection.send(content: Data(head.utf8), completion: .idempotent)
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            connection.send(content: data, completion: .idempotent)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            session.finishTasksAndInvalidate()
            guard responded else {
                SystemPromptProxy.fail(connection, status: 502)
                return
            }
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
        }
    }
}
