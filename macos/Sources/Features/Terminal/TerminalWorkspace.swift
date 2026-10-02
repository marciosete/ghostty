import AppKit
import Combine
import OSLog

/// Saves the open terminal windows and opens them again later: every tab in order with
/// its color, title, splits and working directories, the tab sidebar groups with their
/// names, colors and collapsed state, and the sidebar's folders and folder groups, with
/// the folders that have no sessions. A Claude Code or Codex session running in a
/// terminal is resumed in it (see `AgentSession`); other programs aren't, and the
/// terminal opens a new shell.
///
/// macOS state restoration only brings windows back when "Close windows when quitting
/// an application" is off in System Settings (it is on by default), and it forgets
/// windows that were closed before quitting. The saved workspace fills those gaps. It is
/// opened when Ghostty starts and macOS didn't restore any windows, and when the Dock
/// icon is clicked while no windows are open. Closing the last window doesn't clear it,
/// so it always holds the last windows that were open. Nothing is saved or restored with
/// `window-save-state = never`.
///
/// The saved workspace mirrors the open tabs, so on its own it would follow them into
/// any loss: twenty shells killed from outside close twenty tabs, and five seconds later
/// the workspace would hold the one left. Two things stand in the way of that. Every
/// version is also kept as a file (see `historyDirectory`), so the saved one is never the
/// only copy, and tabs closing because their processes ended are counted: several within
/// a few seconds are taken as lost, stay in the saved workspace until they are reopened
/// or let go, and the sidebar offers to reopen them (see `tabWillCloseBecauseProcessEnded`).
final class TerminalWorkspace: ObservableObject {
    static let shared = TerminalWorkspace()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "workspace")

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
    /// because the app quits, so the workspace keeps them. Sessions lost and not let go
    /// are saved with them, so they come back too.
    ///
    /// Returns true if the workspace was saved, in which case quitting doesn't need to be
    /// confirmed: the windows open again on the next launch.
    func saveBeforeQuitting() -> Bool {
        guard isEnabled else { return false }
        lossCheck?.cancel()
        lossCheck = nil
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

    /// While tabs are closing because their processes ended, nothing is saved: in a few
    /// seconds it is known whether they were lost.
    func save() {
        guard isEnabled, !isTerminating, closingDepth == 0, lossCheck == nil else { return }

        // Never replace the workspace with nothing, so that it survives closing the
        // last window.
        let windows = Self.openWindows()
        guard !windows.isEmpty else { return }

        guard var data = Self.encode(windows) else { return }
        if let pendingLoss {
            data = Self.merging(data, lost: pendingLoss.snapshot) ?? data
        }
        guard data != savedData else { return }
        persist(data)
        recordHistory(data)
    }

    private func persist(_ data: Data) {
        UserDefaults.ghostty.set(data, forKey: Self.defaultsKey)
        savedData = data
    }

    private static func encode(_ windows: [SavedWindow]) -> Data? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return try encoder.encode(Snapshot(
                stateVersion: TerminalRestorableState.version,
                windows: windows))
        } catch {
            logger.error("error saving workspace: \(error, privacy: .public)")
            return nil
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

    // MARK: History

    /// Where every version of the workspace is kept, as JSON files named by their time,
    /// so the saved one is never the only copy. A version kept because sessions were
    /// lost is named `…-lost-N`. The files are thinned (see `thinHistory`).
    static var historyDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty", isDirectory: true)
            .appendingPathComponent("Workspaces", isDirectory: true)
    }

    /// A kept version of the workspace.
    struct HistoryEntry: Identifiable, Equatable {
        let url: URL
        let date: Date

        /// How many sessions were lost right after this version, when it was kept for that.
        let lost: Int?

        var id: URL { url }
    }

    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }()

    /// The kept versions, newest first.
    static func history() -> [HistoryEntry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: historyDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url -> HistoryEntry? in
            guard url.pathExtension == "json" else { return nil }
            var name = url.deletingPathExtension().lastPathComponent
            var lost: Int?
            if let range = name.range(of: "-lost-") {
                lost = Int(name[range.upperBound...])
                name = String(name[..<range.lowerBound])
            }
            guard let date = historyDateFormatter.date(from: name) else { return nil }
            return HistoryEntry(url: url, date: date, lost: lost)
        }
        .sorted { $0.date > $1.date }
    }

    private func recordHistory(_ data: Data, lost: Int? = nil) {
        let directory = Self.historyDirectory
        var name = Self.historyDateFormatter.string(from: Date())
        if let lost { name += "-lost-\(lost)" }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name).appendingPathExtension("json"), options: .atomic)
        } catch {
            Self.logger.error("error keeping workspace history: \(error, privacy: .public)")
        }
        thinHistory()
    }

    /// Keeps every version of the last hour, one an hour for a day, one a day for a
    /// month, and every version kept for lost sessions up to a month old.
    private func thinHistory() {
        let now = Date()
        var hours = Set<Int>()
        var days = Set<Int>()
        for entry in Self.history() {
            let age = now.timeIntervalSince(entry.date)
            let keep: Bool
            if age > 30 * 86_400 {
                keep = false
            } else if entry.lost != nil || age <= 3_600 {
                keep = true
            } else if age <= 86_400 {
                keep = hours.insert(Int(entry.date.timeIntervalSince1970 / 3_600)).inserted
            } else {
                keep = days.insert(Int(entry.date.timeIntervalSince1970 / 86_400)).inserted
            }
            if !keep {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    // MARK: Lost Sessions

    /// How close together tabs have to close, because their processes ended, to count as
    /// lost together, and how many it takes. Someone typing `exit` in a few tabs is
    /// slower than this; a `pkill` that caught every shell isn't.
    private static let lossWindow: TimeInterval = 10
    private static let lossThreshold = 3

    /// Sessions lost together, waiting to be reopened or let go.
    struct PendingLoss: Equatable {
        let count: Int
        let date: Date

        /// The saved workspace from before they were lost.
        let snapshot: Data
    }

    /// The sessions lost and not yet reopened or let go. The sidebar shows them. Until
    /// they are let go they stay in the saved workspace, with whatever is open, so they
    /// come back on the next launch.
    @Published private(set) var pendingLoss: PendingLoss?

    private var lossTimes: [Date] = []

    /// The saved workspace from before the tabs now closing began to.
    private var snapshotBeforeLosses: Data?
    private var lossCheck: DispatchWorkItem?

    /// Called before a tab closes because its process ended on its own, as against being
    /// closed by hand. One or two in a row are shells that ended; several within a few
    /// seconds were killed from outside, and the workspace shouldn't follow them. The
    /// first one saves the workspace with every tab still in it; saving then waits for
    /// the burst to end, when many become a pending loss and a few are let go.
    func tabWillCloseBecauseProcessEnded() {
        guard isEnabled, !isTerminating else { return }

        let now = Date()
        lossTimes.removeAll { now.timeIntervalSince($0) > Self.lossWindow }
        if lossTimes.isEmpty {
            save()
            snapshotBeforeLosses = savedData
        }
        lossTimes.append(now)

        lossCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in self?.lossBurstEnded() }
        lossCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lossWindow, execute: check)
    }

    private func lossBurstEnded() {
        lossCheck = nil
        let count = lossTimes.count
        lossTimes = []
        defer { save() }
        guard count >= Self.lossThreshold, let before = snapshotBeforeLosses else { return }

        Self.logger.error("\(count, privacy: .public) sessions closed within \(Self.lossWindow, privacy: .public)s because their processes ended; keeping them in the workspace")
        recordHistory(before, lost: count)

        // Losses on top of a pending one add up, and the earlier snapshot has them all.
        if let pendingLoss, let merged = Self.merging(before, lost: pendingLoss.snapshot) {
            self.pendingLoss = PendingLoss(count: pendingLoss.count + count, date: Date(), snapshot: merged)
        } else {
            pendingLoss = PendingLoss(count: count, date: Date(), snapshot: before)
        }
    }

    /// Reopens the lost sessions that aren't open, where they were.
    func reopenLostSessions() {
        guard let pendingLoss else { return }
        reopenMissing(from: pendingLoss.snapshot)
        self.pendingLoss = nil
        save()
    }

    /// Lets the lost sessions go: the saved workspace follows the open tabs again.
    func dismissLostSessions() {
        pendingLoss = nil
        save()
    }

    /// `data` with the tabs of `lost` that aren't open now added to its first window, so a
    /// saved workspace keeps lost sessions along with what is open. Nil when either
    /// doesn't parse.
    static func merging(_ data: Data, lost: Data) -> Data? {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var windows = json["windows"] as? [[String: Any]],
              let lostJSON = try? JSONSerialization.jsonObject(with: lost) as? [String: Any],
              let lostWindows = lostJSON["windows"] as? [[String: Any]] else { return nil }

        let open = openIdentities()
        let missing = lostWindows
            .flatMap { $0["tabs"] as? [[String: Any]] ?? [] }
            .filter { identities(of: $0).isDisjoint(with: open) }
        guard !missing.isEmpty else { return data }

        if windows.isEmpty {
            json["windows"] = lostWindows
        } else {
            var first = windows[0]
            first["tabs"] = (first["tabs"] as? [[String: Any]] ?? []) + missing
            windows[0] = first
            json["windows"] = windows
        }
        return try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    // MARK: Reopening

    /// Opens the tabs of a saved workspace that aren't open now: in the window they were
    /// in while it still shows any of them, otherwise in a new window where theirs was.
    /// A tab is open when any of its terminals, or the agent session in one, is.
    /// Returns how many tabs were opened.
    @discardableResult
    func reopenMissing(from data: Data) -> Int {
        guard isEnabled, let ghostty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["stateVersion"] as? Int,
              version >= TerminalRestorableState.minimumVersion,
              let windows = json["windows"] as? [[String: Any]] else { return 0 }

        let open = Self.openIdentities()
        var opened = 0
        for var saved in windows {
            guard let tabs = saved["tabs"] as? [[String: Any]] else { continue }
            let missing = tabs.filter { Self.identities(of: $0).isDisjoint(with: open) }
            guard !missing.isEmpty else { continue }

            // Decoding a tab starts its terminals, so only the missing ones are decoded.
            saved["tabs"] = missing
            guard let windowData = try? JSONSerialization.data(withJSONObject: ["stateVersion": version, "windows": [saved]]),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: windowData),
                  let window = snapshot.windows.first else { continue }

            let host = tabs.lazy
                .filter { !Self.identities(of: $0).isDisjoint(with: open) }
                .compactMap { Self.openWindow(showing: Self.identities(of: $0)) }
                .first
            if let host {
                add(window.tabs, to: host, ghostty)
            } else {
                self.open(window, ghostty)
            }
            opened += missing.count
        }
        return opened
    }

    /// How many tabs of a saved workspace are open now, and how many aren't.
    static func count(_ data: Data) -> (open: Int, missing: Int)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = json["windows"] as? [[String: Any]] else { return nil }
        let open = openIdentities()
        var counts = (open: 0, missing: 0)
        for window in windows {
            for tab in window["tabs"] as? [[String: Any]] ?? [] {
                if identities(of: tab).isDisjoint(with: open) {
                    counts.missing += 1
                } else {
                    counts.open += 1
                }
            }
        }
        return counts
    }

    /// What identifies the terminals of a saved tab: their ids and their agent sessions'
    /// ids, however the session is saved (`claudeCodeSession`, or `agentSession` with the
    /// agent's record inside).
    private static func identities(of tab: [String: Any]) -> Set<String> {
        var found = Set<String>()
        func sessionIDs(_ node: Any) {
            guard let dictionary = node as? [String: Any] else { return }
            if let id = dictionary["id"] as? String, dictionary["cwd"] != nil { found.insert(id.lowercased()) }
            dictionary.values.forEach(sessionIDs)
        }
        func walk(_ node: Any) {
            if let dictionary = node as? [String: Any] {
                for (key, value) in dictionary {
                    if key == "uuid", let id = value as? String { found.insert(id.lowercased()) }
                    if key == "claudeCodeSession" || key == "agentSession" { sessionIDs(value) }
                    walk(value)
                }
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(tab["surfaceTree"] ?? [:])
        return found
    }

    /// The identities of every open tab, read the way they are saved.
    private static func openIdentities() -> Set<String> {
        guard let data = encode(openWindows()),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = json["windows"] as? [[String: Any]] else { return [] }
        var all = Set<String>()
        for window in windows {
            for tab in window["tabs"] as? [[String: Any]] ?? [] {
                all.formUnion(identities(of: tab))
            }
        }
        return all
    }

    /// The window of the open tab with any of `identities`.
    private static func openWindow(showing identities: Set<String>) -> NSWindow? {
        for controller in TerminalController.all {
            guard let window = controller.window else { continue }
            for surface in controller.surfaceTree.root?.leaves() ?? [] {
                if identities.contains(surface.id.uuidString.lowercased()) { return window }
                if let session = surface.agentSessionToSave(),
                   identities.contains(session.id.uuidString.lowercased()) { return window }
            }
        }
        return nil
    }

    /// Adds saved tabs to the end of a window's tabs, with their groups and folders.
    private func add(_ states: [TerminalRestorableState], to host: NSWindow, _ ghostty: Ghostty.App) {
        let selected = host.tabGroup?.selectedWindow ?? host
        for state in states {
            let controller = TerminalController(ghostty, withSurfaceTree: state.surfaceTree)
            state.apply(to: controller)
            guard let window = controller.window else { continue }
            let lastTab = host.tabGroup?.windows.last ?? host
            lastTab.addTabbedWindowSafely(window, ordered: .above)
            controller.showWindowSafely(nil)
        }
        selected.makeKeyAndOrderFront(nil)
        (selected.windowController as? TerminalController)?.relabelTabs()

        // The tabs' groups and folders put them back where they were in the sidebar.
        DispatchQueue.main.async {
            (selected as? TerminalWindow)?.tabSidebarModel.normalizeOrder()
        }
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
              let data = UserDefaults.ghostty.data(forKey: Self.defaultsKey),
              let snapshot = Self.decode(data) else { return false }

        savedData = data

        // Back to front, so the frontmost window ends up in front.
        for window in snapshot.windows.reversed() {
            open(window, ghostty)
        }

        return !snapshot.windows.isEmpty
    }

    private static func decode(_ data: Data) -> Snapshot? {
        do {
            let decoder = JSONDecoder()
            let version = try decoder.decode(SnapshotVersion.self, from: data).stateVersion
            guard version >= TerminalRestorableState.minimumVersion else {
                logger.error("error restoring workspace: version not supported: expected=\(TerminalRestorableState.minimumVersion, privacy: .public), got=\(version, privacy: .public)")
                return nil
            }
            return try decoder.decode(Snapshot.self, from: data)
        } catch {
            logger.error("error restoring workspace: \(error, privacy: .public)")
            return nil
        }
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
