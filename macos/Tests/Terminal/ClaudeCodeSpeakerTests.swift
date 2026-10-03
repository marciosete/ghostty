import Foundation
import Testing
@testable import Ghostty

@Suite
struct ClaudeCodeSpeakerTests {
    private func line(_ object: [String: Any]) -> Data {
        // A fixture that isn't JSON is a mistake in the test, not a case to handle.
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            preconditionFailure("test fixture isn't JSON: \(object)")
        }
        return data
    }

    private func assistant(id: String?, _ blocks: [[String: Any]], sidechain: Bool = false, model: String = "claude-opus-5-5") -> Data {
        var message: [String: Any] = ["role": "assistant", "model": model, "content": blocks]
        if let id { message["id"] = id }
        return line(["type": "assistant", "isSidechain": sidechain, "message": message])
    }

    private func text(_ text: String) -> [String: Any] { ["type": "text", "text": text] }
    private let toolUse: [String: Any] = ["type": "tool_use", "name": "Bash", "input": ["command": "ls"]]

    private func user(_ text: String) -> Data {
        line(["type": "user", "message": ["role": "user", "content": text]])
    }

    // MARK: Last response

    @Test func lastResponseIsTheLastMessageWithText() {
        let lines = [
            user("hi"),
            assistant(id: "a", [text("Let me look.")]),
            assistant(id: "a", [toolUse]),
            user("tool result"),
            assistant(id: "b", [text("Here it is.")]),
            assistant(id: "b", [text("And more.")]),
        ]
        #expect(ClaudeCodeResponse.last(inLines: lines) == "Here it is.\n\nAnd more.")
    }

    @Test func toolCallsAfterTheResponseAreSkipped() {
        let lines = [
            assistant(id: "a", [text("Done.")]),
            assistant(id: "b", [toolUse]),
        ]
        #expect(ClaudeCodeResponse.last(inLines: lines) == "Done.")
    }

    @Test func subagentsAndSyntheticMessagesAreSkipped() {
        let lines = [
            assistant(id: "a", [text("Mine.")]),
            assistant(id: "b", [text("Subagent.")], sidechain: true),
            assistant(id: "c", [text("No response requested.")], model: "<synthetic>"),
            line(["not": "a transcript line"]),
            Data("not json".utf8),
        ]
        #expect(ClaudeCodeResponse.last(inLines: lines) == "Mine.")
    }

    @Test func noResponse() {
        #expect(ClaudeCodeResponse.last(inLines: [user("hi")]) == nil)
        #expect(ClaudeCodeResponse.last(inLines: []) == nil)
    }

    @Test func readsTheEndOfATranscriptFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [user("hi"), assistant(id: "a", [text("Hello there.")])]
        var data = Data()
        for line in lines { data.append(line); data.append(UInt8(ascii: "\n")) }
        try data.write(to: url)
        #expect(ClaudeCodeResponse.last(inTranscript: url) == "Hello there.")
    }

    // MARK: Codex responses

    private func codex(_ type: String, _ payload: [String: Any]) -> Data {
        line(["type": type, "payload": payload])
    }

    private func codexAssistant(_ texts: [String]) -> Data {
        codex("response_item", [
            "type": "message",
            "role": "assistant",
            "content": texts.map { ["type": "output_text", "text": $0] },
        ])
    }

    @Test func codexReadsTheLastMessageWithText() {
        let lines = [
            codexAssistant(["Let me look."]),
            codex("response_item", ["type": "function_call", "name": "exec_command", "arguments": "{}"]),
            codexAssistant(["Here it is.", "  ", "And more."]),
            codex("event_msg", ["type": "task_complete", "last_agent_message": NSNull()]),
        ]
        #expect(ClaudeCodeResponse.last(inCodexLines: lines) == "Here it is.\n\nAnd more.")
    }

    @Test func codexReadsEventMessagesWithoutRepeatingTheResponse() {
        let lines = [
            codexAssistant(["Progress."]),
            codexAssistant(["Done."]),
            codex("event_msg", ["type": "agent_message", "message": "Done."]),
            codex("event_msg", ["type": "task_complete", "last_agent_message": "Done."]),
        ]
        #expect(ClaudeCodeResponse.last(inCodexLines: lines) == "Done.")
        #expect(ClaudeCodeResponse.last(inCodexLines: [lines[2]]) == "Done.")
        #expect(ClaudeCodeResponse.last(inCodexLines: [lines[3]]) == "Done.")
    }

    @Test func codexSkipsToolsReasoningAndUserMessages() {
        let skipped = [
            codex("response_item", [
                "type": "message", "role": "user", "content": [["type": "input_text", "text": "User message"]],
            ]),
            codex("response_item", ["type": "function_call_output", "output": "Tool result"]),
            codex("response_item", ["type": "reasoning", "content": [["type": "reasoning_text", "text": "Thinking"]]]),
            codex("event_msg", ["type": "agent_reasoning", "text": "Thinking"]),
            codexAssistant([" \n"]),
            codex("event_msg", ["type": "agent_message", "message": ""]),
            line(["not": "a rollout line"]),
            Data("not json".utf8),
        ]
        #expect(ClaudeCodeResponse.last(inCodexLines: [codexAssistant(["Done."])] + skipped) == "Done.")
        #expect(ClaudeCodeResponse.last(inCodexLines: skipped) == nil)
        #expect(ClaudeCodeResponse.last(inCodexLines: []) == nil)
    }

    @Test func readsACodexRolloutFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = codexAssistant(["Hello from Codex."])
        data.append(UInt8(ascii: "\n"))
        try data.write(to: url)
        #expect(ClaudeCodeResponse.last(inTranscript: url, of: .codex) == "Hello from Codex.")
        #expect(ClaudeCodeResponse.last(inTranscript: url, of: .claude) == nil)
    }

    // MARK: Model

    @Test func modelIsTheLastResponsesOwn() {
        let lines = [
            assistant(id: "a", [text("Before.")], model: "claude-sonnet-5-5"),
            user("/model opus"),
            assistant(id: "b", [toolUse]),
            assistant(id: "c", [text("Subagent.")], sidechain: true, model: "claude-haiku-4-5-20251001"),
            assistant(id: "d", [text("Interrupted")], model: "<synthetic>"),
            user("hi"),
        ]
        #expect(ClaudeCodeResponse.model(inLines: lines) == "claude-opus-5-5")
        #expect(ClaudeCodeResponse.model(inLines: [user("hi")]) == nil)
    }

    // MARK: Spoken text

    @Test func codeBlocksAreNotRead() {
        let markdown = """
        Run this:

        ```bash
        zig build
        ```

        Then test.
        """
        #expect(ClaudeCodeResponse.spoken(fromMarkdown: markdown) == "Run this:\n\nThen test.")
    }

    @Test func formattingIsNotRead() {
        let markdown = """
        ## Summary
        - **Bold** and `code_name` in [the docs](https://example.com).
        > Quoted, see https://example.com/page
        """
        #expect(ClaudeCodeResponse.spoken(fromMarkdown: markdown)
            == "Summary\nBold and code_name in the docs.\nQuoted, see link")
    }

    @Test func tablesReadAsRows() {
        let markdown = """
        | Name | Count |
        |------|------:|
        | a    | 1     |
        """
        #expect(ClaudeCodeResponse.spoken(fromMarkdown: markdown) == "Name, Count\na, 1")
    }
}
