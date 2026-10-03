import Foundation
import Testing
@testable import Ghostty

@Suite
struct CodexTurnTimingTests {
    private func event(_ payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "event_msg", "payload": payload])
    }

    @Test func usesReportedTimingsWithoutInventingATokenRate() throws {
        let complete = try event([
            "type": "task_complete", "duration_ms": 43_000, "time_to_first_token_ms": 1200,
        ])
        let timing = try #require(CodexTurnTiming.read(lines: [complete]))
        #expect(timing.firstToken == 1.2)
        #expect(timing.duration == 43)
        #expect(timing.label == "ttft 1.2s · turn 43s")
        #expect(timing.help?.contains("tool calls") == true)
        #expect(CodexTurnTiming.read(lines: [complete, try event(["type": "task_started"])])?.label == nil)
        #expect(CodexTurnTiming.read(lines: [complete, try event(["type": "turn_aborted"])])?.label == nil)
    }

    @Test func missingAndInvalidFieldsStayUnknown() throws {
        #expect(CodexTurnTiming.read(lines: [try event(["type": "task_complete"])])?.label == nil)
        let invalid = try event([
            "type": "task_complete", "duration_ms": -1, "time_to_first_token_ms": "unknown",
        ])
        #expect(CodexTurnTiming.read(lines: [invalid])?.label == nil)
        let duration = try event(["type": "task_complete", "duration_ms": 2500])
        #expect(CodexTurnTiming.read(lines: [duration])?.label == "turn 2.5s")
        #expect(CodexTurnTiming.read(lines: [Data("not json".utf8)]) == nil)
    }
}
