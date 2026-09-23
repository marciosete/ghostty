import Foundation

/// The Claude account the Claude Code CLI is signed in to.
struct ClaudeAccount: Equatable {
    let email: String?
    let organizationName: String?

    /// The subscription as the CLI names it: `max`, `pro`, `team`, ...
    let subscriptionType: String?

    /// Whether this is an Anthropic login. Bedrock, Vertex and Foundry use their own
    /// credentials and have no plan limits.
    let isFirstParty: Bool

    /// What to show as the account: the email, falling back to the organization.
    var label: String {
        email ?? organizationName ?? "Claude"
    }

    /// `max` as `Max`.
    var planLabel: String? {
        guard let subscriptionType, !subscriptionType.isEmpty else { return nil }
        return subscriptionType.prefix(1).uppercased() + subscriptionType.dropFirst()
    }
}

/// One of the plan's usage windows, as the Claude settings page shows them.
struct ClaudeLimitWindow: Identifiable, Equatable {
    enum Kind: Equatable {
        /// The rolling five hour window.
        case session

        /// The weekly window covering every model.
        case weeklyAll

        /// A weekly window for one model, such as Fable.
        case weeklyScoped
    }

    enum Severity: String, Equatable {
        case normal
        case warning
        case critical
    }

    let id: String
    let kind: Kind

    /// `Current session`, `All models`, or the model's name for a scoped weekly.
    let label: String

    /// How much of the window is used, 0 to 100.
    let usedPercent: Double

    let resetsAt: Date?
    let severity: Severity

    /// Whether this is the window currently limiting the account.
    let isActive: Bool
}

/// What the Claude Code CLI reports about the plan behind it.
struct ClaudeLimits: Equatable {
    enum Unavailable: Equatable {
        /// The Claude Code CLI isn't installed, or isn't where we look for it.
        case cliMissing

        /// Installed, but not signed in to an Anthropic account.
        case signedOut

        /// Signed in with credentials that have no subscription windows, such as an
        /// API key or Bedrock.
        case noPlanLimits

        /// The CLI ran but didn't answer.
        case failed
    }

    var account: ClaudeAccount?
    var windows: [ClaudeLimitWindow] = []
    var checkedAt: Date
    var unavailable: Unavailable?

    /// The window nearest its limit, which is the one worth showing first.
    var tightest: ClaudeLimitWindow? {
        windows.max { $0.usedPercent < $1.usedPercent }
    }
}

/// Reads the plan limits of the Claude Code CLI.
///
/// The CLI is asked for them with the same `get_usage` control request the Claude Agent
/// SDK makes, so the account's own login is used and Ghostty never reads credentials.
/// The request runs no model turn and costs nothing.
enum ClaudeLimitsReader {
    /// How long the CLI gets to answer before it's given up on.
    private static let timeout: TimeInterval = 30

    /// Where the CLI is looked for, beyond `PATH`. An app opened from the Dock has a
    /// minimal `PATH` that holds none of these.
    private static let searchPaths = [
        ".local/bin", ".claude/local", ".bun/bin", ".volta/bin",
    ]

    private static let systemPaths = [
        "/opt/homebrew/bin", "/usr/local/bin", "/run/current-system/sw/bin", "/usr/bin",
    ]

