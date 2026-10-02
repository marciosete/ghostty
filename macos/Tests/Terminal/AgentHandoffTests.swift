import Foundation
import Testing
@testable import Ghostty

@Suite
struct AgentHandoffTests {
    private func json(_ object: [String: Any]) -> [String: Any] { object }

    // MARK: Claude Code transcripts

    @Test func readsAClaudeConversation() {
        let user = json(["type": "user", "message": ["role": "user", "content": "Fix the flaky test\n\n<system-reminder>be brief</system-reminder>"]])
        let assistant = json(["type": "assistant", "message": ["content": [
            ["type": "text", "text": "Looking at it."],
            ["type": "tool_use", "name": "Read", "input": ["file_path": "/p/t.swift"]],
        ]]])
        let result = json(["type": "user", "message": ["content": [
            ["type": "tool_result", "content": [["type": "text", "text": "line 1\nline 2"]]],
        ]]])
        let sidechain = json(["type": "assistant", "isSidechain": true, "message": ["content": "subagent chatter"]])
        let command = json(["type": "user", "message": ["content": "<command-name>/clear</command-name>"]])

        var entries: [AgentHandoff.Entry] = []
        for line in [user, assistant, result, sidechain, command] {
            entries += AgentHandoff.claudeEntries(line)
        }
        #expect(entries == [
            .user("Fix the flaky test"),
            .assistant("Looking at it."),
            .tool(name: "Read", input: #"{"file_path":"\/p\/t.swift"}"#),
            .toolResult("line 1\nline 2"),
        ])
    }

    // MARK: Codex rollouts

    @Test func readsACodexConversation() {
        func item(_ payload: [String: Any]) -> [String: Any] {
            ["type": "response_item", "payload": payload]
        }
        let context = item(["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>cwd</environment_context>"]]])
        let user = item(["type": "message", "role": "user", "content": [["type": "input_text", "text": "Add a test"]]])
        let call = item(["type": "function_call", "name": "shell", "arguments": #"{"command":["ls"]}"#])
        let output = item(["type": "function_call_output", "output": "a.swift\nb.swift"])
        let reply = item(["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Added."]]])
        let reasoning = item(["type": "reasoning", "summary": []])
        let duplicate: [String: Any] = ["type": "event_msg", "payload": ["type": "user_message", "message": "Add a test"]]

        var entries: [AgentHandoff.Entry] = []
        for line in [context, user, call, output, reply, reasoning, duplicate] {
            entries += AgentHandoff.codexEntries(line)
        }
        #expect(entries == [
            .user("Add a test"),
            .tool(name: "shell", input: #"{"command":["ls"]}"#),
            .toolResult("a.swift\nb.swift"),
            .assistant("Added."),
        ])
    }

    @Test func longToolTextIsCut() {
        let long = String(repeating: "y", count: 1000)
        let entries = AgentHandoff.codexEntries(["type": "response_item", "payload": ["type": "function_call_output", "output": long]])
        #expect(entries == [.toolResult(String(repeating: "y", count: AgentHandoff.toolTextLimit) + "…")])
    }

    // MARK: The document

    @Test func markdownSaysWhoSaidWhat() {
        let markdown = AgentHandoff.markdown(
            entries: [.user("Hi"), .tool(name: "Read", input: "x"), .toolResult("y"), .assistant("Hello")],
            from: .claude, to: .codex)
        #expect(markdown.hasPrefix("# Handoff to Codex"))
        #expect(markdown.contains("from Claude Code to Codex"))
        #expect(markdown.contains("## Conversation with Claude Code"))
        #expect(markdown.contains("**User:**\n\nHi"))
        #expect(markdown.contains("> `Read` `x`"))
        #expect(markdown.contains("> ↳ y"))
        #expect(markdown.contains("**Claude Code:**\n\nHello"))
    }

    @Test func anEarlierHandoffComesFirst() {
        let markdown = AgentHandoff.markdown(entries: [.user("again")], from: .codex, to: .claude, earlier: "## Conversation with Claude Code\n\n**User:**\n\nfirst")
        let earlier = markdown.range(of: "## Conversation with Claude Code")!
        let later = markdown.range(of: "## Conversation with Codex")!
        #expect(earlier.lowerBound < later.lowerBound)
    }

    @Test func aLongConversationKeepsItsEnd() {
        let entries = (0..<2000).map { AgentHandoff.Entry.assistant("message \($0) " + String(repeating: "z", count: 200)) }
        let markdown = AgentHandoff.markdown(entries: entries, from: .claude, to: .codex)
        #expect(markdown.count < AgentHandoff.documentLimit + 2000)
        #expect(markdown.contains("left out for length"))
        #expect(markdown.contains("message 1999 "))
        #expect(!markdown.contains("message 0 "))
    }

    // MARK: The command

    @Test func theNextAgentIsToldToReadTheHandoff() {
        let handoff = URL(fileURLWithPath: "/Users/me/Library/Application Support/x/Handoffs/it's here.md")
        let prompt = AgentHandoff.prompt(from: .claude, handoff: handoff)
        #expect(prompt.contains("taking over a coding session from Claude Code"))
        #expect(prompt.contains(handoff.path))

        let command = AgentHandoff.command(for: .codex, prompt: "it's here")
        #expect(command == "codex 'it'\\''s here'")
        #expect(AgentHandoff.command(for: .claude, prompt: nil) == "claude")
    }
}
