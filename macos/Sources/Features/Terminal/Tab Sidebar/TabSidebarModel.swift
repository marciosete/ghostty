import AppKit
import Combine
import GhosttyKit

extension Notification.Name {
    /// Posted by a `TerminalWindow` when something shown in the tab sidebar changes
    /// (tab color, group, keyboard shortcut label, zoom state). The object is the window.
    static let terminalTabSidebarItemDidChange = Notification.Name("com.mitchellh.ghostty.tabSidebarItemDidChange")
}

/// The state behind the vertical tab sidebar of a single terminal window.
///
/// Every tab is its own `TerminalWindow` inside a native `NSWindowTabGroup`, and every
/// window hosts its own sidebar. Only the selected tab's window is visible at a time,
/// so each model independently mirrors the native tab group it belongs to. The native
/// tab order is the source of truth, so keyboard shortcuts such as `goto_tab` always
/// match what the sidebar shows.
final class TabSidebarModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: ObjectIdentifier
        weak var window: TerminalWindow?
        let index: Int
        let title: String

        /// The color the tab is shown in (see `TerminalWindow.shownTabColor`).
        let color: TerminalTabColor

        /// The color assigned to the tab, which the color menu shows as selected.
        let assignedColor: TerminalTabColor

        /// For an `auto` tab, what its Claude Code sessions are doing.
        let claudeCodeState: ClaudeCodeTabState?

        /// When its Claude Code sessions changed what they were doing.
        let claudeCodeActivity: ClaudeCodeActivity
        /// Whether the tab offers to read its session's last response aloud, and whether it is.
        let canSpeak: Bool
        let isSpeaking: Bool
        let speechVoiceID: String?
        let keyEquivalent: String?
        let isSelected: Bool
        let isZoomed: Bool
        let groupID: UUID?
        let folderID: UUID?
        let folderGroupID: UUID?

        /// What the tab is in at each nesting level, outermost first.
        var nestingKeys: [UUID?] { [folderGroupID, folderID, groupID] }

        static func == (lhs: Tab, rhs: Tab) -> Bool {
            lhs.id == rhs.id &&
                lhs.index == rhs.index &&
                lhs.title == rhs.title &&
                lhs.color == rhs.color &&
                lhs.assignedColor == rhs.assignedColor &&
                lhs.claudeCodeState == rhs.claudeCodeState &&
                lhs.claudeCodeActivity == rhs.claudeCodeActivity &&
                lhs.canSpeak == rhs.canSpeak &&
                lhs.isSpeaking == rhs.isSpeaking &&
                lhs.speechVoiceID == rhs.speechVoiceID &&
                lhs.keyEquivalent == rhs.keyEquivalent &&
                lhs.isSelected == rhs.isSelected &&
                lhs.isZoomed == rhs.isZoomed &&
                lhs.groupID == rhs.groupID &&
                lhs.folderID == rhs.folderID &&
                lhs.folderGroupID == rhs.folderGroupID
        }
    }

    struct GroupSection: Identifiable, Equatable {
        let group: UserTabGroup
        let tabs: [Tab]

        /// A group's members are kept contiguous, but until that is enforced the same
        /// group can briefly appear twice, so the id includes the first tab index.
        var id: String { "\(group.id)-\(tabs.first?.index ?? 0)" }

        var containsSelectedTab: Bool { tabs.contains(where: \.isSelected) }

        /// What the members' Claude Code sessions are doing, shown on the header while
        /// the group is collapsed: the one that needs attention most.
        var claudeCodeLight: ClaudeCodeLight? {
            ClaudeCodeLight.mostUrgent(tabs.compactMap { $0.claudeCodeState?.light })
        }

        /// A member finished a request that hasn't been looked at.
        var hasFinishedUnseen: Bool { tabs.contains { $0.claudeCodeActivity.finishedUnseen } }
    }

    /// A folder with the sessions and groups in it. A folder can have none.
    struct FolderSection: Identifiable, Equatable {
        let folder: UserTabFolder

        /// Sessions and groups only; folders don't nest.
        let rows: [Row]

        /// Like a group's, in case a folder briefly shows twice.
        var id: String { "\(folder.id)-\(tabs.first?.index ?? -1)" }

        var tabs: [Tab] { rows.flatMap(\.allTabs) }

        var containsSelectedTab: Bool { tabs.contains(where: \.isSelected) }

        var claudeCodeLight: ClaudeCodeLight? {
            ClaudeCodeLight.mostUrgent(tabs.compactMap { $0.claudeCodeState?.light })
        }

        var hasFinishedUnseen: Bool { tabs.contains { $0.claudeCodeActivity.finishedUnseen } }
    }

    /// A folder group with its folders.
    struct FolderGroupSection: Identifiable, Equatable {
        let group: UserTabFolderGroup
        var folders: [FolderSection]

        var id: String { "\(group.id)-\(tabs.first?.index ?? -1)" }

        var tabs: [Tab] { folders.flatMap(\.tabs) }

        var containsSelectedTab: Bool { tabs.contains(where: \.isSelected) }

        var claudeCodeLight: ClaudeCodeLight? {
            ClaudeCodeLight.mostUrgent(tabs.compactMap { $0.claudeCodeState?.light })
        }

        var hasFinishedUnseen: Bool { tabs.contains { $0.claudeCodeActivity.finishedUnseen } }
    }

    enum Row: Identifiable, Equatable {
        case tab(Tab)
        case group(GroupSection)
        case folder(FolderSection)
        case folderGroup(FolderGroupSection)

        var id: String {
            switch self {
            case .tab(let tab): return "tab-\(tab.id.hashValue)"
            case .group(let section): return "group-\(section.id)"
            case .folder(let section): return "folder-\(section.id)"
            case .folderGroup(let section): return "folders-\(section.id)"
            }
        }

        /// Every session in the row, shown or collapsed away.
        var allTabs: [Tab] {
            switch self {
            case .tab(let tab): return [tab]
            case .group(let section): return section.tabs
            case .folder(let section): return section.tabs
            case .folderGroup(let section): return section.tabs
            }
        }
    }

    /// The rows to display: in native tab order, then the folders with no sessions in
    /// the order they were opened, each in its folder group where that group shows.
    @Published private(set) var rows: [Row] = []

    /// True when this window shows the sidebar instead of the native tab bar. This is
    /// set by the window.
    @Published var isActive: Bool = false {
        didSet {
            guard isActive != oldValue else { return }
            setNeedsRefresh()
        }
    }

    /// The color to paint the titlebar area above the terminal when the sidebar is active,
    /// since the titlebar itself is made transparent so the sidebar can extend under it.
    @Published var titlebarColor: NSColor?

    /// The modifiers of the `goto_tab` shortcuts. The shortcut labels show while exactly
    /// these are held.
    @Published private(set) var jumpModifiers: NSEvent.ModifierFlags?

    /// Where each tab's sessions work, by tab id. Read after the rows, so it can lag them.
    @Published private(set) var infos: [ObjectIdentifier: TabSidebarSessionInfo] = [:]

    /// The height of the titlebar that the sidebar and terminal content extend under.
    @Published var titlebarHeight: CGFloat = 0

    /// The tab currently being renamed inline, if any.
    @Published var editingTabID: ObjectIdentifier?

    /// The group currently being renamed inline, if any.
    @Published var editingGroupID: UUID?

    /// The folder currently being renamed inline, if any.
    @Published var editingFolderID: UUID?

    /// The folder group currently being renamed inline, if any.
    @Published var editingFolderGroupID: UUID?

    /// The text typed so far while renaming a tab, group, folder or folder group inline.
    @Published var editingDraft = ""

    /// What is typed in the search field. The sidebar shows only the sessions matching it.
    @Published var searchQuery = "" {
        didSet { if searchQuery != oldValue { searchHighlight = nil } }
    }

    /// The session the arrow keys moved to while searching, which Return opens. Nil for
    /// the first match.
    @Published private(set) var searchHighlight: ObjectIdentifier?

    /// Changed to put the keyboard in the search field.
    @Published private(set) var searchFocusRequest = 0

    private weak var hostWindow: TerminalWindow?

    /// The window showing this sidebar.
    var window: TerminalWindow? { hostWindow }
    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabGroupObservations: [NSKeyValueObservation] = []
    private var titleObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var refreshScheduled = false
    private let infoReader = TabSidebarSessionInfoReader()
    private var infoReadScheduled = false
    private var infoTimer: Timer?

    /// How often the info is read again while the sidebar shows, to catch a branch
    /// switched in the shell.
    private static let infoInterval: TimeInterval = 10

    init(hostWindow: TerminalWindow) {
        self.hostWindow = hostWindow

        let center = NotificationCenter.default
        Publishers.MergeMany(
            center.publisher(for: .terminalTabSidebarItemDidChange),
            center.publisher(for: NSWindow.didBecomeKeyNotification),
            center.publisher(for: NSWindow.willCloseNotification)
        )
        .sink { [weak self] _ in self?.setNeedsRefresh() }
        .store(in: &cancellables)

        UserTabGroupStore.shared.$groups
            .sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)

        UserTabFolderStore.shared.$folders
            .sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)

        UserTabFolderGroupStore.shared.$groups
            .sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
    }

    deinit {
        infoTimer?.invalidate()
        tabGroupObservations.forEach { $0.invalidate() }
        titleObservations.values.forEach { $0.invalidate() }
    }

    // MARK: Refresh

    /// Coalesces refreshes to once per main loop turn. This also means we never mutate
    /// KVO observations from inside a KVO callback, which AppKit does not like.
    func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    /// Refreshes right away instead of on the next main loop turn. A window that is
    /// about to be shown for the first time uses this so its first frame already lists
    /// the tabs instead of showing an empty sidebar that fills in a moment later.
    func refreshNow() {
        refresh()
    }

    private func refresh() {
        refreshScheduled = false

        guard isActive, let hostWindow else {
            rebindTabGroup(nil)
            rebindTitles([])
            if !rows.isEmpty { rows = [] }
            stopReadingInfo()
            return
        }

        let tabGroup = hostWindow.tabGroup
        rebindTabGroup(tabGroup)

        let windows = tabWindows
        rebindTitles(windows)
        unifyFolderSpace(windows)

        let selected = tabGroup?.selectedWindow ?? hostWindow
        let folders = UserTabFolderStore.shared
        let folderGroups = UserTabFolderGroupStore.shared
        let tabs = windows.enumerated().map { index, window in
            // Only what the stores know nests; the rest shows as plain.
            let folder = folders[window.userTabFolderID]
            return Tab(
                id: ObjectIdentifier(window),
                window: window,
                index: index,
                title: window.sessionTitle ?? window.title,
                color: window.shownTabColor,
                assignedColor: window.tabColor,
                claudeCodeState: window.claudeCodeState,
                claudeCodeActivity: window.claudeCodeActivity,
                canSpeak: window.canSpeakClaudeCodeResponse,
                isSpeaking: window.isSpeakingClaudeCodeResponse,
                speechVoiceID: window.speechVoiceID,
                keyEquivalent: window.keyEquivalent.flatMap { $0.isEmpty ? nil : $0 },
                isSelected: window === selected,
                isZoomed: window.surfaceIsZoomed,
                groupID: UserTabGroupStore.shared[window.userTabGroupID]?.id,
                folderID: folder?.id,
                folderGroupID: folderGroups[folder?.groupID]?.id)
        }

        var newRows = Self.rows(of: tabs[...], level: 0)

        // Folders with no sessions have no place in the tab order, so they come last,
        // except that one in a folder group that shows goes in with the group.
        var shownFolders = Set<UUID>()
        func collect(_ rows: [Row]) {
            for row in rows {
                switch row {
                case .tab, .group: break
                case .folder(let section): shownFolders.insert(section.folder.id)
                case .folderGroup(let section): section.folders.forEach { shownFolders.insert($0.folder.id) }
                }
            }
        }
        collect(newRows)
        for id in hostWindow.folderSpace.folderIDs where !shownFolders.contains(id) {
            guard let folder = folders[id] else { continue }
            let section = FolderSection(folder: folder, rows: [])
            guard let group = folderGroups[folder.groupID] else {
                newRows.append(.folder(section))
                continue
            }
            if let index = newRows.lastIndex(where: {
                if case .folderGroup(let shown) = $0 { return shown.group.id == group.id }
                return false
            }), case .folderGroup(var shown) = newRows[index] {
                shown.folders.append(section)
                newRows[index] = .folderGroup(shown)
            } else {
                newRows.append(.folderGroup(.init(group: group, folders: [section])))
            }
        }

        if newRows != rows { rows = newRows }

        // Refreshes run on the main loop.
        let jump = MainActor.assumeIsolated {
            hostWindow.terminalController?.ghostty.config.keyboardShortcut(for: "goto_tab:1")
                .map { NSEvent.ModifierFlags(swiftUIFlags: $0.modifiers) }
        }
        if jump != jumpModifiers { jumpModifiers = jump }

        // Only the sidebar that shows reads the info, since every tab's window has one.
        if selected === hostWindow {
            scheduleInfoRead()
        } else {
            stopReadingInfo()
        }

        // If the tab order was changed outside of the sidebar (e.g. "Merge All Windows"
        // or a move_tab keybind), a group or folder can end up split. Put it back
        // together. Only the selected window does this so the windows in a tab group
        // don't all race.
        if selected === hostWindow {
            var ids: [UUID] = []
            func collect(_ rows: [Row]) {
                for row in rows {
                    switch row {
                    case .tab: break
                    case .group(let section): ids.append(section.group.id)
                    case .folder(let section):
                        ids.append(section.folder.id)
                        collect(section.rows)
                    case .folderGroup(let section):
                        ids.append(section.group.id)
                        collect(section.folders.map(Row.folder))
                    }
                }
            }
            collect(newRows)
            if Set(ids).count != ids.count {
                DispatchQueue.main.async { [weak self] in self?.normalizeOrder() }
            }
        }
    }

    /// The rows for `tabs`, nesting from `level` in: runs of tabs in the same folder
    /// group, folder or group become one row each, with the rows of the runs inside it.
    /// Beyond the last level, every tab is a row.
    private static func rows(of tabs: ArraySlice<Tab>, level: Int) -> [Row] {
        guard level < 3 else { return tabs.map(Row.tab) }

        var result: [Row] = []
        var i = tabs.startIndex
        while i < tabs.endIndex {
            let key = tabs[i].nestingKeys[level]
            var j = i + 1
            while j < tabs.endIndex, tabs[j].nestingKeys[level] == key { j += 1 }
            let run = tabs[i..<j]
            let inner = rows(of: run, level: level + 1)
            i = j

            // Only keys the stores know are set, so the lookups don't fail.
            switch (level, key) {
            case (_, nil):
                result.append(contentsOf: inner)
            case (0, let id?):
                guard let group = UserTabFolderGroupStore.shared[id] else { continue }
                let folders = inner.compactMap { row -> FolderSection? in
                    if case .folder(let section) = row { return section }
                    return nil
                }
                result.append(.folderGroup(.init(group: group, folders: folders)))
            case (1, let id?):
                guard let folder = UserTabFolderStore.shared[id] else { continue }
                result.append(.folder(.init(folder: folder, rows: inner)))
            default:
                guard let group = UserTabGroupStore.shared[key] else { continue }
                result.append(.group(.init(group: group, tabs: Array(run))))
            }
        }
        return result
    }

    /// Points every tab's window at one set of folders: the first tab's, with the folders
    /// of the others added. A tab that joined the tab group with folders of its own
    /// brings them along, and restored tabs each come with a copy of the same folders.
    private func unifyFolderSpace(_ windows: [TerminalWindow]) {
        guard let space = windows.first?.folderSpace else { return }
        let store = UserTabFolderStore.shared
        for window in windows.dropFirst() where window.folderSpace !== space {
            window.folderSpace.folderIDs.forEach { space.add($0) }
            window.folderSpace = space
        }
        for window in windows {
            if let id = window.userTabFolderID {
                if store[id] != nil { space.add(id) } else { window.userTabFolderID = nil }
            }
        }
        space.folderIDs.removeAll { store[$0] == nil }
    }

    // MARK: Search

    var isSearching: Bool { !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The rows to show: all of them, or those matching the search.
    var shownRows: [Row] {
        TabSidebarSearch.filter(rows, query: searchQuery, infos: infos)
    }

    /// The session Return opens while searching.
    var highlightedTab: Tab? {
        guard isSearching else { return nil }
        let tabs = TabSidebarSearch.tabs(in: shownRows)
        return tabs.first { $0.id == searchHighlight } ?? tabs.first
    }

    func focusSearch() {
        searchFocusRequest += 1
    }

    /// Moves the highlight `offset` matches down, or up when negative.
    func moveSearchHighlight(by offset: Int) {
        let tabs = TabSidebarSearch.tabs(in: shownRows)
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == highlightedTab?.id } ?? 0
        searchHighlight = tabs[min(max(current + offset, 0), tabs.count - 1)].id
    }

    /// Opens the highlighted session and ends the search.
    func openSearchHighlight() {
        guard let window = highlightedTab?.window else { return }
        searchQuery = ""
        select(window)
        focusTerminal(of: window)
    }

    /// Clears the search and gives the keyboard back to the terminal.
    func endSearch() {
        searchQuery = ""
        if let hostWindow { focusTerminal(of: hostWindow) }
    }

    private func focusTerminal(of window: TerminalWindow) {
        guard let surface = window.terminalController?.focusedSurface else { return }
        window.makeFirstResponder(surface)
    }

    // MARK: Info

    private func scheduleInfoRead() {
        if infoTimer == nil {
            infoTimer = Timer.scheduledTimer(withTimeInterval: Self.infoInterval, repeats: true) { [weak self] _ in
                self?.scheduleInfoRead()
            }
            infoTimer?.tolerance = 2
        }

        guard !infoReadScheduled else { return }
        infoReadScheduled = true
        // Refreshes come in bursts; read once they settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.readInfo()
        }
    }

    private func stopReadingInfo() {
        infoTimer?.invalidate()
        infoTimer = nil
    }

    private func readInfo() {
        infoReadScheduled = false
        guard isActive else { return }

        // Reads run on the main loop.
        let requests = MainActor.assumeIsolated {
            tabWindows.map { window in
                let controller = window.terminalController
                let surfaces = controller?.surfaceTree.root?.leaves() ?? []
                return TabSidebarSessionInfoReader.Request(
                    id: ObjectIdentifier(window),
                    pids: surfaces.compactMap { $0.surfaceModel?.foregroundPID },
                    directory: controller?.focusedSurface?.pwd)
            }
        }
        infoReader.read(requests) { [weak self] infos in
            guard let self, infos != self.infos else { return }
            self.infos = infos
        }
    }

    private func rebindTabGroup(_ tabGroup: NSWindowTabGroup?) {
        guard observedTabGroup !== tabGroup || (tabGroup != nil && tabGroupObservations.isEmpty) else { return }
        tabGroupObservations.forEach { $0.invalidate() }
        tabGroupObservations = []
        observedTabGroup = tabGroup
        guard let tabGroup else { return }

        tabGroupObservations = [
            tabGroup.observe(\.windows, options: []) { [weak self] _, _ in self?.setNeedsRefresh() },
            tabGroup.observe(\.selectedWindow, options: []) { [weak self] _, _ in self?.setNeedsRefresh() },
        ]
    }

    private func rebindTitles(_ windows: [TerminalWindow]) {
        let ids = Set(windows.map(ObjectIdentifier.init))
        for (id, observation) in titleObservations where !ids.contains(id) {
            observation.invalidate()
            titleObservations[id] = nil
        }

        for window in windows where titleObservations[ObjectIdentifier(window)] == nil {
            titleObservations[ObjectIdentifier(window)] = window.observe(\.title, options: []) { [weak self] _, _ in
                self?.setNeedsRefresh()
            }
        }
    }

    // MARK: Queries

    /// The terminal windows in this window's native tab group, in tab order.
    private var tabWindows: [TerminalWindow] {
        guard let hostWindow else { return [] }
        guard let windows = hostWindow.tabGroup?.windows else { return [hostWindow] }
        return windows.compactMap { $0 as? TerminalWindow }
    }

    /// The user groups that currently have tabs in this window.
    var groupsInWindow: [UserTabGroup] {
        var seen = Set<UUID>()
        return tabWindows.compactMap { window in
            guard let id = window.userTabGroupID, seen.insert(id).inserted else { return nil }
            return UserTabGroupStore.shared[id]
        }
    }

    /// The folders open in this window, in the order they were opened.
    var foldersInWindow: [UserTabFolder] {
        hostWindow?.folderSpace.folderIDs.compactMap { UserTabFolderStore.shared[$0] } ?? []
    }

    private func members(of groupID: UUID) -> [TerminalWindow] {
        tabWindows.filter { $0.userTabGroupID == groupID }
    }

    private func members(ofFolder folderID: UUID) -> [TerminalWindow] {
        tabWindows.filter { $0.userTabFolderID == folderID }
    }

    /// The folder a group is in: its first member's.
    func folder(ofGroup groupID: UUID) -> UUID? {
        members(of: groupID).first?.userTabFolderID
    }

    // MARK: Tab Actions

    func select(_ window: TerminalWindow) {
        commitEditing()
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ window: TerminalWindow) {
        guard let controller = window.terminalController else { return }

        // A confirmation sheet can only be shown on a visible window, so bring the tab
        // forward first if closing it will need one.
        if window !== hostWindow?.tabGroup?.selectedWindow,
           controller.surfaceTree.contains(where: { $0.needsConfirmQuit }) {
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { controller.closeTab(nil) }
            return
        }

        controller.closeTab(nil)
    }

    func closeOthers(_ window: TerminalWindow) {
        window.terminalController?.closeOtherTabs(nil)
    }

    func closeBelow(_ window: TerminalWindow) {
        window.terminalController?.closeTabsOnTheRight(nil)
    }

    func moveToNewWindow(_ window: TerminalWindow) {
        window.moveTabToNewWindow(nil)
    }

    func beginRename(_ window: TerminalWindow) {
        commitEditing()
        editingDraft = window.terminalController?.renameDraft ?? window.title
        editingTabID = ObjectIdentifier(window)
    }

    func setColor(_ color: TerminalTabColor, for window: TerminalWindow) {
        window.pickTabColor(color)
    }

    /// Opens a new tab. With a group, the tab is added to the end of that group, in the
    /// group's folder; with a folder, to the end of that folder; otherwise it is added to
    /// the end of the tab list in neither. The new tab inherits the working directory of
    /// a terminal in that group, so it opens in the group's project even when the
    /// selected tab belongs to another group. Without a group, it inherits from this
    /// window's focused terminal. In a folder, it starts in the folder's directory
    /// whatever it would inherit. With `configuration`, its directory, input and
    /// environment override all of that: a pivot starts another agent in a session's
    /// own directory. Returns the new tab's window.
    @discardableResult
    func newTab(
        inGroup groupID: UUID? = nil,
        inFolder: UUID? = nil,
        configuration: Ghostty.SurfaceConfiguration? = nil
    ) -> TerminalWindow? {
        guard let hostWindow,
              let hostController = hostWindow.terminalController else { return nil }

        // Named apart from `folder(ofGroup:)`: a local `folder` next to that call reads
        // as a circular reference to Xcode 26's compiler.
        let folderID = groupID.flatMap { self.folder(ofGroup: $0) } ?? inFolder
        let tabFolder = UserTabFolderStore.shared[folderID]

        let anchor: NSWindow
        var source: TerminalWindow = hostWindow
        if let groupID, let last = members(of: groupID).last {
            anchor = last
            if let selected = hostWindow.tabGroup?.selectedWindow as? TerminalWindow,
               selected.userTabGroupID == groupID {
                source = selected
            } else {
                source = last
            }
        } else if let folderID, let last = members(ofFolder: folderID).last {
            anchor = last
            source = last
        } else {
            anchor = tabWindows.last ?? hostWindow
        }

        var baseConfig: Ghostty.SurfaceConfiguration?
        if let surface = source.terminalController?.focusedSurface?.surface {
            baseConfig = .init(from: ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_TAB))
        }
        if let tabFolder {
            var config = baseConfig ?? Ghostty.SurfaceConfiguration()
            config.workingDirectory = tabFolder.path
            baseConfig = config
        }
        if let configuration {
            var config = baseConfig ?? Ghostty.SurfaceConfiguration()
            config.workingDirectory = configuration.workingDirectory ?? config.workingDirectory
            config.initialInput = configuration.initialInput
            config.environmentVariables.merge(configuration.environmentVariables) { _, new in new }
            baseConfig = config
        }

        guard let controller = TerminalController.newTab(
            hostController.ghostty,
            from: anchor,
            withBaseConfig: baseConfig),
              let window = controller.window as? TerminalWindow else { return nil }

        window.userTabGroupID = groupID
        window.userTabFolderID = tabFolder?.id
        if let groupID {
            UserTabGroupStore.shared.update(groupID) { $0.isCollapsed = false }
        }
        if let tabFolder {
            UserTabFolderStore.shared.update(tabFolder.id) { $0.isCollapsed = false }
        }

        // The group changed after the new tab was prepared, so the sidebar it shows
        // first would still list it under the old group.
        window.prepareTabSidebarForDisplay()

        // The tab group takes a main loop turn to settle after adding a tab.
        DispatchQueue.main.async { [weak self] in self?.normalizeOrder() }
        return window
    }

    // MARK: Pivoting

    /// The handoff each pivoted session started from, so a session pivoted again
    /// carries the whole chain with it, not just its own part.
    private var handoffs: [ObjectIdentifier: URL] = [:]

    /// Opens a new session of `agent` beside `window`, in the same group and in the
    /// directory of `window`'s session, which is its worktree when it has one, so the
    /// files carry over. With `carryingConversation`, the session's conversation is
    /// written out and the new agent starts by reading it. The old session stays.
    func pivot(_ window: TerminalWindow, to agent: CodingAgent, carryingConversation: Bool) {
        let info = infos[ObjectIdentifier(window)]
        let session = info?.sessions.first
        let directory = session?.cwd ?? info?.directory
            ?? window.terminalController?.focusedSurface?.pwd

        var prompt: String?
        if carryingConversation, let session, let transcript = session.transcript {
            let earlier = handoffs[ObjectIdentifier(window)].flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            let entries = AgentHandoff.entries(inTranscript: transcript, of: session.agent)
            let markdown = AgentHandoff.markdown(entries: entries, from: session.agent, to: agent, earlier: earlier)
            do {
                let handoff = try AgentHandoff.write(markdown, from: session.agent, session: session.id)
                prompt = AgentHandoff.prompt(from: session.agent, handoff: handoff)
                pendingHandoff = handoff
            } catch {
                Self.showPivotFailure(error, in: window)
                return
            }
        }

        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = directory
        config.initialInput = AgentHandoff.command(for: agent, prompt: prompt) + "\n"
        config.environmentVariables = [
            AgentStart.environmentVariable: "1",
            AgentStart.agentEnvironmentVariable: agent.rawValue,
        ]
        let opened = newTab(inGroup: window.userTabGroupID, inFolder: window.userTabFolderID, configuration: config)
        if let opened, let handoff = pendingHandoff {
            handoffs[ObjectIdentifier(opened)] = handoff
        }
        pendingHandoff = nil
    }

    private var pendingHandoff: URL?

    private static func showPivotFailure(_ error: Error, in window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The conversation couldn't be written out"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    // MARK: Folder Actions

    /// Opens a directory as a folder in this window's sidebar, with no sessions yet.
    /// Returns the folder's id.
    @discardableResult
    func openFolder(at url: URL) -> UUID? {
        guard let hostWindow else { return nil }
        let folder = UserTabFolderStore.shared.create(path: url.path)
        hostWindow.folderSpace.add(folder.id)
        hostWindow.invalidateRestorableState()
        hostWindow.postTabSidebarItemDidChange()
        return folder.id
    }

    /// Asks for directories to open as folders.
    func presentOpenFolderPanel() {
        presentOpenFolderPanel { [weak self] urls in
            urls.forEach { self?.openFolder(at: $0) }
        }
    }

    private func presentOpenFolderPanel(_ open: @escaping ([URL]) -> Void) {
        guard let hostWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose a folder to open sessions in"
        panel.beginSheetModal(for: hostWindow) { response in
            guard response == .OK else { return }
            open(panel.urls)
        }
    }

    func add(_ window: TerminalWindow, toFolder folderID: UUID) {
        // A grouped session takes its group along.
        if let groupID = window.userTabGroupID {
            add(group: groupID, toFolder: folderID)
            return
        }
        window.userTabFolderID = folderID
        UserTabFolderStore.shared.update(folderID) { $0.isCollapsed = false }
        normalizeOrder()
    }

    func removeFromFolder(_ window: TerminalWindow) {
        if let groupID = window.userTabGroupID {
            removeGroupFromFolder(groupID)
            return
        }
        window.userTabFolderID = nil
        normalizeOrder()
    }

    func add(group groupID: UUID, toFolder folderID: UUID) {
        for window in members(of: groupID) {
            window.userTabFolderID = folderID
        }
        UserTabFolderStore.shared.update(folderID) { $0.isCollapsed = false }
        normalizeOrder()
    }

    func removeGroupFromFolder(_ groupID: UUID) {
        for window in members(of: groupID) {
            window.userTabFolderID = nil
        }
        normalizeOrder()
    }

    /// Opens a new session in the folder and puts it in a new group, then starts
    /// renaming the group. A group can't be empty.
    func createGroup(inFolder folderID: UUID) {
        guard let window = newTab(inFolder: folderID) else { return }
        createGroup(with: window)
    }

    func beginRename(folder folderID: UUID) {
        commitEditing()
        editingDraft = UserTabFolderStore.shared[folderID]?.name ?? ""
        editingFolderID = folderID
    }

    func toggleCollapsed(folder folderID: UUID) {
        UserTabFolderStore.shared.update(folderID) { $0.isCollapsed.toggle() }
    }

    func revealInFinder(folder folderID: UUID) {
        guard let folder = UserTabFolderStore.shared[folderID] else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder.url])
    }

    /// Takes the folder out of the sidebar. Its sessions stay, outside any folder.
    func removeFolder(_ folderID: UUID) {
        guard let hostWindow else { return }
        for window in members(ofFolder: folderID) {
            window.userTabFolderID = nil
        }
        Self.forget([folderID], in: hostWindow.folderSpace)
    }

    /// Takes folders out of a sidebar's folders and the registry, with any folder group
    /// left with no folders, and has the sidebar redraw. The windows showing them are
    /// found through the space, since the one that asked may be closing.
    private static func forget(_ folderIDs: [UUID], in space: TabSidebarFolderSpace) {
        let store = UserTabFolderStore.shared
        let groupIDs = Set(folderIDs.compactMap { store[$0]?.groupID })
        for folderID in folderIDs {
            space.remove(folderID)
            store.remove(folderID)
        }
        for groupID in groupIDs where !store.folders.values.contains(where: { $0.groupID == groupID }) {
            UserTabFolderGroupStore.shared.remove(groupID)
        }
        for case let window as TerminalWindow in NSApp.windows where window.folderSpace === space {
            window.invalidateRestorableState()
            window.postTabSidebarItemDidChange()
        }
    }

    /// Closes the folder's sessions, then takes the folder out of the sidebar.
    func closeFolder(_ folderID: UUID) {
        close(
            folders: [folderID],
            actionName: "Close Folder",
            messageText: "Close Folder?",
            informativeText: "At least one session in this folder still has a running process. If you close the folder the processes will be killed.")
    }

    private func close(folders folderIDs: [UUID], actionName: String, messageText: String, informativeText: String) {
        guard let hostWindow, let hostController = hostWindow.terminalController else { return }
        let controllers = folderIDs.flatMap { members(ofFolder: $0) }.compactMap(\.terminalController)
        let space = hostWindow.folderSpace
        guard !controllers.isEmpty else {
            Self.forget(folderIDs, in: space)
            return
        }

        let closeAll = {
            hostController.undoManager?.beginUndoGrouping()
            defer {
                hostController.undoManager?.setActionName(actionName)
                hostController.undoManager?.endUndoGrouping()
            }

            TerminalWorkspace.shared.closeWindows {
                for controller in controllers {
                    controller.closeTabImmediately(registerRedo: false)
                }
            }
            Self.forget(folderIDs, in: space)
        }

        let needsConfirm = controllers.contains { controller in
            controller.surfaceTree.contains(where: { $0.needsConfirmQuit })
        }
        guard needsConfirm else {
            closeAll()
            return
        }

        hostController.confirmClose(messageText: messageText, informativeText: informativeText) {
            closeAll()
        }
    }

    // MARK: Group Actions

    /// Creates a new group containing the given tab and starts renaming it.
    func createGroup(with window: TerminalWindow) {
        let store = UserTabGroupStore.shared
        let group = store.create(name: store.nextDefaultName())
        window.userTabGroupID = group.id
        normalizeOrder()
        beginRename(group: group.id)
    }

    /// Adds a tab to a group, and so to the group's folder.
    func add(_ window: TerminalWindow, to groupID: UUID) {
        window.userTabFolderID = folder(ofGroup: groupID)
        window.userTabGroupID = groupID
        UserTabGroupStore.shared.update(groupID) { $0.isCollapsed = false }
        normalizeOrder()
    }

    func removeFromGroup(_ window: TerminalWindow) {
        window.userTabGroupID = nil
        normalizeOrder()
    }

    func beginRename(group groupID: UUID) {
        commitEditing()
        editingDraft = UserTabGroupStore.shared[groupID]?.name ?? ""
        editingGroupID = groupID
    }

    func setColor(_ color: TerminalTabColor, forGroup groupID: UUID) {
        UserTabGroupStore.shared.update(groupID) { $0.color = color }
    }

    func toggleCollapsed(_ groupID: UUID) {
        UserTabGroupStore.shared.update(groupID) { $0.isCollapsed.toggle() }
    }

    func ungroup(_ groupID: UUID) {
        for window in members(of: groupID) {
            window.userTabGroupID = nil
        }
        UserTabGroupStore.shared.remove(groupID)
    }

    func closeGroup(_ groupID: UUID) {
        guard let hostController = hostWindow?.terminalController else { return }
        let controllers = members(of: groupID).compactMap(\.terminalController)
        guard !controllers.isEmpty else { return }

        let closeAll = {
            hostController.undoManager?.beginUndoGrouping()
            defer {
                hostController.undoManager?.setActionName("Close Group")
                hostController.undoManager?.endUndoGrouping()
            }

            TerminalWorkspace.shared.closeWindows {
                for controller in controllers {
                    controller.closeTabImmediately(registerRedo: false)
                }
            }
        }

        let needsConfirm = controllers.contains { controller in
            controller.surfaceTree.contains(where: { $0.needsConfirmQuit })
        }
        guard needsConfirm else {
            closeAll()
            return
        }

        hostController.confirmClose(
            messageText: "Close Group?",
            informativeText: "At least one session in this group still has a running process. If you close the group the processes will be killed."
        ) {
            closeAll()
        }
    }

    /// Finishes an inline rename, keeping what was typed. This is called whenever
    /// something else happens (switching tabs, the window losing focus, starting another
    /// rename) so a rename can never be left half done.
    func commitEditing() {
        let name = editingDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        if let tabID = editingTabID,
           let window = tabWindows.first(where: { ObjectIdentifier($0) == tabID }) {
            // An empty title goes back to the title set by the terminal.
            window.terminalController?.titleOverride = name.isEmpty ? nil : name
        } else if let groupID = editingGroupID, !name.isEmpty {
            UserTabGroupStore.shared.update(groupID) { $0.name = name }
        } else if let folderID = editingFolderID, !name.isEmpty {
            UserTabFolderStore.shared.update(folderID) { $0.name = name }
        } else if let groupID = editingFolderGroupID, !name.isEmpty {
            UserTabFolderGroupStore.shared.update(groupID) { $0.name = name }
        }

        endEditing()
    }

    /// Abandons an inline rename.
    func cancelEditing() {
        endEditing()
    }

    private func endEditing() {
        guard editingTabID != nil || editingGroupID != nil || editingFolderID != nil || editingFolderGroupID != nil else { return }
        editingTabID = nil
        editingGroupID = nil
        editingFolderID = nil
        editingFolderGroupID = nil

        // Inline editing takes focus away from the terminal, so give it back.
        guard let hostWindow,
              let surface = hostWindow.terminalController?.focusedSurface else { return }
        hostWindow.makeFirstResponder(surface)
    }

    // MARK: Folder Group Actions

    /// The folder groups with folders in this window, in the order the folders were
    /// opened.
    var folderGroupsInWindow: [UserTabFolderGroup] {
        var seen = Set<UUID>()
        return foldersInWindow.compactMap { folder in
            guard let id = folder.groupID, seen.insert(id).inserted else { return nil }
            return UserTabFolderGroupStore.shared[id]
        }
    }

    private func folders(inGroup groupID: UUID) -> [UserTabFolder] {
        foldersInWindow.filter { $0.groupID == groupID }
    }

    /// Creates a new folder group containing the given folder and starts renaming it.
    func createFolderGroup(with folderID: UUID) {
        let store = UserTabFolderGroupStore.shared
        let group = store.create(name: store.nextDefaultName())
        UserTabFolderStore.shared.update(folderID) { $0.groupID = group.id }
        normalizeOrder()
        beginRename(folderGroup: group.id)
    }

    func add(folder folderID: UUID, toFolderGroup groupID: UUID) {
        UserTabFolderStore.shared.update(folderID) { $0.groupID = groupID }
        UserTabFolderGroupStore.shared.update(groupID) { $0.isCollapsed = false }
        normalizeOrder()
    }

    func removeFolderFromGroup(_ folderID: UUID) {
        guard let groupID = UserTabFolderStore.shared[folderID]?.groupID else { return }
        UserTabFolderStore.shared.update(folderID) { $0.groupID = nil }
        removeFolderGroupIfEmpty(groupID)
        normalizeOrder()
    }

    /// Asks for directories to open as folders in the group.
    func presentOpenFolderPanel(inFolderGroup groupID: UUID) {
        presentOpenFolderPanel { [weak self] urls in
            for url in urls {
                guard let folderID = self?.openFolder(at: url) else { continue }
                UserTabFolderStore.shared.update(folderID) { $0.groupID = groupID }
            }
            self?.normalizeOrder()
        }
    }

    func beginRename(folderGroup groupID: UUID) {
        commitEditing()
        editingDraft = UserTabFolderGroupStore.shared[groupID]?.name ?? ""
        editingFolderGroupID = groupID
    }

    func toggleCollapsed(folderGroup groupID: UUID) {
        UserTabFolderGroupStore.shared.update(groupID) { $0.isCollapsed.toggle() }
    }

    /// Dissolves the folder group. Its folders stay, outside any group.
    func ungroupFolders(_ groupID: UUID) {
        for folder in folders(inGroup: groupID) {
            UserTabFolderStore.shared.update(folder.id) { $0.groupID = nil }
        }
        UserTabFolderGroupStore.shared.remove(groupID)
    }

    /// Closes the sessions of every folder in the group, then takes the folders and the
    /// group out of the sidebar.
    func closeFolderGroup(_ groupID: UUID) {
        close(
            folders: folders(inGroup: groupID).map(\.id),
            actionName: "Close Folder Group",
            messageText: "Close Folder Group?",
            informativeText: "At least one session in these folders still has a running process. If you close the folder group the processes will be killed.")
    }

    private func removeFolderGroupIfEmpty(_ groupID: UUID) {
        guard !UserTabFolderStore.shared.folders.values.contains(where: { $0.groupID == groupID }) else { return }
        UserTabFolderGroupStore.shared.remove(groupID)
    }

    // MARK: Reordering

    /// A tab as `TabSidebarOrder` sees it. The keys are read from the window as they are,
    /// so they are live.
    private struct Entry: TabSidebarOrderItem {
        let window: NSWindow

        var nestingKeys: [UUID?] {
            let window = window as? TerminalWindow
            let folderID = window?.userTabFolderID
            return [UserTabFolderStore.shared[folderID]?.groupID, folderID, window?.userTabGroupID]
        }

        static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.window === rhs.window }
    }

    /// Drops a tab before or after another tab. The dropped tab joins the target's group
    /// and folder.
    func drop(_ window: TerminalWindow, relativeTo target: TerminalWindow, after: Bool) {
        guard window !== target else { return }
        let others = tabWindows.filter { $0 !== window }
        guard let targetIndex = others.firstIndex(of: target) else { return }
        move(window,
             to: after ? targetIndex + 1 : targetIndex,
             groupID: target.userTabGroupID,
             folderID: target.userTabFolderID)
    }

    /// Drops a tab onto a group header, adding it to the start of that group, in the
    /// group's folder.
    func drop(_ window: TerminalWindow, ontoGroup groupID: UUID) {
        let others = tabWindows.filter { $0 !== window }
        guard let firstMember = others.firstIndex(where: { $0.userTabGroupID == groupID }) else { return }
        move(window, to: firstMember, groupID: groupID, folderID: others[firstMember].userTabFolderID)
    }

    /// Drops a tab onto a folder header, adding it to the start of that folder, in no
    /// group. An empty folder shows after every tab, so the tab goes to the end.
    func drop(_ window: TerminalWindow, ontoFolder folderID: UUID) {
        let others = tabWindows.filter { $0 !== window }
        let index = others.firstIndex { $0.userTabFolderID == folderID } ?? others.count
        move(window, to: index, groupID: nil, folderID: folderID)
    }

    /// Drops a tab before or after a group, folder or folder group, outside it: beside a
    /// group it stays in the group's folder; beside a folder it leaves the folder, and the
    /// folder group too when there is one, since those hold only folders. Beside a block
    /// with no tabs, such as an empty folder, is the end.
    func drop(_ window: TerminalWindow, beside block: TabSidebarOrder.Block, after: Bool) {
        let others = tabWindows.filter { $0 !== window }
        let entries = others.map(Entry.init)
        guard let first = entries.first(where: { $0.nestingKeys[block.level] == block.id }) else {
            dropAtEnd(window)
            return
        }

        let landing = TabSidebarOrder.landing(beside: first, from: block.level, of: Self.tabLevel, among: entries)
        let anchor = after ? landing.anchors.last : landing.anchors.first
        guard let anchor, let position = others.firstIndex(where: { $0 === anchor.window }) else {
            dropAtEnd(window)
            return
        }
        move(window,
             to: after ? position + 1 : position,
             groupID: landing.keys[TabSidebarOrder.Level.group],
             folderID: landing.keys[TabSidebarOrder.Level.folder])
    }

    /// Drops a tab below the last tab, moving it to the end outside any group or folder.
    func dropAtEnd(_ window: TerminalWindow) {
        let others = tabWindows.filter { $0 !== window }
        move(window, to: others.count, groupID: nil, folderID: nil)
    }

    /// Moves a tab to a new position. `index` is the position among the other tabs
    /// (i.e. excluding the moved tab), and `groupID` and `folderID` are the group and
    /// folder it should now belong to. The tab may come from another window's tab group,
    /// in which case it moves here, leaving that window's folders behind.
    func move(_ window: TerminalWindow, to index: Int, groupID: UUID?, folderID: UUID?) {
        guard let hostWindow else { return }

        // If the tab comes from another window, move it into our tab group first.
        if let tabGroup = hostWindow.tabGroup, !tabGroup.windows.contains(window) {
            window.tabGroup?.removeWindow(window)
            window.folderSpace = TabSidebarFolderSpace()
            let anchor = tabGroup.windows.last ?? hostWindow
            anchor.addTabbedWindowSafely(window, ordered: .above)
        }

        window.userTabGroupID = groupID
        window.userTabFolderID = folderID
        if let groupID {
            UserTabGroupStore.shared.update(groupID) { $0.isCollapsed = false }
        }
        if let folderID {
            UserTabFolderStore.shared.update(folderID) { $0.isCollapsed = false }
        }

        var order: [NSWindow] = hostWindow.tabGroup?.windows.filter { $0 !== window } ?? []
        order.insert(window, at: min(max(index, 0), order.count))
        apply(order: nestedOrder(order), select: window)
    }

    /// A tab, as a level below every block.
    private static let tabLevel = 3

    /// Where a dragged group, folder or folder group is dropped.
    enum BlockDestination {
        /// Next to a tab, or next to whatever it is in.
        case tab(TerminalWindow)

        /// Next to a group, or whatever it is in.
        case group(UUID)

        /// Next to a folder, or its folder group.
        case folder(UUID)

        /// Next to a folder group.
        case folderGroup(UUID)

        /// After every tab.
        case end
    }

    /// Moves every tab of a group together, before or after `destination`, outside
    /// whatever that is. The tabs keep their order and their group, and take the folder
    /// of where they land (see `TabSidebarOrder.landing`).
    func moveGroup(_ groupID: UUID, to destination: BlockDestination, after: Bool) {
        guard let hostWindow, let tabGroup = hostWindow.tabGroup else { return }
        let block = TabSidebarOrder.Block.group(groupID)
        guard let moved = Self.order(tabGroup.windows, moving: block, to: destination, after: after) else { return }

        let folderID = moved.keys?[TabSidebarOrder.Level.folder]
        for window in members(of: groupID) {
            window.userTabFolderID = folderID
        }
        if let folderID {
            UserTabFolderStore.shared.update(folderID) { $0.isCollapsed = false }
        }
        apply(order: nestedOrder(moved.order), select: nil)
    }

    /// Drops a group onto a folder header, adding it to the start of that folder.
    func drop(group groupID: UUID, ontoFolder folderID: UUID) {
        // Before the folder's first other tab, or at the end when it has none.
        if let first = members(ofFolder: folderID).first(where: { $0.userTabGroupID != groupID }) {
            moveGroup(groupID, to: .tab(first), after: false)
        } else {
            moveGroup(groupID, to: .end, after: false)
            for window in members(of: groupID) {
                window.userTabFolderID = folderID
            }
            UserTabFolderStore.shared.update(folderID) { $0.isCollapsed = false }
            normalizeOrder()
        }
    }

    /// Moves every tab of a folder together, before or after `destination`, outside
    /// whatever that is. The tabs keep their order, their groups and their folder, and the
    /// folder takes the folder group of where it lands.
    func moveFolder(_ folderID: UUID, to destination: BlockDestination, after: Bool) {
        guard let hostWindow, let tabGroup = hostWindow.tabGroup else { return }
        let block = TabSidebarOrder.Block.folder(folderID)
        guard let moved = Self.order(tabGroup.windows, moving: block, to: destination, after: after) else { return }

        let store = UserTabFolderStore.shared
        let groupID = moved.keys?[TabSidebarOrder.Level.folderGroup]
        let oldGroupID = store[folderID]?.groupID
        store.update(folderID) { $0.groupID = groupID }
        if let groupID {
            UserTabFolderGroupStore.shared.update(groupID) { $0.isCollapsed = false }
        }
        if let oldGroupID, oldGroupID != groupID {
            removeFolderGroupIfEmpty(oldGroupID)
        }
        apply(order: nestedOrder(moved.order), select: nil)
    }

    /// Drops a folder onto a folder group header, adding it to the start of that group.
    func drop(folder folderID: UUID, ontoFolderGroup groupID: UUID) {
        // Before the group's first other folder, or just into the group when none shows.
        let store = UserTabFolderStore.shared
        if let first = tabWindows.first(where: { store[$0.userTabFolderID]?.groupID == groupID && $0.userTabFolderID != folderID }),
           let firstFolder = first.userTabFolderID {
            moveFolder(folderID, to: .folder(firstFolder), after: false)
        } else {
            add(folder: folderID, toFolderGroup: groupID)
        }
    }

    /// Moves every tab of a folder group together, before or after `destination`. The
    /// tabs keep their order and everything they are in.
    func moveFolderGroup(_ groupID: UUID, to destination: BlockDestination, after: Bool) {
        guard let hostWindow, let tabGroup = hostWindow.tabGroup else { return }
        let block = TabSidebarOrder.Block.folderGroup(groupID)
        guard let moved = Self.order(tabGroup.windows, moving: block, to: destination, after: after) else { return }
        apply(order: nestedOrder(moved.order), select: nil)
    }

    /// `windows` with the tabs of a block moved to `destination`, and the keys the block
    /// takes there (nil at the end), or nil when the move makes no sense, such as next to
    /// one of its own tabs.
    static func order(
        _ windows: [NSWindow],
        moving block: TabSidebarOrder.Block,
        to destination: BlockDestination,
        after: Bool
    ) -> (order: [NSWindow], keys: [UUID?]?)? {
        let entries = windows.map(Entry.init)
        let target: TabSidebarOrder.Destination<Entry>
        switch destination {
        case .tab(let window): target = .item(Entry(window: window))
        case .group(let id): target = .block(.group(id))
        case .folder(let id): target = .block(.folder(id))
        case .folderGroup(let id): target = .block(.folderGroup(id))
        case .end: target = .end
        }
        guard let order = TabSidebarOrder.order(entries, moving: block, to: target, after: after) else { return nil }
        let others = entries.filter { $0.nestingKeys[block.level] != block.id }
        return (order.map(\.window), TabSidebarOrder.keys(of: block.level, droppedAt: target, among: others))
    }

    /// Makes sure the members of every folder group, folder and group are next to each
    /// other in the tab order. Each is placed where its first member is.
    func normalizeOrder() {
        guard let windows = hostWindow?.tabGroup?.windows else { return }
        let order = nestedOrder(windows)
        guard order != windows else { return }
        apply(order: order, select: nil)
    }

    /// `windows` in the sidebar's order (see `TabSidebarOrder.nested`). A group found
    /// across folders is given its first member's first.
    private func nestedOrder(_ windows: [NSWindow]) -> [NSWindow] {
        var groupFolders: [UUID: UUID?] = [:]
        for case let window as TerminalWindow in windows {
            guard let groupID = window.userTabGroupID else { continue }
            if let folderID = groupFolders[groupID] {
                if window.userTabFolderID != folderID { window.userTabFolderID = folderID }
            } else {
                groupFolders[groupID] = .some(window.userTabFolderID)
            }
        }
        return TabSidebarOrder.nested(windows.map(Entry.init)).map(\.window)
    }

    /// Reorders the native tab group to match `order`.
    private func apply(order: [NSWindow], select: NSWindow?) {
        guard let hostWindow, let tabGroup = hostWindow.tabGroup else { return }
        let selected = select ?? tabGroup.selectedWindow

        if order != tabGroup.windows {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0

            for (index, window) in order.enumerated() {
                // Everything before `index` is already in place, so `window` is somewhere
                // after it. Take it out and put it back directly before the tab currently
                // at `index`.
                let windows = tabGroup.windows
                guard windows.indices.contains(index), windows[index] !== window else { continue }
                let anchor = windows[index]
                tabGroup.removeWindow(window)
                anchor.addTabbedWindowSafely(window, ordered: .below)
            }

            NSAnimationContext.endGrouping()
        }

        if let selected {
            selected.makeKeyAndOrderFront(nil)
        }

        // Keyboard shortcut labels depend on the order.
        (selected?.windowController as? TerminalController ?? hostWindow.terminalController)?.relabelTabs()
        setNeedsRefresh()
    }
}
