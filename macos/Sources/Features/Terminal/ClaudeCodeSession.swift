import Darwin
import Foundation

/// A Claude Code session running in a terminal. It is saved with the terminal and resumed
/// when the terminal opens again, so each terminal gets its own session back.
/// `claude --continue` wouldn't do: it reopens the latest session of a folder, the same one
/// in every terminal open in that folder.
struct ClaudeCodeSession: Codable, Equatable {
    /// Being a UUID, it is safe to type into a shell.
    let id: UUID

    /// The directory Claude Code was started in. Claude Code looks for the session from
    /// there, so this is where the terminal opens again.
    let cwd: String

    init(id: UUID, cwd: String) {
        self.id = id
        self.cwd = cwd
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        cwd = try container.decode(String.self, forKey: .cwd)
        guard cwd.hasPrefix("/") else {
            throw DecodingError.dataCorruptedError(
                forKey: .cwd, in: container, debugDescription: "not an absolute path")
        }
    }

    /// The command typed into the shell to resume the session. Typing it, rather than
    /// running it as the terminal's command, leaves the shell open when Claude Code exits.
    var resumeInput: String {
        "claude --resume \(id.uuidString.lowercased())\n"
    }

    /// Set to the session id in a terminal that resumes a session. Shell startup files that
    /// start Claude Code in every new terminal need to skip it there, or the resume command
    /// would be typed into that Claude Code instead of the shell.
    static let resumeEnvironmentVariable = "GHOSTTY_CLAUDE_CODE_RESUME"

    var resumeEnvironment: [String: String] {
        [Self.resumeEnvironmentVariable: id.uuidString.lowercased()]
    }

    // MARK: Running sessions

    /// Registry entries are written after the process starts, but the two times are read
    /// from clocks with different precision.
    private static let startTimeSlack: TimeInterval = 1

    /// A running Claude Code process's entry in `sessions/<pid>.json`.
    private struct RegistryEntry: Decodable {
        let pid: Int
        let sessionId: String
        let cwd: String

        /// When the entry was written, in milliseconds since 1970.
        let startedAt: Double

        /// "interactive" for a session in a terminal. Older versions don't write it.
        let kind: String?
    }

    /// The session of process `pid`, if it is Claude Code running interactively in a session
    /// that can be resumed.
    static func running(pid: Int) -> ClaudeCodeSession? {
        running(pid: pid, configDirectory: configDirectory)
    }

    static func running(pid: Int, configDirectory: URL) -> ClaudeCodeSession? {
        // Most processes aren't Claude Code, so the file is read before asking the kernel.
        let file = configDirectory.appendingPathComponent("sessions/\(pid).json")
        guard let data = try? Data(contentsOf: file),
              let started = processStartTime(pid),
              let session = session(registry: data, pid: pid, processStarted: started),
              session.hasTranscript(in: configDirectory.appendingPathComponent("projects")) else { return nil }
        return session
    }

    /// Claude Code writes the transcript of a session with its first message, and can't
    /// resume a session without one. Transcripts are in a folder named after the directory
    /// Claude Code runs in, except that the names of long paths are shortened.
    private func hasTranscript(in projects: URL) -> Bool {
        let fileManager = FileManager.default
        let name = "\(id.uuidString.lowercased()).jsonl"
        func exists(in folder: String) -> Bool {
            fileManager.fileExists(atPath: projects.appendingPathComponent(folder).appendingPathComponent(name).path)
        }

        let folder = cwd.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        if exists(in: folder) { return true }
        let folders = (try? fileManager.contentsOfDirectory(atPath: projects.path)) ?? []
        return folders.contains { exists(in: $0) }
    }

    /// The session in a registry entry, if the entry belongs to process `pid`, which
    /// started at `processStarted`.
    static func session(registry data: Data, pid: Int, processStarted: Date) -> ClaudeCodeSession? {
        guard let entry = try? JSONDecoder().decode(RegistryEntry.self, from: data),
              entry.pid == pid,
              entry.kind == nil || entry.kind == "interactive",
              let id = UUID(uuidString: entry.sessionId),
              entry.cwd.hasPrefix("/") else { return nil }

        // A process that dies without cleaning up leaves its entry behind, and its pid can
        // be reused. A process that reused it started after the entry was written.
        let written = Date(timeIntervalSince1970: entry.startedAt / 1000)
        guard processStarted <= written.addingTimeInterval(startTimeSlack) else { return nil }

        return ClaudeCodeSession(id: id, cwd: entry.cwd)
    }

    /// Where Claude Code keeps its data. An app opened from the Dock doesn't see the variables
    /// of a shell profile, so the default is what usually applies.
    private static var configDirectory: URL {
        let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespaces)
        let path = configured.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        return URL(fileURLWithPath: path)
    }

    /// When process `pid` started, according to the kernel.
    private static func processStartTime(_ pid: Int) -> Date? {
        guard let pid = Int32(exactly: pid), pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride

        // A pid that isn't in use succeeds with nothing returned.
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride else { return nil }

        // `p_starttime` is a macro, which Swift doesn't import.
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
