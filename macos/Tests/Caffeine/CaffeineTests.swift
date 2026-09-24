import Foundation
import Testing
@testable import Ghostty

@Suite
@MainActor
struct CaffeineTests {
    @Test func theSudoersRuleAllowsOnlyDisablingSleep() {
        #expect(Caffeine.sudoersRule(for: "marciosete")
            == "marciosete ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1")
        #expect(Caffeine.sudoersRule(for: "first.last-2") != nil)

        // Anything that could change the rule's meaning is refused.
        #expect(Caffeine.sudoersRule(for: "") == nil)
        #expect(Caffeine.sudoersRule(for: "me ALL=(ALL) ALL") == nil)
        #expect(Caffeine.sudoersRule(for: "me'; rm") == nil)
        #expect(Caffeine.sudoersRule(for: "mé") == nil)
    }

    private func run(hours: Double?, minimumBattery: Int?) -> Caffeine.Run {
        let start = Date(timeIntervalSince1970: 0)
        return Caffeine.Run(
            startedAt: start,
            until: hours.map { start.addingTimeInterval($0 * 3600) },
            minimumBattery: minimumBattery,
            coversClosedLid: true)
    }

    @Test func stopsAtItsTimeLimit() {
        let run = run(hours: 2, minimumBattery: nil)
        #expect(Caffeine.stopReason(for: run, now: Date(timeIntervalSince1970: 7199), battery: nil) == nil)
        #expect(Caffeine.stopReason(for: run, now: Date(timeIntervalSince1970: 7200), battery: nil) == .timeLimit)

        let unlimited = self.run(hours: nil, minimumBattery: nil)
        #expect(Caffeine.stopReason(for: unlimited, now: Date(timeIntervalSince1970: 1e9), battery: (1, true)) == nil)
    }

    @Test func stopsAtLowBatteryOnlyOnBattery() {
        let run = run(hours: nil, minimumBattery: 20)
        let now = Date(timeIntervalSince1970: 60)
        #expect(Caffeine.stopReason(for: run, now: now, battery: (21, true)) == nil)
        #expect(Caffeine.stopReason(for: run, now: now, battery: (20, true)) == .battery(20))
        #expect(Caffeine.stopReason(for: run, now: now, battery: (5, false)) == nil)
        #expect(Caffeine.stopReason(for: run, now: now, battery: nil) == nil)
    }

    @Test func showsTheTimeLeft() {
        #expect(CaffeineFormat.remaining(3 * 3600 + 11 * 60 + 5) == "3h 12m")
        #expect(CaffeineFormat.remaining(12 * 60) == "12m")
        #expect(CaffeineFormat.remaining(-5) == "0m")
    }
}
