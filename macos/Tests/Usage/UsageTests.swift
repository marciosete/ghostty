import Foundation
import Testing
@testable import Ghostty

// Most cases are ported from T3 Code's usage tests (apps/server/src/usage/*.test.ts).

private func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func ms(_ iso: String) -> Int {
    UsageTimestamp.milliseconds(iso)!
}

// MARK: - Timestamps

struct UsageTimestampTests {
    @Test func parsesUTCWithFraction() {
        let date = ISO8601DateFormatter().date(from: "2026-08-07T04:05:13Z")!
        #expect(UsageTimestamp.milliseconds("2026-08-07T04:05:13.944Z") == Int(date.timeIntervalSince1970) * 1000 + 944)
    }

    @Test func parsesOffsets() {
        #expect(ms("2026-08-07T14:05:13+10:00") == ms("2026-08-07T04:05:13Z"))
        #expect(ms("2026-08-06T21:05:13.5-0700") == ms("2026-08-07T04:05:13.500Z"))
    }

    @Test func rejectsGarbage() {
        #expect(UsageTimestamp.milliseconds("not a date") == nil)
        #expect(UsageTimestamp.milliseconds(12) == nil)
    }
}

// MARK: - Claude Code

struct UsageClaudeParserTests {
    private func line(messageId: String, contentType: String) -> Data {
        json([
            "type": "assistant",
            "timestamp": "2026-08-07T04:05:13.944Z",
            "sessionId": "5a128faa",
            "message": [
                "id": messageId,
                "role": "assistant",
                "model": "claude-fable-5",
                "content": [["type": contentType]],
                "usage": [
                    "input_tokens": 2,
                    "cache_creation_input_tokens": 66818,
                    "cache_read_input_tokens": 1000,
                    "output_tokens": 286,
                ],
            ],
        ])
    }

    @Test func extractsTotalsAndDedupeKey() throws {
        let record = try #require(UsageTranscripts.parseClaudeLine(line(messageId: "msg_1", contentType: "text")))
        #expect(record.provider == .claude)
        #expect(record.model == "claude-fable-5")
        #expect(record.sessionId == "5a128faa")
        #expect(record.totals == UsageTokenTotals(uncachedInput: 2, cachedInput: 1000, cacheCreation: 66818, output: 286))
        #expect(record.dedupeKey == "msg_1:")
    }

    @Test func contentBlocksOfOneMessageShareTheirKey() {
        let text = UsageTranscripts.parseClaudeLine(line(messageId: "msg_2", contentType: "text"))
        let toolUse = UsageTranscripts.parseClaudeLine(line(messageId: "msg_2", contentType: "tool_use"))
        #expect(text?.dedupeKey == toolUse?.dedupeKey)
    }

    @Test func ignoresOtherRecords() {
        #expect(UsageTranscripts.parseClaudeLine(json(["type": "user", "message": [:] as [String: Any]])) == nil)
        #expect(UsageTranscripts.parseClaudeLine(Data("not json".utf8)) == nil)
    }
}

// MARK: - Codex

struct UsageCodexParserTests {
    private let sessionMeta = json([
        "type": "session_meta",
        "timestamp": "2026-08-01T05:17:41.289Z",
        "payload": ["type": "session_meta", "id": "019fbbc1"],
    ])

    private let turnContext = json([
        "type": "turn_context",
        "timestamp": "2026-08-01T05:17:42.694Z",
        "payload": ["type": "turn_context", "model": "gpt-5.6-sol"],
    ])

