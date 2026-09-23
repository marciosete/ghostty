import AppKit
import Charts
import SwiftUI

/// The usage panel: what the coding agents used on this Mac, at API prices, laid out like
/// T3 Code's usage page. A wide panel puts the summary beside the chart, as the page does.
struct UsagePanelView: View {
    @ObservedObject var model = UsagePanelModel.shared
    @ObservedObject var settings = UsageSettings.shared

    /// Space to leave at the top when the panel extends under the titlebar.
    let topInset: CGFloat

    @State private var resizeStartWidth: CGFloat?

    private var isWide: Bool { settings.width >= 720 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: topInset)
            header
            Divider()
            content
        }
        .font(.system(size: 12))
        .background(TabSidebarVisualEffectBackground())
        .overlay(alignment: .leading) { resizeHandle }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("USAGE")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(UsageFormat.window(model.summary?.window ?? .last(days: settings.windowDays)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                refreshButton
            }

            HStack(spacing: 8) {
                Picker("Metric", selection: $settings.metric) {
                    Text("Cost").tag(UsageMetric.cost)
                    Text("Tokens").tag(UsageMetric.tokens)
                }
                .fixedSize()

                Spacer(minLength: 0)

                Picker("Period", selection: $settings.windowDays) {
                    ForEach(UsageSettings.windowOptions, id: \.self) { days in
                        Text(windowLabel(days)).tag(days)
                    }
                }
                .fixedSize()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func windowLabel(_ days: Int) -> String {
        if days == 1 { return isWide ? "Past 24h" : "24h" }
        return isWide ? "\(days) days" : "\(days)d"
    }

    private var refreshButton: some View {
        ZStack {
            if model.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else {
                Button {
                    model.refresh(refreshRates: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Rescan transcripts and update model prices")
            }
        }
        .frame(width: 20, height: 20)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let summary = model.summary {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 28) {
                    if summary.activeProviders.isEmpty {
                        emptyState
                    } else {
                        if isWide {
                            HStack(alignment: .top, spacing: 24) {
                                overview(summary)
                                    .frame(width: 288)
                                chart(summary)
                            }
                        } else {
                            overview(summary)
                            chart(summary)
                        }
                        totals(summary)
                        breakdown(summary)
                    }
                    footer(summary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No usage in this period")
            Text("Usage is read from the session transcripts of Claude Code (~/.claude) and Grok Build (~/.grok).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func overview(_ summary: UsageSummary) -> some View {
        let metric = settings.metric
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(metric == .cost ? UsageFormat.usd(summary.costUsd) : UsageFormat.tokens(summary.totals.total))
                    .font(.system(size: 32, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(subtitle(summary))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            ForEach(summary.activeProviders) { provider in
                providerRow(summary.totals(of: provider), metric: metric)
            }
        }
    }

    private func subtitle(_ summary: UsageSummary) -> String {
        let sessions = "\(UsageFormat.count(summary.sessions)) sessions"
        guard settings.metric == .cost else { return sessions }
        guard summary.unpricedShare > 0 else { return sessions + " · API estimate" }
        return sessions + " · API estimate excludes \(UsageFormat.percent(summary.unpricedShare)) unpriced records"
    }

    private func providerRow(_ totals: UsageSummary.ProviderTotals, metric: UsageMetric) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(totals.provider.color)
                    .frame(width: 7, height: 7)
                UsageProviderMark(provider: totals.provider)
                    .frame(width: 14, height: 14)
                Text(totals.provider.label)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .layoutPriority(-1)
                Text("\(UsageFormat.count(totals.sessions)) \(totals.sessions == 1 ? "session" : "sessions")")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
                Spacer(minLength: 8)
                Text(metric == .cost ? UsageFormat.usd(totals.costUsd) : UsageFormat.tokens(totals.totalTokens))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .fixedSize()
            }

            Text(metric == .cost
                ? "\(UsageFormat.percent(totals.costShare)) of cost · \(UsageFormat.tokens(totals.totalTokens)) tokens"
                : "\(UsageFormat.percent(totals.tokenShare)) of tokens · \(UsageFormat.usd(totals.costUsd))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func chart(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(summary.window.hourly == nil ? "Daily" : "Hourly") \(settings.metric == .cost ? "cost" : "processed tokens")")
                .font(.system(size: 13, weight: .medium))
            UsageChart(summary: summary, metric: settings.metric)
                .frame(height: isWide ? 240 : 190)
        }
    }

    private func totals(_ summary: UsageSummary) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .leading), count: isWide ? 5 : 2)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Totals")
                .font(.system(size: 13, weight: .medium))
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                metric("Processed tokens", UsageFormat.tokens(summary.totals.total))
                metric("Cached input", UsageFormat.tokens(summary.totals.cachedInput))
                metric("Uncached input", UsageFormat.tokens(summary.totals.uncachedInput))
                metric("Output", UsageFormat.tokens(summary.totals.output))
                metric("Cache savings", UsageFormat.usd(summary.cacheSavingsUsd))
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
        }
    }

    // MARK: Breakdown

    private func breakdown(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Breakdown")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Picker("Breakdown", selection: $model.breakdown) {
                    Text("Model").tag(UsagePanelModel.Breakdown.model)
                    Text(summary.window.hourly == nil ? "Day" : "Hour").tag(UsagePanelModel.Breakdown.period)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }

            switch model.breakdown {
            case .model: modelTable(summary)
            case .period: periodTable(summary)
            }
        }
    }

    private func modelTable(_ summary: UsageSummary) -> some View {
        let models = settings.metric == .tokens
            ? summary.models.sorted { lhs, rhs in
                lhs.totalTokens != rhs.totalTokens ? lhs.totalTokens > rhs.totalTokens : lhs.costUsd > rhs.costUsd
            }
            : summary.models

        return VStack(spacing: 0) {
            UsageTableRow(isHeader: true) {
                Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                Text("Cost").frame(width: UsageColumn.money, alignment: .trailing)
                Text("Share").frame(width: UsageColumn.share, alignment: .trailing)
                Text("Tokens").frame(width: UsageColumn.tokens, alignment: .trailing)
            }

            ForEach(models) { row in
                UsageTableRow {
                    HStack(spacing: 6) {
                        UsageProviderMark(provider: row.provider)
                            .frame(width: 12, height: 12)
                        Text(row.model)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(row.model)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Group {
                        if row.isCostUnknown {
                            Text("Unpriced").foregroundStyle(.secondary)
                        } else {
                            Text(UsageFormat.usd(row.costUsd))
                        }
                    }
                    .frame(width: UsageColumn.money, alignment: .trailing)

                    Text(row.isCostUnknown ? "—" : UsageFormat.percent(row.costShare))
                        .foregroundStyle(.secondary)
                        .frame(width: UsageColumn.share, alignment: .trailing)

                    Text(UsageFormat.tokens(row.totalTokens))
                        .foregroundStyle(.secondary)
                        .frame(width: UsageColumn.tokens, alignment: .trailing)
                }
            }
        }
    }

    private func periodTable(_ summary: UsageSummary) -> some View {
        let providers = summary.activeProviders
        // Newest first: the window can run 90 periods, and the recent end is what matters.
        let periods = summary.periods.filter(\.hasUsage).reversed()

        return VStack(spacing: 0) {
            UsageTableRow(isHeader: true) {
                Text(summary.window.hourly == nil ? "Day" : "Hour").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(providers) { provider in
                    Text(provider.label)
                        .lineLimit(1)
                        .frame(width: UsageColumn.money, alignment: .trailing)
                }
                Text("Total").frame(width: UsageColumn.money, alignment: .trailing)
                Text("Tokens").frame(width: UsageColumn.tokens, alignment: .trailing)
            }

            ForEach(periods) { period in
                UsageTableRow {
                    Text(UsageFormat.period(period, in: summary.window))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(providers) { provider in
                        Text(UsageFormat.usd(period.value(of: provider, .cost)))
                            .foregroundStyle(.secondary)
                            .frame(width: UsageColumn.money, alignment: .trailing)
                    }
                    Text(UsageFormat.usd(period.costUsd))
                        .frame(width: UsageColumn.money, alignment: .trailing)
                    Text(UsageFormat.tokens(period.totalTokens))
                        .foregroundStyle(.secondary)
                        .frame(width: UsageColumn.tokens, alignment: .trailing)
                }
            }
        }
    }

    private func footer(_ summary: UsageSummary) -> some View {
        Text(pricingNote(summary.pricing))
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func pricingNote(_ pricing: UsagePricingStatus) -> String {
        let estimate = "Costs are API list price estimates, not your subscription bill."
        guard pricing.source != .unavailable, let fetchedAt = pricing.fetchedAt else {
            return "Model prices couldn't be downloaded from LiteLLM, so costs are missing. " + estimate
        }
        let now = Date()
        let age = now.timeIntervalSince(fetchedAt) < 60
            ? "just now"
            : RelativeDateTimeFormatter().localizedString(for: fetchedAt, relativeTo: now)
        return "\(estimate) Prices from LiteLLM, updated \(age)."
    }

    // MARK: Resizing

    private var resizeHandle: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        // The handle is on the left, so dragging left widens the panel.
                        let start = resizeStartWidth ?? settings.width
                        resizeStartWidth = start
                        settings.width = UsageSettings.clampWidth(start - value.translation.width)
                    }
                    .onEnded { _ in resizeStartWidth = nil }
            )
    }
}

