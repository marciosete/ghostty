import Foundation
import Testing
@testable import Ghostty

// The payloads follow what `claude auth status --json` and the CLI's `get_usage` control
// request answer, with invented numbers.

private func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

struct ClaudeAccountTests {
    @Test func readsTheSignedInAccount() throws {
        let account = try #require(ClaudeLimitsReader.parseAccount(json([
            "loggedIn": true,
            "authMethod": "claude.ai",
            "apiProvider": "firstParty",
            "email": "someone@example.com",
            "orgName": "Example Org",
            "subscriptionType": "max",
        ])))

        #expect(account.email == "someone@example.com")
        #expect(account.organizationName == "Example Org")
        #expect(account.planLabel == "Max")
        #expect(account.label == "someone@example.com")
        #expect(account.isFirstParty)
    }

    @Test func fallsBackToTheOrganization() throws {
        let account = try #require(ClaudeLimitsReader.parseAccount(json([
            "loggedIn": true, "orgName": "Example Org", "subscriptionType": "pro",
        ])))
        #expect(account.label == "Example Org")
        #expect(account.planLabel == "Pro")
    }

    @Test func signedOutIsNoAccount() {
        #expect(ClaudeLimitsReader.parseAccount(json(["loggedIn": false])) == nil)
        #expect(ClaudeLimitsReader.parseAccount(Data("not json".utf8)) == nil)
    }

    @Test func marksNonAnthropicLogins() throws {
        let account = try #require(ClaudeLimitsReader.parseAccount(json([
            "loggedIn": true, "apiProvider": "bedrock",
        ])))
        #expect(!account.isFirstParty)
    }
}

struct ClaudeLimitsParsingTests {
    private func payload(_ rateLimits: [String: Any], available: Bool = true) -> [String: Any] {
        ["subscription_type": "max", "rate_limits_available": available, "rate_limits": rateLimits]
    }

    private func limitsEntry(
        kind: String,
        percent: Double,
        resetsAt: String? = "2026-09-26T21:00:00.000Z",
        model: String? = nil,
        severity: String = "normal",
        isActive: Bool = false
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "kind": kind,
            "group": kind == "session" ? "session" : "weekly",
            "percent": percent,
            "severity": severity,
            "is_active": isActive,
            "resets_at": resetsAt ?? NSNull(),
        ]
        if let model {
            entry["scope"] = ["model": ["display_name": model, "id": NSNull()], "surface": NSNull()]
        }
        return entry
    }

    @Test func readsSessionWeeklyAndModelWindows() throws {
        let windows = ClaudeLimitsReader.parseWindows(payload([
            "limits": [
                limitsEntry(kind: "session", percent: 3),
                limitsEntry(kind: "weekly_all", percent: 57),
                limitsEntry(kind: "weekly_scoped", percent: 67, model: "Fable", isActive: true),
            ],
        ]))

        #expect(windows.map(\.label) == ["Current session", "All models", "Fable"])
        #expect(windows.map(\.kind) == [.session, .weeklyAll, .weeklyScoped])
        #expect(windows.map(\.usedPercent) == [3, 57, 67])
        #expect(windows.last?.isActive == true)
        #expect(windows.first?.resetsAt == Date(timeIntervalSince1970: 1_790_456_400))
    }

    @Test func keepsSeverityForAWindowNearItsLimit() throws {
        let windows = ClaudeLimitsReader.parseWindows(payload([
            "limits": [limitsEntry(kind: "weekly_all", percent: 96, severity: "critical")],
        ]))
        #expect(windows.first?.severity == .critical)
    }

    @Test func skipsWindowsItCannotName() {
        let windows = ClaudeLimitsReader.parseWindows(payload([
            "limits": [
                limitsEntry(kind: "weekly_scoped", percent: 10),
                limitsEntry(kind: "something_new", percent: 10),
                ["kind": "session"],
            ],
        ]))
        #expect(windows.isEmpty)
    }

    @Test func clampsOutOfRangePercentages() throws {
        let windows = ClaudeLimitsReader.parseWindows(payload([
            "limits": [limitsEntry(kind: "session", percent: 140)],
        ]))
        #expect(windows.first?.usedPercent == 100)
    }

    @Test func readsWindowsFromAnOlderCLIWithoutTheLimitsArray() throws {
        let windows = ClaudeLimitsReader.parseWindows(payload([
            "five_hour": ["utilization": 3, "resets_at": "2026-09-23T02:00:00.000Z"],
            "seven_day": ["utilization": 57, "resets_at": "2026-09-26T21:00:00.000Z"],
            "model_scoped": [["display_name": "Fable", "utilization": 67, "resets_at": "2026-09-26T21:00:00.000Z"]],
        ]))

        #expect(windows.map(\.label) == ["Current session", "All models", "Fable"])
        #expect(windows.map(\.usedPercent) == [3, 57, 67])
    }

    @Test func reportsNoWindowsWhenTheAccountHasNone() {
        #expect(ClaudeLimitsReader.parseWindows(payload([:], available: false)).isEmpty)
        #expect(ClaudeLimitsReader.parseWindows(["rate_limits_available": true]).isEmpty)
    }

    @Test func findsTheUsagePayloadInTheStream() throws {
        let stream = [
            #"{"type":"system","subtype":"init"}"#,
            "not json",
            String(decoding: json([
                "type": "control_response",
                "response": [
                    "subtype": "success",
                    "request_id": "ghostty-usage",
                    "response": payload(["limits": [limitsEntry(kind: "session", percent: 12)]]),
                ],
            ]), as: UTF8.self),
        ].joined(separator: "\n")

        let payload = try #require(ClaudeLimitsReader.usageResponse(in: Data(stream.utf8)))
        #expect(ClaudeLimitsReader.parseWindows(payload).first?.usedPercent == 12)
    }

    @Test func ignoresAStreamWithoutAUsageResponse() {
        let stream = #"{"type":"control_response","response":{"subtype":"error","error":"nope"}}"#
        #expect(ClaudeLimitsReader.usageResponse(in: Data(stream.utf8)) == nil)
    }
}

struct UsageResetFormatTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func countsDownWithinADay() {
        #expect(UsageFormat.reset(now.addingTimeInterval(2 * 3600 + 18 * 60), now: now) == "Resets in 2 hr 18 min")
        #expect(UsageFormat.reset(now.addingTimeInterval(42 * 60), now: now) == "Resets in 42 min")
        #expect(UsageFormat.reset(now.addingTimeInterval(20), now: now) == "Resets in 1 min")
        #expect(UsageFormat.reset(now.addingTimeInterval(-60), now: now) == "Resetting now")
    }

    @Test func namesTheDayBeyondADay() {
        let text = UsageFormat.reset(now.addingTimeInterval(3 * 24 * 3600), now: now)
        #expect(text.hasPrefix("Resets "))
        #expect(!text.contains("hr"))
    }
}
