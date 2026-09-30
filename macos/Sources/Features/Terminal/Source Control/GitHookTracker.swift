import Combine
import Foundation

/// A run of a hook: the steps it reached, and how long each took.
struct GitHookRun: Equatable {
    enum Outcome: Equatable {
        case running

        case passed

        /// It stopped at `current` without passing.
        case failed

        /// It ended, but neither its output nor its steps say whether it passed: its
        /// output went to a terminal, or it announces no steps.
        case ended
    }

    struct Step: Equatable {
        let title: String

        /// When the run was seen to reach the step. Nil if it hasn't, if it skipped it, or
        /// if it was past the step before it was seen.
        var startedAt: Date?

        var endedAt: Date?

        var duration: TimeInterval? {
            guard let startedAt, let endedAt else { return nil }
            return endedAt.timeIntervalSince(startedAt)
        }
    }

    /// The process running the hook's script.
    let pid: pid_t

    let startedAt: Date
    var endedAt: Date?
    var steps: [Step]

    /// The step running, or the one it failed at.
    var current: Int?

    var outcome: Outcome = .running

    /// Its steps are followed through its output, which is written to a file.
    let followsSteps: Bool

    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}

/// Follows the pre-commit and pre-push hooks of one repository as they run, whoever runs
/// them: the processes running as the user are scanned for the hook's script, and the
/// file its output goes to, when it goes to one, such as Claude Code's, is read for the
/// markers of its steps.
///
/// There is one tracker per repository, kept for the life of the app so the last run of
/// each hook stays known. It only scans while a panel watches it.
final class GitHookTracker: ObservableObject {
    let repository: Git.Repository

    /// The repository's hooks, in the order they run. The panel shows none when empty.
    @Published private(set) var scripts: [GitHookScript] = []

    /// The latest run of each hook, by name.
    @Published private(set) var runs: [String: GitHookRun] = [:]

    /// Often enough for a step's start to be timed to within half a second.
    private static let interval: DispatchTimeInterval = .milliseconds(500)

    /// How many scans pass between looking for the hooks' scripts again, which notices
    /// them being added, removed or changed.
    private static let scriptsEvery = 10

    /// The shells a hook's script runs in.
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash"]

    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.git-hooks", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var watchers = 0

    /// Only touched on `queue`.
    private var scans = 0
    private var knownScripts: [GitHookScript] = []
    private var outputs: [String: Output] = [:]

    /// A run whose output is being read. Only touched on `queue`.
    private struct Output {
        let pid: pid_t
        let startedAt: Date
        let file: URL?
        var offset: UInt64 = 0
        var parser: GitHookOutputParser

        /// When the run was first seen to have ended. Its output is read once more
        /// before it counts, since what runs the script may still be writing about it.
        var endedAt: Date?

        var isFinished = false
    }

    /// What a scan found about the run of one hook.
    private struct Scan {
        let script: GitHookScript
        let pid: pid_t
        let startedAt: Date
        let reached: [Int]
        let followsSteps: Bool
        var endedAt: Date?
        var outcome: GitHookRun.Outcome = .running
    }

    // MARK: Shared Trackers

    private static var trackers: [Git.Repository: GitHookTracker] = [:]

    /// The tracker of `repository`. Must be called on the main thread.
    static func tracker(for repository: Git.Repository) -> GitHookTracker {
        if let existing = trackers[repository] { return existing }
        let tracker = GitHookTracker(repository: repository)
        trackers[repository] = tracker
        return tracker
    }

    private init(repository: Git.Repository) {
        self.repository = repository
    }

    /// Scans until the returned value is cancelled or released. Must be called on the
    /// main thread.
    func watch() -> AnyCancellable {
        watchers += 1
        if watchers == 1 { start() }
        var released = false
        return AnyCancellable { [weak self] in
            DispatchQueue.main.async {
                guard let self, !released else { return }
                released = true
                self.watchers -= 1
                if self.watchers == 0 { self.stop() }
            }
        }
    }

