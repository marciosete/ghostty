import Foundation
import Testing
@testable import Ghostty

@Suite
struct ClaudeCodeLightTests {
    // MARK: Status

    @Test func statusColors() {
        #expect(ClaudeCodeLight(status: "busy", pending: false)?.tabColor == .blue)
        #expect(ClaudeCodeLight(status: "shell", pending: true)?.tabColor == .blue)
        #expect(ClaudeCodeLight(status: "idle", pending: true)?.tabColor == .yellow)
        #expect(ClaudeCodeLight(status: "waiting", pending: false)?.tabColor == .red)
        #expect(ClaudeCodeLight(status: "idle", pending: false)?.tabColor == .green)
    }

    @Test func pendingOnlyShowsOnceStopped() {
        #expect(ClaudeCodeLight(status: "busy", pending: true) == .working)
        #expect(ClaudeCodeLight(status: "waiting", pending: true) == .waiting)
    }

    @Test func unknownStatusShowsNothing() {
        #expect(ClaudeCodeLight(status: "parked", pending: false) == nil)
    }

    @Test func tabShowsTheSessionThatNeedsAttentionMost() {
        #expect(ClaudeCodeLight.mostUrgent([.clean, .waiting, .working]) == .waiting)
        #expect(ClaudeCodeLight.mostUrgent([.pending, .working]) == .working)
        #expect(ClaudeCodeLight.mostUrgent([.clean, .pending]) == .pending)
        #expect(ClaudeCodeLight.mostUrgent([]) == nil)
    }

    // MARK: Tab state

    @Test func badgeCountsPendingFilesWhileYellow() {
        let state = ClaudeCodeTabState(light: .pending, pendingFiles: 3, editedFiles: 7)
        #expect(state.badge == 3)
        #expect(state.badgeHelp == "3 of 7 edited files not committed")
        #expect(ClaudeCodeTabState(light: .clean, pendingFiles: 0, editedFiles: 7).badge == nil)
        #expect(ClaudeCodeTabState(light: .working).badge == nil)
    }

    @Test func committedButNotLandedIsTeal() {
        #expect(ClaudeCodeLight(status: "idle", pending: false, unlanded: true) == .unlanded)
        #expect(ClaudeCodeLight(status: "idle", pending: true, unlanded: true) == .pending)
        #expect(ClaudeCodeLight(status: "busy", pending: false, unlanded: true) == .working)
        #expect(ClaudeCodeLight.unlanded.tabColor == .teal)
        #expect(ClaudeCodeLight.mostUrgent([.clean, .unlanded]) == .unlanded)
        #expect(ClaudeCodeLight.mostUrgent([.unlanded, .pending]) == .pending)
    }

    @Test func badgeCountsCommitsWhileTeal() {
        let worktree = Git.Worktree(
            root: URL(fileURLWithPath: "/repo/.claude/worktrees/a"),
            gitDir: URL(fileURLWithPath: "/repo/.git/worktrees/a"),
            commonDir: URL(fileURLWithPath: "/repo/.git"),
            branch: "worktree-a",
            mainRoot: URL(fileURLWithPath: "/repo"),
            baseBranch: "main")
        let state = ClaudeCodeTabState(light: .unlanded, unlandedCommits: 2, worktrees: [worktree])
        #expect(state.badge == 2)
        #expect(state.badgeHelp == "2 commits not on main yet")
        #expect(state.landableWorktrees == [worktree])
        #expect(state.landingBranch == "main")

        // Only a teal tab can land: yellow still has files to commit.
        let pending = ClaudeCodeTabState(light: .pending, pendingFiles: 1, editedFiles: 1, unlandedCommits: 2, worktrees: [worktree])
        #expect(pending.landableWorktrees.isEmpty)
        #expect(pending.badgeHelp == "1 file not committed")
    }

    @Test func splitTabAddsUpItsSessions() {
        let combined = ClaudeCodeTabState.combined([
            ClaudeCodeTabState(light: .pending, pendingFiles: 2, editedFiles: 4),
            ClaudeCodeTabState(light: .clean, pendingFiles: 0, editedFiles: 3),
            ClaudeCodeTabState(light: .pending, pendingFiles: 1, editedFiles: 1),
        ])
        #expect(combined == ClaudeCodeTabState(light: .pending, pendingFiles: 3, editedFiles: 8))

        // A session that needs attention hides the count.
        let waiting = ClaudeCodeTabState.combined([
            ClaudeCodeTabState(light: .pending, pendingFiles: 2, editedFiles: 4),
            ClaudeCodeTabState(light: .waiting),
        ])
        #expect(waiting?.light == .waiting)
        #expect(waiting?.badge == nil)
        #expect(ClaudeCodeTabState.combined([]) == nil)
    }

