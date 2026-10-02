import AppKit
import Combine

/// Where a session works, shown on its extended row, in its hover card and copied from its
/// menu: the directory of its agent session, or else of its focused terminal, and the
/// branch checked out there. With the model its agent is using.
struct TabSidebarSessionInfo: Equatable {
    /// The directory, when a terminal has reported one.
    var directory: String?

    /// How `directory` is checked out, or nil outside a repository.
    var checkout: Git.Checkout?

    /// The branch checked out in `directory`, or nil outside a repository or when HEAD is
    /// detached.
    var branch: String? { checkout?.branch }

    /// `directory` is in a linked worktree, such as one `claude --worktree` made.
    var isLinkedWorktree: Bool { checkout?.isLinkedWorktree ?? false }

    /// The agent sessions, Claude Code or Codex, running in the tab's terminals.
    var sessions: [AgentSession] = []

    /// When an agent session last wrote to its transcript, which says how long ago a
    /// session found already finished did its last work.
    var lastActive: Date?

    /// The model of the last response of the tab's agent session, which is the model it
    /// is using.
    var model: String?

    /// `directory` with the home directory as `~`.
    var abbreviatedDirectory: String? {
        directory.map { ($0 as NSString).abbreviatingWithTildeInPath }
    }
}

/// Reads the info of the sessions of a sidebar off the main thread. Git is asked about a
/// directory at most every few seconds, however often the sidebar refreshes, and a
/// transcript is read for its model only once it has changed.
final class TabSidebarSessionInfoReader {
    /// How long what git said about a directory is trusted.
    private static let gitMaxAge: TimeInterval = 10

    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.tab-sidebar-info", qos: .utility)

    /// Only touched on `queue`.
    private var checkouts: [String: (value: Git.Checkout?, readAt: Date)] = [:]

    /// Only touched on `queue`.
    private var models: [URL: (value: String?, modified: Date)] = [:]

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
        info.sessions = request.pids.compactMap(AgentSession.running(pid:))
        info.directory = info.sessions.first?.cwd ?? request.directory
        info.lastActive = info.sessions
            .compactMap { $0.transcript.flatMap(Self.modified) }
            .max()
        info.model = info.sessions.first.flatMap(model(of:))

        info.checkout = info.directory.flatMap(checkout(of:))
        return info
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func model(of session: AgentSession) -> String? {
        guard let transcript = session.transcript, let modified = Self.modified(transcript) else { return nil }
        if let known = models[transcript], known.modified == modified {
            return known.value
        }
        // A response too far back to read leaves the model it was known to be.
        let read: String?
        switch session {
        case .claude: read = ClaudeCodeResponse.model(inTranscript: transcript)
        case .codex: read = CodexSession.Rollout.model(of: transcript)
        }
        let value = read ?? models[transcript]?.value
        models[transcript] = (value, modified)
        return value
    }

    private func checkout(of directory: String) -> Git.Checkout? {
        if let known = checkouts[directory], Date().timeIntervalSince(known.readAt) < Self.gitMaxAge {
            return known.value
        }
        let value = Git.checkout(of: URL(fileURLWithPath: directory))
        checkouts[directory] = (value, Date())
        return value
    }
}

/// What an agent session has used so far, by model: the tokens, and their cost priced
/// like the usage panel prices it, with the rates the panel last downloaded.
enum ClaudeCodeSessionCost {
    struct ModelUsage: Equatable {
        let model: String

        /// Every token processed, cached or not.
        var tokens: Int

        /// Nil when the model has no rate.
        var cost: Double?
    }

    private static let queue = DispatchQueue(label: "com.mitchellh.ghostty.session-cost", qos: .utility)

    /// Only touched on `queue`.
    private static var rates: UsageRateTable?

    /// Calls `completion` on the main thread with what `sessions` used, most costly model
    /// first, or nil when none of them has a transcript.
    static func usage(of sessions: [AgentSession], completion: @escaping ([ModelUsage]?) -> Void) {
        queue.async {
            let transcripts = sessions.compactMap { session in
                session.transcript.map { (url: $0, provider: session.agent.usageProvider) }
            }
            let usage = transcripts.isEmpty ? nil : usage(of: transcripts, rates: loadRates())
            DispatchQueue.main.async { completion(usage) }
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

    static func usage(of transcripts: [(url: URL, provider: UsageProvider)], rates: UsageRateTable) -> [ModelUsage] {
        let records = transcripts.flatMap { transcript -> [UsageRecord] in
            guard let result = UsageTranscriptReader.read(path: transcript.url.path, provider: transcript.provider) else {
                return []
            }
            return result.records + result.tailRecords
        }
        return usage(of: records, rates: rates)
    }

    static func usage(of records: [UsageRecord], rates: UsageRateTable) -> [ModelUsage] {
        var seen = Set<String>()
        var byModel: [String: ModelUsage] = [:]
        for record in records {
            if let key = record.dedupeKey, !seen.insert(key).inserted { continue }
            var usage = byModel[record.model] ?? ModelUsage(model: record.model, tokens: 0, cost: 0)
            usage.tokens += record.totals.total
            if let reported = record.reportedCostUsd {
                usage.cost = usage.cost.map { $0 + reported }
            } else if let rate = rates.rate(for: record.model) {
                usage.cost = usage.cost.map { $0 + rate.cost(of: record.totals) }
            } else {
                usage.cost = nil
            }
            byModel[record.model] = usage
        }
        return byModel.values.sorted {
            ($0.cost ?? -1, $0.tokens) > ($1.cost ?? -1, $1.tokens)
        }
    }
}
