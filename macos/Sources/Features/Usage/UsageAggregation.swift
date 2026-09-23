import Foundation

/// A span of time the usage panel reports on, as "the last `amount` `unit`s".
struct UsageRange: Hashable {
    enum Unit: String, CaseIterable {
        case minute
        case hour
        case day
        case week
        case month

        /// The largest amount the panel accepts. Every unit tops out around a year, the
        /// longest the scanner keeps the usage of deleted transcripts.
        var maxAmount: Int {
            switch self {
            case .minute: return 7 * 24 * 60
            case .hour: return 366 * 24
            case .day: return 366
            case .week: return 52
            case .month: return 12
            }
        }
    }

    let amount: Int
    let unit: Unit

    init(_ amount: Int, _ unit: Unit) {
        self.amount = min(max(amount, 1), unit.maxAmount)
        self.unit = unit
    }

    /// The ranges the panel offers as one click choices.
    static let presets = [UsageRange(24, .hour), UsageRange(7, .day), UsageRange(30, .day), UsageRange(90, .day)]

    /// `24 hours`, `1 week`
    var label: String {
        "\(amount) \(unit.rawValue)\(amount == 1 ? "" : "s")"
    }

    /// `24h`, `7d`, `3mo`
    var shortLabel: String {
        let suffix: String
        switch unit {
        case .minute: suffix = "m"
        case .hour: suffix = "h"
        case .day: suffix = "d"
        case .week: suffix = "w"
        case .month: suffix = "mo"
        }
        return "\(amount)\(suffix)"
    }

    /// The form saved in user defaults, as `24 hour`.
    var storageValue: String { "\(amount) \(unit.rawValue)" }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: " ")
        guard parts.count == 2, let amount = Int(parts[0]), amount > 0,
              let unit = Unit(rawValue: String(parts[1])) else { return nil }
        self.init(amount, unit)
    }
}

/// The range of time a usage report covers. Minutes and hours are a rolling window
/// reported in time buckets. Days, weeks and months are whole calendar days of the
/// viewer's time zone, so they line up with the days the viewer experienced.
struct UsageWindow: Equatable {
    let range: UsageRange

    /// The first and last day of the window as `YYYY-MM-DD`, both included.
    let sinceDay: String
    let untilDay: String

    let timeZone: TimeZone

    /// For a rolling window, its exact bounds and the length of its buckets. It is
    /// reported by bucket rather than by day.
    let timed: TimeRange?

    struct TimeRange: Equatable {
        let sinceMs: Int
        let untilMs: Int
        let bucketMs: Int
    }

    static let minuteMs = 60_000
    static let hourMs = 3_600_000
    static let dayMs = 86_400_000

    /// The bucket lengths of a rolling window, shortest first. A window uses the
    /// longest that still gives the chart `minBuckets` points, so the past 24 hours is
    /// hourly and the past 6 hours is by quarter hour.
    static let bucketLengthsMs = [1, 5, 15, 30, 60, 180, 360, 720, 1440].map { $0 * minuteMs }
    static let minBuckets = 24

