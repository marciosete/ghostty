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
        let keyEquivalent: String?
        let isSelected: Bool
        let isZoomed: Bool
        let groupID: UUID?

        static func == (lhs: Tab, rhs: Tab) -> Bool {
            lhs.id == rhs.id &&
                lhs.index == rhs.index &&
                lhs.title == rhs.title &&
                lhs.color == rhs.color &&
                lhs.assignedColor == rhs.assignedColor &&
                lhs.claudeCodeState == rhs.claudeCodeState &&
                lhs.keyEquivalent == rhs.keyEquivalent &&
                lhs.isSelected == rhs.isSelected &&
                lhs.isZoomed == rhs.isZoomed &&
                lhs.groupID == rhs.groupID
        }
    }

    struct GroupSection: Identifiable, Equatable {
        let group: UserTabGroup
        let tabs: [Tab]

        /// A group's members are kept contiguous, but until that is enforced the same
        /// group can briefly appear twice, so the id includes the first tab index.
        var id: String { "\(group.id)-\(tabs.first?.index ?? 0)" }

        var containsSelectedTab: Bool { tabs.contains(where: \.isSelected) }
    }

    enum Row: Identifiable, Equatable {
        case tab(Tab)
        case group(GroupSection)

        var id: String {
            switch self {
            case .tab(let tab): return "tab-\(tab.id.hashValue)"
            case .group(let section): return "group-\(section.id)"
            }
        }
    }

    /// The rows to display, in native tab order.
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

    /// The height of the titlebar that the sidebar and terminal content extend under.
    @Published var titlebarHeight: CGFloat = 0

    /// The tab currently being renamed inline, if any.
    @Published var editingTabID: ObjectIdentifier?

    /// The group currently being renamed inline, if any.
    @Published var editingGroupID: UUID?

    /// The text typed so far while renaming a tab or group inline.
    @Published var editingDraft = ""

    private weak var hostWindow: TerminalWindow?
    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabGroupObservations: [NSKeyValueObservation] = []
    private var titleObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var refreshScheduled = false

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
    }

    deinit {
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

    private func refresh() {
        refreshScheduled = false

        guard isActive, let hostWindow else {
            rebindTabGroup(nil)
            rebindTitles([])
            if !rows.isEmpty { rows = [] }
            return
        }

        let tabGroup = hostWindow.tabGroup
        rebindTabGroup(tabGroup)

        let windows = tabWindows
        rebindTitles(windows)

        let selected = tabGroup?.selectedWindow ?? hostWindow
        let tabs = windows.enumerated().map { index, window in
            Tab(
                id: ObjectIdentifier(window),
                window: window,
                index: index,
                title: window.title,
                color: window.shownTabColor,
                assignedColor: window.tabColor,
                claudeCodeState: window.claudeCodeState,
                keyEquivalent: window.keyEquivalent.flatMap { $0.isEmpty ? nil : $0 },
                isSelected: window === selected,
                isZoomed: window.surfaceIsZoomed,
                groupID: window.userTabGroupID)
        }

        var newRows: [Row] = []
        let store = UserTabGroupStore.shared
        var i = 0
        while i < tabs.count {
            guard let group = store[tabs[i].groupID] else {
                newRows.append(.tab(tabs[i]))
                i += 1
                continue
            }

            var j = i + 1
            while j < tabs.count, tabs[j].groupID == group.id { j += 1 }
            newRows.append(.group(.init(group: group, tabs: Array(tabs[i..<j]))))
            i = j
        }

        if newRows != rows { rows = newRows }

        // If the tab order was changed outside of the sidebar (e.g. "Merge All Windows"
        // or a move_tab keybind), a group can end up split. Put it back together. Only
        // the selected window does this so the windows in a tab group don't all race.
        if selected === hostWindow {
            let groupIDs = newRows.compactMap { row -> UUID? in
                if case .group(let section) = row { return section.group.id }
                return nil
            }
            if Set(groupIDs).count != groupIDs.count {
                DispatchQueue.main.async { [weak self] in self?.normalizeOrder() }
            }
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

    private func members(of groupID: UUID) -> [TerminalWindow] {
        tabWindows.filter { $0.userTabGroupID == groupID }
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
        editingDraft = window.terminalController?.titleOverride ?? window.title
        editingTabID = ObjectIdentifier(window)
    }

    func setColor(_ color: TerminalTabColor, for window: TerminalWindow) {
        window.tabColor = color
    }

    /// Opens a new tab. With a group, the tab is added to the end of that group;
    /// otherwise it is added to the end of the tab list without a group. The new tab
    /// inherits the working directory of a terminal in that group, so it opens in the
    /// group's project even when the selected tab belongs to another group. Without a
    /// group, it inherits from this window's focused terminal.
    func newTab(inGroup groupID: UUID? = nil) {
        guard let hostWindow,
              let hostController = hostWindow.terminalController else { return }

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
        } else {
            anchor = tabWindows.last ?? hostWindow
        }

        var baseConfig: Ghostty.SurfaceConfiguration?
        if let surface = source.terminalController?.focusedSurface?.surface {
            baseConfig = .init(from: ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_TAB))
        }

        guard let controller = TerminalController.newTab(
            hostController.ghostty,
            from: anchor,
            withBaseConfig: baseConfig),
              let window = controller.window as? TerminalWindow else { return }

        window.userTabGroupID = groupID
        if let groupID {
            UserTabGroupStore.shared.update(groupID) { $0.isCollapsed = false }
        }

        // The tab group takes a main loop turn to settle after adding a tab.
        DispatchQueue.main.async { [weak self] in self?.normalizeOrder() }
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

    func add(_ window: TerminalWindow, to groupID: UUID) {
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
        }

        endEditing()
    }

    /// Abandons an inline rename.
    func cancelEditing() {
        endEditing()
    }

    private func endEditing() {
        guard editingTabID != nil || editingGroupID != nil else { return }
        editingTabID = nil
        editingGroupID = nil

        // Inline editing takes focus away from the terminal, so give it back.
        guard let hostWindow,
              let surface = hostWindow.terminalController?.focusedSurface else { return }
        hostWindow.makeFirstResponder(surface)
    }

    // MARK: Reordering

    /// Drops a tab before or after another tab. The dropped tab joins the target's group.
    func drop(_ window: TerminalWindow, relativeTo target: TerminalWindow, after: Bool) {
        guard window !== target else { return }
        let others = tabWindows.filter { $0 !== window }
        guard let targetIndex = others.firstIndex(of: target) else { return }
        move(window, to: after ? targetIndex + 1 : targetIndex, groupID: target.userTabGroupID)
    }

    /// Drops a tab onto a group header, adding it to the start of that group.
    func drop(_ window: TerminalWindow, ontoGroup groupID: UUID) {
        let others = tabWindows.filter { $0 !== window }
        guard let firstMember = others.firstIndex(where: { $0.userTabGroupID == groupID }) else { return }
        move(window, to: firstMember, groupID: groupID)
    }

    /// Drops a tab below the last tab, moving it to the end outside any group.
    func dropAtEnd(_ window: TerminalWindow) {
        let others = tabWindows.filter { $0 !== window }
        move(window, to: others.count, groupID: nil)
    }

    /// Moves a tab to a new position. `index` is the position among the other tabs
    /// (i.e. excluding the moved tab), and `groupID` is the group it should now belong to.
    /// The tab may come from another window's tab group, in which case it moves here.
    func move(_ window: TerminalWindow, to index: Int, groupID: UUID?) {
        guard let hostWindow else { return }

        // If the tab comes from another window, move it into our tab group first.
        if let tabGroup = hostWindow.tabGroup, !tabGroup.windows.contains(window) {
            window.tabGroup?.removeWindow(window)
            let anchor = tabGroup.windows.last ?? hostWindow
            anchor.addTabbedWindowSafely(window, ordered: .above)
        }

        window.userTabGroupID = groupID
        if let groupID {
            UserTabGroupStore.shared.update(groupID) { $0.isCollapsed = false }
        }

        var order: [NSWindow] = hostWindow.tabGroup?.windows.filter { $0 !== window } ?? []
        order.insert(window, at: min(max(index, 0), order.count))
        apply(order: groupedOrder(order), select: window)
    }

    /// Makes sure the members of every group are next to each other in the tab order.
    /// A group is placed where its first member is.
    func normalizeOrder() {
        guard let windows = hostWindow?.tabGroup?.windows else { return }
        let order = groupedOrder(windows)
        guard order != windows else { return }
        apply(order: order, select: nil)
    }

    private func groupedOrder(_ windows: [NSWindow]) -> [NSWindow] {
        var result: [NSWindow] = []
        var emitted = Set<UUID>()
        for window in windows {
            guard let groupID = (window as? TerminalWindow)?.userTabGroupID else {
                result.append(window)
                continue
            }

            guard emitted.insert(groupID).inserted else { continue }
            result.append(contentsOf: windows.filter { ($0 as? TerminalWindow)?.userTabGroupID == groupID })
        }

        return result
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
