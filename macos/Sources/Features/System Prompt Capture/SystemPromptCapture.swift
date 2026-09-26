import AppKit
import Foundation
import OSLog

/// Saves the requests Claude Code sends to the model, system prompt and all, exactly as the
/// API receives them. It is off until turned on, and then applies to terminals opened
/// afterwards: they get `ANTHROPIC_BASE_URL` set to a local proxy, which keeps a folder per
/// session with the latest request of each of its threads.
///
/// Once started the proxy runs until Ghostty quits, since terminals opened while capturing
/// keep sending their requests to it after capturing is turned off. It stops saving then.
final class SystemPromptCapture {
    static let shared = SystemPromptCapture(sessionName: SystemPromptCapture.tabName(ofSession:))

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

    /// Sorts each session's requests into threads, by session ID. Only touched on
    /// `writeQueue`.
    private var routers: [String: CaptureRouter] = [:]

    /// The name of the tab running a session, by the session's ID. Called on the main queue.
    private let sessionName: (String) -> String?

    init(
        directory: URL = SystemPromptCapture.defaultDirectory,
        sessionName: @escaping (String) -> String? = { _ in nil }
    ) {
        self.directory = directory
        self.sessionName = sessionName
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
        guard saving.withLock({ isSaving }), !request.body.isEmpty else { return }
        writeQueue.async { [self] in
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            let id = Self.sessionID(of: request, body: body)
            let name = id.flatMap { id in DispatchQueue.main.sync { sessionName(id) } }
            do {
                try save(request, body: body, sessionID: id, sessionName: name)
            } catch {
                Self.logger.error("couldn't save a request: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Headers that carry the account's credentials. Their values aren't written to disk.
    static let credentialHeaders: Set<String> = ["authorization", "x-api-key", "proxy-authorization", "cookie"]

    /// Claude Code sends the ID of its session in a header, and in the request's metadata.
    static func sessionID(of request: ProxyRequest, body: [String: Any]?) -> String? {
        if let id = request.header("X-Claude-Code-Session-Id"), !id.isEmpty { return id.lowercased() }
        guard let metadata = body?["metadata"] as? [String: Any],
              let userID = (metadata["user_id"] as? String)?.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: userID)) as? [String: Any] else { return nil }
        return (object["session_id"] as? String)?.lowercased()
    }

    /// Brings the folder of the request's thread up to date with it: the request as it
    /// was sent, in `request.json` and `request.http` (credentials masked), and laid out
    /// for reading beside them. Only files whose content changed are written, so each
    /// thread's folder holds its latest request.
    func save(_ request: ProxyRequest, body: [String: Any]?, sessionID: String?, sessionName: String?) throws {
        let session = try sessionFolder(id: sessionID, name: sessionName)
        let thread: String
        if let body {
            thread = routers[sessionID ?? "", default: CaptureRouter()].folder(for: body, path: request.path)
        } else {
            thread = "side-calls/" + CaptureRouter.slug(request.path, words: 6)
        }
        let folder = thread.isEmpty ? session : session.appendingPathComponent(thread)

        var files: [String: Data] = [:]
        if let body, body["messages"] != nil || body["system"] != nil {
            let name = thread.isEmpty ? session.lastPathComponent : "\(session.lastPathComponent)/\(thread)"
            files = RequestExploder.files(of: body, name: name, rawSize: request.body.count)
        }
        files[body == nil ? "request.body" : "request.json"] = request.body
        files["request.http"] = Data(request.head(redacting: Self.credentialHeaders).utf8)

        try CaptureFolder.sync(files, into: folder, keeping: thread.isEmpty ? ["agents", "side-calls"] : [])
    }

    /// The session's folder, `<tab name> (<start of the session ID>)`. The folder follows the
    /// tab when it is renamed, and keeps its last name once the tab is gone.
    private func sessionFolder(id: String?, name: String?) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let id else { return directory.appendingPathComponent("unknown session") }

        let short = String(id.prefix(8))
        let existing = (try? fileManager.contentsOfDirectory(atPath: directory.path))?
            .first { $0 == short || $0.hasSuffix(" (\(short))") }
        guard let name = name.map(Self.folderName), !name.isEmpty else {
            return directory.appendingPathComponent(existing ?? short)
        }

        let wanted = "\(name) (\(short))"
        let url = directory.appendingPathComponent(wanted)
        if let existing, existing != wanted, !fileManager.fileExists(atPath: url.path) {
            try fileManager.moveItem(at: directory.appendingPathComponent(existing), to: url)
        }
        return url
    }

    /// A tab name made safe for a folder name.
    private static func folderName(_ name: String) -> String {
        let safe = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(safe.drop { $0 == "." }.prefix(80))
    }

    func revealInFinder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}
