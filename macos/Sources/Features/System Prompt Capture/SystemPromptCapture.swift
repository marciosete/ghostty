import AppKit
import Foundation
import OSLog

/// Saves the requests Claude Code sends to the model, system prompt and all, exactly as the
/// API receives them. It is off until turned on, and then applies to terminals opened
/// afterwards: they get `ANTHROPIC_BASE_URL` set to a local proxy, which saves every request
/// it passes on to disk.
///
/// Once started the proxy runs until Ghostty quits, since terminals opened while capturing
/// keep sending their requests to it after capturing is turned off. It stops saving then.
final class SystemPromptCapture {
    static let shared = SystemPromptCapture()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "system-prompt-capture")

    static var defaultDirectory: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty", isDirectory: true)
            .appendingPathComponent("Claude Code Requests", isDirectory: true)
    }

    let directory: URL

    /// Whether new terminals are captured. Only changed on the main queue.
    private(set) var isEnabled = false

    /// Set once the proxy is listening.
    private var port: UInt16?
    private var proxy: SystemPromptProxy?

    /// Read by the proxy as requests come in, so kept apart from `isEnabled`.
    private let saving = NSLock()
    private var isSaving = false

    /// Saves requests in the order they came in.
    private let writeQueue = DispatchQueue(label: "com.mitchellh.ghostty.system-prompt-capture")

    /// Keeps apart requests sent within the same millisecond.
    private var sequence = 0

    init(directory: URL = SystemPromptCapture.defaultDirectory) {
        self.directory = directory
    }

    /// The variables that send a new terminal's Claude Code requests through the proxy.
    var environment: [String: String] {
        guard isEnabled, let port else { return [:] }
        return ["ANTHROPIC_BASE_URL": "http://127.0.0.1:\(port)"]
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        saving.withLock { isSaving = enabled }
        guard enabled, proxy == nil else { return }

        // Chain onto a base URL Ghostty was itself started with, such as a gateway.
        let upstream = ProcessInfo.processInfo.environment["ANTHROPIC_BASE_URL"] ?? "https://api.anthropic.com"
        let proxy = SystemPromptProxy(upstream: upstream) { [weak self] request in
            self?.record(request)
        }
        self.proxy = proxy
        proxy.start { [weak self] port in
            guard let self else { return }
            if let port {
                self.port = port
            } else {
                Self.logger.error("the system prompt proxy couldn't start")
                self.proxy = nil
                self.isEnabled = false
                self.saving.withLock { self.isSaving = false }
            }
        }
    }

    private func record(_ request: ProxyRequest) {
        guard saving.withLock({ isSaving }) else { return }
        let capturedAt = Date()
        writeQueue.async { [self] in
            do {
                try save(request, capturedAt: capturedAt)
            } catch {
                Self.logger.error("couldn't save a request: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Headers that carry the account's credentials. Their values aren't written to disk.
    static let credentialHeaders: Set<String> = ["authorization", "x-api-key", "proxy-authorization", "cookie"]

    /// Writes the request's body byte for byte as it goes to the API, and its request line
    /// and headers next to it, credentials masked. Names start with the time to the
    /// millisecond, so the files sort in the order the requests were sent.
    func save(_ request: ProxyRequest, capturedAt: Date) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss.SSS"
        let path = request.path.split(separator: "/").joined(separator: "-")
        sequence += 1
        let base = [
            formatter.string(from: capturedAt), String(sequence), request.method, path.isEmpty ? "root" : path,
        ].joined(separator: "-")

        try Data(request.head(redacting: Self.credentialHeaders).utf8)
            .write(to: directory.appendingPathComponent(base + ".http"), options: .atomic)
        if !request.body.isEmpty {
            let isJSON = request.header("Content-Type")?.contains("json") ?? false
            try request.body
                .write(to: directory.appendingPathComponent(base + (isJSON ? ".json" : ".body")), options: .atomic)
        }
    }

    func revealInFinder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}
