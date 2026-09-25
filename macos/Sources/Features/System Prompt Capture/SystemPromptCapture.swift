import AppKit
import Foundation
import OSLog

/// Saves samples of the system prompt Claude Code sends to the model. It is off until turned
/// on, and then applies to terminals opened afterwards: they get `ANTHROPIC_BASE_URL` set to a
/// local proxy, which saves each distinct system prompt and tool list it sees to disk.
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
            .appendingPathComponent("System Prompts", isDirectory: true)
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

    /// Saves samples in order, and remembers which prompts are already saved.
    private let writeQueue = DispatchQueue(label: "com.mitchellh.ghostty.system-prompt-capture")
    private var savedFingerprints: Set<String>?

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
        guard saving.withLock({ isSaving }), let sample = SystemPromptSample(request) else { return }
        let capturedAt = Date()
        writeQueue.async { [self] in
            do {
                try save(sample, capturedAt: capturedAt)
            } catch {
                Self.logger.error("couldn't save a system prompt: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Writes the sample as JSON, and its system prompt as Markdown for reading. A prompt
    /// already saved, in this run or an earlier one, is skipped.
    func save(_ sample: SystemPromptSample, capturedAt: Date) throws {
        var saved = savedFingerprints ?? loadFingerprints()
        defer { savedFingerprints = saved }
        guard !saved.contains(sample.fingerprint) else { return }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let model = sample.model.replacingOccurrences(of: "/", with: "-")
        let base = "\(formatter.string(from: capturedAt))-\(model)-\(sample.fingerprint)"

        try sample.json(capturedAt: capturedAt)
            .write(to: directory.appendingPathComponent(base + ".json"), options: .atomic)
        try Data(sample.systemText.utf8)
            .write(to: directory.appendingPathComponent(base + ".md"), options: .atomic)
        saved.insert(sample.fingerprint)
    }

    /// The fingerprints of the samples already in the directory, which end each file name.
    private func loadFingerprints() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            return name.dropLast(".json".count).split(separator: "-").last.map(String.init)
        })
    }

    func revealInFinder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}