    /// The window of `range`, ending now.
    static func last(_ range: UsageRange, now: Date = Date(), timeZone: TimeZone = .current) -> UsageWindow {
        let nowMs = Int(now.timeIntervalSince1970 * 1000)

        switch range.unit {
        case .minute, .hour:
            // Minute aligned bounds keep labels readable while still covering the exact
            // span. Fixed length hours stay correct across daylight saving changes.
            let spanMs = range.amount * (range.unit == .minute ? minuteMs : hourMs)
            let untilMs = nowMs / minuteMs * minuteMs
            let sinceMs = untilMs - spanMs
            let bucketMs = bucketLengthsMs.last { spanMs / $0 >= minBuckets } ?? minuteMs
            return UsageWindow(
                range: range,
                sinceDay: UsageDay.day(ofMs: sinceMs, in: timeZone),
                untilDay: UsageDay.day(ofMs: untilMs, in: timeZone),
                timeZone: timeZone,
                timed: TimeRange(sinceMs: sinceMs, untilMs: untilMs, bucketMs: bucketMs))

        case .day, .week, .month:
            // Subtracting a fixed number of milliseconds lands on the wrong day around a
            // daylight saving change, so the start is calendar arithmetic on the end day.
            let untilDay = UsageDay.day(ofMs: nowMs, in: timeZone)
            let untilIndex = UsageDay.index(of: untilDay) ?? nowMs / dayMs
            let sinceIndex: Int
            switch range.unit {
            case .week: sinceIndex = untilIndex - (7 * range.amount - 1)
            case .month: sinceIndex = UsageDay.index(monthsBefore: range.amount, dayIndex: untilIndex) + 1
            default: sinceIndex = untilIndex - (range.amount - 1)
            }
            return UsageWindow(
                range: range,
                sinceDay: UsageDay.string(fromIndex: sinceIndex),
                untilDay: untilDay,
                timeZone: timeZone,
                timed: nil)
        }
    }

    /// Every day of the window, oldest first.
    var allDays: [String] {
        guard let since = UsageDay.index(of: sinceDay),
              let until = UsageDay.index(of: untilDay),
              since <= until else { return [] }
        return (since...until).map(UsageDay.string(fromIndex:))
    }

    /// The start of every bucket of a rolling window, oldest first.
    var allBucketStarts: [Int] {
        guard let timed else { return [] }
        return Array(stride(from: timed.sinceMs, to: timed.untilMs, by: timed.bucketMs))
    }

    /// No record in a file last modified before this can fall in the window. The slack
    /// covers a session whose last write lands just before midnight on the first day.
    var earliestRelevantModificationMs: Int {
        let slackMs = 36 * Self.hourMs
        if let timed { return timed.sinceMs - slackMs }
        let sinceIndex = UsageDay.index(of: sinceDay) ?? 0
        return sinceIndex * Self.dayMs - slackMs
    }
}

/// Calendar days as `YYYY-MM-DD` strings, which sort in date order.
enum UsageDay {
    static func string(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// The day of an instant in a time zone.
    static func day(ofMs milliseconds: Int, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return day(ofMs: milliseconds, in: calendar)
    }

    static func day(ofMs milliseconds: Int, in calendar: Calendar) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return string(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }

    /// Days since 1970-01-01 of a `YYYY-MM-DD` string.
    static func index(of day: String) -> Int? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return UsageTimestamp.daysFromCivil(year: parts[0], month: parts[1], day: parts[2])
    }

    /// The day index `months` calendar months before a day index, on the same day of the
    /// month or the last day of a shorter month.
    static func index(monthsBefore months: Int, dayIndex: Int) -> Int {
        let parts = string(fromIndex: dayIndex).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return dayIndex - 30 * months }
        let monthsSinceYearZero = parts[0] * 12 + (parts[1] - 1) - months
        let year = monthsSinceYearZero >= 0 ? monthsSinceYearZero / 12 : (monthsSinceYearZero - 11) / 12
        let month = monthsSinceYearZero - year * 12 + 1
        let nextMonthStart = month == 12
            ? UsageTimestamp.daysFromCivil(year: year + 1, month: 1, day: 1)
            : UsageTimestamp.daysFromCivil(year: year, month: month + 1, day: 1)
        let monthLength = nextMonthStart - UsageTimestamp.daysFromCivil(year: year, month: month, day: 1)
        return UsageTimestamp.daysFromCivil(year: year, month: month, day: min(parts[2], monthLength))
    }

    /// The `YYYY-MM-DD` string of a day index (Howard Hinnant's algorithm).
    static func string(fromIndex index: Int) -> String {
        let shifted = index + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return string(year: year, month: month, day: day)
    }
}

/// The usage of one model of one provider on one day, or in one bucket of a rolling window.
struct UsageBucket: Equatable {
    let day: String
    let startMs: Int?
    let provider: UsageProvider
    let model: String
    var totals = UsageTokenTotals()
    var costUsd = 0.0
    var cacheSavingsUsd = 0.0
    var records = 0

