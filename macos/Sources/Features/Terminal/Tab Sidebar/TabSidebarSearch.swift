import AppKit

/// Finds sessions in the sidebar by what they are called and where they work.
enum TabSidebarSearch {
    /// Whether every word of `query` is in one of `fields`, ignoring case and accents.
    static func matches(_ query: String, _ fields: [String?]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let text = fields.compactMap { $0 }.joined(separator: "\n")
        return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// What a session is found by: its title, its group's name, and its project, branch
    /// and folder.
    static func fields(
        of tab: TabSidebarModel.Tab,
        group: UserTabGroup?,
        info: TabSidebarSessionInfo?
    ) -> [String?] {
        [tab.title, group?.name, info?.checkout?.project, info?.branch, info?.abbreviatedDirectory]
    }

    /// The rows showing only the sessions matching `query`. A group whose name matches
    /// keeps all its sessions. Groups with a match are shown open, whatever their state.
    static func filter(
        _ rows: [TabSidebarModel.Row],
        query: String,
        infos: [ObjectIdentifier: TabSidebarSessionInfo]
    ) -> [TabSidebarModel.Row] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return rows }

        return rows.compactMap { row in
            switch row {
            case .tab(let tab):
                return matches(query, fields(of: tab, group: nil, info: infos[tab.id])) ? row : nil

            case .group(let section):
                let tabs = matches(query, [section.group.name])
                    ? section.tabs
                    : section.tabs.filter { matches(query, fields(of: $0, group: section.group, info: infos[$0.id])) }
                guard !tabs.isEmpty else { return nil }
                var group = section.group
                group.isCollapsed = false
                return .group(.init(group: group, tabs: tabs))
            }
        }
    }

    /// The sessions in `rows`, in the order they show.
    static func tabs(in rows: [TabSidebarModel.Row]) -> [TabSidebarModel.Tab] {
        rows.flatMap { row -> [TabSidebarModel.Tab] in
            switch row {
            case .tab(let tab): return [tab]
            case .group(let section): return section.group.isCollapsed ? [] : section.tabs
            }
        }
    }
}
