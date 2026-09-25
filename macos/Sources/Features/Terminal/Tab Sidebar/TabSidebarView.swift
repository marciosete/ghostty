import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Lays out the tab sidebar next to the terminal content of a window.
///
/// When the sidebar is active the window uses a full size content view with a transparent
/// titlebar so the sidebar can run the full height of the window, behind the traffic
/// lights. The terminal content stays below the titlebar, and the titlebar area above it
/// is painted with the terminal background color so it looks like a normal titlebar.
struct TabSidebarContainerView<Content: View>: View {
    @ObservedObject var model: TabSidebarModel
    @ObservedObject var settings = TabSidebarSettings.shared
    let sourceControl: SourceControlPanelModel
    @ObservedObject var sourceControlSettings = SourceControlSettings.shared
    @ObservedObject var usageSettings = UsageSettings.shared
    let content: Content

    init(
        model: TabSidebarModel,
        sourceControl: SourceControlPanelModel,
        @ViewBuilder content: () -> Content
    ) {
        self.model = model
        self.sourceControl = sourceControl
        self.content = content()
    }

    var body: some View {
        if model.isActive {
            HStack(spacing: 0) {
                if !settings.isCollapsed {
                    TabSidebarView(model: model, topInset: model.titlebarHeight)
                        .frame(width: settings.width)

                    separator
                }

                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color(nsColor: model.titlebarColor ?? .clear))
                        .frame(height: model.titlebarHeight)

                    content
                }

                rightPanels(topInset: model.titlebarHeight)
            }
            .ignoresSafeArea(.container, edges: .top)
        } else {
            HStack(spacing: 0) {
                content
                rightPanels(topInset: 0)
            }
        }
    }

    @ViewBuilder
    private func rightPanels(topInset: CGFloat) -> some View {
        if sourceControlSettings.isVisible {
            separator
            SourceControlPanelView(model: sourceControl, topInset: topInset)
                .frame(width: sourceControlSettings.width)
        }

        if usageSettings.isVisible {
            separator
            UsagePanelView(topInset: topInset)
                .frame(width: usageSettings.width)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
    }
}

// MARK: - Sidebar

struct TabSidebarView: View {
    @ObservedObject var model: TabSidebarModel
    @ObservedObject var settings = TabSidebarSettings.shared
    let topInset: CGFloat

    @State private var dropAtEnd = false
    @State private var resizeStartWidth: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            // Leave room for the traffic lights and the titlebar.
            Color.clear.frame(height: max(topInset, 8))

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.rows) { row in
                        switch row {
                        case .tab(let tab):
                            TabSidebarTabRow(model: model, tab: tab, group: nil)

                        case .group(let section):
                            TabSidebarGroupSection(model: model, section: section)
                        }
                    }

                    // Dropping below the last tab moves a tab to the end, outside any group.
                    Color.clear
                        .frame(height: 32)
                        .overlay(alignment: .top) {
                            if dropAtEnd { TabSidebarDropIndicator() }
                        }
                        .onDrop(of: [.plainText], delegate: TabSidebarDropDelegate(
                            model: model,
                            target: .end,
                            height: 32,
                            placement: Binding(
                                get: { dropAtEnd ? .before : nil },
                                set: { dropAtEnd = $0 != nil })))
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    model.newTab()
                } label: {
                    Label("New Session", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Session")

                CaffeineButton()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .background(TabSidebarVisualEffectBackground())
        .overlay(alignment: .trailing) { resizeHandle }
    }

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
                        let start = resizeStartWidth ?? settings.width
                        resizeStartWidth = start
                        settings.width = TabSidebarSettings.clampWidth(start + value.translation.width)
                    }
                    .onEnded { _ in resizeStartWidth = nil }
            )
    }
}

// MARK: - Group

private struct TabSidebarGroupSection: View {
    @ObservedObject var model: TabSidebarModel
    let section: TabSidebarModel.GroupSection

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TabSidebarGroupHeader(model: model, section: section)