    private func tokenCount(_ input: Int, _ cached: Int, _ output: Int, _ reasoning: Int, at timestamp: String = "2026-08-01T05:17:49.919Z") -> Data {
        json([
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": cached,
                        "cache_write_input_tokens": 0,
                        "output_tokens": output,
                        "reasoning_output_tokens": reasoning,
                    ],
                ],
            ],
        ])
    }

    private func meta(id: String, at timestamp: String, forkedFrom: String? = nil, spawnedBy: String? = nil) -> Data {
        var payload: [String: Any] = ["type": "session_meta", "id": id]
        if let forkedFrom { payload["forked_from_id"] = forkedFrom }
        if let spawnedBy {
            payload["source"] = ["subagent": ["thread_spawn": ["parent_thread_id": spawnedBy]]]
        }
        return json(["type": "session_meta", "timestamp": timestamp, "payload": payload])
    }

    private func turnContext(at timestamp: String) -> Data {
        json(["type": "turn_context", "timestamp": timestamp, "payload": ["type": "turn_context", "model": "gpt-5.6-sol"]])
    }

    @Test func attributesUsageToTheTurnContextModel() throws {
        var state = UsageTranscripts.CodexScanState()
        _ = UsageTranscripts.parseCodexLine(sessionMeta, state: &state)
        _ = UsageTranscripts.parseCodexLine(turnContext, state: &state)
        let record = try #require(UsageTranscripts.parseCodexLine(tokenCount(19239, 11008, 299, 116), state: &state))

        #expect(record.model == "gpt-5.6-sol")
        #expect(record.sessionId == "019fbbc1")
        // Codex reports input_tokens including the cached part.
        #expect(record.totals.uncachedInput == 19239 - 11008)
        #expect(record.totals.cachedInput == 11008)
        #expect(record.totals.reasoning == 116)
        #expect(record.totals.total == 19239 + 299)
    }

    @Test func skipsARepeatedTokenCount() {
        var state = UsageTranscripts.CodexScanState()
        _ = UsageTranscripts.parseCodexLine(turnContext, state: &state)
        #expect(UsageTranscripts.parseCodexLine(tokenCount(100, 0, 10, 0), state: &state) != nil)
        #expect(UsageTranscripts.parseCodexLine(tokenCount(100, 0, 10, 0), state: &state) == nil)
    }

    @Test func aPreModelEventDoesNotPoisonTheSignature() {
        var state = UsageTranscripts.CodexScanState()
        #expect(UsageTranscripts.parseCodexLine(tokenCount(100, 0, 10, 0), state: &state) == nil)
        _ = UsageTranscripts.parseCodexLine(turnContext, state: &state)
        #expect(UsageTranscripts.parseCodexLine(tokenCount(100, 0, 10, 0), state: &state) != nil)
    }

    @Test func keepsTheChildSessionOverCopiedAncestorMetas() {
        var state = UsageTranscripts.CodexScanState()
        _ = UsageTranscripts.parseCodexLine(meta(id: "child", at: "2026-08-01T05:00:00.000Z"), state: &state)
        _ = UsageTranscripts.parseCodexLine(meta(id: "parent", at: "2026-08-01T05:00:00.000Z"), state: &state)
        _ = UsageTranscripts.parseCodexLine(turnContext, state: &state)
        #expect(UsageTranscripts.parseCodexLine(tokenCount(100, 0, 10, 0), state: &state)?.sessionId == "child")
    }

    @Test func dropsTheCopiedBurstOfAFork() {
        var state = UsageTranscripts.CodexScanState()
        let fork = "2026-08-01T05:00:00.000Z"
        _ = UsageTranscripts.parseCodexLine(meta(id: "child", at: fork, forkedFrom: "parent"), state: &state)
        _ = UsageTranscripts.parseCodexLine(meta(id: "parent", at: fork), state: &state)
        _ = UsageTranscripts.parseCodexLine(turnContext(at: fork), state: &state)

        #expect(UsageTranscripts.parseCodexLine(tokenCount(100, 0, 10, 0, at: "2026-08-01T05:00:00.001Z"), state: &state) == nil)
        #expect(UsageTranscripts.parseCodexLine(tokenCount(200, 0, 20, 0, at: "2026-08-01T05:00:00.002Z"), state: &state) == nil)

        let real = UsageTranscripts.parseCodexLine(tokenCount(300, 0, 30, 0, at: "2026-08-01T05:00:06.000Z"), state: &state)
        #expect(real?.totals.output == 30)

        // Suppression never restarts.
        #expect(UsageTranscripts.parseCodexLine(tokenCount(400, 0, 40, 0, at: "2026-08-01T05:00:06.100Z"), state: &state) != nil)
    }

    @Test func recognizesSubagentSpawns() {
        var state = UsageTranscripts.CodexScanState()
        let spawn = "2026-08-01T05:00:00.000Z"
        _ = UsageTranscripts.parseCodexLine(meta(id: "child", at: spawn, spawnedBy: "parent"), state: &state)
        _ = UsageTranscripts.parseCodexLine(turnContext(at: spawn), state: &state)
        #expect(UsageTranscripts.parseCodexLine(tokenCount(100, 0, 10, 0, at: "2026-08-01T05:00:00.001Z"), state: &state) == nil)
    }

    @Test func doesNotSuppressARolloutThatIsNotAFork() {
        var state = UsageTranscripts.CodexScanState()
        _ = UsageTranscripts.parseCodexLine(meta(id: "root", at: "2026-08-01T05:00:00.000Z"), state: &state)
        _ = UsageTranscripts.parseCodexLine(turnContext(at: "2026-08-01T05:00:00.100Z"), state: &state)
        #expect(UsageTranscripts.parseCodexLine(tokenCount(100, 0, 10, 0, at: "2026-08-01T05:00:00.200Z"), state: &state) != nil)
    }
}

