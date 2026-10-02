import Combine
import Foundation

/// App-wide settings for the source control panel, shared by all windows and saved in
/// user defaults.
final class SourceControlSettings: ObservableObject {
    static let shared = SourceControlSettings()

    private static let visibleKey = "SourceControlPanelVisible"
    private static let widthKey = "SourceControlPanelWidth"

    static let minWidth: CGFloat = 180
    static let maxWidth: CGFloat = 520
    static let defaultWidth: CGFloat = 280

    @Published var isVisible: Bool {
        didSet { UserDefaults.ghostty.set(isVisible, forKey: Self.visibleKey) }
    }

    @Published var width: CGFloat {
        didSet { UserDefaults.ghostty.set(Double(width), forKey: Self.widthKey) }
    }

    private init() {
        let defaults = UserDefaults.ghostty
        isVisible = defaults.bool(forKey: Self.visibleKey)

        let storedWidth = defaults.double(forKey: Self.widthKey)
        width = storedWidth > 0 ? Self.clampWidth(CGFloat(storedWidth)) : Self.defaultWidth
    }

    static func clampWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minWidth), maxWidth)
    }
}

/// The state behind the source control panel of one terminal window. It follows the
/// window's focused terminal: the directory Claude Code runs in while it runs there, which
/// is its worktree if it was started with `--worktree`, and the terminal's working
/// directory otherwise.
final class SourceControlPanelModel: ObservableObject {
    enum State: Equatable {
        /// The focused terminal hasn't reported a working directory.
        case noDirectory

        /// The working directory isn't inside a git repository.
        case notRepository(directory: String)

        /// Waiting for the first `git status`.
        case loading(Git.Repository)

        case ready(Git.Repository, GitStatus)
    }

    @Published private(set) var state: State = .noDirectory

    /// Tree folders and sections the user collapsed, keyed by `SourceControlTree` ids.
    @Published var collapsed: Set<String> = []

    /// Follows the pre-commit and pre-push hooks of the repository shown.
    @Published private(set) var hookTracker: GitHookTracker?

    /// How often the focused terminal is checked for Claude Code starting or exiting,
    /// which doesn't change the terminal's working directory.
    private static let sessionCheckInterval: TimeInterval = 2

    /// The working directory the focused terminal reported.
    private var directory: String?

    /// The focused terminal's foreground process.
    private var foregroundPID: @MainActor () -> Int? = { nil }

    /// The directory whose repository is shown, or is being looked up.
    private var shownDirectory: String?

    private var isVisible = false
    private var monitor: GitRepositoryMonitor?
    private var monitorCancellable: AnyCancellable?
    private var hookWatch: AnyCancellable?
    private var sessionCheckTimer: Timer?

    /// Incremented for every lookup so a slow, outdated lookup can't win over a newer one.
    private var lookupGeneration = 0

    deinit {
        sessionCheckTimer?.invalidate()
    }

    /// Follows a newly focused terminal, whose foreground process `foregroundPID` returns.
    func setTerminal(foregroundPID: @escaping @MainActor () -> Int?) {
        self.foregroundPID = foregroundPID
        update()
    }

    /// Sets the focused terminal's working directory.
    func setDirectory(_ directory: String?) {
        let directory = directory.flatMap { $0.isEmpty ? nil : $0 }
        guard directory != self.directory else { return }
        self.directory = directory
        update()
    }

    /// The panel only watches the repository while it is visible.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        update()
    }

    private func update() {
        lookupGeneration += 1
        shownDirectory = nil

        guard isVisible else {
            sessionCheckTimer?.invalidate()
            sessionCheckTimer = nil
            stopMonitoring()
            return
        }

        if sessionCheckTimer == nil {
            let timer = Timer(timeInterval: Self.sessionCheckInterval, repeats: true) { [weak self] _ in
                self?.lookUp()
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            sessionCheckTimer = timer
        }

        lookUp()
    }

    /// Works out which directory to show: the one Claude Code runs in, if the focused
    /// terminal runs it, or else the terminal's working directory. Looks up its repository
    /// if it changed.
    private func lookUp() {
        let generation = lookupGeneration
        let pid = MainActor.assumeIsolated { foregroundPID() }
        let directory = directory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let target = pid.flatMap(AgentSession.directory(ofRunning:)) ?? directory
            DispatchQueue.main.async {
                guard let self, generation == self.lookupGeneration else { return }
                guard let target else {
                    self.shownDirectory = nil
                    self.stopMonitoring()
                    self.state = .noDirectory
                    return
                }
                guard target != self.shownDirectory else { return }
                self.shownDirectory = target
                self.lookUpRepository(of: target)
            }
        }
    }

    private func lookUpRepository(of directory: String) {
        lookupGeneration += 1
        let generation = lookupGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let repository = Git.repository(containing: URL(fileURLWithPath: directory))
            DispatchQueue.main.async {
                guard let self, generation == self.lookupGeneration else { return }
                self.show(repository, for: directory)
            }
        }
    }

    private func show(_ repository: Git.Repository?, for directory: String) {
        guard let repository else {
            stopMonitoring()
            state = .notRepository(directory: directory)
            return
        }

        guard monitor?.repository != repository else { return }

        let monitor = GitRepositoryMonitor.monitor(for: repository)
        self.monitor = monitor
        let hookTracker = GitHookTracker.tracker(for: repository)
        self.hookTracker = hookTracker
        hookWatch = hookTracker.watch()
        state = monitor.status.map { .ready(repository, $0) } ?? .loading(repository)
        monitorCancellable = monitor.$status
            .compactMap { $0 }
            .sink { [weak self] status in
                self?.state = .ready(repository, status)
            }

        // A shared monitor may already have a status, but check again in case the
        // panel was hidden while things changed.
        monitor.setNeedsRefresh()
    }

    private func stopMonitoring() {
        monitorCancellable = nil
        monitor = nil
        hookWatch = nil
        hookTracker = nil
    }
}