            if !section.group.isCollapsed {
                ForEach(section.tabs) { tab in
                    TabSidebarTabRow(model: model, tab: tab, group: section.group)
                }
            }
        }
        .padding(.top, 4)
    }
}

private struct TabSidebarGroupHeader: View {
    @ObservedObject var model: TabSidebarModel
    let section: TabSidebarModel.GroupSection

    @State private var isHovering = false
    @State private var placement: TabSidebarDropPlacement?
    @FocusState private var fieldFocused: Bool

    private var group: UserTabGroup { section.group }
    private var isEditing: Bool { model.editingGroupID == group.id }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                .foregroundStyle(.secondary)
                .frame(width: 10)

            if isEditing {
                TextField("Group Name", text: $model.editingDraft)
                    .textFieldStyle(.plain)
                    .font(TabSidebarStyle.titleFont)
                    .focused($fieldFocused)
                    .onAppear { DispatchQueue.main.async { fieldFocused = true } }
                    .onSubmit { model.commitEditing() }
                    .onExitCommand { model.cancelEditing() }
                    .onChange(of: fieldFocused) { focused in
                        if !focused && isEditing { model.commitEditing() }
                    }
            } else {
                nameLabel
            }

            if group.isCollapsed {
                Text("(\(section.tabs.count))")
                    .font(TabSidebarStyle.titleFont)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            // A collapsed group still says what its sessions are doing.
            if group.isCollapsed && !(isHovering && !isEditing) {
                if section.hasFinishedUnseen {
                    TabSidebarUnseenDot()
                }
                if let light = section.claudeCodeLight, let color = light.tabColor.displayColor {
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 8, height: 8)
                        .help(light.label)
                }
            }

