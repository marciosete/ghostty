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

            Button {
                model.newTab()
            } label: {
                Label("New Tab", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .help("New Tab")
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
                .help("New Tab in Group")
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
        Button("New Tab in Group") { model.newTab(inGroup: group.id) }
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

    private var isEditing: Bool { model.editingTabID == tab.id }
    private var tabColor: NSColor? { tab.color.displayColor }

    var body: some View {
        HStack(spacing: 6) {
            if tab.isZoomed {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .help("A split is zoomed")
            }

            if isEditing {
                TextField("Tab Title", text: $model.editingDraft)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onAppear { DispatchQueue.main.async { fieldFocused = true } }
                    .onSubmit { model.commitEditing() }
                    .onExitCommand { model.cancelEditing() }
                    .onChange(of: fieldFocused) { focused in
                        if !focused && isEditing { model.commitEditing() }
                    }
            } else {
                Text(tab.title)
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
                .help("Close Tab")
            } else if let keyEquivalent = tab.keyEquivalent {
                Text(keyEquivalent)
                    .font(.system(size: 11))
                    .opacity(0.6)
            }
        }
        .font(tab.isSelected ? TabSidebarStyle.titleFont.weight(.semibold) : TabSidebarStyle.titleFont)
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 6).fill(background))
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
            Button("Rename Tab…") { model.beginRename(window) }
            TabSidebarColorMenu(title: "Tab Color", choices: TerminalTabColor.tabChoices, selected: tab.assignedColor) { color in
                model.setColor(color, for: window)
            }

            Divider()

            Button("Add Tab to New Group") { model.createGroup(with: window) }
            let otherGroups = model.groupsInWindow.filter { $0.id != tab.groupID }
            if !otherGroups.isEmpty {
                Menu("Add Tab to Group") {
                    ForEach(otherGroups) { group in
                        Button(group.name) { model.add(window, to: group.id) }
                    }
                }
            }
            if tab.groupID != nil {
                Button("Remove from Group") { model.removeFromGroup(window) }
            }

            Divider()

            Button("Move Tab to New Window") { model.moveToNewWindow(window) }

            Divider()

            Button("Close Tab") { model.close(window) }
            Button("Close Other Tabs") { model.closeOthers(window) }
            Button("Close Tabs Below") { model.closeBelow(window) }
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
