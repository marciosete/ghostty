import Combine
import Foundation

/// App-wide settings of the usage panel, shared by all windows and saved in user defaults.
final class UsageSettings: ObservableObject {
    static let shared = UsageSettings()

    private static let visibleKey = "UsagePanelVisible"
    private static let widthKey = "UsagePanelWidth"
    private static let metricKey = "UsagePanelMetric"
    private static let windowDaysKey = "UsagePanelWindowDays"

    static let minWidth: CGFloat = 320
    static let maxWidth: CGFloat = 960
    static let defaultWidth: CGFloat = 420

    /// The windows the panel offers, in days. 1 is the rolling past 24 hours.
    static let windowOptions = [1, 7, 30, 90]

    @Published var isVisible: Bool {
        didSet { UserDefaults.ghostty.set(isVisible, forKey: Self.visibleKey) }
    }

    @Published var width: CGFloat {
        didSet { UserDefaults.ghostty.set(Double(width), forKey: Self.widthKey) }
    }

    @Published var metric: UsageMetric {
        didSet { UserDefaults.ghostty.set(metric.rawValue, forKey: Self.metricKey) }
    }

    @Published var windowDays: Int {
        didSet { UserDefaults.ghostty.set(windowDays, forKey: Self.windowDaysKey) }
    }

    private init() {
        let defaults = UserDefaults.ghostty
        isVisible = defaults.bool(forKey: Self.visibleKey)

        let storedWidth = defaults.double(forKey: Self.widthKey)
        width = storedWidth > 0 ? Self.clampWidth(CGFloat(storedWidth)) : Self.defaultWidth

        metric = defaults.string(forKey: Self.metricKey).flatMap(UsageMetric.init(rawValue:)) ?? .cost

        let storedDays = defaults.integer(forKey: Self.windowDaysKey)
        windowDays = Self.windowOptions.contains(storedDays) ? storedDays : 30
    }

    static func clampWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minWidth), maxWidth)
    }
}

/// The usage the panel shows. Usage is the same for every window, so one model serves
/// them all. It scans when the panel is shown, when the window changes, and on refresh.
final class UsagePanelModel: ObservableObject {
    static let shared = UsagePanelModel()

    enum Breakdown: Hashable {
        case model
        case period
    }

    /// The latest scan's usage, or nil until the first scan finishes.
    @Published private(set) var summary: UsageSummary?

    @Published private(set) var isScanning = false

    @Published var breakdown: Breakdown = .model

    private let scanner: UsageScanner
    private let settings: UsageSettings
    private var cancellables: Set<AnyCancellable> = []

    /// Scans run in order, so only the latest one's result is shown.
    private var latestScan = 0

    init(scanner: UsageScanner = .shared, settings: UsageSettings = .shared) {
        self.scanner = scanner
        self.settings = settings

        // Published values arrive before the property changes, so the new value is
        // passed along rather than read back.
        settings.$isVisible
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        settings.$windowDays
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] days in self?.refresh(days: days) }
            .store(in: &cancellables)
    }

    /// Scans the transcripts again. `refreshRates` also downloads the model prices again.
    func refresh(days: Int? = nil, refreshRates: Bool = false) {
        latestScan += 1
        let scan = latestScan
        isScanning = true
        scanner.scan(.last(days: days ?? settings.windowDays), refreshRates: refreshRates) { [weak self] report in
            guard let self, scan == self.latestScan else { return }
            self.summary = UsageSummary(report)
            self.isScanning = false
        }
    }
}