    private func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.scan() }
        timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(100))
        // Look for the scripts first, in case they changed while no panel watched.
        queue.async { [weak self] in self?.scans = 0 }
        timer.resume()
        self.timer = timer
    }

    private func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: Scanning

    private func scan() {
        if scans % Self.scriptsEvery == 0 {
            knownScripts = GitHookScript.scripts(of: repository)
        }
        scans += 1

        let scripts = knownScripts
        var found: [Scan] = []
        if !scripts.isEmpty {
            let running = runningScripts(scripts)
            for script in scripts {
                if let scan = follow(script, running: running[script.name]) {
                    found.append(scan)
                }
            }
        }

        let now = Date()
        DispatchQueue.main.async { [weak self] in
            self?.apply(scripts: scripts, scans: found, at: now)
        }
    }

    /// The process running each hook's script, by the hook's name. A script's subshells
    /// run with the same arguments, so it is the one that started first.
    private func runningScripts(_ scripts: [GitHookScript]) -> [String: (pid: pid_t, startedAt: Date)] {
        let names = Set(scripts.map(\.name))
        var running: [String: (pid: pid_t, startedAt: Date)] = [:]
        for pid in RunningProcess.all() {
            guard let name = RunningProcess.name(pid), Self.shells.contains(name),
                  let arguments = RunningProcess.arguments(pid) else { continue }
            for argument in arguments.dropFirst() where names.contains((argument as NSString).lastPathComponent) {
                let path: String
                if argument.hasPrefix("/") {
                    path = argument
                } else if let directory = RunningProcess.directory(pid) {
                    path = (directory as NSString).appendingPathComponent(argument)
                } else {
                    continue
                }
                guard let script = scripts.first(where: { $0.path == Git.realPath(path) }),
                      let startedAt = RunningProcess.startTime(pid) else { continue }
                if let known = running[script.name], known.startedAt <= startedAt { continue }
                running[script.name] = (pid, startedAt)
            }
        }
        return running
    }

    /// Reads on in the output of the run of `script`, if one runs or has just ended.
    private func follow(_ script: GitHookScript, running: (pid: pid_t, startedAt: Date)?) -> Scan? {
        if let running, outputs[script.name]?.pid != running.pid {
            outputs[script.name] = Output(
                pid: running.pid,
                startedAt: running.startedAt,
                file: RunningProcess.outputFile(running.pid),
                parser: GitHookOutputParser(script: script))
        }
        guard var output = outputs[script.name], !output.isFinished else { return nil }
        defer { outputs[script.name] = output }

        if let file = output.file, let handle = try? FileHandle(forReadingFrom: file) {
            defer { try? handle.close() }
            if (try? handle.seek(toOffset: output.offset)) != nil, let data = try? handle.readToEnd() {
                output.offset += UInt64(data.count)
                output.parser.feed(data)
            }
        }

        var scan = Scan(
            script: script,
            pid: output.pid,
            startedAt: output.startedAt,
            reached: output.parser.reached,
            followsSteps: output.file != nil && !script.steps.isEmpty)
        guard running == nil else { return scan }

        guard let endedAt = output.endedAt else {
            output.endedAt = Date()
            return scan
        }

        output.parser.finish()
        output.isFinished = true
        scan = Scan(
            script: script,
            pid: output.pid,
            startedAt: output.startedAt,
            reached: output.parser.reached,
            followsSteps: scan.followsSteps,
            endedAt: endedAt,
            outcome: Self.outcome(of: output, script: script))
        return scan
    }

    private static func outcome(of output: Output, script: GitHookScript) -> GitHookRun.Outcome {
        let parser = output.parser
        if parser.failed { return .failed }
        if parser.passed { return .passed }
        guard output.file != nil else { return .ended }
        // Husky says when the script fails, and it didn't.
        if script.isHusky { return .passed }
        // Without it, a script that stopped before its last step failed.
        guard let last = parser.reached.last else { return .ended }
        return last == script.steps.count - 1 ? .ended : .failed
    }

    // MARK: Runs

    private func apply(scripts: [GitHookScript], scans: [Scan], at now: Date) {
        if scripts != self.scripts { self.scripts = scripts }

        var runs = self.runs
        for scan in scans {
            var run: GitHookRun
            var isNew = false
            if let known = runs[scan.script.name], known.pid == scan.pid, known.startedAt == scan.startedAt {
                run = known
            } else {
                isNew = true
                run = GitHookRun(
                    pid: scan.pid,
                    startedAt: scan.startedAt,
                    steps: scan.script.steps.map { GitHookRun.Step(title: $0) },
                    followsSteps: scan.followsSteps)
            }

            Self.reach(scan.reached, in: &run, isNew: isNew, at: now)

            if let endedAt = scan.endedAt {
                run.endedAt = endedAt
                run.outcome = scan.outcome
                if let current = run.current, run.steps[current].endedAt == nil {
                    run.steps[current].endedAt = endedAt
                }
            }
            runs[scan.script.name] = run
        }
        // Hooks that are gone take their runs with them.
        runs = runs.filter { name, _ in scripts.contains { $0.name == name } }
        if runs != self.runs { self.runs = runs }
    }

    /// Marks the steps a run reached. The latest runs from now, and those before it are
    /// done. A run seen for the first time may be past some of them already, and their
    /// durations are unknown.
    private static func reach(_ reached: [Int], in run: inout GitHookRun, isNew: Bool, at now: Date) {
        for (order, step) in reached.enumerated() where run.steps.indices.contains(step) {
            let isLatest = order == reached.count - 1
            if run.steps[step].startedAt == nil, run.steps[step].endedAt == nil {
                if order == 0, isLatest || !isNew {
                    // The first step starts with the script.
                    run.steps[step].startedAt = run.startedAt
                } else if isLatest || !isNew {
                    run.steps[step].startedAt = now
                }
                if !isLatest { run.steps[step].endedAt = now }
            } else if !isLatest, run.steps[step].endedAt == nil {
                run.steps[step].endedAt = now
            }
        }
        run.current = reached.last
    }
}
