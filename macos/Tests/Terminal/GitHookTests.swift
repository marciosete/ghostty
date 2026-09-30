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

    // MARK: Commands

    /// The commands of agent-harness's hooks, trimmed to what matters here.
    private static let preCommit = GitHookScript(
        name: "pre-commit", path: URL(fileURLWithPath: "/repo/.husky/pre-commit"), isHusky: true, text: """
            #!/bin/bash
            require_tool() {
              command -v "$1" &>/dev/null && return 0
              exit 1
            }
            echo "[1/7] Checking for secrets (gitleaks)…"
            require_tool gitleaks "brew install gitleaks"
            gitleaks protect --staged --verbose || {
              echo "Secrets detected — commit blocked."
              exit 1
            }
            echo "[2/7] Checking shell scripts (shellcheck + bracket style)…"
            STAGED_SH=$(git diff --cached --name-only --diff-filter=ACMR | grep -E '\\.sh$' || true)
            if [[ -n "$STAGED_SH" ]]; then
              echo "$STAGED_SH" | xargs shellcheck -x || {
                exit 1
              }
            fi
            echo "[3/7] Type-checking the package…"
            ./scripts/check-staged-types.sh || exit 1
            echo "[4/7] Linting & formatting staged files…"
            pnpm exec lint-staged || {
              exit 1
            }
            echo "[7/7] Dependency audit (blocking)…"
            ./scripts/audit-ci.sh || {
              exit 1
            }
            """)

    private static let prePushCommands = GitHookScript(
        name: "pre-push", path: URL(fileURLWithPath: "/repo/.husky/pre-push"), isHusky: true, text: """
            git lfs pre-push "$@" || exit 1
            echo "[1/9] Lint (harness + workspaces, --max-warnings 0)…"
            pnpm lint || { echo "lint failed."; exit 1; }
            pnpm -r --if-present lint || { echo "workspace lint failed."; exit 1; }
            echo "[2/9] Type-check (harness + workspaces)…"
            pnpm typecheck || { echo "harness typecheck failed."; exit 1; }
            pnpm -r --if-present typecheck || { echo "workspace typecheck failed."; exit 1; }
            echo "[3/9] Prettier format check…"
            pnpm exec prettier --check . || {
              exit 1
            }
            pnpm -r --if-present format:check || { echo "workspace format failed."; exit 1; }
            echo "[4/9] YAML lint…"
            yamllint . || { echo "yamllint failed."; exit 1; }
            echo "[5/9] Workflow hygiene (actionlint + zizmor)…"
            actionlint || { echo "actionlint failed."; exit 1; }
            zizmor --no-progress .github/ || { echo "zizmor failed."; exit 1; }
            echo "[6/9] Test suite (harness + workspaces)…"
            pnpm test || { echo "harness tests failed."; exit 1; }
            pnpm -r --if-present --workspace-concurrency=1 test || { echo "workspace tests failed."; exit 1; }
            """)

    @Test func readsTheCommandsOfEachStep() {
        #expect(Self.preCommit.commands == [
            [["gitleaks", "protect"]],
            [["git", "diff"], ["shellcheck"]],
            [["check-staged-types.sh"]],
            [["pnpm", "exec", "lint-staged"]],
            [["audit-ci.sh"]],
        ])
        #expect(Self.prePushCommands.commands[2] == [["pnpm", "exec", "prettier"], ["pnpm", "format:check"]])
    }

    @Test func tellsTheStepOfARunningCommand() {
        let pnpm = ["node", "/opt/homebrew/lib/node_modules/pnpm/bin/pnpm.cjs"]
        #expect(Self.preCommit.step(running: ["gitleaks", "protect", "--staged", "--verbose"]) == 0)
        #expect(Self.preCommit.step(running: ["xargs", "shellcheck", "-x"]) == 1)
        #expect(Self.preCommit.step(running: ["/bin/bash", "./scripts/check-staged-types.sh"]) == 2)
        #expect(Self.preCommit.step(running: pnpm + ["exec", "lint-staged"]) == 3)
        #expect(Self.preCommit.step(running: ["/bin/bash", "./scripts/audit-ci.sh"]) == 4)

        let prePush = Self.prePushCommands
        #expect(prePush.step(running: pnpm + ["lint"]) == 0)
        #expect(prePush.step(running: pnpm + ["-r", "--if-present", "lint"]) == 0)
        #expect(prePush.step(running: pnpm + ["typecheck"]) == 1)
        #expect(prePush.step(running: pnpm + ["-r", "--if-present", "format:check"]) == 2)
        #expect(prePush.step(running: ["yamllint", "."]) == 3)
        #expect(prePush.step(running: ["/opt/homebrew/bin/zizmor", "--no-progress", ".github/"]) == 4)
        #expect(prePush.step(running: pnpm + ["-r", "--if-present", "--workspace-concurrency=1", "test"]) == 5)
        // Before its first step, and commands of no step.
        #expect(prePush.step(running: ["git", "lfs", "pre-push", "origin"]) == nil)
        #expect(prePush.step(running: pnpm + ["install"]) == nil)
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

    @Test @MainActor func followsACommitWhoseOutputGoesThroughAPipe() async throws {
        let root = try Self.huskyRepository(hook: "pre-commit", script: """
            echo "[1/2] One…"
            ./scripts/one.sh
            echo "[2/2] Two…"
            ./scripts/two.sh
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write("#!/bin/sh\nsleep 1.5\n", to: root.appendingPathComponent("scripts/one.sh"))
        try Self.write("#!/bin/sh\nsleep 1.5\n", to: root.appendingPathComponent("scripts/two.sh"))

        let run = try await Self.track(root, hook: "pre-commit") { try Self.commitThroughPipe(in: root) }
        #expect(run.outcome == .passed)
        #expect(run.followsSteps)
        #expect(run.current == 1)
        #expect(abs((run.steps[0].duration ?? 0) - 1.5) < 0.8)
        #expect(abs((run.steps[1].duration ?? 0) - 1.5) < 0.8)
    }

    @Test @MainActor func seesACommitWhoseOutputGoesThroughAPipeFail() async throws {
        let root = try Self.huskyRepository(hook: "pre-commit", script: """
            echo "[1/2] One…"
            ./scripts/one.sh
            echo "[2/2] Two…"
            ./scripts/two.sh
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write("#!/bin/sh\nsleep 1\n", to: root.appendingPathComponent("scripts/one.sh"))
        try Self.write("#!/bin/sh\nsleep 1\nexit 1\n", to: root.appendingPathComponent("scripts/two.sh"))

        let run = try await Self.track(root, hook: "pre-commit") { try Self.commitThroughPipe(in: root) }
        #expect(run.outcome == .failed)
        #expect(run.current == 1)
    }

    @Test @MainActor func aRunThatEndedGoesOnceHeadMovesOn() async throws {
        let root = try Self.huskyRepository(hook: "pre-commit", script: """
            echo "[1/1] One…"
            ./scripts/one.sh
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write("#!/bin/sh\nsleep 1\n", to: root.appendingPathComponent("scripts/one.sh"))
        let repository = try #require(Git.repository(containing: root))
        let tracker = GitHookTracker.tracker(for: repository)
        let watch = tracker.watch()
        defer { watch.cancel() }
        try await Self.wait { !tracker.scripts.isEmpty }

        let commit = try Self.commitThroughPipe(in: root)
        try await Self.wait { tracker.runs["pre-commit"]?.outcome == .passed }
        commit.waitUntilExit()

        // The commit it made leaves it standing.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        #expect(tracker.runs["pre-commit"]?.outcome == .passed)

        // Another commit moves HEAD on.
        try Self.git(["commit", "-q", "--allow-empty", "--no-verify", "-m", "next"], in: root)
        try await Self.wait { tracker.runs["pre-commit"] == nil }
    }

    @Test @MainActor func aRunThatEndedGoesWhenItsStepsChange() async throws {
        let root = try Self.huskyRepository(prePush: """
            echo "[1/1] One…"
            sleep 1
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let run = try await Self.track(root)
        #expect(run.outcome == .passed)

        let repository = try #require(Git.repository(containing: root))
        let tracker = GitHookTracker.tracker(for: repository)
        let watch = tracker.watch()
        defer { watch.cancel() }
        try Self.write("#!/bin/bash\necho \"[1/2] One…\"\necho \"[2/2] Two…\"\n", to: root.appendingPathComponent(".husky/pre-push"))
        try await Self.wait { tracker.runs["pre-push"] == nil }
        #expect(tracker.scripts.first?.steps == ["One", "Two"])
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
        try await track(root, hook: "pre-push") {
            try runHook(in: root, output: root.appendingPathComponent("output.txt"))
        }
    }

    /// Starts what runs `hook`, and waits for the tracker to see it end.
    @MainActor
    private static func track(_ root: URL, hook: String, start: () throws -> Process) async throws -> GitHookRun {
        let repository = try #require(Git.repository(containing: root))
        let tracker = GitHookTracker.tracker(for: repository)
        let watch = tracker.watch()
        defer { watch.cancel() }

        // Wait for the tracker to find the script.
        for _ in 0..<40 where tracker.scripts.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(tracker.scripts.map(\.name) == [hook])

        let process = try start()
        defer { if process.isRunning { process.terminate() } }

        for _ in 0..<150 {
            if let run = tracker.runs[hook], run.outcome != .running { return run }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        Issue.record("The run never ended: \(String(describing: tracker.runs[hook]))")
        throw CancellationError()
    }

    /// Waits up to ten seconds for `condition`.
    @MainActor
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        Issue.record("Timed out")
        throw CancellationError()
    }

    /// A repository whose pre-push hook is Husky's, running `prePush`.
    private static func huskyRepository(prePush: String) throws -> URL {
        try huskyRepository(hook: "pre-push", script: prePush)
    }

    /// A repository whose `hook` is Husky's, running `script`.
    private static func huskyRepository(hook: String, script: String) throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString)")
        let husky = root.appendingPathComponent(".husky")
        try fileManager.createDirectory(at: husky.appendingPathComponent("_"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try git(["init", "-q"], in: root)
        try git(["config", "core.hooksPath", ".husky/_"], in: root)
        try git(["config", "user.name", "Test"], in: root)
        try git(["config", "user.email", "test@example.com"], in: root)

        try write("#!/usr/bin/env sh\n. \"$(dirname \"$0\")/h\"", to: husky.appendingPathComponent("_/\(hook)"))
        try write(huskyRunner, to: husky.appendingPathComponent("_/h"))
        try write("#!/bin/bash\n" + script, to: husky.appendingPathComponent(hook))
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

    /// Commits a new file the way Claude Code often does, with git's output going through
    /// a pipe the hook's can't be read from.
    private static func commitThroughPipe(in root: URL) throws -> Process {
        try "hello".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try git(["add", "file.txt"], in: root)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "'\(Git.executableURL!.path)' commit -q -m test 2>&1 | tail -5"]
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
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
