import Combine
import Foundation

/// App-wide settings of the usage panel, shared by all windows and saved in user defaults.
final class UsageSettings: ObservableObject {
    static let shared = UsageSettings()

    private static let visibleKey = "UsagePanelVisible"
    private static let widthKey = "UsagePanelWidth"
    private static let metricKey = "UsagePanelMetric"
    private static let rangeKey = "UsagePanelRange"

    /// Where builds before custom ranges saved the window, in days. 1 was the past 24 hours.
    private static let legacyWindowDaysKey = "UsagePanelWindowDays"

    static let minWidth: CGFloat = 320
    static let maxWidth: CGFloat = 960
    static let defaultWidth: CGFloat = 420

    @Published var isVisible: Bool {
        didSet { UserDefaults.ghostty.set(isVisible, forKey: Self.visibleKey) }
    }

    @Published var width: CGFloat {
        didSet { UserDefaults.ghostty.set(Double(width), forKey: Self.widthKey) }
    }

    @Published var metric: UsageMetric {
        didSet { UserDefaults.ghostty.set(metric.rawValue, forKey: Self.metricKey) }
    }

    @Published var range: UsageRange {
        didSet { UserDefaults.ghostty.set(range.storageValue, forKey: Self.rangeKey) }
    }

    private init() {
        let defaults = UserDefaults.ghostty
        isVisible = defaults.bool(forKey: Self.visibleKey)

        let storedWidth = defaults.double(forKey: Self.widthKey)
        width = storedWidth > 0 ? Self.clampWidth(CGFloat(storedWidth)) : Self.defaultWidth

        metric = defaults.string(forKey: Self.metricKey).flatMap(UsageMetric.init(rawValue:)) ?? .cost

        if let stored = defaults.string(forKey: Self.rangeKey).flatMap(UsageRange.init(storageValue:)) {
            range = stored
        } else {
            let legacyDays = defaults.integer(forKey: Self.legacyWindowDaysKey)
            range = legacyDays == 1 ? UsageRange(24, .hour) : UsageRange(legacyDays > 0 ? legacyDays : 30, .day)
        }
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

    /// The plan limits of the Claude Code CLI, or nil until they're first read.
    @Published private(set) var limits: ClaudeLimits?

    @Published private(set) var isScanning = false

    @Published var breakdown: Breakdown = .model

    private let scanner: UsageScanner
    private let settings: UsageSettings
    private var cancellables: Set<AnyCancellable> = []

    /// Scans run in order, so only the latest one's result is shown.
    private var latestScan = 0

    /// Asking the CLI costs a couple of seconds, so an automatic check waits at least
    /// this long after the last one. An explicit refresh ignores it.
    private static let limitsMinimumInterval: TimeInterval = 5 * 60

    /// How often the limits are re-read while the panel is open.
    private static let limitsRefreshInterval: TimeInterval = 5 * 60

    private let limitsQueue = DispatchQueue(label: "com.mitchellh.ghostty.usage-limits", qos: .userInitiated)
    private var limitsTimer: Timer?
    private var isReadingLimits = false

    init(scanner: UsageScanner = .shared, settings: UsageSettings = .shared) {
        self.scanner = scanner
        self.settings = settings

        // Published values arrive before the property changes, so the new value is
        // passed along rather than read back.
        settings.$isVisible
            .removeDuplicates()
            .sink { [weak self] isVisible in
                guard let self else { return }
                guard isVisible else {
                    self.limitsTimer?.invalidate()
                    self.limitsTimer = nil
                    return
                }
                self.refresh()
                self.refreshLimits()
                self.startLimitsTimer()
            }
            .store(in: &cancellables)

        settings.$range
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] range in self?.refresh(range: range) }
            .store(in: &cancellables)
    }

    /// Reads the plan limits again. Automatic checks are spaced out; `force` is the
    /// refresh button and ignores that.
    func refreshLimits(force: Bool = false) {
        if !force, let checkedAt = limits?.checkedAt,
           Date().timeIntervalSince(checkedAt) < Self.limitsMinimumInterval {
            return
        }
        guard !isReadingLimits else { return }

        isReadingLimits = true
        limitsQueue.async { [weak self] in
            let limits = ClaudeLimitsReader.read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.limits = limits
                self.isReadingLimits = false
            }
        }
    }

    private func startLimitsTimer() {
        limitsTimer?.invalidate()
        let timer = Timer(timeInterval: Self.limitsRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshLimits()
        }
        // The common mode keeps it firing while a menu is open or the panel scrolls.
        RunLoop.main.add(timer, forMode: .common)
        limitsTimer = timer
    }

    /// Scans the transcripts again. `refreshRates` also downloads the model prices again.
    func refresh(range: UsageRange? = nil, refreshRates: Bool = false) {
        latestScan += 1
        let scan = latestScan
        isScanning = true
        scanner.scan(.last(range ?? settings.range), refreshRates: refreshRates) { [weak self] report in
            guard let self, scan == self.latestScan else { return }
            self.summary = UsageSummary(report)
            self.isScanning = false
        }
    }
}
