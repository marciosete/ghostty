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
/// working directory of the window's focused terminal.
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

    private var directory: String?
    private var isVisible = false
    private var monitor: GitRepositoryMonitor?
    private var monitorCancellable: AnyCancellable?

    /// Incremented for every lookup so a slow, outdated lookup can't win over a newer one.
    private var lookupGeneration = 0

    /// Sets the working directory to show the repository of.
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

        guard isVisible else {
            stopMonitoring()
            return
        }

        guard let directory else {
            stopMonitoring()
            state = .noDirectory
            return
        }

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
    }
}