            if isHovering && !isEditing {
                Button {
                    model.newTab(inGroup: group.id)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Session in Group")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: TabSidebarStyle.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(background))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            guard !isEditing else { return }
            withAnimation(.easeOut(duration: 0.15)) { model.toggleCollapsed(group.id) }
        }
        .overlay {
            if placement != nil {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .onDrop(of: [.plainText], delegate: TabSidebarDropDelegate(
            model: model,
            target: .group(group.id),
            height: TabSidebarStyle.rowHeight,
            placement: $placement))
        .contextMenu { contextMenu }
    }

    private var background: Color {
        if group.isCollapsed && section.containsSelectedTab { return Color.primary.opacity(0.14) }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }

    @ViewBuilder
    private var nameLabel: some View {
        if let color = group.color.displayColor {
            Text(group.name)
                .font(TabSidebarStyle.titleFont)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .foregroundStyle(Color(nsColor: color.isLightColor ? .black : .white))
                .background(Capsule().fill(Color(nsColor: color)))
        } else {
            Text(group.name)
                .font(TabSidebarStyle.titleFont)
                .lineLimit(1)
                .foregroundStyle(Color.primary.opacity(0.8))
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("New Session in Group") { model.newTab(inGroup: group.id) }
        Button("Rename Group…") { model.beginRename(group: group.id) }
        TabSidebarColorMenu(title: "Group Color", choices: TerminalTabColor.groupChoices, selected: group.color) { color in
            model.setColor(color, forGroup: group.id)
        }
        Button(group.isCollapsed ? "Expand Group" : "Collapse Group") {
            model.toggleCollapsed(group.id)
        }
        Divider()
        Button("Ungroup") { model.ungroup(group.id) }
        Button("Close Group") { model.closeGroup(group.id) }
    }
}

// MARK: - Tab

private struct TabSidebarTabRow: View {
    @ObservedObject var model: TabSidebarModel
    let tab: TabSidebarModel.Tab
    let group: UserTabGroup?

    @State private var isHovering = false
    @State private var placement: TabSidebarDropPlacement?
    @FocusState private var fieldFocused: Bool

    private static let height = TabSidebarStyle.rowHeight

    @ObservedObject private var modifiers = TabSidebarModifierMonitor.shared

    private var isEditing: Bool { model.editingTabID == tab.id }
    private var tabColor: NSColor? { tab.color.displayColor }
    private var finishedUnseen: Bool { tab.claudeCodeActivity.finishedUnseen && !tab.isSelected }

    /// Shortcut labels only show while their modifiers are held, like the menu bar's.
    private var showsShortcut: Bool {
        guard let jump = model.jumpModifiers, !jump.isEmpty else { return false }
        return modifiers.held == jump
    }

    private var recedes: Bool {
        tab.claudeCodeState?.light == .working && !tab.isSelected && !isHovering
    }

    var body: some View {
        HStack(spacing: 6) {
            if tab.isZoomed {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .help("A split is zoomed")
            }

            if isEditing {
                TextField("Session Title", text: $model.editingDraft)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onAppear { DispatchQueue.main.async { fieldFocused = true } }
                    .onSubmit { model.commitEditing() }
                    .onExitCommand { model.cancelEditing() }
                    .onChange(of: fieldFocused) { focused in
                        if !focused && isEditing { model.commitEditing() }
                    }
            } else {
                if finishedUnseen {
                    TabSidebarUnseenDot()
                }

                Text(tab.title)
                    .fontWeight(finishedUnseen ? .semibold : nil)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            if isHovering && !isEditing {
                Button {
                    if let window = tab.window { model.close(window) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(0.8)
                .help("Close Session")
            } else if showsShortcut, let keyEquivalent = tab.keyEquivalent {
                Text(keyEquivalent)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 5)
                    .frame(minHeight: 16)
                    .background(Capsule().fill(foreground.opacity(0.18)))
            } else if let state = tab.claudeCodeState {
                TabSidebarClaudeCodeStatus(state: state, activity: tab.claudeCodeActivity)
            }
        }
        .font(tab.isSelected ? TabSidebarStyle.titleFont.weight(.semibold) : TabSidebarStyle.titleFont)
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 6).fill(background))
        // A session that is working needs nothing yet, so it steps back and the ones
        // waiting for an answer or finished stand out.
        .opacity(recedes ? 0.7 : 1)
        .animation(.easeOut(duration: 0.15), value: recedes)
        .overlay {
            if tab.isSelected && tabColor == nil {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .overlay(alignment: .leading) { groupMarker }
        .overlay(alignment: placement == .after ? .bottom : .top) {
            if placement != nil { TabSidebarDropIndicator() }
        }
        .padding(.leading, group == nil ? 0 : 12)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            guard !isEditing, let window = tab.window else { return }

            // Each click of a double click arrives here, so the first click selects
            // the tab immediately and the second starts renaming it.
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                model.beginRename(window)
            } else {
                model.select(window)
            }
        }
        .onDrag {
            guard let window = tab.window else { return NSItemProvider() }
            return NSItemProvider(object: TabSidebarDragState.shared.begin(window) as NSString)
        }
        .onDrop(of: [.plainText], delegate: TabSidebarDropDelegate(
            model: model,
            target: .tab(tab.window),
            height: Self.height,
            placement: $placement))
        .contextMenu { contextMenu }
        .help(tab.title)
    }

    /// A thin bar in the group's color marks tabs that belong to a colored group.
    @ViewBuilder
    private var groupMarker: some View {
        if let group, let color = group.color.displayColor {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(nsColor: color))
                .frame(width: 3, height: Self.height - 10)
                .offset(x: -8)
        }
    }

    private var background: Color {
        if let tabColor {
            // Colored tabs are filled with their color: fully when selected, and
            // lighter otherwise so the selected tab stands out.
            let opacity = tab.isSelected ? 1.0 : (isHovering ? 0.55 : 0.4)
            return Color(nsColor: tabColor).opacity(opacity)
        }

        if tab.isSelected { return Color.primary.opacity(0.14) }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }

    private var foreground: Color {
        if let tabColor, tab.isSelected {
            return Color(nsColor: tabColor.isLightColor ? .black : .white)
        }

        return tab.isSelected ? .primary : .primary.opacity(0.8)
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let window = tab.window {
            Button("Rename Session…") { model.beginRename(window) }
            TabSidebarColorMenu(title: "Session Color", choices: TerminalTabColor.tabChoices, selected: tab.assignedColor) { color in
                model.setColor(color, for: window)
            }
            if let state = tab.claudeCodeState, !state.landableWorktrees.isEmpty {
                Button("Land on \(state.landingBranch ?? "Main Checkout")") {
                    ClaudeCodeLights.shared.land(window)
                }
                .help("Rebase the session's commits onto the branch, then fast-forward it")
            }

            Divider()

            Button("Add Session to New Group") { model.createGroup(with: window) }
            let otherGroups = model.groupsInWindow.filter { $0.id != tab.groupID }
            if !otherGroups.isEmpty {
                Menu("Add Session to Group") {
                    ForEach(otherGroups) { group in
                        Button(group.name) { model.add(window, to: group.id) }
                    }
                }
            }
            if tab.groupID != nil {
                Button("Remove from Group") { model.removeFromGroup(window) }
            }

            Divider()

            Button("Move Session to New Window") { model.moveToNewWindow(window) }

            Divider()

            Button("Close Session") { model.close(window) }
            Button("Close Other Sessions") { model.closeOthers(window) }
            Button("Close Sessions Below") { model.closeBelow(window) }
        }
    }
}

// MARK: - Shared Pieces

/// Sizes shared by tab rows and group headers so they line up.
private enum TabSidebarStyle {
    static let titleFont = Font.system(size: 12)
    static let rowHeight: CGFloat = 28
}

/// A submenu that picks a tab color, showing a swatch for each color.
private struct TabSidebarColorMenu: View {
    let title: String
    let choices: [TerminalTabColor]
    let selected: TerminalTabColor
    let onSelect: (TerminalTabColor) -> Void

    var body: some View {
        Menu(title) {
            ForEach(choices, id: \.self) { color in
                Button {
                    onSelect(color)
                } label: {
                    Label {
                        Text(color == selected ? "\(color.localizedName) ✓" : color.localizedName)
                    } icon: {
                        Image(nsImage: color.swatchImage(selected: false))
                    }
                }
            }
        }
    }
}

/// Marks a session that finished while it wasn't looked at, like an unread message. It
/// takes the text's color, since the accent color could be read as a light.
private struct TabSidebarUnseenDot: View {
    var body: some View {
        Circle()
            .frame(width: 6, height: 6)
            .help("Finished while you were away")
    }
}

/// What a session's Claude Code is doing, as a symbol and a few characters, so it reads
/// without telling the row's colors apart: how long it has been working, that it waits
/// for an answer, how many files or commits are left, or how long ago it finished.
private struct TabSidebarClaudeCodeStatus: View {
    let state: ClaudeCodeTabState
    let activity: ClaudeCodeActivity

    var body: some View {
        // Only a working session counts seconds.
        TimelineView(.periodic(from: .now, by: state.light == .working ? 1 : 30)) { context in
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                if let text = text(at: context.date) {
                    Text(text)
                        .font(.system(size: 11))
                        .monospacedDigit()
                }
            }
            .opacity(0.85)
            .help(help(at: context.date))
        }
    }

    private var symbol: String {
        switch state.light {
        case .working: return "circle.dashed"
        case .waiting: return "exclamationmark.bubble"
        case .pending: return "pencil"
        case .unlanded: return "arrow.triangle.merge"
        case .clean: return "checkmark"
        }
    }

    private func text(at now: Date) -> String? {
        switch state.light {
        case .working:
            return activity.workingSince.map { ClaudeCodeActivity.elapsed(since: $0, at: now) }
        case .waiting:
            return nil
        case .pending, .unlanded:
            return state.badge.map(String.init)
        case .clean:
            return activity.stoppedSince.map { ClaudeCodeActivity.ago($0, at: now) }
        }
    }

    private func help(at now: Date) -> String {
        var parts = [state.badgeHelp ?? state.light.label]
        if state.light == .working, let start = activity.workingSince {
            parts.append("for \(ClaudeCodeActivity.elapsed(since: start, at: now))")
        } else if let stopped = activity.stoppedSince {
            let ago = ClaudeCodeActivity.ago(stopped, at: now)
            parts.append(ago == "now" ? "just now" : "since \(ago) ago")
        }
        return parts.joined(separator: ", ")
    }
}

/// The modifier keys held down, once they have been held for a moment, so shortcut
/// labels don't flash while a shortcut is typed.
final class TabSidebarModifierMonitor: ObservableObject {
    static let shared = TabSidebarModifierMonitor()

