import Foundation
import Testing
@testable import Ghostty

struct CodexContextCaptureTests {
    @Test func preservesOriginalContextAndLabelsTheSnapshot() throws {
        let id = UUID()
        let lines = [
            #"{"type":"session_meta","payload":{"base_instructions":{"text":"Original instructions"},"future_field":42}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-test","developer_instructions":"Local context"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix this"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"world_state","payload":{"unknown":{"retained":true}}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","output":"result"}}"#,
            #"{"type":"event_msg","payload":{"type":"thread_settings_applied","model":"new-model"}}"#,
        ]
        let rollout = Data((lines.joined(separator: "\n") + "\n").utf8)
        let session = CodexSession(id: id, cwd: "/project/worktree")
        let files = CodexContextCapture.files(rollout: rollout, session: session, model: "gpt-test")

        #expect(files["rollout.jsonl"] == rollout)
        let context = try #require(files["context.jsonl"])
        #expect(String(decoding: context, as: UTF8.self) ==
            [lines[0], lines[1], lines[2], lines[4], lines[5], lines[6]].joined(separator: "\n") + "\n")
        let readme = String(decoding: try #require(files["00-README.md"]), as: UTF8.self)
        #expect(readme.contains("not an exact API request"))
        #expect(readme.contains("additional instructions and tool"))
        #expect(files["request.json"] == nil)
        #expect(files["request.http"] == nil)

        let metadataData = try #require(files["session.json"])
        let metadata = try #require(JSONSerialization.jsonObject(with: metadataData) as? [String: Any])
        #expect(metadata["session_id"] as? String == id.uuidString.lowercased())
        #expect(metadata["cwd"] as? String == session.cwd)
        #expect(metadata["model"] as? String == "gpt-test")
        #expect(metadata["context_records"] as? Int == 6)
    }

    @Test func keepsAnIncompleteTailOnlyInTheOriginalSnapshot() throws {
        let rollout = Data("{\"type\":\"session_meta\",\"payload\":{}}\n{\"type\":\"response_item\"".utf8)
        let files = CodexContextCapture.files(
            rollout: rollout, session: CodexSession(id: UUID(), cwd: "/project"), model: nil)
        #expect(files["rollout.jsonl"] == rollout)
        #expect(files["context.jsonl"] == Data("{\"type\":\"session_meta\",\"payload\":{}}\n".utf8))
        let metadataData = try #require(files["session.json"])
        let metadata = try #require(JSONSerialization.jsonObject(with: metadataData) as? [String: Any])
        #expect(metadata["model"] is NSNull)
    }
}
