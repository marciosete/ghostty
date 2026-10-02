import Foundation
import Testing
@testable import Ghostty

@Suite
struct ClaudeCodeStartTests {
    /// A repository with a worktree, in a temporary directory removed after `body`.
    private func withRepository(_ body: (_ main: String, _ worktree: String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("maggie-start-\(UUID().uuidString)")
        let main = root.appendingPathComponent("repo")
        let worktree = root.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try git(["init", "-q", "-b", "main"], in: main)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "first"], in: main)
        try git(["worktree", "add", "-q", worktree.path], in: main)

        try body(main.path, worktree.path)
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    @Test func outsideARepositoryIsPlainClaude() {
        #expect(ClaudeCodeStart.command(in: nil) == "claude")
        #expect(ClaudeCodeStart.command(in: FileManager.default.temporaryDirectory.path) == "claude")
    }

    @Test func inTheMainCheckoutItIsAWorktreeSession() throws {
        try withRepository { main, _ in
            #expect(ClaudeCodeStart.command(in: main) == "claude -w || claude")
        }
    }

    @Test func inAWorktreeItStartsFromTheMainCheckout() throws {
        try withRepository { main, worktree in
            let real = URL(fileURLWithPath: main).standardizedFileURL.resolvingSymlinksInPath().path
            let command = ClaudeCodeStart.command(in: worktree)
            #expect(command.hasPrefix("(cd '"))
            #expect(command.hasSuffix("' && claude -w) || claude"))
            #expect(command.contains(real) || command.contains(main))
            #expect(ClaudeCodeStart.mainCheckout(of: worktree).map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
            } == real)
        }
    }

    @Test @MainActor func aRestoredSessionKeepsItsResumeInput() {
        var config = Ghostty.SurfaceConfiguration()
        config.initialInput = "claude --resume abc\n"
        ClaudeCodeStart.shared.apply(to: &config)
        #expect(config.initialInput == "claude --resume abc\n")
        #expect(config.environmentVariables[ClaudeCodeStart.environmentVariable] == nil)
    }
}
