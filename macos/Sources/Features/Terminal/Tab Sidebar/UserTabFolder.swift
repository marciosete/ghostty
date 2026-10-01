import AppKit
import Combine

/// A directory opened in the tab sidebar. Sessions and groups of sessions live in it,
/// and every session opened in it starts in its directory. Each `TerminalWindow` refers
/// to its folder by `id`; a group is in the folder its members are in.
struct UserTabFolder: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String

    /// The absolute path of the directory.
    let path: String
    var isCollapsed: Bool

    /// The folder group the folder is in, if any.
    var groupID: UUID?

    init(id: UUID = UUID(), name: String? = nil, path: String, isCollapsed: Bool = false, groupID: UUID? = nil) {
        self.id = id
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.isCollapsed = isCollapsed
        self.groupID = groupID
    }

    /// The path as the shell shows it, with the home directory as `~`.
    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// The folders open in the sidebar of one native tab group, in the order they were
/// opened, whether or not they have sessions. Every tab's window in the tab group points
/// at the same one; a window that joins the tab group gives its folders to it (see
/// `TabSidebarModel.unifyFolderSpace`). A folder with no sessions has nothing else to
/// keep it, which is why this exists.
final class TabSidebarFolderSpace {
    var folderIDs: [UUID] = []

    init(folderIDs: [UUID] = []) {
        self.folderIDs = folderIDs
    }

    func add(_ id: UUID) {
        guard !folderIDs.contains(id) else { return }
        folderIDs.append(id)
    }

    func remove(_ id: UUID) {
        folderIDs.removeAll { $0 == id }
    }
}

/// The shared registry of all folders, like `UserTabGroupStore` for groups.
final class UserTabFolderStore: ObservableObject {
    static let shared = UserTabFolderStore()

    @Published private(set) var folders: [UUID: UserTabFolder] = [:]

    private init() {}

    subscript(id: UUID?) -> UserTabFolder? {
        guard let id else { return nil }
        return folders[id]
    }

    /// Creates and registers a folder for a directory, named after it.
    func create(path: String) -> UserTabFolder {
        let folder = UserTabFolder(path: URL(fileURLWithPath: path).standardizedFileURL.path)
        folders[folder.id] = folder
        return folder
    }

    /// Registers a folder decoded from saved state. If a folder with the same id is
    /// already known (because another restored tab registered it first), the existing
    /// value wins so all tabs agree.
    func register(_ folder: UserTabFolder) {
        guard folders[folder.id] == nil else { return }
        folders[folder.id] = folder
    }

    func update(_ id: UUID, _ body: (inout UserTabFolder) -> Void) {
        guard var folder = folders[id] else { return }
        body(&folder)
        guard folder != folders[id] else { return }
        folders[id] = folder
        Self.invalidateRestorableState(forFolder: id)
    }

    func remove(_ id: UUID) {
        folders[id] = nil
    }

    /// Folder metadata is saved with each window's restorable state, so whenever it
    /// changes the windows showing the folder need to re-save.
    fileprivate static func invalidateRestorableState(forFolder id: UUID) {
        for window in NSApp.windows {
            guard let window = window as? TerminalWindow, window.folderSpace.folderIDs.contains(id) else { continue }
            window.invalidateRestorableState()
        }
    }
}

/// A named group of folders in the tab sidebar: a label the folders in it share, with
/// nothing else to it. Each `UserTabFolder` refers to its group by `groupID`.
struct UserTabFolderGroup: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var isCollapsed: Bool

    init(id: UUID = UUID(), name: String, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
    }
}

/// The shared registry of all folder groups, like `UserTabGroupStore` for groups.
final class UserTabFolderGroupStore: ObservableObject {
    static let shared = UserTabFolderGroupStore()

    @Published private(set) var groups: [UUID: UserTabFolderGroup] = [:]

    private init() {}

    subscript(id: UUID?) -> UserTabFolderGroup? {
        guard let id else { return nil }
        return groups[id]
    }

    func create(name: String) -> UserTabFolderGroup {
        let group = UserTabFolderGroup(name: name)
        groups[group.id] = group
        return group
    }

    /// Registers a folder group decoded from saved state; the first registered wins.
    func register(_ group: UserTabFolderGroup) {
        guard groups[group.id] == nil else { return }
        groups[group.id] = group
    }

    func update(_ id: UUID, _ body: (inout UserTabFolderGroup) -> Void) {
        guard var group = groups[id] else { return }
        body(&group)
        guard group != groups[id] else { return }
        groups[id] = group
        for folder in UserTabFolderStore.shared.folders.values where folder.groupID == id {
            UserTabFolderStore.invalidateRestorableState(forFolder: folder.id)
        }
    }

    func remove(_ id: UUID) {
        groups[id] = nil
    }

    /// Returns a default name for a new folder group that isn't already in use.
    func nextDefaultName() -> String {
        let existing = Set(groups.values.map(\.name))
        var index = 1
        while existing.contains("Folders \(index)") { index += 1 }
        return "Folders \(index)"
    }
}
