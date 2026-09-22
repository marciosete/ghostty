import AppKit

/// Saves the open terminal windows and opens them again later: every tab in order with
/// its color, title, splits and working directories, and the tab sidebar groups with
/// their names, colors and collapsed state. A Claude Code session running in a terminal
/// is resumed in it (see `ClaudeCodeSession`); other programs aren't, and the terminal
/// opens a new shell.
///
/// macOS state restoration only brings windows back when "Close windows when quitting
/// an application" is off in System Settings (it is on by default), and it forgets
/// windows that were closed before quitting. The saved workspace fills those gaps. It is
/// opened when Ghostty starts and macOS didn't restore any windows, and when the Dock
/// icon is clicked while no windows are open. Closing the last window doesn't clear it,
/// so it always holds the last windows that were open. Nothing is saved or restored with
/// `window-save-state = never`.
final class TerminalWorkspace {
    static let shared = TerminalWorkspace()

    private static let defaultsKey = "TerminalWorkspace"

    /// Some of what is saved, such as a terminal's working directory, changes without
    /// notice, so the workspace is also saved on a timer. Unchanged state isn't rewritten.
    private static let autosaveInterval: TimeInterval = 5

    private struct SavedWindow: Codable {
        let frame: CGRect
        let selectedTab: Int
        let fullscreenMode: FullscreenMode?
        let tabs: [TerminalRestorableState]
    }

    private struct Snapshot: Codable {
        let stateVersion: Int
        /// Front to back.
        let windows: [SavedWindow]
    }

    /// Decoding a tab starts its terminals, so the version is checked on its own first.
    private struct SnapshotVersion: Decodable {
        let stateVersion: Int
    }

    private weak var ghostty: Ghostty.App?
    private var autosaveTimer: Timer?

    /// The data last written to or read from user defaults.
    private var savedData: Data?

    /// Greater than zero while several windows are closed together, after the state from
    /// before closing them was saved.
    private var closingDepth = 0

    private var isTerminating = false

    private init() {}

    private var isEnabled: Bool {
        guard let ghostty else { return false }
        return ghostty.config.windowSaveState != "never"
    }

    // MARK: Lifecycle

