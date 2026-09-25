import Foundation
import Testing
@testable import Ghostty

@Suite
struct ClaudeCodeActivityTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    @Test func workingCountsFromWhenTheRequestStarted() {
        var activity = ClaudeCodeActivity()
        activity.update(from: .clean, to: .working, at: at(10), seen: true)
        #expect(activity.workingSince == at(10))
        #expect(activity.stoppedSince == nil)
    }

    @Test func aQuestionInTheMiddleDoesNotRestartTheRequest() {
        var activity = ClaudeCodeActivity()
        activity.update(from: .clean, to: .working, at: at(10), seen: true)
        activity.update(from: .working, to: .waiting, at: at(20), seen: true)
        #expect(activity.stoppedSince == at(20))
        activity.update(from: .waiting, to: .working, at: at(30), seen: true)
        #expect(activity.workingSince == at(10))
        #expect(activity.stoppedSince == nil)
    }

    @Test func finishingUnseenIsMarkedUntilSeen() {
        var activity = ClaudeCodeActivity()
        activity.update(from: .clean, to: .working, at: at(10), seen: true)
        activity.update(from: .working, to: .pending, at: at(70), seen: false)
        #expect(activity.finishedUnseen)
        #expect(activity.workingSince == nil)
        #expect(activity.stoppedSince == at(70))

        // Committing doesn't change when it finished.
        activity.update(from: .pending, to: .clean, at: at(90), seen: false)
        #expect(activity.stoppedSince == at(70))
        #expect(activity.finishedUnseen)

        activity.markSeen()
        #expect(!activity.finishedUnseen)
    }

    @Test func finishingWhileLookedAtIsNotMarked() {
        var activity = ClaudeCodeActivity()
        activity.update(from: .clean, to: .working, at: at(10), seen: true)
        activity.update(from: .working, to: .clean, at: at(20), seen: true)
        #expect(!activity.finishedUnseen)
    }

    @Test func aSessionFirstSeenStoppedHasNoTime() {
        var activity = ClaudeCodeActivity()
        activity.update(from: nil, to: .clean, at: at(10), seen: false)
        #expect(activity == ClaudeCodeActivity())

        activity.update(from: nil, to: .working, at: at(10), seen: false)
        #expect(activity.workingSince == at(10))
    }

    @Test func noSessionForgetsEverything() {
        var activity = ClaudeCodeActivity()
        activity.update(from: .clean, to: .working, at: at(10), seen: true)
        activity.update(from: .working, to: .clean, at: at(20), seen: false)
        activity.update(from: .clean, to: nil, at: at(30), seen: false)
        #expect(activity == ClaudeCodeActivity())
    }

    @Test func markingUnreadWaitsForTheSessionToStop() {
        var activity = ClaudeCodeActivity()
        activity.update(from: .clean, to: .working, at: at(10), seen: true)
        activity.markUnseen()
        #expect(!activity.finishedUnseen)

        activity.update(from: .working, to: .clean, at: at(20), seen: true)
        activity.markUnseen()
        #expect(activity.finishedUnseen)
    }

    @Test func summarySaysWhatAndSinceWhen() {
        var activity = ClaudeCodeActivity()
        activity.update(from: .clean, to: .working, at: at(0), seen: true)
        #expect(ClaudeCodeTabState(light: .working).summary(activity, at: at(240)) == "Working, for 4m")

        activity.update(from: .working, to: .pending, at: at(300), seen: true)
        let pending = ClaudeCodeTabState(light: .pending, pendingFiles: 3, editedFiles: 3)
        #expect(pending.summary(activity, at: at(600)) == "3 files not committed, since 5m ago")
        #expect(pending.summary(activity, at: at(310)) == "3 files not committed, just now")
        #expect(ClaudeCodeTabState(light: .clean).summary(ClaudeCodeActivity(), at: at(0)) == "Done")
    }

    @Test func sessionUsageIsTalliedByModel() {
        let rates = UsageRateTable(liteLLM: [
            "claude-opus-5-5": ["input_cost_per_token": 0.001, "output_cost_per_token": 0.002],
        ])
        func record(_ model: String, input: Int, output: Int, key: String?, reported: Double? = nil) -> UsageRecord {
            UsageRecord(
                provider: .claude, timestampMs: 0, model: model, sessionId: "s",
                totals: UsageTokenTotals(uncachedInput: input, output: output),
                reportedCostUsd: reported, dedupeKey: key)
        }
        let usage = ClaudeCodeSessionCost.usage(of: [
            record("claude-opus-5-5", input: 100, output: 10, key: "a"),
            // The same message again, as Claude Code writes one line per content block.
            record("claude-opus-5-5", input: 100, output: 10, key: "a"),
            record("claude-opus-5-5", input: 200, output: 20, key: "b"),
            record("claude-haiku-4-5", input: 1000, output: 0, key: "c"),
            record("claude-sonnet-5", input: 10, output: 0, key: "d", reported: 0.05),
        ], rates: rates)

        #expect(usage.map(\.model) == ["claude-opus-5-5", "claude-sonnet-5", "claude-haiku-4-5"])
        #expect(usage[0].tokens == 330)
        #expect(abs((usage[0].cost ?? 0) - 0.36) < 1e-9)
        #expect(usage[1].cost == 0.05)
        // A model without a rate has no cost, rather than a cost of nothing.
        #expect(usage[2].tokens == 1000)
        #expect(usage[2].cost == nil)
    }

    @Test func modelNamesAreShortened() {
        #expect(TabSidebarHoverCardView.shortName("claude-opus-5-5") == "opus-5-5")
        #expect(TabSidebarHoverCardView.shortName("claude-haiku-4-5-20251001") == "haiku-4-5")
        #expect(TabSidebarHoverCardView.shortName("gpt-5") == "gpt-5")
    }

    @Test func elapsed() {
        #expect(ClaudeCodeActivity.elapsed(since: start, at: at(12)) == "12s")
        #expect(ClaudeCodeActivity.elapsed(since: start, at: at(4 * 60 + 5)) == "4m")
        #expect(ClaudeCodeActivity.elapsed(since: start, at: at(3600)) == "1h")
        #expect(ClaudeCodeActivity.elapsed(since: start, at: at(3600 + 5 * 60)) == "1h 5m")
    }

    @Test func ago() {
        #expect(ClaudeCodeActivity.ago(start, at: at(30)) == "now")
        #expect(ClaudeCodeActivity.ago(start, at: at(12 * 60)) == "12m")
        #expect(ClaudeCodeActivity.ago(start, at: at(3 * 3600)) == "3h")
        #expect(ClaudeCodeActivity.ago(start, at: at(2 * 86400)) == "2d")
    }
}