// MARK: - Grok Build

struct UsageGrokParserTests {
    private func turnCompleted(_ usage: [String: Any], promptId: String? = "prompt-1") -> Data {
        var update: [String: Any] = ["sessionUpdate": "turn_completed", "usage": usage]
        if let promptId { update["prompt_id"] = promptId }
        return json([
            "timestamp": 1_786_000_000,
            "params": [
                "sessionId": "grok-session",
                "update": update,
                "_meta": ["agentTimestampMs": 1_786_000_000_123],
            ],
        ])
    }

    @Test func splitsTheTurnCostAcrossModelsByTokens() {
        let records = UsageTranscripts.parseGrokLine(turnCompleted([
            "inputTokens": 300,
            "outputTokens": 0,
            "costUsdTicks": 30_000_000_000,
            "modelUsage": [
                "grok-a": ["inputTokens": 100, "outputTokens": 0],
                "grok-b": ["inputTokens": 200, "outputTokens": 0],
            ],
        ]))

        #expect(records.map(\.model) == ["grok-a", "grok-b"])
        #expect(records.map(\.reportedCostUsd) == [1, 2])
        #expect(records.first?.timestampMs == 1_786_000_000_123)
        #expect(records.first?.dedupeKey == "grok-session:prompt-1:grok-a")
    }

    @Test func fallsBackToAGenericModel() {
        let records = UsageTranscripts.parseGrokLine(turnCompleted(
            ["inputTokens": 50, "cachedReadTokens": 20, "outputTokens": 5],
            promptId: nil))
        #expect(records.count == 1)
        #expect(records.first?.model == "grok")
        #expect(records.first?.totals == UsageTokenTotals(uncachedInput: 30, cachedInput: 20, output: 5))
        #expect(records.first?.dedupeKey == nil)
    }
}

// MARK: - Pricing

struct UsagePricingTests {
    private func rate(_ input: Double, _ cacheRead: Double? = nil) -> [String: Any] {
        var entry: [String: Any] = ["input_cost_per_token": input, "output_cost_per_token": input * 5]
        if let cacheRead { entry["cache_read_input_token_cost"] = cacheRead }
        return entry
    }

    @Test func keepsTheCanonicalRateSeparateFromQualifiedEntries() {
        let table = UsageRateTable(liteLLM: [
            "claude-fable-5": rate(1e-5, 1e-6),
            "deepinfra/anthropic/claude-fable-5": rate(1e-5),
        ])
        #expect(table.rate(for: "claude-fable-5")?.cacheRead == 1e-6)
        #expect(table.rate(for: "deepinfra/anthropic/claude-fable-5")?.cacheRead == 1e-5)
        #expect(table.rate(for: "other/claude-fable-5") == nil)
    }

    @Test func pricesAContextTierVariantAtTheBaseRate() {
        let table = UsageRateTable(liteLLM: ["claude-fable-5-1": rate(1e-5, 2.5e-7)])
        #expect(table.rate(for: "claude-fable-5-1[1m]") == table.rate(for: "claude-fable-5-1"))
        #expect(table.rate(for: "claude-fable-5-1[1m]") != nil)
    }

