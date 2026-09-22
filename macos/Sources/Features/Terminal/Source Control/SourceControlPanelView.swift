import AppKit
import SwiftUI

/// The source control panel: the staged and unstaged changes of the focused terminal's
/// repository, each as a file tree.
struct SourceControlPanelView: View {
    @ObservedObject var model: SourceControlPanelModel
    @ObservedObject var settings = SourceControlSettings.shared

    /// Space to leave at the top when the panel extends under the titlebar.
    let topInset: CGFloat

    @State private var resizeStartWidth: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: topInset)
            header
            Divider()
            content
        }
        .font(SourceControlStyle.font)
        .background(TabSidebarVisualEffectBackground())
        .overlay(alignment: .leading) { resizeHandle }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SOURCE CONTROL")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if case let .ready(repository, status) = model.state {
                HStack(spacing: 4) {
                    Text(repository.root.lastPathComponent)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if let branch = status.branch {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(branch)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .help(repository.root.path)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .noDirectory:
            message("No working directory",
                    detail: "The focused terminal hasn't reported its directory yet.")

        case .notRepository(let directory):
            message("Not a git repository", detail: directory)

        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
            Spacer(minLength: 0)

        case .ready(_, let status):
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    section(.staged, title: "Staged Changes", changes: status.staged)
                    section(.changes, title: "Changes", changes: status.unstaged)
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func section(_ section: SourceControlTree.Section, title: String, changes: [GitFileChange]) -> some View {
        let id = SourceControlTree.sectionID(section)
        let isCollapsed = model.collapsed.contains(id)

        SourceControlSectionHeader(title: title, count: changes.count, isCollapsed: isCollapsed) {
            toggle(id)
        }

        if !isCollapsed {
            ForEach(SourceControlTree.rows(for: changes, in: section, collapsed: model.collapsed)) { row in
                SourceControlRowView(row: row) { toggle(row.id) }
            }
        }
    }

    private func toggle(_ id: String) {
        if model.collapsed.contains(id) {
            model.collapsed.remove(id)
        } else {
            model.collapsed.insert(id)
        }
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        // The handle is on the left, so dragging left widens the panel.
                        let start = resizeStartWidth ?? settings.width
                        resizeStartWidth = start
                        settings.width = SourceControlSettings.clampWidth(start - value.translation.width)
                    }
                    .onEnded { _ in resizeStartWidth = nil }
            )
    }
}

// MARK: - Rows

private enum SourceControlStyle {
    static let font = Font.system(size: 12)
    static let rowHeight: CGFloat = 22
    static let indent: CGFloat = 12
}

private struct SourceControlSectionHeader: View {
    let title: String
    let count: Int
    let isCollapsed: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .foregroundStyle(.secondary)
                .frame(width: 12)

            Text(title)
                .fontWeight(.semibold)

            Spacer(minLength: 4)

            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.12)))
        }
        .padding(.horizontal, 8)
        .frame(height: SourceControlStyle.rowHeight + 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

private struct SourceControlRowView: View {
    let row: SourceControlTree.Row
    let toggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            if row.change == nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Color.clear.frame(width: 10)
                Image(systemName: "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text(row.name)
                .strikethrough(row.change?.kind == .deleted)
                .foregroundStyle(nameColor)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if let change = row.change {
                Text(change.kind.letter)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(change.kind.color)
                    .frame(width: 12)
            }
        }
        .padding(.leading, 8 + CGFloat(row.depth) * SourceControlStyle.indent)
        .padding(.trailing, 10)
        .frame(height: SourceControlStyle.rowHeight)
        .background(isHovering ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            if row.change == nil { toggle() }
        }
        .help(row.help)
    }

    private var nameColor: Color {
        guard let change = row.change else { return .primary }
        return change.kind.color
    }
}

private extension GitFileChange.Kind {
    /// The status letter VS Code shows next to a file.
    var letter: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .untracked: return "U"
        case .conflicted: return "!"
        }
    }

    var color: Color {
        switch self {
        case .modified, .typeChanged: return Color(nsColor: .systemOrange)
        case .added, .untracked, .copied: return Color(nsColor: .systemGreen)
        case .deleted: return Color(nsColor: .systemRed)
        case .renamed: return Color(nsColor: .systemTeal)
        case .conflicted: return Color(nsColor: .systemPurple)
        }
    }
}

// MARK: - Tree

/// Turns a flat list of changed paths into the visible rows of a file tree, the way
/// VS Code's tree view shows them: folders first, and chains of folders that only
/// contain one folder are shown as one row (e.g. `macos/Sources`).
enum SourceControlTree {
    enum Section: String {
        case staged
        case changes
    }

    struct Row: Identifiable {
        /// Unique within the panel. For folders this is also the key used to collapse it.
        let id: String
        let name: String
        let depth: Int
        let isExpanded: Bool

        /// The change for file rows, nil for folders.
        let change: GitFileChange?

        let help: String
    }

    static func sectionID(_ section: Section) -> String {
        "section:\(section.rawValue)"
    }

    static func rows(for changes: [GitFileChange], in section: Section, collapsed: Set<String>) -> [Row] {
        let root = Node(name: "", path: "")
        for change in changes {
            var node = root
            let components = change.path.split(separator: "/").map(String.init)
            for component in components.dropLast() {
                node = node.folder(named: component)
            }
            node.files.append(change)
        }

        var rows: [Row] = []
        append(root, depth: 0, section: section, collapsed: collapsed, to: &rows)
        return rows
    }

    private static func append(_ node: Node, depth: Int, section: Section, collapsed: Set<String>, to rows: inout [Row]) {
        let folders = node.folders.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for var folder in folders {
            // Merge folders that only contain a single folder into one row.
            var name = folder.name
            while folder.files.isEmpty, folder.folders.count == 1, let only = folder.folders.values.first {
                folder = only
                name += "/" + only.name
            }

            let id = "\(section.rawValue):\(folder.path)/"
            let isExpanded = !collapsed.contains(id)
            rows.append(Row(id: id, name: name, depth: depth, isExpanded: isExpanded, change: nil, help: folder.path))
            if isExpanded {
                append(folder, depth: depth + 1, section: section, collapsed: collapsed, to: &rows)
            }
        }

        let files = node.files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        for file in files {
            let name = String(file.path.split(separator: "/").last ?? Substring(file.path))
            var help = file.path
            if let originalPath = file.originalPath {
                help = "\(originalPath) → \(file.path)"
            }
            rows.append(Row(
                id: "\(section.rawValue):\(file.path)",
                name: name,
                depth: depth,
                isExpanded: false,
                change: file,
                help: help))
        }
    }

    private final class Node {
        let name: String
        let path: String
        var folders: [String: Node] = [:]
        var files: [GitFileChange] = []

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        func folder(named name: String) -> Node {
            if let existing = folders[name] { return existing }
            let folder = Node(name: name, path: path.isEmpty ? name : "\(path)/\(name)")
            folders[name] = folder
            return folder
        }
    }
}