// MARK: - Table

/// A row of the breakdown tables, with a divider below and a highlight on hover.
/// The widths of the numeric columns of the breakdown tables.
private enum UsageColumn {
    static let money: CGFloat = 76
    static let share: CGFloat = 50
    static let tokens: CGFloat = 50
}

private struct UsageTableRow<Content: View>: View {
    var isHeader = false
    @ViewBuilder let content: Content

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                content
            }
            .font(.system(size: isHeader ? 11 : 12))
            .foregroundStyle(isHeader ? .secondary : .primary)
            .monospacedDigit()
            .padding(.vertical, isHeader ? 6 : 7)
            .padding(.horizontal, 4)
            .background(isHovered && !isHeader ? Color.primary.opacity(0.05) : .clear)

            Divider()
                .opacity(isHeader ? 1 : 0.5)
        }
        .onHover { isHovered = $0 }
    }
}

// MARK: - Chart

/// The daily (or hourly) cost or tokens of each provider, as overlaid areas rather than
/// stacked ones so each is measured from zero. Hovering shows a period's values.
private struct UsageChart: View {
    let summary: UsageSummary
    let metric: UsageMetric

    @State private var hoverIndex: Int?
    @State private var hoverOnRight = false

    private var periods: [UsageSummary.PeriodTotals] { summary.periods }

