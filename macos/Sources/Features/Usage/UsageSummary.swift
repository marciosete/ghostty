import Foundation

/// A report's buckets totalled the ways the usage panel shows them.
struct UsageSummary {
    struct ProviderTotals: Identifiable {
        let provider: UsageProvider
        var costUsd = 0.0
        var totalTokens = 0
        var sessions = 0
        var costShare = 0.0
        var tokenShare = 0.0

        var id: UsageProvider { provider }
    }

    struct ModelTotals: Identifiable {
        let provider: UsageProvider
        let model: String
        var costUsd = 0.0
        var totalTokens = 0
        var records = 0
        var unpricedRecords = 0
        var costShare = 0.0

        var id: String { "\(provider.rawValue):\(model)" }

        /// A model whose every record lacked rates has an unknown cost, not a zero one.
        var isCostUnknown: Bool { records > 0 && unpricedRecords >= records }
    }

    /// One day, or one bucket of a rolling window.
    struct PeriodTotals: Identifiable {
        let day: String
        let startMs: Int?
        var costUsd = 0.0
        var totalTokens = 0
        var byProvider: [UsageProvider: (costUsd: Double, totalTokens: Int)] = [:]

        var id: String { startMs.map(String.init) ?? day }
        var hasUsage: Bool { !byProvider.isEmpty }

        func value(of provider: UsageProvider, _ metric: UsageMetric) -> Double {
            guard let totals = byProvider[provider] else { return 0 }
            return metric == .cost ? totals.costUsd : Double(totals.totalTokens)
        }

        func value(_ metric: UsageMetric) -> Double {
            metric == .cost ? costUsd : Double(totalTokens)
        }
    }

    let window: UsageWindow
    let pricing: UsagePricingStatus
    let costUsd: Double
    let totals: UsageTokenTotals
    let cacheSavingsUsd: Double
    let sessions: Int

    /// The share of records whose cost isn't known because their model has no rates.
    let unpricedShare: Double

    /// Sorted by cost, highest first.
    let providers: [ProviderTotals]

    /// Sorted by cost, then tokens, highest first.
    let models: [ModelTotals]

    /// Every day (or bucket) of the window, oldest first, including those without usage.
    let periods: [PeriodTotals]

    init(_ report: UsageReport) {
        window = report.window
        pricing = report.pricing

        var costUsd = 0.0
        var totals = UsageTokenTotals()
        var cacheSavingsUsd = 0.0
        var records = 0
        var unpricedRecords = 0
        var providers: [UsageProvider: ProviderTotals] = [:]
        var models: [String: ModelTotals] = [:]
        var periods: [String: PeriodTotals] = [:]

        for bucket in report.buckets {
            let tokens = bucket.totals.total
            costUsd += bucket.costUsd
            totals += bucket.totals
            cacheSavingsUsd += bucket.cacheSavingsUsd
            records += bucket.records
            unpricedRecords += bucket.unpricedRecords

            providers[bucket.provider, default: ProviderTotals(provider: bucket.provider)].costUsd += bucket.costUsd
            providers[bucket.provider]?.totalTokens += tokens

            let modelKey = "\(bucket.provider.rawValue):\(bucket.model)"
            var model = models[modelKey] ?? ModelTotals(provider: bucket.provider, model: bucket.model)
            model.costUsd += bucket.costUsd
            model.totalTokens += tokens
            model.records += bucket.records
            model.unpricedRecords += bucket.unpricedRecords
            models[modelKey] = model

            let periodKey = bucket.startMs.map(String.init) ?? bucket.day
            var period = periods[periodKey] ?? PeriodTotals(day: bucket.day, startMs: bucket.startMs)
            period.costUsd += bucket.costUsd
            period.totalTokens += tokens
            let providerTotals = period.byProvider[bucket.provider] ?? (0, 0)
            period.byProvider[bucket.provider] = (providerTotals.costUsd + bucket.costUsd, providerTotals.totalTokens + tokens)
            periods[periodKey] = period
        }

        for (provider, sessions) in report.sessionsByProvider where sessions > 0 {
            providers[provider, default: ProviderTotals(provider: provider)].sessions += sessions
        }

        self.costUsd = costUsd
        self.totals = totals
        self.cacheSavingsUsd = cacheSavingsUsd
        sessions = report.sessionsByProvider.values.reduce(0, +)
        unpricedShare = records == 0 ? 0 : Double(unpricedRecords) / Double(records)

        self.providers = providers.values
            .map { provider in
                var provider = provider
                provider.costShare = costUsd == 0 ? 0 : provider.costUsd / costUsd
                provider.tokenShare = totals.total == 0 ? 0 : Double(provider.totalTokens) / Double(totals.total)
                return provider
            }
            .sorted { $0.costUsd > $1.costUsd }

        self.models = models.values
            .map { model in
                var model = model
                model.costShare = costUsd == 0 ? 0 : model.costUsd / costUsd
                return model
            }
            .sorted { lhs, rhs in
                lhs.costUsd != rhs.costUsd ? lhs.costUsd > rhs.costUsd : lhs.totalTokens > rhs.totalTokens
            }

        if report.window.timed != nil {
            self.periods = report.window.allBucketStarts.map { startMs in
                periods[String(startMs)] ?? PeriodTotals(
                    day: UsageDay.day(ofMs: startMs, in: report.window.timeZone),
                    startMs: startMs)
            }
        } else {
            self.periods = report.window.allDays.map { day in
                periods[day] ?? PeriodTotals(day: day, startMs: nil)
            }
        }
    }