    private static let delay: TimeInterval = 0.2

    @Published private(set) var held: NSEvent.ModifierFlags = []

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var pending: DispatchWorkItem?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(event.modifierFlags)
            return event
        }

        // Modifiers released in another app are never seen.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.update([]) }
    }

    private func update(_ flags: NSEvent.ModifierFlags) {
        let flags = flags.intersection([.command, .option, .control, .shift])
        pending?.cancel()
        pending = nil
        if !held.isEmpty { held = [] }
        guard !flags.isEmpty else { return }

        let item = DispatchWorkItem { [weak self] in self?.held = flags }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: item)
    }
}

private struct TabSidebarDropIndicator: View {
    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 2)
    }
}

struct TabSidebarVisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The × in the header of a panel beside the terminal, for those who don't know its
/// shortcut. `help` names the shortcut.
struct SidePanelCloseButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .frame(width: 20, height: 20)
        .help(help)
        .accessibilityLabel("Close")
    }
}

// MARK: - Drag and Drop

enum TabSidebarDropPlacement {
    case before
    case after
}

/// Tracks the tab being dragged. The drag pasteboard only carries a token; the window
/// itself is looked up here once the token is verified, so an unrelated text drop can
/// never move a tab.
final class TabSidebarDragState {
    static let shared = TabSidebarDragState()

