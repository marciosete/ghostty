import AppKit
import Combine

/// A user-created, named group of tabs shown in the tab sidebar.
///
/// This is unrelated to `NSWindowTabGroup`, which is AppKit's native grouping of
/// windows into tabs. A `UserTabGroup` is a label that a subset of the tabs within
/// a native tab group share. Each `TerminalWindow` refers to its group by `id`.
struct UserTabGroup: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var color: TerminalTabColor
    var isCollapsed: Bool

    init(id: UUID = UUID(), name: String, color: TerminalTabColor = .none, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
    }
}

/// The shared registry of all user tab groups. Group metadata (name, color, collapsed state)
/// lives here so that every window in a native tab group sees the same values.
final class UserTabGroupStore: ObservableObject {
    static let shared = UserTabGroupStore()

    @Published private(set) var groups: [UUID: UserTabGroup] = [:]

    private init() {}

    subscript(id: UUID?) -> UserTabGroup? {
        guard let id else { return nil }
        return groups[id]
    }

    /// Creates and registers a new group.
    func create(name: String, color: TerminalTabColor = .none) -> UserTabGroup {
        let group = UserTabGroup(name: name, color: color)
        groups[group.id] = group
        return group
    }

    /// Registers a group decoded from saved state. If a group with the same id is
    /// already known (because another restored tab registered it first), the existing
    /// value wins so all tabs agree.
    func register(_ group: UserTabGroup) {
        guard groups[group.id] == nil else { return }
        groups[group.id] = group
    }

    func update(_ id: UUID, _ body: (inout UserTabGroup) -> Void) {
        guard var group = groups[id] else { return }
        body(&group)
        guard group != groups[id] else { return }
        groups[id] = group
        Self.invalidateRestorableState(forGroup: id)
    }

    func remove(_ id: UUID) {
        groups[id] = nil
    }

    /// Returns a default name for a new group that isn't already in use.
    func nextDefaultName() -> String {
        let existing = Set(groups.values.map(\.name))
        var index = 1
        while existing.contains("Group \(index)") { index += 1 }
        return "Group \(index)"
    }

    /// Group metadata is saved with each window's restorable state, so whenever it
    /// changes the member windows need to re-save.
    private static func invalidateRestorableState(forGroup id: UUID) {
        for window in NSApp.windows {
            guard let window = window as? TerminalWindow, window.userTabGroupID == id else { continue }
            window.invalidateRestorableState()
        }
    }
}
