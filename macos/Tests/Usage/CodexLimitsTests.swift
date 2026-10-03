import Foundation
import Testing
@testable import Ghostty

struct CodexLimitsTests {
    private let account: [String: Any] = ["type": "chatgpt", "email": "someone@example.com", "planType": "pro"]

    private func window(_ percent: Double, minutes: Int, reset: Int = 1_790_456_400) -> [String: Any] {
        ["usedPercent": percent, "windowDurationMins": minutes, "resetsAt": reset]
    }

    @Test func readsCodexAccountAndPlanWindows() {
        let limits = CodexLimitsReader.parse(account: account, rateLimits: [
            "rateLimits": ["primary": window(17, minutes: 300), "secondary": window(42, minutes: 10080)],
        ])
        #expect(limits.accountLabel == "someone@example.com")
        #expect(limits.planLabel == "Pro")
        #expect(limits.windows.map(\.label) == ["Current session", "Weekly limit"])
        #expect(limits.windows.map(\.usedPercent) == [17, 42])
        #expect(limits.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_790_456_400))
        #expect(limits.unavailable == nil)
    }

    @Test func multiBucketLimitsDoNotRepeatTheLegacyBucket() {
        let codex: [String: Any] = ["primary": window(17, minutes: 300)]
        let limits = CodexLimitsReader.parse(account: account, rateLimits: [
            "rateLimits": codex,
            "rateLimitsByLimitId": [
                "codex": codex,
                "other": ["limitName": "Other model", "primary": window(25, minutes: 60)],
            ],
        ])
        #expect(limits.windows.map(\.id) == ["codex:primary", "other:primary"])
        #expect(limits.windows.last?.label == "Other model · 1-hour limit")
    }

    @Test func unavailableAccountsDoNotInventUsage() {
        #expect(CodexLimitsReader.parse(account: nil, rateLimits: nil).unavailable == .signedOut)
        #expect(CodexLimitsReader.parse(account: ["type": "apiKey"], rateLimits: nil).unavailable == .noPlanLimits)
        #expect(CodexLimitsReader.parse(account: account, rateLimits: nil, failed: true).unavailable == .failed)
        #expect(CodexLimitsReader.parse(account: account, rateLimits: [:]).windows.isEmpty)
    }

    @Test func missingAndInvalidWindowsAreSkipped() {
        let limits = CodexLimitsReader.parse(account: account, rateLimits: [
            "rateLimits": ["primary": ["usedPercent": true], "secondary": window(140, minutes: 30)],
        ])
        #expect(limits.windows.count == 1)
        #expect(limits.windows.first?.label == "30-minute limit")
        #expect(limits.windows.first?.usedPercent == 100)
    }
}
