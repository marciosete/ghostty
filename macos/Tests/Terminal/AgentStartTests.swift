import Darwin
import Foundation
import Testing
@testable import Ghostty

@Suite
struct AgentStartTests {
    /// A repository with a worktree, in a temporary directory removed after `body`.
    private func withRepository(
        named name: String = "repo",
        _ body: (_ main: String, _ worktree: String) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("maggie-start-\(UUID().uuidString)")
        let main = root.appendingPathComponent(name)
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

    @Test func outsideARepositoryIsAPlainStart() {
        #expect(AgentStart.command(for: .claude, in: nil) == "claude")
        #expect(AgentStart.command(for: .claude, in: FileManager.default.temporaryDirectory.path) == "claude")
        #expect(AgentStart.command(for: .codex, in: FileManager.default.temporaryDirectory.path) == CodingAgent.codex.launchCommand)
    }

    @Test func inTheMainCheckoutItIsAWorktreeSession() throws {
        try withRepository { main, _ in
            #expect(AgentStart.command(for: .claude, in: main) == "claude -w || claude")
            let codex = CodingAgent.codex.launchCommand
            #expect(AgentStart.command(for: .codex, in: main) == "\(CodingAgent.codex.worktreeCommand) || \(codex)")
        }
    }

    @Test func inAWorktreeItStartsFromTheMainCheckout() throws {
        try withRepository { main, worktree in
            let real = URL(fileURLWithPath: main).standardizedFileURL.resolvingSymlinksInPath().path
            let command = AgentStart.command(for: .claude, in: worktree)
            #expect(command.hasPrefix("(cd '"))
            #expect(command.hasSuffix("' && claude -w) || claude"))
            #expect(command.contains(real) || command.contains(main))
            let codex = CodingAgent.codex.launchCommand
            #expect(AgentStart.command(for: .codex, in: worktree)
                .hasSuffix("' && \(CodingAgent.codex.worktreeCommand)) || \(codex)"))
            #expect(AgentStart.mainCheckout(of: worktree).map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
            } == real)
        }
    }

    /// Run the generated command with a harmless agent that reports its directory and
    /// arguments. This exercises quoting and deferred directory discovery in a shell.
    private func run(_ command: String, in directory: String, agent: CodingAgent) throws -> [String] {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("maggie-agent-bin-\(UUID())")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        let executable = bin.appendingPathComponent(agent.command)
        // A native helper avoids spawning another shell interpreter for each fake
        // agent. In particular, a blocked child must never hold a pipe open forever.
        let source = bin.appendingPathComponent("agent.c")
        try Data("""
            #include <stdio.h>
            #include <stdlib.h>
            #include <unistd.h>
            int main(int argc, char **argv) {
                char *cwd = getcwd(NULL, 0);
                if (!cwd) return 1;
                puts(cwd);
                free(cwd);
                for (int i = 1; i < argc; i++) puts(argv[i]);
                return ferror(stdout) ? 1 : 0;
            }
            """.utf8).write(to: source)
        let outputURL = bin.appendingPathComponent("output.txt")
        try Data().write(to: outputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = [source.path, "-o", executable.path]
        compiler.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        compiler.standardOutput = output
        compiler.standardError = output
        try runToCompletion(compiler)
        try output.truncate(atOffset: 0)
        try output.seek(toOffset: 0)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = ["PATH": bin.path + ":/usr/bin:/bin", "HOME": NSHomeDirectory()]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try runToCompletion(process)
        let data = try Data(contentsOf: outputURL)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private func runToCompletion(_ process: Process) throws {
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let exited = finished.wait(timeout: .now() + .seconds(10)) == .success
        if !exited {
            func stop(_ pid: pid_t) {
                for child in RunningProcess.children(pid) { stop(child) }
                kill(pid, SIGKILL)
            }
            stop(process.processIdentifier)
        }
        try #require(exited, "Temporary agent process did not exit within 10 seconds")
        try #require(process.terminationStatus == 0)
    }

    @Test func unspecifiedDirectoryUsesTheShellsRepository() throws {
        try withRepository { main, worktree in
            for directory in [main, worktree] {
                let output = try run(AgentStart.command(for: .codex, in: nil), in: directory, agent: .codex)
                let actual = try #require(output.first)
                #expect(AgentStart.mainCheckout(of: actual).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } ==
                    URL(fileURLWithPath: main).resolvingSymlinksInPath())
                #expect(output.contains("--worktree"))
            }
        }
    }

    @Test func unspecifiedDirectoryOutsideGitStartsNormally() throws {
        let directory = FileManager.default.temporaryDirectory.path
        for agent in CodingAgent.allCases {
            let output = try run(AgentStart.command(for: agent, in: nil), in: directory, agent: agent)
            #expect(!output.contains("--worktree"))
            #expect(!output.contains("-w"))
        }
    }

    @Test func repositoryNamesAreQuotedWithoutShellExpansion() throws {
        try withRepository(named: "repo's space $literal") { main, worktree in
            for directory in [Optional(worktree), nil] {
                for agent in CodingAgent.allCases where directory != nil || agent == .codex {
                    let output = try run(AgentStart.command(for: agent, in: directory), in: worktree, agent: agent)
                    let actual = try #require(output.first)
                    #expect(AgentStart.mainCheckout(of: actual).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } ==
                        URL(fileURLWithPath: main).resolvingSymlinksInPath())
                }
            }
        }
    }

    @Test @MainActor func aRestoredSessionKeepsItsResumeInput() {
        for agent in CodingAgent.allCases {
            var config = Ghostty.SurfaceConfiguration()
            let input = agent.resumeCommand(UUID()) + "\n"
            config.initialInput = input
            config.workingDirectory = "/existing/worktree"
            AgentStart.shared.apply(to: &config)
            #expect(config.initialInput == input)
            #expect(config.workingDirectory == "/existing/worktree")
            #expect(config.environmentVariables[AgentStart.environmentVariable] == nil)
        }
    }

    @Test func codexUsesItsOwnServerWhenSupported() {
        let command = CodingAgent.codex.launchCommand(isolateCodex: true)
        #expect(command.hasPrefix("codex --no-daemon -c "))
        #expect(command.contains(#"["activity","app-name","model","run-state","session-id","thread-title"]"#))
        #expect(CodingAgent.codex.launchCommand(isolateCodex: false) == "codex")
        #expect(CodingAgent.claude.launchCommand(isolateCodex: true) == "claude")
    }

    @Test func codexWorktreesEnableTheirRequiredFeature() {
        let command = CodingAgent.codex.worktreeCommand
        #expect(command.hasPrefix(CodingAgent.codex.launchCommand))
        #expect(command.hasSuffix(" --enable worktrees --worktree"))
    }
}