    @Test func aliasesABareNameOnlyWhenUnambiguous() {
        let same = UsageRateTable(liteLLM: ["a/example": rate(1), "b/example": rate(1)])
        #expect(same.rate(for: "example") == same.rate(for: "a/example"))

        let different = UsageRateTable(liteLLM: ["a/example": rate(1), "b/example": rate(3)])
        #expect(different.rate(for: "b/example")?.input == 3)
        #expect(different.rate(for: "example") == nil)
    }

    @Test func neverPricesSyntheticOrBareFamilyNames() {
        let table = UsageRateTable(liteLLM: ["<synthetic>": rate(1), "opus": rate(1)])
        #expect(table.rate(for: "<synthetic>") == nil)
        #expect(table.rate(for: "opus") == nil)
    }

    @Test func pricesCacheReadsAsInputWhenTheTableOmitsThem() {
        let rate = UsageRateTable(liteLLM: ["model": rate(2)]).rate(for: "model")
        #expect(rate?.cacheRead == 2)
        #expect(rate?.cacheCreation == 2)
    }
}

// MARK: - Aggregation

struct UsageAggregationTests {
    private let rates = UsageRateTable(liteLLM: [
        "claude-fable-5": [
            "input_cost_per_token": 1e-5,
            "output_cost_per_token": 5e-5,
            "cache_read_input_token_cost": 1e-6,
            "cache_creation_input_token_cost": 1.25e-5,
        ],
    ])

    private func record(
        at timestamp: String = "2026-08-07T04:05:13.944Z",
        model: String = "claude-fable-5",
        cost: Double? = nil,
        key: String? = nil
    ) -> UsageRecord {
        UsageRecord(
            provider: .claude,
            timestampMs: ms(timestamp),
            model: model,
            sessionId: "session-a",
            totals: UsageTokenTotals(uncachedInput: 100, cachedInput: 1000, cacheCreation: 10, output: 50),
            reportedCostUsd: cost,
            dedupeKey: key)
    }

    private func window(_ timeZone: String = "UTC", hourly: Bool = false) -> UsageWindow {
        UsageWindow(
            days: hourly ? 1 : 31,
            sinceDay: "2026-08-01",
            untilDay: "2026-08-31",
            timeZone: TimeZone(identifier: timeZone)!,
            hourly: hourly ? .init(sinceMs: ms("2026-08-06T04:37:00Z"), untilMs: ms("2026-08-07T04:37:00Z")) : nil)
    }

    private func aggregate(_ records: [UsageRecord], _ window: UsageWindow) -> (UsageAggregator, [UsageBucket]) {
        let aggregator = UsageAggregator(window: window, rates: rates)
        records.forEach { aggregator.add($0) }
        return (aggregator, aggregator.finish())
    }

    @Test func keepsOnlyTheFirstRecordOfAKey() {
        let (aggregator, buckets) = aggregate([record(key: "a"), record(key: "a"), record()], window())
        #expect(aggregator.duplicatesDropped == 1)
        #expect(buckets.first?.records == 2)
    }

    @Test func bucketsByTheDayOfTheTimeZone() {
        #expect(aggregate([record()], window("UTC")).1.first?.day == "2026-08-07")
        #expect(aggregate([record()], window("America/Los_Angeles")).1.first?.day == "2026-08-06")
    }

    @Test func anchorsHourlyBucketsToTheWindowStart() {
        let (_, buckets) = aggregate(
            [record(at: "2026-08-07T02:40:13.944Z"), record(at: "2026-08-07T03:40:13.944Z")],
            window("America/Los_Angeles", hourly: true))
        #expect(buckets.map(\.day) == ["2026-08-06", "2026-08-06"])
        #expect(buckets.map(\.hourStartMs) == [ms("2026-08-07T02:37:00Z"), ms("2026-08-07T03:37:00Z")])
    }

