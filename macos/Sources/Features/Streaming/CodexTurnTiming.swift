import AppKit
import Foundation

/// Timing Codex reports for a completed turn. A turn includes tools and approval
/// waits, so its duration must not be presented as a token generation rate.
struct CodexTurnTiming: Equatable {
    var firstToken: TimeInterval?
    var duration: TimeInterval?

    var label: String? {
        let parts = [
            firstToken.map { "ttft \(ClaudeStreamState.seconds($0))" },
            duration.map { "turn \(ClaudeStreamState.seconds($0))" },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var help: String? {
        guard label != nil else { return nil }
        var parts: [String] = []
        if let firstToken { parts.append("First token after \(ClaudeStreamState.seconds(firstToken))") }
        if let duration { parts.append("Turn completed in \(ClaudeStreamState.seconds(duration))") }
        return parts.joined(separator: ". ") + ". Turn time includes tool calls and time spent waiting."
    }

    /// A new or interrupted turn clears the previous timing. Missing fields stay
    /// unknown rather than being estimated from completed messages.
    static func read(lines: [Data]) -> CodexTurnTiming? {
        for line in lines.reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  entry["type"] as? String == "event_msg",
                  let payload = entry["payload"] as? [String: Any] else { continue }
            switch payload["type"] as? String {
            case "task_started", "turn_aborted": return CodexTurnTiming()
            case "task_complete":
                func seconds(_ key: String) -> TimeInterval? {
                    guard let number = payload[key] as? NSNumber else { return nil }
                    let value = number.doubleValue / 1000
                    return value.isFinite && value >= 0 ? value : nil
                }
                return CodexTurnTiming(
                    firstToken: seconds("time_to_first_token_ms"), duration: seconds("duration_ms"))
            default: continue
            }
        }
        return nil
    }

    static func read(url: URL) -> CodexTurnTiming? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > 1 << 20 ? end - (1 << 20) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return read(lines: lines)
    }
}

/// Reads completed turn timings off the UI thread, including when the sidebar is
/// hidden. Codex supplies these without proxying or changing its API connection.
@MainActor
final class CodexTurnTimings {
    static let shared = CodexTurnTimings()
    private var timer: Timer?
    private var reading = false
    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.codex-turn-timings", qos: .utility)
    private var cached: [URL: (modified: Date, timing: CodexTurnTiming?)] = [:]

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        guard ClaudeStreams.shared.isEnabled, !reading else { return }
        let requests = NSApp.windows.compactMap { window -> (TerminalWindow, Int)? in
            guard let window = window as? TerminalWindow else { return nil }
            guard let pid = window.terminalController?.focusedSurface?.surfaceModel?.foregroundPID else {
                window.codexTurnTiming = nil
                return nil
            }
            return (window, pid)
        }
        reading = true
        let cached = cached
        queue.async {
            var cache = cached
            let results = requests.map { window, pid -> (TerminalWindow, Int, CodexTurnTiming?) in
                guard let session = CodexSession.running(pid: pid) else {
                    let active = CodexSession.liveStatus(pid: pid) != nil
                    return (window, pid, active ? CodexTurnTiming() : nil)
                }
                guard let url = session.rollout,
                      let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
                        as? Date else { return (window, pid, CodexTurnTiming()) }
                if cache[url]?.modified != modified {
                    cache[url] = (modified, CodexTurnTiming.read(url: url))
                }
                return (window, pid, cache[url]?.timing ?? CodexTurnTiming())
            }
            DispatchQueue.main.async {
                self.cached = cache
                self.reading = false
                guard ClaudeStreams.shared.isEnabled else { return }
                for (window, pid, timing) in results {
                    guard window.terminalController?.focusedSurface?.surfaceModel?.foregroundPID == pid else { continue }
                    window.codexTurnTiming = timing
                }
            }
        }
    }
}
