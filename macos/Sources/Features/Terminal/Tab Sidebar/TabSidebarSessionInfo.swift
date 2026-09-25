import AppKit
import Combine

/// Where a session works, shown on its extended row, in its hover card and copied from its
/// menu: the directory of its Claude Code session, or else of its focused terminal, and
/// the branch checked out there.
struct TabSidebarSessionInfo: Equatable {
    /// The directory, when a terminal has reported one.
    var directory: String?

    /// The branch checked out in `directory`, or nil outside a repository or when HEAD is
    /// detached.
    var branch: String?

    /// `directory` is in a linked worktree, such as one `claude --worktree` made.
    var isLinkedWorktree = false

    /// The Claude Code sessions running in the tab's terminals.
    var claudeSessions: [ClaudeCodeSession] = []

    /// `directory` with the home directory as `~`.
    var abbreviatedDirectory: String? {
        directory.map { ($0 as NSString).abbreviatingWithTildeInPath }
    }

    /// The last component of `directory`.
    var directoryName: String? {
        directory.map { ($0 as NSString).lastPathComponent }
    }
}

/// Reads the info of the sessions of a sidebar off the main thread. Git is asked about a
/// directory at most every few seconds, however often the sidebar refreshes.
final class TabSidebarSessionInfoReader {
    /// How long what git said about a directory is trusted.
    private static let gitMaxAge: TimeInterval = 10

    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.tab-sidebar-info", qos: .utility)

    /// Only touched on `queue`.
    private var checkouts: [String: (value: (branch: String?, isLinkedWorktree: Bool)?, readAt: Date)] = [:]

    /// A tab to read: its foreground processes and its focused terminal's directory.
    struct Request {
        let id: ObjectIdentifier
        let pids: [Int]
        let directory: String?
    }

    /// Reads `requests` and calls `completion` on the main thread with the result.
    func read(_ requests: [Request], completion: @escaping ([ObjectIdentifier: TabSidebarSessionInfo]) -> Void) {
        queue.async { [self] in
            var infos: [ObjectIdentifier: TabSidebarSessionInfo] = [:]
            for request in requests {
                infos[request.id] = info(for: request)
            }
            DispatchQueue.main.async { completion(infos) }
        }
    }

    private func info(for request: Request) -> TabSidebarSessionInfo {
        var info = TabSidebarSessionInfo()
        info.claudeSessions = request.pids.compactMap(ClaudeCodeSession.running(pid:))
        info.directory = info.claudeSessions.first?.cwd ?? request.directory

        if let directory = info.directory, let checkout = checkout(of: directory) {
            info.branch = checkout.branch
            info.isLinkedWorktree = checkout.isLinkedWorktree
        }
        return info
    }

    private func checkout(of directory: String) -> (branch: String?, isLinkedWorktree: Bool)? {
        if let known = checkouts[directory], Date().timeIntervalSince(known.readAt) < Self.gitMaxAge {
            return known.value
        }
        let value = Git.checkout(of: URL(fileURLWithPath: directory))
        checkouts[directory] = (value, Date())
        return value
    }
}

/// What a Claude Code session has cost so far, priced like the usage panel prices it:
/// with the rates the panel last downloaded.
enum ClaudeCodeSessionCost {
    private static let queue = DispatchQueue(label: "com.mitchellh.ghostty.session-cost", qos: .utility)

    /// Only touched on `queue`.
    private static var rates: UsageRateTable?

    /// Calls `completion` on the main thread with the cost of `sessions`, or nil when
    /// none of them has a transcript or no rates were ever downloaded.
    static func cost(of sessions: [ClaudeCodeSession], completion: @escaping (Double?) -> Void) {
        queue.async {
            let transcripts = sessions.compactMap(\.transcript)
            let rates = loadRates()
            let cost: Double? = transcripts.isEmpty ? nil : transcripts.reduce(0) { total, url in
                total + cost(of: url, rates: rates)
            }
            DispatchQueue.main.async { completion(rates.count > 0 ? cost : nil) }
        }
    }

    private static func loadRates() -> UsageRateTable {
        if let rates { return rates }
        let url = UsageScanner.defaultStorageDirectory.appendingPathComponent("model-rates.json")
        let table = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }
            .map(UsageRateTable.init(liteLLM:)) ?? UsageRateTable()
        rates = table
        return table
    }

    private static func cost(of transcript: URL, rates: UsageRateTable) -> Double {
        guard let result = UsageTranscriptReader.read(path: transcript.path, provider: .claude) else { return 0 }
        var seen = Set<String>()
        var total = 0.0
        for record in result.records + result.tailRecords {
            if let key = record.dedupeKey, !seen.insert(key).inserted { continue }
            if let reported = record.reportedCostUsd {
                total += reported
            } else if let rate = rates.rate(for: record.model) {
                total += rate.cost(of: record.totals)
            }
        }
        return total
    }
}