    @Test func renamesCountOnce() {
        let output = "R  new.swift\0old.swift\0 M a.swift\0?? b.swift\0"
        #expect(Git.changedPaths(porcelain: output) == ["new.swift", "a.swift", "b.swift"])
    }

    // MARK: Colors

    @Test func trafficLightColorsCantBePickedByHand() {
        for light in ClaudeCodeLight.allCases {
            #expect(!TerminalTabColor.tabChoices.contains(light.tabColor))
            #expect(!TerminalTabColor.groupChoices.contains(light.tabColor))
            #expect(light.tabColor.isTrafficLight)
        }
        #expect(TerminalTabColor.tabChoices.first == .auto)
        #expect(!TerminalTabColor.groupChoices.contains(.auto))
        #expect(!TerminalTabColor.groupChoices.contains(.attention))
        #expect(TerminalTabColor.attention.followsClaudeCode)
        #expect(!TerminalTabColor.pink.followsClaudeCode)
        #expect(!TerminalTabColor.pink.isTrafficLight)
    }

    // One test, since it changes a setting the others would race on.
    @Test func followingIsAutoUntilPickedForEveryTab() {
        let key = "TabColorFollowing"
        let saved = UserDefaults.ghostty.object(forKey: key)
        defer { UserDefaults.ghostty.set(saved, forKey: key) }

        UserDefaults.ghostty.removeObject(forKey: key)
        #expect(TerminalTabColor.following == .auto)

        TerminalTabColor.following = .attention
        #expect(TerminalTabColor.auto.resolvingFollowing == .attention)
        #expect(TerminalTabColor.attention.resolvingFollowing == .attention)
        #expect(TerminalTabColor.pink.resolvingFollowing == .pink)
        #expect(TerminalTabColor.none.resolvingFollowing == TerminalTabColor.none)

        // Only a following color can be the one tabs follow with.
        TerminalTabColor.following = .pink
        #expect(TerminalTabColor.following == .attention)

        TerminalTabColor.following = .auto
        #expect(TerminalTabColor.attention.resolvingFollowing == .auto)
    }

    @Test func everySessionReadsWithCharlieUntilAnotherVoiceIsPicked() {
        let saved = UserDefaults.ghostty.object(forKey: ElevenLabs.voiceIDKey)
        defer { UserDefaults.ghostty.set(saved, forKey: ElevenLabs.voiceIDKey) }

        UserDefaults.ghostty.removeObject(forKey: ElevenLabs.voiceIDKey)
        #expect(ElevenLabs.voiceName == "Charlie")
        #expect(ElevenLabs.Voice.configured().id == ElevenLabs.defaultVoiceID)

        ElevenLabs.voiceID = "FGY2WhTYpPnrIDTdsKH5"
        #expect(ElevenLabs.voiceName == "Laura")
        #expect(ElevenLabs.Voice.configured().id == "FGY2WhTYpPnrIDTdsKH5")
    }

    @Test func savedColorsKeepTheirValues() {
        #expect(TerminalTabColor.none.rawValue == 0)
        #expect(TerminalTabColor.graphite.rawValue == 9)
        #expect(TerminalTabColor.auto.rawValue == 10)
        #expect(TerminalTabColor.attention.rawValue == 11)
    }

    // MARK: Edited files

    private static func toolUse(_ name: String, _ input: [String: Any], sidechain: Bool = false) -> Data {
        line([
            "type": "assistant",
            "isSidechain": sidechain,
            "message": ["content": [["type": "tool_use", "id": UUID().uuidString, "name": name, "input": input]]],
        ])
    }

