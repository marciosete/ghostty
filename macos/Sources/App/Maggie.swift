import AppKit

/// What this build is: Maggie, the Ghostty it was forked from, or a build under some
/// other bundle ID. `fork/package.sh` sets Maggie's.
///
/// Ghostty's name is in its menus, windows and dialogs. Rather than edit each of them,
/// which upstream would conflict with on every merge, Maggie puts its own name in at
/// the few places they pass through.
enum Maggie {
    static let bundleID = "com.marciosete.maggie"

    /// Where releases are published, and the update feed with them.
    static let repositoryURL = "https://github.com/marciosete/maggie"
    static let releasesURL = "\(repositoryURL)/releases"
    static let feedURL = "\(releasesURL)/latest/download/appcast.xml"

    /// Ghostty's own documentation, which covers everything Maggie inherits.
    static let ghosttyDocsURL = "https://ghostty.org/docs"

    static var isMaggie: Bool {
        Bundle.main.bundleIdentifier == bundleID
    }

    static var isGhostty: Bool {
        Bundle.main.bundleIdentifier?.hasPrefix("com.mitchellh.ghostty") ?? false
    }

    /// What the app is called, as the bundle says.
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Maggie"
    }

    /// `text` with Ghostty's name replaced by this app's, when this app is Maggie.
    /// Ghostty's ghost goes with it: "👻 Ghostty" is "Maggie".
    static func branded(_ text: String) -> String {
        guard isMaggie else { return text }
        return text
            .replacingOccurrences(of: "👻 Ghostty", with: appName)
            .replacingOccurrences(of: "Ghostty", with: appName)
    }

    /// The first item under `menu`, at any depth, whose action is `action`.
    static func item(withAction action: Selector, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.action == action { return item }
            if let submenu = item.submenu, let found = Self.item(withAction: action, in: submenu) {
                return found
            }
        }
        return nil
    }

    /// Puts this app's name in every title under `menu`, when this app is Maggie.
    static func brand(menu: NSMenu) {
        guard isMaggie else { return }
        menu.title = branded(menu.title)
        for item in menu.items {
            item.title = branded(item.title)
            if let submenu = item.submenu { brand(menu: submenu) }
        }
    }
}
