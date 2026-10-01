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

    /// What a session is found by: its title, the names of its group, its folder and its
    /// folder group, its folder's path, and its project, branch and directory.
    static func fields(
        of tab: TabSidebarModel.Tab,
        group: UserTabGroup?,
        folder: UserTabFolder? = nil,
        folderGroup: UserTabFolderGroup? = nil,
        info: TabSidebarSessionInfo?
    ) -> [String?] {
        [
            tab.title,
            group?.name,
            folder?.name,
            folder?.abbreviatedPath,
            folderGroup?.name,
            info?.checkout?.project,
            info?.branch,
            info?.abbreviatedDirectory,
        ]
    }

    /// The rows showing only the sessions matching `query`. A group, folder or folder
    /// group whose name matches keeps all its sessions. Those with a match are shown
    /// open, whatever their state.
    static func filter(
        _ rows: [TabSidebarModel.Row],
        query: String,
        infos: [ObjectIdentifier: TabSidebarSessionInfo]
    ) -> [TabSidebarModel.Row] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return rows }
        return filter(rows, query: query, folder: nil, folderGroup: nil, infos: infos)
    }

    private static func filter(
        _ rows: [TabSidebarModel.Row],
        query: String,
        folder: UserTabFolder?,
        folderGroup: UserTabFolderGroup?,
        infos: [ObjectIdentifier: TabSidebarSessionInfo]
    ) -> [TabSidebarModel.Row] {
        func fields(of tab: TabSidebarModel.Tab, group: UserTabGroup?) -> [String?] {
            Self.fields(of: tab, group: group, folder: folder, folderGroup: folderGroup, info: infos[tab.id])
        }

        return rows.compactMap { row in
            switch row {
            case .tab(let tab):
                return matches(query, fields(of: tab, group: nil)) ? row : nil

            case .group(let section):
                let tabs = matches(query, [section.group.name])
                    ? section.tabs
                    : section.tabs.filter { matches(query, fields(of: $0, group: section.group)) }
                guard !tabs.isEmpty else { return nil }
                var group = section.group
                group.isCollapsed = false
                return .group(.init(group: group, tabs: tabs))

            case .folder(let section):
                var folder = section.folder
                let rows = matches(query, [folder.name, folder.abbreviatedPath])
                    ? section.rows
                    : filter(section.rows, query: query, folder: folder, folderGroup: folderGroup, infos: infos)
                guard !rows.isEmpty else { return nil }
                folder.isCollapsed = false
                return .folder(.init(folder: folder, rows: rows))

            case .folderGroup(let section):
                var group = section.group
                let folders = matches(query, [group.name])
                    ? section.folders
                    : filter(section.folders.map(TabSidebarModel.Row.folder), query: query, folder: nil, folderGroup: group, infos: infos)
                        .compactMap { row -> TabSidebarModel.FolderSection? in
                            if case .folder(let folder) = row { return folder }
                            return nil
                        }
                guard !folders.isEmpty else { return nil }
                group.isCollapsed = false
                return .folderGroup(.init(group: group, folders: folders))
            }
        }
    }

    /// The sessions in `rows`, in the order they show.
    static func tabs(in rows: [TabSidebarModel.Row]) -> [TabSidebarModel.Tab] {
        rows.flatMap { row -> [TabSidebarModel.Tab] in
            switch row {
            case .tab(let tab): return [tab]
            case .group(let section): return section.group.isCollapsed ? [] : section.tabs
            case .folder(let section): return section.folder.isCollapsed ? [] : tabs(in: section.rows)
            case .folderGroup(let section):
                return section.group.isCollapsed ? [] : tabs(in: section.folders.map(TabSidebarModel.Row.folder))
            }
        }
    }
}
