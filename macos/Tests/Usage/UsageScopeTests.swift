import Foundation
import Testing
@testable import Ghostty

struct UsageScopeTests {
    private let projects = "/Users/me/.claude/projects"

    private func transcript(_ folder: String, _ file: String = "abc.jsonl") -> String {
        "\(projects)/\(UsageScopeFilter.claudeFolderName(of: folder))/\(file)"
    }

    @Test func namesFoldersLikeClaudeCode() {
        #expect(UsageScopeFilter.claudeFolderName(of: "/Users/me/projects/KIT") == "-Users-me-projects-KIT")
        #expect(UsageScopeFilter.claudeFolderName(of: "/Users/me/projects/KIT/") == "-Users-me-projects-KIT")
        #expect(UsageScopeFilter.claudeFolderName(of: "/Users/me/my app.v2") == "-Users-me-my-app-v2")
    }

    @Test func workIsTheWorkFoldersAndEverythingBelowThem() {
        let work = UsageScopeFilter(scope: .work, workFolders: ["/Users/me/projects/KIT"])
        let projects = UsageScopeFilter(scope: .projects, workFolders: ["/Users/me/projects/KIT"])

        let inside = [
            transcript("/Users/me/projects/KIT"),
            transcript("/Users/me/projects/KIT/foundry/agent-harness"),
            transcript("/Users/me/projects/KIT/foundry/agent-harness/.claude/worktrees/wiggly"),
            transcript("/Users/me/projects/KIT/foundry/agent-harness", "abc/subagents/agent-1.jsonl"),
        ]
        let outside = [
            transcript("/Users/me/projects/Stuff/dojo"),
            transcript("/Users/me/projects/open-source/ghostty"),
            transcript("/Users/me/projects"),
            transcript("/Users/me/projects/KITCHEN"),
        ]

        for path in inside {
            #expect(work.includes(path: path, in: self.projects, provider: .claude))
            #expect(!projects.includes(path: path, in: self.projects, provider: .claude))
        }
        for path in outside {
            #expect(!work.includes(path: path, in: self.projects, provider: .claude))
            #expect(projects.includes(path: path, in: self.projects, provider: .claude))
        }
    }

    @Test func allCountsEverything() {
        let all = UsageScopeFilter(scope: .all, workFolders: ["/Users/me/projects/KIT"])
        #expect(all.includes(path: transcript("/Users/me/projects/KIT"), in: projects, provider: .claude))
        #expect(all.includes(path: transcript("/Users/me/projects/Stuff"), in: projects, provider: .claude))
    }

    @Test func withoutWorkFoldersEverythingIsProjects() {
        let work = UsageScopeFilter(scope: .work, workFolders: [])
        let projects = UsageScopeFilter(scope: .projects, workFolders: [])
        #expect(!work.includes(path: transcript("/Users/me/projects/KIT"), in: self.projects, provider: .claude))
        #expect(projects.includes(path: transcript("/Users/me/projects/KIT"), in: self.projects, provider: .claude))
    }

    @Test func grokCountsAsProjects() {
        let work = UsageScopeFilter(scope: .work, workFolders: ["/Users/me/projects/KIT"])
        let path = "/Users/me/.grok/sessions/-Users-me-projects-KIT/updates.jsonl"
        #expect(!work.includes(path: path, in: "/Users/me/.grok/sessions", provider: .grok))
    }
}