    /// The Claude Code CLI, or nil when it isn't installed.
    static func executableURL() -> URL? {
        let home = NSHomeDirectory() as NSString
        let fromPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = fromPath
            + searchPaths.map { home.appendingPathComponent($0) }
            + systemPaths

        for directory in candidates {
            let path = (directory as NSString).appendingPathComponent("claude")
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Asks the CLI who it is signed in as and how much of the plan is left. Blocking,
    /// so callers run it off the main thread.
    static func read() -> ClaudeLimits {
        let checkedAt = Date()
        guard let executable = executableURL() else {
            return ClaudeLimits(checkedAt: checkedAt, unavailable: .cliMissing)
        }

        let account = run(executable, arguments: ["auth", "status", "--json"])
            .flatMap { parseAccount($0) }

        if let account, !account.isFirstParty {
            return ClaudeLimits(account: account, checkedAt: checkedAt, unavailable: .noPlanLimits)
        }
        if account == nil {
            return ClaudeLimits(checkedAt: Date(), unavailable: .signedOut)
        }

        let request = #"{"type":"control_request","request_id":"ghostty-usage","request":{"subtype":"get_usage"}}"#
        guard let output = run(
            executable,
            arguments: ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"],
            input: request + "\n")
        else {
            return ClaudeLimits(account: account, checkedAt: Date(), unavailable: .failed)
        }

        guard let response = usageResponse(in: output) else {
            return ClaudeLimits(account: account, checkedAt: Date(), unavailable: .failed)
        }

        let windows = parseWindows(response)
        return ClaudeLimits(
            account: account,
            windows: windows,
            checkedAt: Date(),
            unavailable: windows.isEmpty ? .noPlanLimits : nil)
    }

    // MARK: Parsing

    /// The account from `claude auth status --json`, or nil when signed out.
    static func parseAccount(_ data: Data) -> ClaudeAccount? {
        guard let status = UsageJSON.object(data), status["loggedIn"] as? Bool == true else { return nil }
        return ClaudeAccount(
            email: (status["email"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            organizationName: (status["orgName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            subscriptionType: status["subscriptionType"] as? String,
            // Only an Anthropic login has plan windows.
            isFirstParty: (status["apiProvider"] as? String ?? "firstParty") == "firstParty")
    }

    /// The `get_usage` payload carried by a line of the CLI's stream, if any.
    static func usageResponse(in output: Data) -> [String: Any]? {
        for line in output.split(separator: UInt8(ascii: "\n")) {
            guard let message = UsageJSON.object(Data(line)),
                  message["type"] as? String == "control_response",
                  let response = message["response"] as? [String: Any],
                  response["subtype"] as? String == "success",
                  let payload = response["response"] as? [String: Any],
                  payload["rate_limits"] != nil || payload["rate_limits_available"] != nil
            else { continue }
            return payload
        }
        return nil
    }

    /// The plan windows of a `get_usage` payload.
    ///
    /// Recent CLIs describe every window in one `limits` array, which is what the
    /// Claude settings page shows. Older ones only carry the windows separately, so
    /// those are read when the array is absent.
    static func parseWindows(_ payload: [String: Any]) -> [ClaudeLimitWindow] {
        guard payload["rate_limits_available"] as? Bool != false,
              let rateLimits = payload["rate_limits"] as? [String: Any] else { return [] }

        if let limits = rateLimits["limits"] as? [[String: Any]], !limits.isEmpty {
            return limits.compactMap(window(fromLimitsEntry:))
        }
        return legacyWindows(rateLimits)
    }

    private static func window(fromLimitsEntry entry: [String: Any]) -> ClaudeLimitWindow? {
        guard let rawKind = entry["kind"] as? String,
              let percent = UsageJSON.number(entry["percent"]) else { return nil }

        let scopeName = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String

        let kind: ClaudeLimitWindow.Kind
        let label: String
        switch rawKind {
        case "session":
            kind = .session
            label = "Current session"
        case "weekly_all":
            kind = .weeklyAll
            label = "All models"
        case "weekly_scoped":
            kind = .weeklyScoped
            // A scoped window with no model name says nothing useful.
            guard let scopeName, !scopeName.isEmpty else { return nil }
            label = scopeName
        default:
            return nil
        }

        return ClaudeLimitWindow(
            id: scopeName.map { "\(rawKind):\($0)" } ?? rawKind,
            kind: kind,
            label: label,
            usedPercent: min(max(percent, 0), 100),
            resetsAt: date(entry["resets_at"]),
            severity: (entry["severity"] as? String).flatMap(ClaudeLimitWindow.Severity.init(rawValue:)) ?? .normal,
            isActive: entry["is_active"] as? Bool ?? false)
    }

    private static func legacyWindows(_ rateLimits: [String: Any]) -> [ClaudeLimitWindow] {
        var windows: [ClaudeLimitWindow] = []

        for (key, kind, label) in [
            ("five_hour", ClaudeLimitWindow.Kind.session, "Current session"),
            ("seven_day", .weeklyAll, "All models"),
        ] {
            guard let window = rateLimits[key] as? [String: Any],
                  let utilization = UsageJSON.number(window["utilization"]) else { continue }
            windows.append(ClaudeLimitWindow(
                id: key,
                kind: kind,
                label: label,
                usedPercent: min(max(utilization, 0), 100),
                resetsAt: date(window["resets_at"]),
                severity: .normal,
                isActive: false))
        }

        for scoped in rateLimits["model_scoped"] as? [[String: Any]] ?? [] {
            guard let name = scoped["display_name"] as? String, !name.isEmpty,
                  let utilization = UsageJSON.number(scoped["utilization"]) else { continue }
            windows.append(ClaudeLimitWindow(
                id: "seven_day:\(name)",
                kind: .weeklyScoped,
                label: name,
                usedPercent: min(max(utilization, 0), 100),
                resetsAt: date(scoped["resets_at"]),
                severity: .normal,
                isActive: false))
        }

        return windows
    }

    private static func date(_ value: Any?) -> Date? {
        guard let milliseconds = UsageTimestamp.milliseconds(value) else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    // MARK: Running the CLI

    /// Runs the CLI and returns everything it wrote, or nil when it failed or hung.
    private static func run(_ executable: URL, arguments: [String], input: String? = nil) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // A neutral working directory: the CLI reads the settings of wherever it runs,
        // and this asks nothing of a project.
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let stdin = Pipe()
        process.standardInput = stdin

        do {
            try process.run()
        } catch {
            return nil
        }

        try? stdin.fileHandleForWriting.write(contentsOf: Data((input ?? "").utf8))
        try? stdin.fileHandleForWriting.close()

        // Read on another thread: a full pipe buffer would otherwise block the CLI
        // before it exits, and the wait below would never return.
        var data = Data()
        let reading = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            reading.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        if reading.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = reading.wait(timeout: .now() + 2)
            return nil
        }
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning { process.terminate() }

        return data.isEmpty ? nil : data
    }
}