    /// Records whose tokens are counted but which added nothing to the cost because their
    /// model has no rates.
    var unpricedRecords = 0
}

/// Folds usage records into buckets by day (or time bucket), provider and model, pricing them
/// as they come in.
///
/// De-duplication spans every file of a scan: Claude Code copies a message's records into
/// the new transcript when a session is resumed or forked, so the same key legitimately
/// shows up in several files.
final class UsageAggregator {
    private struct Key: Hashable {
        let day: String
        let startMs: Int?
        let provider: UsageProvider
        let model: String
    }

    private let window: UsageWindow
    private let rates: UsageRateTable
    private let calendar: Calendar
    private var buckets: [Key: UsageBucket] = [:]
    private var seen: Set<String> = []
    private var ratesByModel: [String: UsageModelRate?] = [:]

    /// Days by quarter hour since the epoch. Every time zone offset is a multiple of 15
    /// minutes, so all instants of a quarter hour fall on the same day.
    private var daysByQuarterHour: [Int: String] = [:]

    /// Records dropped because an earlier record had the same key.
    private(set) var duplicatesDropped = 0

    /// Records outside the window.
    private(set) var outOfWindow = 0

    init(window: UsageWindow, rates: UsageRateTable) {
        self.window = window
        self.rates = rates
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = window.timeZone
        self.calendar = calendar
    }

    /// Folds in one record. Returns whether it counted, so callers can derive facts such
    /// as distinct sessions from the records that landed in the window.
    @discardableResult
    func add(_ record: UsageRecord) -> Bool {
        if let key = record.dedupeKey {
            guard seen.insert(key).inserted else {
                duplicatesDropped += 1
                return false
            }
        }

        if let timed = window.timed,
           record.timestampMs < timed.sinceMs || record.timestampMs >= timed.untilMs {
            outOfWindow += 1
            return false
        }

        let day = self.day(ofMs: record.timestampMs)
        if window.timed == nil, day < window.sinceDay || day > window.untilDay {
            outOfWindow += 1
            return false
        }

        let startMs = window.timed.map { timed in
            timed.sinceMs + (record.timestampMs - timed.sinceMs) / timed.bucketMs * timed.bucketMs
        }
        let key = Key(day: day, startMs: startMs, provider: record.provider, model: record.model)
        var bucket = buckets[key] ?? UsageBucket(
            day: day, startMs: startMs, provider: record.provider, model: record.model)

        let rate = self.rate(for: record.model)
        bucket.totals += record.totals
        bucket.records += 1
        if let reported = record.reportedCostUsd {
            bucket.costUsd += reported
        } else if let rate {
            bucket.costUsd += rate.cost(of: record.totals)
        } else {
            bucket.unpricedRecords += 1
        }
        bucket.cacheSavingsUsd += rate?.cacheSavings(of: record.totals) ?? 0

        buckets[key] = bucket
        return true
    }

    /// The buckets, in a stable order.
    func finish() -> [UsageBucket] {
        buckets.values.sorted { lhs, rhs in
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            if lhs.startMs != rhs.startMs { return (lhs.startMs ?? 0) < (rhs.startMs ?? 0) }
            if lhs.provider != rhs.provider { return lhs.provider.rawValue < rhs.provider.rawValue }
            return lhs.model < rhs.model
        }
    }

    private func rate(for model: String) -> UsageModelRate? {
        if let cached = ratesByModel[model] { return cached }
        let rate = rates.rate(for: model)
        ratesByModel.updateValue(rate, forKey: model)
        return rate
    }

    private func day(ofMs milliseconds: Int) -> String {
        let quarterHour = milliseconds >= 0 ? milliseconds / 900_000 : (milliseconds - 899_999) / 900_000
        if let day = daysByQuarterHour[quarterHour] { return day }
        let day = UsageDay.day(ofMs: milliseconds, in: calendar)
        daysByQuarterHour[quarterHour] = day
        return day
    }
}