    /// Providers with any usage, in reading order.
    var activeProviders: [UsageProvider] {
        let active = Set(providers.filter { $0.totalTokens > 0 || $0.costUsd > 0 }.map(\.provider))
        return UsageProvider.allCases.filter(active.contains)
    }

    func totals(of provider: UsageProvider) -> ProviderTotals {
        providers.first { $0.provider == provider } ?? ProviderTotals(provider: provider)
    }
}

/// What the usage panel measures.
enum UsageMetric: String, CaseIterable {
    case cost
    case tokens
}

// MARK: - Formatting

enum UsageFormat {
    private static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let integer: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// `$10,887.91`
    static func usd(_ value: Double) -> String {
        currency.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    /// `1,234`
    static func count(_ value: Int) -> String {
        integer.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// A token count compacted to three significant figures with a unit, so columns line
    /// up at a glance: `13.8B`, `5.38M`, `209K`.
    static func tokens(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1e12 { return trim(value / 1e12) + "T" }
        if magnitude >= 1e9 { return trim(value / 1e9) + "B" }
        if magnitude >= 1e6 { return trim(value / 1e6) + "M" }
        if magnitude >= 1e3 { return trim(value / 1e3) + "K" }
        return count(Int(value.rounded()))
    }

    static func tokens(_ value: Int) -> String {
        tokens(Double(value))
    }

    private static func trim(_ value: Double) -> String {
        let magnitude = abs(value)
        let digits = magnitude >= 100 ? 0 : magnitude >= 10 ? 1 : 2
        var string = String(format: "%.\(digits)f", value)
        // Drop an all-zero fraction, as `1.00` → `1`, but keep `1.50`.
        if let dot = string.firstIndex(of: "."), string[string.index(after: dot)...].allSatisfy({ $0 == "0" }) {
            string = String(string[..<dot])
        }
        return string
    }

    /// `34.9%`
    static func percent(_ share: Double) -> String {
        String(format: "%.1f%%", share * 100)
    }

    static func value(_ value: Double, _ metric: UsageMetric) -> String {
        metric == .cost ? usd(value) : tokens(value)
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `2026-08-07` → `Aug 7`
    static func day(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return day }
        return "\(months[parts[1] - 1]) \(parts[2])"
    }

    /// The start of an hour bucket, as `2 PM`.
    static func hour(_ milliseconds: Int, in timeZone: TimeZone) -> String {
        formatter("h a", timeZone).string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    /// The start of a bucket shorter than an hour, as `2:15 PM`.
    static func time(_ milliseconds: Int, in timeZone: TimeZone) -> String {
        formatter("h:mm a", timeZone).string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    /// `Aug 11, 2 PM`
    static func dateTime(_ milliseconds: Int, in timeZone: TimeZone) -> String {
        formatter("MMM d, h a", timeZone).string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        formatter.timeZone = timeZone
        return formatter
    }

    /// A period's label, as `Aug 24`, `2 PM`, `2:15 PM`, or `Aug 11, 2 PM` when a
    /// rolling window spans more than two days.
    static func period(_ period: UsageSummary.PeriodTotals, in window: UsageWindow) -> String {
        guard let startMs = period.startMs, let timed = window.timed else { return day(period.day) }
        if timed.untilMs - timed.sinceMs > 2 * UsageWindow.dayMs { return dateTime(startMs, in: window.timeZone) }
        return clock(startMs, in: window)
    }

    /// A period's label in the chart's hover card, as `Aug 24`, `2 PM today` or
    /// `2:15 PM yesterday`.
    static func periodDetail(_ period: UsageSummary.PeriodTotals, in window: UsageWindow) -> String {
        guard let startMs = period.startMs, let timed = window.timed else { return day(period.day) }
        let today = UsageDay.day(ofMs: timed.untilMs, in: window.timeZone)
        guard let daysAgo = UsageDay.index(of: today).flatMap({ todayIndex in
            UsageDay.index(of: period.day).map { todayIndex - $0 }
        }) else { return dateTime(startMs, in: window.timeZone) }

        switch daysAgo {
        case 0: return clock(startMs, in: window) + " today"
        case 1: return clock(startMs, in: window) + " yesterday"
        default: return dateTime(startMs, in: window.timeZone)
        }
    }

    /// A bucket's start as a time of day, with minutes only when buckets are shorter
    /// than an hour.
    private static func clock(_ startMs: Int, in window: UsageWindow) -> String {
        let bucketMs = window.timed?.bucketMs ?? UsageWindow.hourMs
        return bucketMs < UsageWindow.hourMs ? time(startMs, in: window.timeZone) : hour(startMs, in: window.timeZone)
    }

    /// What one period of the window is, for the chart's title and the breakdown: `Day`,
    /// `Hour`, `5 min` or `3 hr`.
    static func periodName(_ window: UsageWindow) -> String {
        guard let timed = window.timed else { return "Day" }
        let minutes = timed.bucketMs / UsageWindow.minuteMs
        if minutes == 60 { return "Hour" }
        if minutes == 24 * 60 { return "Day" }
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) hr"
    }

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("EEE jmm")
        return formatter
    }()

    /// When a plan window resets, as `Resets in 2 hr 18 min` within a day, and as
    /// `Resets Sat 7:00 AM` beyond that.
    static func reset(_ date: Date, now: Date = Date()) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "Resetting now" }

        if interval < 24 * 60 * 60 {
            let minutes = Int(interval / 60)
            guard minutes >= 60 else { return "Resets in \(max(minutes, 1)) min" }
            return "Resets in \(minutes / 60) hr \(minutes % 60) min"
        }
        return "Resets " + resetFormatter.string(from: date)
    }