    @Test func includesTheStartAndExcludesTheEndOfAnHourlyWindow() {
        let (aggregator, buckets) = aggregate([
            record(at: "2026-08-06T04:36:59.999Z"),
            record(at: "2026-08-06T04:37:00.000Z"),
            record(at: "2026-08-07T04:36:59.999Z"),
            record(at: "2026-08-07T04:37:00.000Z"),
        ], window(hourly: true))
        #expect(aggregator.outOfWindow == 2)
        #expect(buckets.map(\.hourStartMs) == [ms("2026-08-06T04:37:00Z"), ms("2026-08-07T03:37:00Z")])
    }

    @Test func pricesAgainstTheRateTable() {
        let bucket = aggregate([record()], window()).1.first
        let expected = 100 * 1e-5 + 1000 * 1e-6 + 10 * 1.25e-5 + 50 * 5e-5
        #expect(abs((bucket?.costUsd ?? 0) - expected) < 1e-12)
        #expect(abs((bucket?.cacheSavingsUsd ?? 0) - 1000 * (1e-5 - 1e-6)) < 1e-12)
    }

    @Test func countsTokensButNotCostOfAnUnpricedModel() {
        let bucket = aggregate([record(model: "mystery")], window()).1.first
        #expect(bucket?.costUsd == 0)
        #expect(bucket?.unpricedRecords == 1)
        #expect(bucket?.totals.total == 1160)
    }

    @Test func prefersAReportedCost() {
        #expect(aggregate([record(cost: 0.42)], window()).1.first?.costUsd == 0.42)
    }

    @Test func dropsRecordsOutsideTheWindow() {
        let (aggregator, buckets) = aggregate([record(at: "2026-09-02T00:00:00Z")], window())
        #expect(buckets.isEmpty)
        #expect(aggregator.outOfWindow == 1)
    }
}

// MARK: - Windows and Formatting

struct UsageWindowTests {
    @Test func coversWholeCalendarDays() {
        let timeZone = TimeZone(identifier: "Australia/Sydney")!
        // 10:02 on Sep 22 in Sydney.
        let now = Date(timeIntervalSince1970: Double(ms("2026-09-22T00:02:04Z")) / 1000)
        let window = UsageWindow.last(days: 30, now: now, timeZone: timeZone)
        #expect(window.sinceDay == "2026-08-24")
        #expect(window.untilDay == "2026-09-22")
        #expect(window.allDays.count == 30)
        #expect(UsageFormat.window(window) == "Aug 24 to Sep 22")
    }

    @Test func pastDayIsHourly() {
        let now = Date(timeIntervalSince1970: Double(ms("2026-09-22T00:02:34Z")) / 1000)
        let window = UsageWindow.last(days: 1, now: now, timeZone: TimeZone(identifier: "UTC")!)
        #expect(window.hourly?.untilMs == ms("2026-09-22T00:02:00Z"))
        #expect(window.allHourStarts.count == 24)
    }

    @Test func dayIndexRoundTrips() {
        for day in ["1970-01-01", "2000-02-29", "2026-12-31", "2027-03-01"] {
            #expect(UsageDay.string(fromIndex: UsageDay.index(of: day)!) == day)
        }
    }

    @Test func formatsTokensToThreeFigures() {
        #expect(UsageFormat.tokens(13_800_000_000) == "13.8B")
        #expect(UsageFormat.tokens(5_380_000) == "5.38M")
        #expect(UsageFormat.tokens(209_000) == "209K")
        #expect(UsageFormat.tokens(2_000_000) == "2M")
        #expect(UsageFormat.tokens(1_500) == "1.50K")
        #expect(UsageFormat.tokens(0) == "0")
    }

    @Test func formatsMoney() {
        #expect(UsageFormat.usd(10887.914) == "$10,887.91")
        #expect(UsageFormat.percent(0.349) == "34.9%")
    }

    @Test func roundsTheScaleUpToANiceStep() {
        let scale = UsageFormat.niceScale(peak: 1130)
        #expect(scale.max == 1500)
        #expect(scale.ticks == [0, 500, 1000, 1500])
    }
}

// MARK: - Reading Files

