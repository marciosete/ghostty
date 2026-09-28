import AppKit
import Combine
import Foundation
import os

/// The reply timing a tab shows: the latest turn of the conversation in its terminal.
struct ClaudeStreamState: Equatable {
    let sample: ClaudeStreamSample

    /// When the state was computed. Live values are shown against it, and it changes with
    /// every tick while a reply streams, so the tab redraws.
    let asOf: Date

    /// What the title shows: the time to the first token, then the tokens per second: the
    /// rate over the last moments while the reply streams, and the average over the whole
    /// reply once it's done. While the first token is awaited, the time so far. Nothing
    /// for a reply that failed before it produced anything.
    var label: String? {
        guard let ttft = sample.timeToFirstToken else {
            guard sample.isStreaming else { return nil }
            return "ttft " + Self.seconds(asOf.timeIntervalSince(sample.startedAt)) + "…"
        }
        var label = "ttft \(Self.seconds(ttft))"
        if sample.isStreaming {
            if let rate = sample.liveTokensPerSecond(at: asOf) {
                label += " · ~\(Int(rate.rounded())) tok/s"
            } else {
                label += " · …"
            }
        } else if let rate = sample.averageTokensPerSecond {
            label += " · avg \(sample.hasExactRate ? "" : "~")\(Int(rate.rounded())) tok/s"
        }
        return label
    }

    var help: String? {
        guard let ttft = sample.timeToFirstToken else {
            return sample.isStreaming ? "Waiting for the first token" : nil
        }
        var text = "First token after \(Self.seconds(ttft))"
        if sample.isStreaming {
            text += ". Streaming"
            if let rate = sample.liveTokensPerSecond(at: asOf) {
                text += " at about \(Int(rate.rounded())) tokens per second"
            }
        } else if let tokens = sample.outputTokens, let last = sample.lastTokenAt, let first = sample.firstTokenAt {
            text += ". \(tokens.formatted()) output tokens in \(Self.seconds(last.timeIntervalSince(first)))"
            if let rate = sample.averageTokensPerSecond {
                text += ", \(Int(rate.rounded())) tokens per second on average"
            }
        } else if sample.failed {
            text += ". The reply was cut short"
        }
        return text + "."
    }

    static func seconds(_ interval: TimeInterval) -> String {
        interval < 10 ? String(format: "%.1fs", interval) : "\(Int(interval.rounded()))s"
    }
}

/// Times the replies of the Claude Code sessions in the terminals, and shows the timing of
/// each session's latest turn in the title of its window.
///
/// New terminals are pointed at a local proxy through `ANTHROPIC_BASE_URL`, and the proxy
/// reads the replies as they stream through it. Each reply names its session in a header,
/// and the session's registry entry names its process, which is the foreground process of
/// the terminal it runs in.
@MainActor
final class ClaudeStreams: NSObject, ObservableObject {
    static let shared = ClaudeStreams()

    private static let enabledKey = "ClaudeStreamMetricsEnabled"

    /// Logs the proxy's address and each timed reply, for checking the timing from outside
    /// the app (`log show --predicate 'category == "claude-streams"'`).
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ghostty", category: "claude-streams")

    /// How often the live values are redrawn while a reply streams.
    private static let tickInterval: TimeInterval = 0.25