    var body: some View {
        let providers = summary.activeProviders
        // Paint the heaviest series first so a lighter one isn't buried under it.
        let layered = providers.sorted { total(of: $0) > total(of: $1) }
        // The scale tops out at the largest single provider, not the sum: the series are
        // overlaid, so a combined peak would leave the plot half empty.
        let peak = periods.flatMap { period in providers.map { period.value(of: $0, metric) } }.max() ?? 0
        let scale = UsageFormat.niceScale(peak: peak)
        let lastIndex = Double(max(periods.count - 1, 1))

        Chart {
            ForEach(layered) { provider in
                ForEach(periods.indices, id: \.self) { index in
                    AreaMark(
                        x: .value("Period", Double(index)),
                        y: .value("Value", periods[index].value(of: provider, metric)),
                        series: .value("Provider", provider.rawValue),
                        stacking: .unstacked)
                        .foregroundStyle(provider.color.opacity(0.12))
                        .interpolationMethod(.monotone)
                }
            }

            // Every line after every fill, so no fill covers another series' line.
            ForEach(layered) { provider in
                ForEach(periods.indices, id: \.self) { index in
                    LineMark(
                        x: .value("Period", Double(index)),
                        y: .value("Value", periods[index].value(of: provider, metric)),
                        series: .value("Provider", provider.rawValue))
                        .foregroundStyle(provider.color)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
            }

            if let hoverIndex {
                RuleMark(x: .value("Period", Double(hoverIndex)))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: 0...lastIndex)
        .chartYScale(domain: 0...max(scale.max, 1e-9))
        .chartYAxis {
            AxisMarks(position: .leading, values: scale.ticks) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let tick = value.as(Double.self) {
                        Text(tick == 0 ? "0" : UsageFormat.value(tick, metric))
                            .font(.system(size: 9.5))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: xAxisIndices.map(Double.init)) { value in
                if let index = value.as(Double.self).map({ Int($0) }), periods.indices.contains(index) {
                    AxisValueLabel(anchor: xLabelAnchor(index)) {
                        Text(UsageFormat.period(periods[index], in: summary.window).uppercased())
                            .font(.system(size: 9.5))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let plot = geometry[proxy.plotAreaFrame]
                            guard let value = proxy.value(atX: location.x - plot.minX, as: Double.self) else { return }
                            hoverIndex = min(max(Int(value.rounded()), 0), periods.count - 1)
                            hoverOnRight = location.x > geometry.size.width / 2

                        case .ended:
                            hoverIndex = nil
                        }
                    }
            }
        }
        .overlay(alignment: hoverOnRight ? .topLeading : .topTrailing) {
            if let hoverIndex, periods.indices.contains(hoverIndex) {
                hoverCard(periods[hoverIndex], providers: providers)
                    .padding(.leading, hoverOnRight ? 56 : 0)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The first, middle and last periods, as on T3 Code's chart.
    private var xAxisIndices: [Int] {
        guard !periods.isEmpty else { return [] }
        return Array(Set([0, periods.count / 2, periods.count - 1])).sorted()
    }

    private func xLabelAnchor(_ index: Int) -> UnitPoint {
        if index == 0 { return .topLeading }
        if index == periods.count - 1 { return .topTrailing }
        return .top
    }

    private func total(of provider: UsageProvider) -> Double {
        periods.reduce(0) { $0 + $1.value(of: provider, metric) }
    }

    private func hoverCard(_ period: UsageSummary.PeriodTotals, providers: [UsageProvider]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(UsageFormat.periodDetail(period, in: summary.window))
                .foregroundStyle(.secondary)
                .padding(.bottom, 1)

            ForEach(providers) { provider in
                HStack(spacing: 5) {
                    UsageProviderMark(provider: provider)
                        .frame(width: 10, height: 10)
                    Text(provider.label)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(UsageFormat.value(period.value(of: provider, metric), metric))
                }
            }

            Divider()
                .padding(.vertical, 1)

            HStack {
                Text("Total")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(UsageFormat.value(period.value(metric), metric))
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(minWidth: 150)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}

// MARK: - Providers

extension UsageProvider: Identifiable {
    var id: Self { self }

    var label: String {
        switch self {
        case .claude: "Claude Code"
        case .grok: "Grok Build"
        }
    }

    /// The provider's color in charts and legends. Grok takes the text color, as on
    /// T3 Code, so it reads white in dark mode and black in light mode.
    var color: Color {
        switch self {
        case .claude: Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        case .grok: .primary
        }
    }

    fileprivate var markImageName: String {
        switch self {
        case .claude: "UsageClaudeMark"
        case .grok: "UsageGrokMark"
        }
    }
}

/// The logo of the agent a row belongs to.
struct UsageProviderMark: View {
    let provider: UsageProvider

    var body: some View {
        Image(provider.markImageName)
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(provider == .claude ? provider.color : .primary)
    }
}