    private static func line(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    @Test func collectsEditedFiles() {
        let tracker = ClaudeCodeEditTracker()
        tracker.consume(line: Self.toolUse("Edit", ["file_path": "/repo/a.swift"]))
        tracker.consume(line: Self.toolUse("Write", ["file_path": "/repo/b.swift"]))
        tracker.consume(line: Self.toolUse("MultiEdit", ["file_path": "/repo/a.swift"]))
        tracker.consume(line: Self.toolUse("NotebookEdit", ["notebook_path": "/repo/c.ipynb"]))
        #expect(tracker.files == ["/repo/a.swift", "/repo/b.swift", "/repo/c.ipynb"])
    }

    @Test func ignoresReadsCommandsAndSubagents() {
        let tracker = ClaudeCodeEditTracker()
        tracker.consume(line: Self.toolUse("Read", ["file_path": "/repo/a.swift"]))
        tracker.consume(line: Self.toolUse("Bash", ["command": "touch /repo/b.swift"]))
        tracker.consume(line: Self.toolUse("Edit", ["file_path": "/repo/c.swift"], sidechain: true))
        #expect(tracker.files.isEmpty)
    }

    @Test func codexOnlyCountsSuccessfulChangesAndResolvesRelativePaths() {
        let tracker = ClaudeCodeEditTracker(agent: .codex, directory: "/repo")
        func fileChange(_ path: String, status: String) -> Data {
            Self.line(["type": "event_msg", "payload": ["type": "item_completed", "item": [
                "type": "FileChange", "status": status, "changes": [path: ["type": "update"]],
            ]]])
        }
        tracker.consume(line: fileChange("failed.swift", status: "failed"))
        tracker.consume(line: fileChange("declined.swift", status: "declined"))
        tracker.consume(line: fileChange("src/../edited.swift", status: "completed"))
        tracker.consume(line: Self.line(["type": "event_msg", "payload": [
            "type": "patch_apply_end", "success": false, "changes": ["failed-patch.swift": ["type": "add"]],
        ]]))
        tracker.consume(line: Self.line(["type": "event_msg", "payload": [
            "type": "patch_apply_end", "success": true,
            "changes": ["old.swift": ["type": "update", "move_path": "new.swift"]],
        ]]))
        #expect(tracker.files == ["/repo/edited.swift", "/repo/old.swift", "/repo/new.swift"])
    }

    @Test func readsOnlyWhatWasAdded() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-code-light-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        var contents = Self.toolUse("Edit", ["file_path": "/repo/a.swift"]) + Data("\n".utf8)
        try contents.write(to: url)
        let tracker = ClaudeCodeEditTracker()
        tracker.update(from: url)
        #expect(tracker.files == ["/repo/a.swift"])

        // A line still being written is read once it is complete.
        let next = Self.toolUse("Write", ["file_path": "/repo/b.swift"])
        contents += next.prefix(10)
        try contents.write(to: url)
        tracker.update(from: url)
        #expect(tracker.files == ["/repo/a.swift"])

        contents += next.dropFirst(10) + Data("\n".utf8)
        try contents.write(to: url)
        tracker.update(from: url)
        #expect(tracker.files == ["/repo/a.swift", "/repo/b.swift"])
    }

    // MARK: Git

    private static func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = Git.executableURL
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func parsesTheWorktreeList() {
        let output = "worktree /repo\0HEAD abc\0branch refs/heads/main\0\0worktree /repo/.claude/worktrees/a\0HEAD def\0branch refs/heads/worktree-a\0locked\0\0worktree /tmp/d\0HEAD 123\0detached\0\0"
        let worktrees = Git.parseWorktreeList(output)
        #expect(worktrees.map(\.path) == ["/repo", "/repo/.claude/worktrees/a", "/tmp/d"])
        #expect(worktrees.map(\.branch) == ["main", "worktree-a", nil])
    }

    @Test func readsWhereADirectoryIsCheckedOut() throws {
        let (made, main, worktree) = try Self.repositoryWithWorktree()
        defer { try? FileManager.default.removeItem(at: made) }

        let mainCheckout = Git.checkout(of: main)
        #expect(mainCheckout == Git.Checkout(project: "main", branch: "main", isLinkedWorktree: false))

        // A worktree is named after its main checkout, whatever its own folder is called.
        let worktreeCheckout = Git.checkout(of: worktree)
        #expect(worktreeCheckout == Git.Checkout(project: "main", branch: "worktree-a", isLinkedWorktree: true))

        #expect(Git.checkout(of: made) == nil)
        #expect(Git.parseCheckout("/r\n/r/.git\n/r/.git\nHEAD\n")?.branch == nil)
    }