    /// Whether replies are timed and shown. Turning it off stops showing them at once, and
    /// terminals opened from then on connect to the API directly.
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.ghostty.set(isEnabled, forKey: Self.enabledKey)
            menuItem?.state = isEnabled ? .on : .off
            if isEnabled { startProxy() }
            for case let window as TerminalWindow in NSApp.windows {
                window.claudeStreamDisplayDidChange()
            }
        }
    }

    private(set) var proxy: ClaudeStreamProxy?
    private var menuItem: NSMenuItem?

    /// The latest turn of each session, and the tab it was last shown in.
    private struct Session {
        var request: ClaudeStreamRequest
        var sample: ClaudeStreamSample
        var pid: Int?
        var window: ObjectIdentifier?
    }

    private struct WeakWindow {
        weak var window: TerminalWindow?
    }

    private var sessions: [UUID: Session] = [:]
    private var windows: [ObjectIdentifier: WeakWindow] = [:]
    private var ticker: Timer?

    private override init() {
        isEnabled = UserDefaults.ghostty.object(forKey: Self.enabledKey) as? Bool ?? true
        super.init()
    }

    /// Starts the proxy, when replies are timed. Called once the app has launched.
    func start() {
        guard isEnabled else { return }
        startProxy()
    }

    private func startProxy() {
        guard proxy == nil else { return }
        let proxy = ClaudeStreamProxy(upstream: Self.upstream)
        proxy.onUpdate = { [weak self] request, sample in
            DispatchQueue.main.async {
                self?.update(request, sample)
            }
        }
        do {
            try proxy.start()
            self.proxy = proxy
            Self.logger.log("Timing Claude Code replies through \(proxy.baseURL ?? "", privacy: .public), forwarding to \(proxy.upstream.absoluteString, privacy: .public)")
        } catch {
            Self.logger.error("Claude Code replies won't be timed: the proxy didn't start: \(String(describing: error), privacy: .public)")
        }
    }

    /// Where the proxy forwards requests. A base URL in the app's own environment, such as
    /// a gateway, stays in front of the API.
    private static var upstream: URL {
        let configured = ProcessInfo.processInfo.environment["ANTHROPIC_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !configured.isEmpty, let url = URL(string: configured), url.scheme != nil, url.host != nil,
              url.host != "127.0.0.1", url.host != "localhost" else {
            return ClaudeStreamProxy.defaultUpstream
        }
        return url
    }

    /// The environment that points Claude Code in a new terminal at the proxy. Variables
    /// the terminal already sets are kept.
    func addEnvironment(to configuration: inout Ghostty.SurfaceConfiguration) {
        guard isEnabled, let baseURL = proxy?.baseURL else { return }
        var environment = configuration.environmentVariables
        if environment["ANTHROPIC_BASE_URL"] == nil {
            environment["ANTHROPIC_BASE_URL"] = baseURL
        }
        // Claude Code only says which requests are turns of the conversation when asked.
        if environment["CLAUDE_CODE_GATEWAY_HINT_HEADERS"] == nil {
            environment["CLAUDE_CODE_GATEWAY_HINT_HEADERS"] = "1"
        }
        configuration.environmentVariables = environment
    }

    // MARK: Menu

    /// Adds the toggle to the View menu, after `item`.
    func installMenuItem(in menu: NSMenu, at index: Int) {
        let item = NSMenuItem(title: "Show Reply Speed", action: #selector(toggle(_:)), keyEquivalent: "")
        item.target = self
        item.state = isEnabled ? .on : .off
        item.setImageIfDesired(systemSymbolName: "gauge.with.dots.needle.67percent")
        menu.insertItem(item, at: index)
        menuItem = item
    }

    @objc private func toggle(_ sender: Any?) {
        isEnabled.toggle()
    }

    // MARK: Updates

    private func update(_ request: ClaudeStreamRequest, _ sample: ClaudeStreamSample) {
        guard request.isMainConversation, let sessionID = request.sessionID else { return }

        var session = sessions[sessionID] ?? Session(request: request, sample: sample)
        // A turn that started later replaces the one shown; one that finished later doesn't
        // take over from a turn that's still streaming.
        guard session.request.id == request.id || sample.startedAt >= session.sample.startedAt else { return }
        let isNewTurn = sessions[sessionID] == nil || session.request.id != request.id
        let wasStreaming = isNewTurn || session.sample.isStreaming
        session.request = request
        session.sample = sample
        sessions[sessionID] = session

        // Content arrives many times a second; the title is redrawn at the ticker's pace
        // instead, and at once only when a turn starts or ends.
        if isNewTurn || !sample.isStreaming {
            show(sessionID)
        }
        updateTicker()

        if wasStreaming, !sample.isStreaming {
            let state = ClaudeStreamState(sample: sample, asOf: Date())
            let shown = sessions[sessionID]?.window.flatMap { windows[$0]?.window?.title } ?? "no tab"
            Self.logger.log("Reply of session \(sessionID.uuidString, privacy: .public): \(state.help ?? "nothing arrived", privacy: .public) Shown in: \(shown, privacy: .public)")
        }
    }

    /// Shows the session's latest turn in the tab its terminal is in.
    private func show(_ sessionID: UUID) {
        guard var session = sessions[sessionID] else { return }
        let now = Date()

        if session.pid == nil {
            session.pid = ClaudeCodeSession.registeredPID(ofSession: sessionID)
        }
        let window = session.pid.flatMap(Self.window(runningPID:))
        if let previous = session.window, previous != window.map(ObjectIdentifier.init) {
            // The session moved, or its terminal closed.
            windows[previous]?.window?.claudeStreamState = nil
            windows[previous] = nil
        }
        session.window = window.map(ObjectIdentifier.init)
        sessions[sessionID] = session

        guard let window else { return }
        windows[ObjectIdentifier(window)] = WeakWindow(window: window)
        window.claudeStreamState = ClaudeStreamState(sample: session.sample, asOf: now)
    }

    /// The tab whose terminal runs process `pid` in the foreground.
    private static func window(runningPID pid: Int) -> TerminalWindow? {
        for case let window as TerminalWindow in NSApp.windows {
            let surfaces = window.terminalController?.surfaceTree.root?.leaves() ?? []
            if surfaces.contains(where: { $0.surfaceModel?.foregroundPID == pid }) {
                return window
            }
        }
        return nil
    }

    private func updateTicker() {
        let streaming = sessions.values.contains { $0.sample.isStreaming }
        if streaming, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } else if !streaming {
            ticker?.invalidate()
            ticker = nil
        }
    }

    /// Redraws the live values of the replies still streaming.
    private func tick() {
        for (sessionID, session) in sessions where session.sample.isStreaming {
            show(sessionID)
        }
        updateTicker()
    }
}
