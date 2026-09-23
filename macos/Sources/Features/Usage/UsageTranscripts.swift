import Foundation

// The usage panel is a port of the usage page of T3 Code
// (https://github.com/pingdotgg/t3code, MIT License, Copyright (c) 2026 T3 Tools Inc.).
// The parsing, de-duplication, pricing and aggregation rules follow
// apps/server/src/usage in that repository.

/// A coding agent whose on-disk session transcripts usage is read from.
enum UsageProvider: String, CaseIterable {
    // Declaration order is the reading order of every chart, row and table.
    case claude
    case grok
}

/// Token counts of one or more usage events.
///
/// `cachedInput` and `cacheCreation` are disjoint from `uncachedInput`, so the three sum
/// to the total input. `reasoning` is a subset of `output` (Grok reports it that way, and
/// Anthropic folds thinking into output), so it's never added on top.
struct UsageTokenTotals: Equatable {
    var uncachedInput = 0
    var cachedInput = 0
    var cacheCreation = 0
    var output = 0
    var reasoning = 0

    /// Every processed token.
    var total: Int { uncachedInput + cachedInput + cacheCreation + output }

    static func += (lhs: inout UsageTokenTotals, rhs: UsageTokenTotals) {
        lhs.uncachedInput += rhs.uncachedInput
        lhs.cachedInput += rhs.cachedInput
        lhs.cacheCreation += rhs.cacheCreation
        lhs.output += rhs.output
        lhs.reasoning += rhs.reasoning
    }
}

/// One usage event read from a transcript.
struct UsageRecord: Equatable {
    let provider: UsageProvider
    let timestampMs: Int
    let model: String
    let sessionId: String
    let totals: UsageTokenTotals

    /// A cost the transcript reported itself, which takes precedence over model rates.
    let reportedCostUsd: Double?

    /// The key records are de-duplicated by across files, or nil when the record is
    /// unique by nature.
    var dedupeKey: String?
}

/// Parsers for single lines of the coding agents' JSONL transcripts. None of them touch
/// the filesystem, so callers can stream files line by line.
enum UsageTranscripts {
    // MARK: Claude Code

