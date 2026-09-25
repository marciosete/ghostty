import AppKit
import Combine

/// App-wide settings for the vertical tab sidebar. These are shared by every terminal
/// window so toggling the sidebar in one window applies to all of them, and they are
/// persisted in user defaults so they survive relaunches.
final class TabSidebarSettings: ObservableObject {
    static let shared = TabSidebarSettings()

    private static let enabledKey = "TabSidebarEnabled"
    private static let collapsedKey = "TabSidebarCollapsed"
    private static let widthKey = "TabSidebarWidth"
    private static let rowStyleKey = "TabSidebarRowStyle"

    static let minWidth: CGFloat = 150
    static let maxWidth: CGFloat = 420
    static let defaultWidth: CGFloat = 220

    /// When true, tabs are shown in a vertical sidebar instead of the native tab bar.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.ghostty.set(isEnabled, forKey: Self.enabledKey) }
    }

    /// When true, the sidebar is hidden completely (but vertical tabs remain enabled,
    /// so the native tab bar stays hidden too).
    @Published var isCollapsed: Bool {
        didSet { UserDefaults.ghostty.set(isCollapsed, forKey: Self.collapsedKey) }
    }

    /// The width of the sidebar in points.
    @Published var width: CGFloat {
        didSet { UserDefaults.ghostty.set(Double(width), forKey: Self.widthKey) }
    }

    /// How much each session's row shows.
    enum RowStyle: String, CaseIterable {
        /// One line: the title and what the session is doing.
        case simple

        /// A taller row that also shows where the session works: its branch, or its
        /// directory.
        case extended

        var localizedName: String {
            switch self {
            case .simple: return "Simple"
            case .extended: return "Extended"
            }
        }
    }

    @Published var rowStyle: RowStyle {
        didSet { UserDefaults.ghostty.set(rowStyle.rawValue, forKey: Self.rowStyleKey) }
    }

    private init() {
        let defaults = UserDefaults.ghostty
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        isCollapsed = defaults.bool(forKey: Self.collapsedKey)
        rowStyle = defaults.string(forKey: Self.rowStyleKey).flatMap(RowStyle.init(rawValue:)) ?? .simple

        let storedWidth = defaults.double(forKey: Self.widthKey)
        width = storedWidth > 0
            ? Self.clampWidth(CGFloat(storedWidth))
            : Self.defaultWidth
    }

    static func clampWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minWidth), maxWidth)
    }
}
