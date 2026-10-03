import Darwin
import Foundation

/// Subscription usage reported by Codex's app server, using the CLI's own login.
struct CodexLimits: Equatable {
    enum Unavailable: Equatable {
        case cliMissing
        case signedOut
        case noPlanLimits
        case failed
    }

    struct Window: Identifiable, Equatable {
        let id: String
        let label: String
        let usedPercent: Double
        let resetsAt: Date?
    }

    var accountLabel: String?
    var planLabel: String?
    var windows: [Window] = []
    var checkedAt: Date
    var unavailable: Unavailable?
}

/// The account and rate-limit requests run no model turn and never read credentials.
enum CodexLimitsReader {
    private static let timeout: TimeInterval = 30

    static func read() -> CodexLimits {
        guard let executable = CodingAgent.codex.executableURL() else {
            return CodexLimits(checkedAt: Date(), unavailable: .cliMissing)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": CodingAgent.searchPath.joined(separator: ":"),
        ]) { _, new in new }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return CodexLimits(checkedAt: Date(), unavailable: .failed)
        }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        func send(_ object: [String: Any]) -> Bool {
            guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
            data.append(UInt8(ascii: "\n"))
            do {
                try input.fileHandleForWriting.write(contentsOf: data)
                return true
            } catch {
                return false
            }
        }

        guard send([
            "id": 0, "method": "initialize",
            "params": ["clientInfo": ["name": "maggie_usage", "version": "1.0"]],
        ]) else { return CodexLimits(checkedAt: Date(), unavailable: .failed) }

        let fd = output.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)
        var pending = Data()
        var account: [String: Any]?
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1000))
            let ready = poll(&descriptor, 1, remaining)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { break }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            pending.append(contentsOf: buffer.prefix(count))
            // These replies are small. A broken or incompatible server mustn't grow
            // an unbounded buffer while the panel is open.
            guard pending.count <= 1 << 20 else { break }
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let reply = UsageJSON.object(line), let id = reply["id"] as? Int else { continue }
                guard let result = reply["result"] as? [String: Any] else {
                    return parse(account: account, rateLimits: nil, failed: true)
                }
                switch id {
                case 0:
                    guard send(["method": "initialized"]),
                          send(["id": 1, "method": "account/read", "params": ["refreshToken": false]]) else {
                        return parse(account: account, rateLimits: nil, failed: true)
                    }
                case 1:
                    account = result["account"] as? [String: Any]
                    guard account?["type"] as? String == "chatgpt" else {
                        return parse(account: account, rateLimits: nil)
                    }
                    guard send(["id": 2, "method": "account/rateLimits/read"]) else {
                        return parse(account: account, rateLimits: nil, failed: true)
                    }
                case 2:
                    return parse(account: account, rateLimits: result)
                default:
                    continue
                }
            }
        }
        return parse(account: account, rateLimits: nil, failed: true)
    }

    static func parse(account: [String: Any]?, rateLimits: [String: Any]?, failed: Bool = false) -> CodexLimits {
        let accountType = account?["type"] as? String
        let email = (account?["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let plan = (account?["planType"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var limits = CodexLimits(
            accountLabel: email,
            planLabel: plan.map { $0.replacingOccurrences(of: "_", with: " ").capitalized },
            checkedAt: Date())
        guard !failed else { limits.unavailable = .failed; return limits }
        guard let accountType else { limits.unavailable = .signedOut; return limits }
        guard accountType == "chatgpt" else { limits.unavailable = .noPlanLimits; return limits }

        let buckets: [(String, [String: Any])]
        if let byID = rateLimits?["rateLimitsByLimitId"] as? [String: [String: Any]], !byID.isEmpty {
            buckets = byID.sorted { lhs, rhs in
                if lhs.key == "codex" { return rhs.key != "codex" }
                if rhs.key == "codex" { return false }
                return lhs.key < rhs.key
            }
        } else if let single = rateLimits?["rateLimits"] as? [String: Any] {
            buckets = [(single["limitId"] as? String ?? "codex", single)]
        } else {
            buckets = []
        }
        for (id, bucket) in buckets {
            let name = bucket["limitName"] as? String ?? id
            for key in ["primary", "secondary"] {
                guard let window = bucket[key] as? [String: Any],
                      let used = UsageJSON.number(window["usedPercent"]) else { continue }
                let duration = UsageJSON.count(window["windowDurationMins"])
                let label: String
                switch duration {
                case 300: label = "Current session"
                case 10080: label = "Weekly limit"
                case let minutes where minutes > 0 && minutes.isMultiple(of: 60): label = "\(minutes / 60)-hour limit"
                case let minutes where minutes > 0: label = "\(minutes)-minute limit"
                default: label = key == "primary" ? "Primary limit" : "Secondary limit"
                }
                limits.windows.append(CodexLimits.Window(
                    id: "\(id):\(key)",
                    label: id == "codex" ? label : "\(name) · \(label)",
                    usedPercent: min(max(used, 0), 100),
                    resetsAt: UsageJSON.number(window["resetsAt"]).map(Date.init(timeIntervalSince1970:))))
            }
        }
        if limits.windows.isEmpty { limits.unavailable = .noPlanLimits }
        return limits
    }
}