    /// Parses one line of a Claude Code transcript.
    ///
    /// Claude Code writes one line per content block of an assistant message, and every
    /// one of them repeats the message's complete `usage`. Summing them overcounts, so
    /// callers must keep only the first record of each `dedupeKey`.
    static func parseClaudeLine(_ line: Data) -> UsageRecord? {
        guard let record = UsageJSON.object(line),
              record["type"] as? String == "assistant",
              let message = record["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let timestampMs = UsageTimestamp.milliseconds(record["timestamp"]),
              let model = message["model"] as? String, !model.isEmpty
        else { return nil }

        // Matches ccusage: prefer the message and request pair, falling back to whichever
        // half exists. Records with neither can't be de-duplicated.
        let messageId = message["id"] as? String
        let requestId = record["requestId"] as? String
        let dedupeKey = messageId == nil && requestId == nil
            ? nil
            : "\(messageId ?? ""):\(requestId ?? "")"

        return UsageRecord(
            provider: .claude,
            timestampMs: timestampMs,
            model: model,
            sessionId: record["sessionId"] as? String ?? "",
            totals: UsageTokenTotals(
                uncachedInput: UsageJSON.count(usage["input_tokens"]),
                cachedInput: UsageJSON.count(usage["cache_read_input_tokens"]),
                cacheCreation: UsageJSON.count(usage["cache_creation_input_tokens"]),
                output: UsageJSON.count(usage["output_tokens"]),
                // Anthropic folds thinking tokens into output and doesn't break them out.
                reasoning: 0),
            reportedCostUsd: UsageJSON.number(record["costUSD"]),
            dedupeKey: dedupeKey)
    }

    // MARK: Grok Build

    /// Grok reports cost in integer ticks, 10^10 to the dollar.
    static let grokCostTicksPerDollar = 10_000_000_000.0

    private struct GrokTotals {
        let input: Int
        let output: Int
        let cachedRead: Int
        let cacheCreation: Int
        let reasoning: Int
        let costTicks: Double?

        init?(_ value: Any?) {
            guard let record = value as? [String: Any] else { return nil }
            input = UsageJSON.count(record["inputTokens"])
            output = UsageJSON.count(record["outputTokens"])
            cachedRead = UsageJSON.count(record["cachedReadTokens"])
            cacheCreation = UsageJSON.count(record["cacheCreationTokens"])
            reasoning = UsageJSON.count(record["reasoningTokens"])
            costTicks = UsageJSON.number(record["costUsdTicks"])
        }

        var costUsd: Double? {
            guard let costTicks, costTicks >= 0 else { return nil }
            return costTicks / UsageTranscripts.grokCostTicksPerDollar
        }

        var usage: UsageTokenTotals {
            UsageTokenTotals(
                // Grok reports inputTokens including the cached part.
                uncachedInput: max(0, input - cachedRead - cacheCreation),
                cachedInput: cachedRead,
                cacheCreation: cacheCreation,
                output: output,
                reasoning: min(output, reasoning))
        }
    }

    /// Parses one line of a Grok Build `updates.jsonl` session log.
    ///
    /// Usage lands on `turn_completed` updates. When they break usage down by model, each
    /// model becomes its own record.
    static func parseGrokLine(_ line: Data) -> [UsageRecord] {
        guard let record = UsageJSON.object(line),
              let params = record["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "turn_completed",
              let usage = update["usage"] as? [String: Any],
              let topLevel = GrokTotals(usage) else { return [] }

        let sessionId = params["sessionId"] as? String ?? ""
        let promptId = update["prompt_id"] as? String

        // Prefer the high resolution agent clock, falling back to the outer unix seconds.
        var timestampMs: Int?
        if let meta = params["_meta"] as? [String: Any],
           let agentMs = UsageJSON.number(meta["agentTimestampMs"]) {
            timestampMs = UsageJSON.integer(agentMs)
        }
        if timestampMs == nil, let timestamp = UsageJSON.number(record["timestamp"]) {
            timestampMs = UsageJSON.integer(timestamp > 1e12 ? timestamp : timestamp * 1000)
        }
        guard let timestampMs else { return [] }

        func dedupeKey(_ model: String) -> String? {
            // Without a prompt id, two updates in the same second can't be told apart.
            promptId.map { "\(sessionId):\($0):\(model)" }
        }

        var entries: [(model: String, totals: GrokTotals)] = []
        if let modelUsage = usage["modelUsage"] as? [String: Any] {
            for (model, raw) in modelUsage where !model.isEmpty {
                if let totals = GrokTotals(raw) {
                    entries.append((model, totals))
                }
            }
            entries.sort { $0.model < $1.model }
        }

        if entries.isEmpty {
            guard topLevel.usage.total > 0 else { return [] }
            return [UsageRecord(
                provider: .grok,
                timestampMs: timestampMs,
                model: "grok",
                sessionId: sessionId,
                totals: topLevel.usage,
                reportedCostUsd: topLevel.costUsd,
                dedupeKey: dedupeKey("grok"))]
        }

        // Models with their own cost keep it. What remains of the turn's cost is split
        // across the models without one by their share of tokens. Models without tokens
        // are never emitted and never count toward either.
        var tickedCostUsd = 0.0
        var untickedTokens = 0
        for entry in entries where entry.totals.usage.total > 0 {
            if entry.totals.costTicks != nil {
                tickedCostUsd += entry.totals.costUsd ?? 0
            } else {
                untickedTokens += entry.totals.usage.total
            }
        }
        let remainingCostUsd = topLevel.costUsd.map { max(0, $0 - tickedCostUsd) }

        return entries.compactMap { entry in
            let totals = entry.totals.usage
            guard totals.total > 0 else { return nil }

            var costUsd = entry.totals.costUsd
            if costUsd == nil, let remainingCostUsd, untickedTokens > 0 {
                costUsd = remainingCostUsd * Double(totals.total) / Double(untickedTokens)
            }

            return UsageRecord(
                provider: .grok,
                timestampMs: timestampMs,
                model: entry.model,
                sessionId: sessionId,
                totals: totals,
                reportedCostUsd: costUsd,
                dedupeKey: dedupeKey(entry.model))
        }
    }
}

// MARK: - JSON

/// Helpers for reading `JSONSerialization` values.
enum UsageJSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A finite number. `JSONSerialization` also returns booleans as `NSNumber`, so they
    /// are told apart explicitly.
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// A positive token count, truncated to an integer, or 0.
    static func count(_ value: Any?) -> Int {
        guard let double = number(value), double > 0 else { return 0 }
        return integer(double) ?? 0
    }

    /// `value` truncated to an integer, or nil when it doesn't fit.
    static func integer(_ value: Double) -> Int? {
        abs(value) < 9e18 ? Int(value) : nil
    }

    /// A stable string for comparing two JSON objects.
    static func signature(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Timestamps

enum UsageTimestamp {
    /// Parses an ISO 8601 instant such as `2026-09-22T10:02:04.123Z` into epoch
    /// milliseconds. Transcripts carry one per line, so the usual shape is parsed by hand
    /// and anything else goes through `ISO8601DateFormatter`.
    static func milliseconds(_ value: Any?) -> Int? {
        guard var string = value as? String else { return nil }
        if let milliseconds = string.withUTF8(parse) {
            return milliseconds
        }
        guard let date = fractionalFormatter.date(from: string) ?? wholeSecondFormatter.date(from: string) else {
            return nil
        }
        return UsageJSON.integer((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSecondFormatter = ISO8601DateFormatter()

    private static func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        func digits(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= bytes.count else { return nil }
            var value = 0
            for index in start..<(start + count) {
                let byte = bytes[index]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }

        guard bytes.count >= 20,
              bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T") || bytes[10] == UInt8(ascii: " "),
              bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
              let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second <= 60
        else { return nil }

        var index = 19
        var milliseconds = 0
        if bytes[index] == UInt8(ascii: ".") {
            index += 1
            var scale = 100
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                milliseconds += Int(bytes[index] - 0x30) * scale
                scale /= 10
                index += 1
            }
        }

        // An instant without a zone is left to the formatter.
        guard index < bytes.count else { return nil }
        var offsetSeconds = 0
        switch bytes[index] {
        case UInt8(ascii: "Z"), UInt8(ascii: "z"):
            index += 1

        case UInt8(ascii: "+"), UInt8(ascii: "-"):
            let sign = bytes[index] == UInt8(ascii: "+") ? 1 : -1
            guard let hours = digits(index + 1, 2) else { return nil }
            var next = index + 3
            if next < bytes.count, bytes[next] == UInt8(ascii: ":") { next += 1 }
            guard let minutes = digits(next, 2) else { return nil }
            offsetSeconds = sign * (hours * 3600 + minutes * 60)
            index = next + 2

        default:
            return nil
        }
        guard index == bytes.count else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return seconds * 1000 + milliseconds
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let year = month <= 2 ? year - 1 : year
        let era = (year >= 0 ? year : year - 399) / 400
        let yearOfEra = year - era * 400
        let monthIndex = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