    /// The window as `Aug 24 to Sep 22`, `Sep 21, 10:02 PM to Sep 22, 10:02 PM`, or
    /// `2:15 PM to 2:45 PM` within a day.
    static func window(_ window: UsageWindow) -> String {
        if let timed = window.timed {
            let format = window.sinceDay == window.untilDay ? "h:mm a" : "MMM d, h:mm a"
            let formatter = formatter(format, window.timeZone)
            let since = formatter.string(from: Date(timeIntervalSince1970: Double(timed.sinceMs) / 1000))
            let until = formatter.string(from: Date(timeIntervalSince1970: Double(timed.untilMs) / 1000))
            return "\(since) to \(until)"
        }
        if window.sinceDay == window.untilDay { return day(window.untilDay) }
        return "\(day(window.sinceDay)) to \(day(window.untilDay))"
    }

    /// A chart scale whose top is a readable 1, 2 or 5 × 10ⁿ step at or above `peak`.
    /// Rounding the top up keeps the tallest point inside the plot.
    static func niceScale(peak: Double, tickCount: Int = 4) -> (max: Double, ticks: [Double]) {
        guard peak > 0 else { return (0, [0]) }
        let rawStep = peak / Double(tickCount)
        let magnitude = pow(10, floor(log10(rawStep)))
        let normalized = rawStep / magnitude
        let step = (normalized > 5 ? 10 : normalized > 2 ? 5 : normalized > 1 ? 2 : 1) * magnitude
        let max = (peak / step).rounded(.up) * step
        let ticks = stride(from: 0.0, through: max + step * 1e-6, by: step).map { $0 }
        return (max, ticks)
    }
}
