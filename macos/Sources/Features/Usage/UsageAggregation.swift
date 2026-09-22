import Foundation

/// The range of time a usage report covers, in calendar days of the viewer's time zone so
/// they line up with the days the viewer experienced.
struct UsageWindow: Equatable {
    /// How many days the window spans. 1 is the rolling past 24 hours.
    let days: Int

    /// The first and last day of the window as `YYYY-MM-DD`, both included.
    let sinceDay: String
    let untilDay: String

    let timeZone: TimeZone

    /// For the past 24 hours, the exact bounds of the window. It is reported by hour
    /// rather than by day.
    let hourly: HourRange?

    struct HourRange: Equatable {
        let sinceMs: Int
        let untilMs: Int
    }

    static let hourMs = 3_600_000
    static let dayMs = 86_400_000

    /// The window of the last `days` days, ending now.
    static func last(days: Int, now: Date = Date(), timeZone: TimeZone = .current) -> UsageWindow {
        let nowMs = Int(now.timeIntervalSince1970 * 1000)

        if days == 1 {
            // Minute aligned bounds keep labels readable while still covering exactly 24
            // hours. Fixed length hours stay correct across daylight saving changes.
            let untilMs = nowMs / 60_000 * 60_000
            let sinceMs = untilMs - 24 * hourMs
            return UsageWindow(
                days: 1,
                sinceDay: UsageDay.day(ofMs: sinceMs, in: timeZone),
                untilDay: UsageDay.day(ofMs: untilMs, in: timeZone),
                timeZone: timeZone,
                hourly: HourRange(sinceMs: sinceMs, untilMs: untilMs))
        }

        // Subtracting a fixed number of milliseconds lands on the wrong day around a
        // daylight saving change, so the start is calendar arithmetic on the end day.
        let untilDay = UsageDay.day(ofMs: nowMs, in: timeZone)
        let untilIndex = UsageDay.index(of: untilDay) ?? nowMs / dayMs
        return UsageWindow(
            days: days,
            sinceDay: UsageDay.string(fromIndex: untilIndex - (days - 1)),
            untilDay: untilDay,
            timeZone: timeZone,
            hourly: nil)
    }

    /// Every day of the window, oldest first.
    var allDays: [String] {
        guard let since = UsageDay.index(of: sinceDay),
              let until = UsageDay.index(of: untilDay),
              since <= until else { return [] }
        return (since...until).map(UsageDay.string(fromIndex:))
    }

    /// The start of every hour of an hourly window, oldest first.
    var allHourStarts: [Int] {
        guard let hourly else { return [] }
        return Array(stride(from: hourly.sinceMs, to: hourly.untilMs, by: Self.hourMs))
    }

    /// No record in a file last modified before this can fall in the window. The slack
    /// covers a session whose last write lands just before midnight on the first day.
    var earliestRelevantModificationMs: Int {
        let slackMs = 36 * Self.hourMs
        if let hourly { return hourly.sinceMs - slackMs }
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

/// The usage of one model of one provider on one day, or in one hour of an hourly window.
struct UsageBucket: Equatable {
    let day: String
    let hourStartMs: Int?
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

/// Folds usage records into buckets by day (or hour), provider and model, pricing them
/// as they come in.
///
/// De-duplication spans every file of a scan: Claude Code copies a message's records into
/// the new transcript when a session is resumed or forked, so the same key legitimately
/// shows up in several files.
final class UsageAggregator {
    private struct Key: Hashable {
        let day: String
        let hourStartMs: Int?
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

        if let hourly = window.hourly,
           record.timestampMs < hourly.sinceMs || record.timestampMs >= hourly.untilMs {
            outOfWindow += 1
            return false
        }

        let day = self.day(ofMs: record.timestampMs)
        if window.hourly == nil, day < window.sinceDay || day > window.untilDay {
            outOfWindow += 1
            return false
        }

        let hourStartMs = window.hourly.map { hourly in
            hourly.sinceMs + (record.timestampMs - hourly.sinceMs) / UsageWindow.hourMs * UsageWindow.hourMs
        }
        let key = Key(day: day, hourStartMs: hourStartMs, provider: record.provider, model: record.model)
        var bucket = buckets[key] ?? UsageBucket(
            day: day, hourStartMs: hourStartMs, provider: record.provider, model: record.model)

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
            if lhs.hourStartMs != rhs.hourStartMs { return (lhs.hourStartMs ?? 0) < (rhs.hourStartMs ?? 0) }
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