    /// Starts saving the workspace while the app runs.
    func start(_ ghostty: Ghostty.App) {
        self.ghostty = ghostty
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: Self.autosaveInterval, repeats: true) { [weak self] _ in
            self?.save()
        }
        autosaveTimer?.tolerance = 1
    }

    /// Saves the workspace one last time before the app quits. This must happen before
    /// termination starts, since AppKit takes windows out of their tab groups by the time
    /// `applicationWillTerminate` is called. Windows that close after this are closing
    /// because the app quits, so the workspace keeps them.
    ///
    /// Returns true if the workspace was saved, in which case quitting doesn't need to be
    /// confirmed: the windows open again on the next launch.
    func saveBeforeQuitting() -> Bool {
        guard isEnabled else { return false }
        save()
        isTerminating = true
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        return true
    }

    /// Called before terminal tabs or windows close, so that the workspace still has them
    /// if they were the last ones open.
    func windowsWillClose() {
        save()
    }

    /// Closes several windows as a single change, so the workspace keeps all of them if
    /// nothing is left open afterwards.
    func closeWindows(_ body: () -> Void) {
        save()
        closingDepth += 1
        defer { closingDepth -= 1 }
        body()
    }

    // MARK: Saving

    func save() {
        guard isEnabled, !isTerminating, closingDepth == 0 else { return }

        // Never replace the workspace with nothing, so that it survives closing the
        // last window.
        let windows = Self.openWindows()
        guard !windows.isEmpty else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(Snapshot(
                stateVersion: TerminalRestorableState.version,
                windows: windows))
            guard data != savedData else { return }
            UserDefaults.ghostty.set(data, forKey: Self.defaultsKey)
            savedData = data
        } catch {
            AppDelegate.logger.error("error saving workspace: \(error, privacy: .public)")
        }
    }

    /// The open terminal windows with their tabs, front to back.
    private static func openWindows() -> [SavedWindow] {
        let zOrder = NSApp.orderedWindows
        var seen = Set<ObjectIdentifier>()
        var windows: [(zIndex: Int, window: SavedWindow)] = []

        for controller in TerminalController.all {
            guard let window = controller.window else { continue }
            let tabWindows = window.tabGroup?.windows ?? [window]
            guard let firstTab = tabWindows.first,
                  seen.insert(ObjectIdentifier(firstTab)).inserted else { continue }

            // Tabs running a command given at launch aren't restorable, like with
            // macOS state restoration.
            let tabs = tabWindows
                .compactMap { $0.windowController as? TerminalController }
                .filter { ($0.window?.isRestorable ?? false) && !$0.surfaceTree.isEmpty }
            guard !tabs.isEmpty else { continue }

            let selectedWindow = window.tabGroup?.selectedWindow ?? window
            let selectedTab = tabs.firstIndex { $0.window === selectedWindow } ?? 0
            let fullscreenMode = tabs[selectedTab].fullscreenStyle.flatMap {
                $0.isFullscreen ? $0.fullscreenMode : nil
            }

            windows.append((
                zOrder.firstIndex(of: selectedWindow) ?? .max,
                SavedWindow(
                    frame: selectedWindow.frame,
                    selectedTab: selectedTab,
                    fullscreenMode: fullscreenMode,
                    tabs: tabs.map { TerminalRestorableState(from: $0) })))
        }

        return windows.sorted { $0.zIndex < $1.zIndex }.map(\.window)
    }

    // MARK: Restoring

    /// Opens the saved workspace when the app starts, unless macOS restored its windows.
    /// Windows that were opened for another reason, such as a folder dropped on the Dock
    /// icon, stay in front.
    func restoreAtLaunch() {
        guard !TerminalWindowRestoration.hasRestoredWindows else { return }
        let front = NSApp.orderedWindows.first { $0.windowController is TerminalController }
        guard restore() else { return }
        front?.makeKeyAndOrderFront(nil)
    }

    /// Opens the windows of the saved workspace. Returns false if there was nothing to open.
    @discardableResult
    func restore() -> Bool {
        guard isEnabled,
              let ghostty,
              let data = UserDefaults.ghostty.data(forKey: Self.defaultsKey) else { return false }

        let snapshot: Snapshot
        do {
            let decoder = JSONDecoder()
            let version = try decoder.decode(SnapshotVersion.self, from: data).stateVersion
            guard version >= TerminalRestorableState.minimumVersion else {
                AppDelegate.logger.error("error restoring workspace: version not supported: expected=\(TerminalRestorableState.minimumVersion, privacy: .public), got=\(version, privacy: .public)")
                return false
            }

            snapshot = try decoder.decode(Snapshot.self, from: data)
        } catch {
            AppDelegate.logger.error("error restoring workspace: \(error, privacy: .public)")
            return false
        }

        savedData = data

        // Back to front, so the frontmost window ends up in front.
        for window in snapshot.windows.reversed() {
            open(window, ghostty)
        }

        return !snapshot.windows.isEmpty
    }

    private func open(_ saved: SavedWindow, _ ghostty: Ghostty.App) {
        let controllers = saved.tabs.map { state in
            let controller = TerminalController(ghostty, withSurfaceTree: state.surfaceTree)
            state.apply(to: controller)
            return controller
        }
        guard let first = controllers.first, let firstWindow = first.window else { return }

        first.showWindow(nil)
        for controller in controllers.dropFirst() {
            guard let window = controller.window else { continue }
            let lastTab = firstWindow.tabGroup?.windows.last ?? firstWindow
            lastTab.addTabbedWindowSafely(window, ordered: .above)
            controller.showWindowSafely(nil)
        }

        let selected = controllers.indices.contains(saved.selectedTab)
            ? controllers[saved.selectedTab]
            : first
        guard let selectedWindow = selected.window else { return }
        selectedWindow.makeKeyAndOrderFront(nil)

        // Showing a window moves it to where the last window was, so put it back.
        selectedWindow.setFrame(saved.frame, display: true)
        selectedWindow.constrainToScreen()
        selected.relabelTabs()

        if let mode = saved.fullscreenMode {
            // Fullscreen needs the content view set up, which takes a main loop turn.
            DispatchQueue.main.async {
                selected.toggleFullscreen(mode: mode)
            }
        }
    }
}
