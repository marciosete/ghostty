import Combine
import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized)
struct GitHookTests {
    // MARK: Scripts

    @Test func readsAMarker() throws {
        let marker = try #require(GitHookScript.marker(in: #"echo "[5/9] Workflow hygiene (actionlint + zizmor)…""#))
        #expect(marker.number == 5)
        #expect(marker.total == 9)
        #expect(marker.title == "Workflow hygiene (actionlint + zizmor)")

        #expect(GitHookScript.marker(in: "[2/7] Checking shell scripts...")?.title == "Checking shell scripts")
        #expect(GitHookScript.marker(in: "Running pre-push quality checks…") == nil)
    }

    /// Steps are counted in order, whatever totals the markers give.
    @Test func readsTheStepsOfAScript() {
        let script = GitHookScript(name: "pre-push", path: URL(fileURLWithPath: "/repo/.husky/pre-push"), isHusky: true, text: """
            #!/bin/bash
            # 1. Full lint, which [1/8] marks
            echo ""
            echo "[1/8] Lint (harness + workspaces, --max-warnings 0)…"
            pnpm lint || { echo "lint failed."; exit 1; }
            echo "[2/8] Type-check (harness + workspaces)…"
            echo "[5/9] Workflow hygiene (actionlint + zizmor)…"
            echo "  Pre-push checks PASSED — pushing…"
            """)
        #expect(script.steps == [
            "Lint (harness + workspaces, --max-warnings 0)",
            "Type-check (harness + workspaces)",
            "Workflow hygiene (actionlint + zizmor)",
        ])
        #expect(script.totals == [8, 9])
    }

    @Test func findsHuskyHooks() throws {
        let root = try Self.huskyRepository(prePush: "echo \"[1/2] One…\"\necho \"[2/2] Two…\"\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = try #require(Git.repository(containing: root))
        let scripts = GitHookScript.scripts(of: repository)
        #expect(scripts.map(\.name) == ["pre-push"])
        #expect(scripts.first?.isHusky == true)
        #expect(scripts.first?.path == Git.realPath(root.appendingPathComponent(".husky/pre-push").path))
        #expect(scripts.first?.steps == ["One", "Two"])
    }

    @Test func aRepositoryWithoutHooksHasNone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.git(["init", "-q"], in: root)

        let repository = try #require(Git.repository(containing: root))
        #expect(GitHookScript.scripts(of: repository).isEmpty)
    }

    // MARK: Output

    private static let prePush = GitHookScript(
        name: "pre-push", path: URL(fileURLWithPath: "/repo/.husky/pre-push"), isHusky: true, text: """
            echo "[1/3] Lint…"
            echo "[2/3] Tests…"
            echo "[3/3] CodeQL…"
            """)

    @Test func followsTheStepsInTheOutput() {
        var parser = GitHookOutputParser(script: Self.prePush)
        parser.feed(Data("Running pre-push…\n[1/3] Lint…\nok\n[2/3] Te".utf8))
        #expect(parser.reached == [0])

        // A marker counts once its line is complete.
        parser.feed(Data("sts…\n 824 tests passed\n".utf8))
        #expect(parser.reached == [0, 1])
        #expect(!parser.passed)

        parser.feed(Data("[3/3] CodeQL…\n  Pre-push checks PASSED — pushing…".utf8))
        #expect(!parser.passed)
        parser.finish()
        #expect(parser.reached == [0, 1, 2])
        #expect(parser.passed)
        #expect(!parser.failed)
    }

    @Test func seesHuskySayTheScriptFailed() {
        var parser = GitHookOutputParser(script: Self.prePush)
        parser.feed(Data("[1/3] Lint…\n[2/3] Tests…\nharness tests failed.\nhusky - pre-push script failed (code 1)\n".utf8))
        #expect(parser.reached == [0, 1])
        #expect(parser.failed)
    }

    @Test func ignoresAnotherHooksMarkersAndStartsOverOnANewRun() {
        var parser = GitHookOutputParser(script: Self.prePush)
        parser.feed(Data("[1/7] Checking for secrets…\n[2/7] Checking shell scripts…\n".utf8))
        #expect(parser.reached.isEmpty)

        parser.feed(Data("[1/3] Lint…\n[2/3] Tests…\nhusky - pre-push script failed (code 1)\n[1/3] Lint…\n".utf8))
        #expect(parser.reached == [0])
        #expect(!parser.failed)
    }

    // MARK: Running hooks

    @Test func findsARunningScriptAndItsOutputFile() throws {
        let root = try Self.huskyRepository(prePush: "sleep 5\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output.txt")
        let process = try Self.runHook(in: root, output: output)
        defer { process.terminate() }
        Thread.sleep(forTimeInterval: 0.5)

        let script = Git.realPath(root.appendingPathComponent(".husky/pre-push").path).path
        let found = RunningProcess.all().filter { pid in
            guard let arguments = RunningProcess.arguments(pid), arguments.contains(".husky/pre-push") else { return false }
            return RunningProcess.directory(pid).map { Git.realPath("\($0)/.husky/pre-push").path } == script
        }
        let pid = try #require(found.first)
        #expect(["sh", "bash", "dash"].contains(RunningProcess.name(pid) ?? ""))
        #expect(RunningProcess.arguments(pid)?.dropFirst() == ["-e", ".husky/pre-push", "origin", "git@example.com:repo.git"])
        #expect(RunningProcess.outputFile(pid)?.lastPathComponent == "output.txt")
        #expect(RunningProcess.startTime(pid).map { abs($0.timeIntervalSinceNow) < 5 } == true)
    }

    @Test @MainActor func timesTheStepsOfAHookThatPasses() async throws {
        let root = try Self.huskyRepository(prePush: """
            echo "[1/3] One…"
            sleep 1.5
            echo "[2/3] Two…"
            sleep 1.5
            echo "[3/3] Three…"
            sleep 0.5
            echo "PASSED"
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let run = try await Self.track(root)

        #expect(run.outcome == .passed)
        #expect(run.followsSteps)
        #expect(run.current == 2)
        let durations = run.steps.map(\.duration)
        #expect(durations.allSatisfy { $0 != nil })
        #expect(abs((durations[0] ?? 0) - 1.5) < 0.8)
        #expect(abs((durations[1] ?? 0) - 1.5) < 0.8)
        #expect(abs((run.duration ?? 0) - 3.5) < 1.2)
    }

    @Test @MainActor func stopsAtTheStepAHookFailsAt() async throws {
        let root = try Self.huskyRepository(prePush: """
            echo "[1/3] One…"
            sleep 1
            echo "[2/3] Two…"
            sleep 1
            echo "tests failed."
            exit 1
            echo "[3/3] Three…"
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let run = try await Self.track(root)

        #expect(run.outcome == .failed)
        #expect(run.current == 1)
        #expect(run.steps[1].duration != nil)
        #expect(run.steps[2].startedAt == nil)
    }

    // MARK: Helpers

    /// Runs the repository's pre-push hook, the way git does, and waits for the tracker
    /// to see it end.
    @MainActor
    private static func track(_ root: URL) async throws -> GitHookRun {
        let repository = try #require(Git.repository(containing: root))
        let tracker = GitHookTracker.tracker(for: repository)
        let watch = tracker.watch()
        defer { watch.cancel() }

        // Wait for the tracker to find the script.
        for _ in 0..<40 where tracker.scripts.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(tracker.scripts.map(\.name) == ["pre-push"])

        let process = try runHook(in: root, output: root.appendingPathComponent("output.txt"))
        defer { if process.isRunning { process.terminate() } }

        for _ in 0..<150 {
            if let run = tracker.runs["pre-push"], run.outcome != .running { return run }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        Issue.record("The run never ended: \(String(describing: tracker.runs["pre-push"]))")
        throw CancellationError()
    }

    /// A repository whose pre-push hook is Husky's, running `prePush`.
    private static func huskyRepository(prePush: String) throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString)")
        let husky = root.appendingPathComponent(".husky")
        try fileManager.createDirectory(at: husky.appendingPathComponent("_"), withIntermediateDirectories: true)
        try git(["init", "-q"], in: root)
        try git(["config", "core.hooksPath", ".husky/_"], in: root)

        try write("#!/usr/bin/env sh\n. \"$(dirname \"$0\")/h\"", to: husky.appendingPathComponent("_/pre-push"))
        try write(huskyRunner, to: husky.appendingPathComponent("_/h"))
        try write("#!/bin/bash\n" + prePush, to: husky.appendingPathComponent("pre-push"))
        return root
    }

    /// Husky's `.husky/_/h`, which runs the script of the hook it is named for.
    private static let huskyRunner = """
        #!/usr/bin/env sh
        n=$(basename "$0")
        s=$(dirname "$(dirname "$0")")/$n

        [ ! -f "$s" ] && exit 0

        sh -e "$s" "$@"
        c=$?

        [ $c != 0 ] && echo "husky - $n script failed (code $c)"
        exit $c
        """

    private static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Runs the pre-push hook as git would, from the repository's root, with its output
    /// going to `output`, as Claude Code's does.
    private static func runHook(in root: URL, output: URL) throws -> Process {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [".husky/_/pre-push", "origin", "git@example.com:repo.git"]
        process.currentDirectoryURL = root
        let handle = try FileHandle(forWritingTo: output)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        return process
    }

    private static func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = Git.executableURL
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