struct UsageTranscriptReaderTests {
    private func claudeLine(_ id: String, output: Int = 10) -> String {
        String(decoding: json([
            "type": "assistant",
            "timestamp": "2026-08-07T04:05:13.944Z",
            "sessionId": "s",
            "message": ["id": id, "model": "claude-fable-5", "usage": ["input_tokens": 1, "output_tokens": output]],
        ]), as: UTF8.self)
    }

    private func temporaryFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).jsonl")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
    }

    @Test func resumesWithOnlyTheAppendedLines() throws {
        let url = try temporaryFile(claudeLine("a") + "\n" + "{\"type\":\"user\"}\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try #require(UsageTranscriptReader.read(path: url.path, provider: .claude))
        #expect(first.records.map(\.dedupeKey) == ["a:"])

        try append(claudeLine("b") + "\n", to: url)
        let second = try #require(UsageTranscriptReader.read(path: url.path, provider: .claude, resumingFrom: first.position))
        #expect(second.resumed)
        #expect(second.records.map(\.dedupeKey) == ["b:"])
    }

    @Test func defersAnUnterminatedLastLine() throws {
        let url = try temporaryFile(claudeLine("a") + "\n" + claudeLine("b"))
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try #require(UsageTranscriptReader.read(path: url.path, provider: .claude))
        #expect(first.records.map(\.dedupeKey) == ["a:"])
        #expect(first.tailRecords.map(\.dedupeKey) == ["b:"])

        try append("\n", to: url)
        let second = try #require(UsageTranscriptReader.read(path: url.path, provider: .claude, resumingFrom: first.position))
        #expect(second.records.map(\.dedupeKey) == ["b:"])
        #expect(second.tailRecords.isEmpty)
    }

    @Test func startsOverWhenTheFileWasRewritten() throws {
        let url = try temporaryFile(claudeLine("a") + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try #require(UsageTranscriptReader.read(path: url.path, provider: .claude))

        try (claudeLine("x", output: 99) + "\n" + claudeLine("y") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let second = try #require(UsageTranscriptReader.read(path: url.path, provider: .claude, resumingFrom: first.position))
        #expect(!second.resumed)
        #expect(second.records.map(\.dedupeKey) == ["x:", "y:"])
    }

    @Test func readsALineLongerThanOneChunk() throws {
        let padding = String(repeating: "x", count: 3 << 20)
        let long = String(decoding: json([
            "type": "assistant",
            "timestamp": "2026-08-07T04:05:13.944Z",
            "padding": padding,
            "message": ["id": "long", "model": "m", "usage": ["output_tokens": 7]],
        ]), as: UTF8.self)
        let url = try temporaryFile(claudeLine("a") + "\n" + long + "\n" + claudeLine("b") + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try #require(UsageTranscriptReader.read(path: url.path, provider: .claude))
        #expect(result.records.map(\.dedupeKey) == ["a:", "long:", "b:"])
    }

    @Test func failsForAMissingFile() {
        #expect(UsageTranscriptReader.read(path: "/nonexistent/usage.jsonl", provider: .claude) == nil)
    }

    @Test func cacheRoundTrips() throws {
        let url = try temporaryFile(claudeLine("a") + "\n" + claudeLine("b"))
        defer { try? FileManager.default.removeItem(at: url) }
        let parsed = try #require(UsageTranscriptReader.read(path: url.path, provider: .claude))

        let codexState = UsageTranscripts.CodexScanState(
            model: "gpt", sessionId: "s", lastUsageSignature: nil,
            sawSessionMeta: true, suppressingForkCopies: false, forkCopyAnchorMs: 5)
        var codexPosition = parsed.position
        codexPosition.codexState = codexState

        let cache = [
            "/a.jsonl": UsageCachedTranscript(
                size: 10, mtimeNs: 1_786_000_000_123_456_789, provider: .claude,
                records: parsed.records, tailRecords: parsed.tailRecords, position: parsed.position),
            "/b.jsonl": UsageCachedTranscript(
                size: 20, mtimeNs: 1, provider: .codex,
                records: [], tailRecords: [], position: codexPosition),
        ]
        let data = try #require(UsageScanCache.encode(cache))
        #expect(UsageScanCache.decode(data) == cache)
    }
}