    /// A repository with one commit on `main` and a linked worktree on `worktree-a`.
    private static func repositoryWithWorktree() throws -> (made: URL, main: URL, worktree: URL) {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("claude-code-light-\(UUID().uuidString)")
        let main = made.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: main)
        try git(["config", "user.name", "Test"], in: main)
        try git(["config", "user.email", "test@example.com"], in: main)
        try Data("base\n".utf8).write(to: main.appendingPathComponent("shared.txt"))
        try git(["add", "."], in: main)
        try git(["commit", "-q", "-m", "base"], in: main)
        let worktree = made.appendingPathComponent("a")
        try git(["worktree", "add", "-q", "-b", "worktree-a", worktree.path], in: main)
        return (made, main, worktree)
    }

    private static func commit(_ file: String, _ contents: String, in directory: URL) throws {
        try Data(contents.utf8).write(to: directory.appendingPathComponent(file))
        try git(["add", "."], in: directory)
        try git(["commit", "-q", "-m", file], in: directory)
    }

    @Test func worktreeProgressAndLanding() throws {
        let (made, main, worktreeURL) = try Self.repositoryWithWorktree()
        defer { try? FileManager.default.removeItem(at: made) }

        #expect(Git.linkedWorktree(containing: main) == nil)
        let worktree = try #require(Git.linkedWorktree(containing: worktreeURL))
        #expect(worktree.branch == "worktree-a")
        #expect(worktree.baseBranch == "main")
        #expect(worktree.mainRoot == Git.repository(containing: main)?.root)

        // Every change in the worktree counts, however it was made.
        try Data("x".utf8).write(to: worktreeURL.appendingPathComponent("made-by-a-script.txt"))
        #expect(Git.progress(of: worktree)?.uncommittedFiles == 1)
        #expect(Git.land(worktree).isFailure)

        try Self.git(["add", "."], in: worktreeURL)
        try Self.git(["commit", "-q", "-m", "script"], in: worktreeURL)
        #expect(Git.progress(of: worktree)?.uncommittedFiles == 0)
        #expect(Git.progress(of: worktree)?.unlandedCommits == 1)

        // Another session landed first: the commit is replayed on top, with no merge.
        try Self.commit("other.txt", "other\n", in: main)
        guard case .success = Git.land(worktree) else {
            Issue.record("landing failed")
            return
        }
        #expect(Git.progress(of: worktree)?.unlandedCommits == 0)
        #expect(FileManager.default.fileExists(atPath: main.appendingPathComponent("made-by-a-script.txt").path))
        #expect(try Self.output(["rev-list", "--merges", "--count", "main"], in: main) == "0")
        #expect(try Self.output(["rev-list", "--count", "main"], in: main) == "3")
    }

    /// Another session rebased the worktree's commits and landed them, and this branch
    /// still has the commits they were rebased from.
    @Test func commitsLandedAsCopiesHaveLanded() throws {
        let (made, main, worktreeURL) = try Self.repositoryWithWorktree()
        defer { try? FileManager.default.removeItem(at: made) }
        let worktree = try #require(Git.linkedWorktree(containing: worktreeURL))
        let repository = try #require(Git.repository(containing: worktreeURL))

        try Self.commit("a.txt", "a\n", in: worktreeURL)
        try Self.commit("b.txt", "b\n", in: worktreeURL)
        try Self.commit("other.txt", "other\n", in: main)
        try Self.git(["cherry-pick", "main..worktree-a"], in: main)
        #expect(try Self.output(["rev-list", "--count", "main..worktree-a"], in: main) == "2")

        #expect(Git.progress(of: worktree)?.unlandedCommits == 0)
        let status = try #require(Git.status(of: repository))
        #expect(status.ahead == 0)
        #expect(status.behind == 3)

        // A commit of its own still counts.
        try Self.commit("c.txt", "c\n", in: worktreeURL)
        #expect(Git.progress(of: worktree)?.unlandedCommits == 1)
    }

    @Test func conflictsLeaveBothBranchesAlone() throws {
        let (made, main, worktreeURL) = try Self.repositoryWithWorktree()
        defer { try? FileManager.default.removeItem(at: made) }
        let worktree = try #require(Git.linkedWorktree(containing: worktreeURL))

        try Self.commit("shared.txt", "mine\n", in: worktreeURL)
        try Self.commit("shared.txt", "theirs\n", in: main)
        let mainBefore = try Self.output(["rev-parse", "main"], in: main)
        let branchBefore = try Self.output(["rev-parse", "worktree-a"], in: main)

        guard case .failure(.conflicts) = Git.land(worktree) else {
            Issue.record("expected a conflict")
            return
        }
        #expect(try Self.output(["rev-parse", "main"], in: main) == mainBefore)
        #expect(try Self.output(["rev-parse", "worktree-a"], in: main) == branchBefore)
        #expect(Git.progress(of: worktree)?.uncommittedFiles == 0)
    }

    @Test func worktreeStatusCountsAgainstTheMainCheckout() throws {
        let (made, main, worktreeURL) = try Self.repositoryWithWorktree()
        defer { try? FileManager.default.removeItem(at: made) }

        let mainRepository = try #require(Git.repository(containing: main))
        let repository = try #require(Git.repository(containing: worktreeURL))
        #expect(!mainRepository.isLinkedWorktree)
        #expect(repository.isLinkedWorktree)
        #expect(repository.commonDir == mainRepository.gitDir)

        try Self.commit("a.txt", "a\n", in: worktreeURL)
        try Self.commit("b.txt", "b\n", in: worktreeURL)
        try Self.commit("other.txt", "other\n", in: main)

        let status = try #require(Git.status(of: repository))
        #expect(status.upstream == nil)
        #expect(status.base == "main")
        #expect(status.ahead == 2)
        #expect(status.behind == 1)

        // The main checkout itself has nothing to count against.
        #expect(Git.status(of: mainRepository)?.base == nil)
    }

    @Test func detachedCodexWorktreeCountsAndLandsCommits() throws {
        let (made, main, worktreeURL) = try Self.repositoryWithWorktree()
        defer { try? FileManager.default.removeItem(at: made) }
        try Self.git(["checkout", "--detach"], in: worktreeURL)
        try Self.commit("codex.txt", "Codex change\n", in: worktreeURL)
        try Self.commit("main.txt", "Main change\n", in: main)

        let repository = try #require(Git.repository(containing: worktreeURL))
        let worktree = try #require(Git.linkedWorktree(containing: worktreeURL))
        #expect(worktree.branch == nil)
        #expect(worktree.baseBranch == "main")
        let status = try #require(Git.status(of: repository))
        #expect(status.branch == nil)
        #expect(status.base == "main")
        #expect(status.ahead == 1)
        #expect(status.behind == 1)
        #expect(Git.progress(of: worktree)?.unlandedCommits == 1)

        guard case .success = Git.land(worktree) else {
            Issue.record("expected detached worktree commits to land")
            return
        }
        #expect(Git.status(of: repository)?.ahead == 0)
        #expect(Git.progress(of: worktree)?.unlandedCommits == 0)
        #expect(try String(contentsOf: main.appendingPathComponent("codex.txt"), encoding: .utf8) == "Codex change\n")
        #expect(Git.linkedWorktree(containing: worktreeURL)?.branch == nil)
    }

    @Test func codexPrepromptDirectoryRequiresLiveThreadOwnership() throws {
        let (made, main, worktreeURL) = try Self.repositoryWithWorktree()
        defer { try? FileManager.default.removeItem(at: made) }
        let sibling = made.appendingPathComponent("sibling")
        try Self.git(["worktree", "add", "-q", "--detach", sibling.path], in: main)
        let worktree = try #require(Git.repository(containing: worktreeURL))
        let siblingRepository = try #require(Git.repository(containing: sibling))
        let id = UUID()
        let otherID = UUID()
        func own(_ repository: Git.Repository, by owner: UUID) throws {
            try Self.line(["version": 1, "ownerThreadId": owner.uuidString])
                .write(to: repository.gitDir.appendingPathComponent("codex-thread.json"))
        }
        try own(worktree, by: id)
        try own(siblingRepository, by: otherID)
        #expect(CodexSession.worktreeDirectory(of: id, in: worktree.commonDir) == worktree.root.path)
        #expect(CodexSession.worktreeDirectory(of: UUID(), in: worktree.commonDir) == nil)

        let lockDirectory = made.appendingPathComponent("thread-writer-locks")
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let lock = lockDirectory.appendingPathComponent("\(id.uuidString).lock")
        try Data().write(to: lock)
        let binary = made.appendingPathComponent("codex")
        try CodexTestProcess.copyExecutable("/bin/sleep", to: binary)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["30"]
        process.currentDirectoryURL = main
        process.standardInput = try FileHandle(forReadingFrom: lock)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let pid = Int(process.processIdentifier)
        defer {
            CodexSession.forget(pid: pid)
            if process.isRunning { process.terminate() }
        }
        #expect(CodexSession.observe(title: "codex | test-model | Ready | \(id) | Test", pid: pid) == "✳ Test")
        #expect(CodexSession.liveDirectory(pid: pid) == worktree.root.path)
        #expect(CodexSession.running(pid: pid) == nil) // No durable history to resume yet.

        #expect(CodexSession.observe(title: "codex | test-model | Ready | \(otherID) | Other", pid: pid) == "✳ Other")
        #expect(CodexSession.liveDirectory(pid: pid) == nil) // Sibling metadata alone cannot claim its thread.
        try own(siblingRepository, by: id)
        #expect(CodexSession.worktreeDirectory(of: id, in: worktree.commonDir) == nil) // Ambiguous owner records.
    }

    @Test func upstreamCommitsAreNotUnlanded() throws {
        // A clone whose main hasn't been pulled, with a worktree branched from origin/main.
        let (made, upstream, _) = try Self.repositoryWithWorktree()
        defer { try? FileManager.default.removeItem(at: made) }
        let clone = made.appendingPathComponent("clone")
        try Self.git(["clone", "-q", upstream.path, clone.path], in: made)
        try Self.commit("pulled.txt", "pulled\n", in: upstream)
        try Self.commit("pulled-too.txt", "pulled\n", in: upstream)
        try Self.git(["fetch", "-q"], in: clone)
        let worktreeURL = made.appendingPathComponent("b")
        try Self.git(["worktree", "add", "-q", "-b", "worktree-b", worktreeURL.path, "origin/main"], in: clone)

        let worktree = try #require(Git.linkedWorktree(containing: worktreeURL))
        #expect(Git.progress(of: worktree)?.unlandedCommits == 0)
        let repository = try #require(Git.repository(containing: worktreeURL))
        #expect(Git.status(of: repository)?.ahead == 0)

        try Self.commit("mine.txt", "mine\n", in: worktreeURL)
        #expect(Git.progress(of: worktree)?.unlandedCommits == 1)
        #expect(Git.status(of: repository)?.ahead == 1)
    }

    private static func output(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = Git.executableURL
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func uncommittedChangesOfTheGivenFilesOnly() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("claude-code-light-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: made) }

        try Self.git(["init", "-q"], in: made)
        let repository = try #require(Git.repository(containing: made))
        let root = repository.root
        let mine = root.appendingPathComponent("mine [1].swift").path
        let other = root.appendingPathComponent("other.swift").path

        // A new file is pending until it is committed.
        try Data("a".utf8).write(to: URL(fileURLWithPath: mine))
        #expect(Git.uncommittedFileCount([mine], in: repository) == 1)
        try Self.git(["add", "."], in: root)
        #expect(Git.uncommittedFileCount([mine], in: repository) == 1)
        try Self.git(["commit", "-q", "-m", "first"], in: root)
        #expect(Git.uncommittedFileCount([mine], in: repository) == 0)

        // Another session's changes don't count.
        try Data("b".utf8).write(to: URL(fileURLWithPath: other))
        #expect(Git.uncommittedFileCount([mine], in: repository) == 0)

        // Neither does a file outside the repository, or no file at all.
        #expect(Git.uncommittedFileCount(["/elsewhere/x.swift"], in: repository) == 0)
        #expect(Git.uncommittedFileCount([], in: repository) == 0)

        try Data("c".utf8).write(to: URL(fileURLWithPath: mine))
        #expect(Git.uncommittedFileCount([mine], in: repository) == 1)

        // Each pending file counts once.
        try Data("d".utf8).write(to: URL(fileURLWithPath: other))
        #expect(Git.uncommittedFileCount([mine, other, mine], in: repository) == 2)
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