    private(set) weak var window: TerminalWindow?
    private var token: String?

    func begin(_ window: TerminalWindow) -> String {
        let token = "ghostty-tab:\(UUID().uuidString)"
        self.window = window
        self.token = token
        return token
    }

    func take(token: String) -> TerminalWindow? {
        guard token == self.token else { return nil }
        self.token = nil
        defer { self.window = nil }
        return window
    }
}

private struct TabSidebarDropDelegate: DropDelegate {
    enum Target {
        case tab(TerminalWindow?)
        case group(UUID)
        case end
    }

    let model: TabSidebarModel
    let target: Target
    let height: CGFloat
    @Binding var placement: TabSidebarDropPlacement?

    func validateDrop(info: DropInfo) -> Bool {
        TabSidebarDragState.shared.window != nil && info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        placement = placement(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        placement = placement(for: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        placement = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let finalPlacement = placement(for: info)
        placement = nil

        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let model = model
        let target = target
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let token = object as? String else { return }
            DispatchQueue.main.async {
                guard let window = TabSidebarDragState.shared.take(token: token) else { return }
                switch target {
                case .tab(let targetWindow):
                    guard let targetWindow else { return }
                    model.drop(window, relativeTo: targetWindow, after: finalPlacement == .after)
                case .group(let groupID):
                    model.drop(window, ontoGroup: groupID)
                case .end:
                    model.dropAtEnd(window)
                }
            }
        }

        return true
    }

    private func placement(for info: DropInfo) -> TabSidebarDropPlacement {
        switch target {
        case .tab:
            return info.location.y < height / 2 ? .before : .after
        case .group, .end:
            return .before
        }
    }
}
