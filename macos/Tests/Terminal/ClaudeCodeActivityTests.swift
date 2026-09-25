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
