import AppKit
import SwiftUI

enum TerminalTabColor: Int, CaseIterable, Codable {
    case none
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case teal
    case graphite

    /// Follows the Claude Code session running in the tab (see `ClaudeCodeLight`).
    /// Added last so the raw values of colors saved before it don't move.
    case auto

    /// Follows the Claude Code session like `auto`, but only fills the tab while the
    /// session needs something: an answer, a commit or landing.
    case attention

    /// The colors a tab can be given. The traffic-light colors that `auto` shows are left
    /// out, so a color picked by hand is never mistaken for a session's state.
    static let tabChoices: [TerminalTabColor] = [.auto, .attention, .none, .purple, .pink, .orange, .graphite]

    /// The colors a group can be given. A group runs no session, so it can't follow one.
    static let groupChoices: [TerminalTabColor] = tabChoices.filter { !$0.followsClaudeCode }

    /// Whether the tab shows what its Claude Code session is doing.
    var followsClaudeCode: Bool {
        self == .auto || self == .attention
    }

    private static let followingKey = "TabColorFollowing"

    /// How every tab that follows its Claude Code session shows it, `auto` or
    /// `attention`. Picking one for a tab picks it for all of them, and new tabs start
    /// with it. Tabs given a color by hand keep theirs.
    static var following: TerminalTabColor {
        get {
            let saved = UserDefaults.ghostty.object(forKey: followingKey) as? Int
            return saved.flatMap(TerminalTabColor.init(rawValue:)).flatMap { $0.followsClaudeCode ? $0 : nil } ?? .auto
        }
        set {
            guard newValue.followsClaudeCode else { return }
            UserDefaults.ghostty.set(newValue.rawValue, forKey: followingKey)
        }
    }

    /// This color, with a following one saved earlier read as the one all tabs follow
    /// with now.
    var resolvingFollowing: TerminalTabColor {
        followsClaudeCode ? Self.following : self
    }

    /// Whether this is one of the colors `auto` uses to show a session's state.
    var isTrafficLight: Bool {
        ClaudeCodeLight.allCases.contains { $0.tabColor == self }
    }

    var localizedName: String {
        switch self {
        case .none:
            return "None"
        case .blue:
            return "Blue"
        case .purple:
            return "Purple"
        case .pink:
            return "Pink"
        case .red:
            return "Red"
        case .orange:
            return "Orange"
        case .yellow:
            return "Yellow"
        case .green:
            return "Green"
        case .teal:
            return "Teal"
        case .graphite:
            return "Graphite"
        case .auto:
            return "Auto"
        case .attention:
            return "Attention"
        }
    }

    var displayColor: NSColor? {
        switch self {
        case .none:
            return nil
        case .blue:
            return .systemBlue
        case .purple:
            return .systemPurple
        case .pink:
            return .systemPink
        case .red:
            return .systemRed
        case .orange:
            return .systemOrange
        case .yellow:
            return .systemYellow
        case .green:
            return .systemGreen
        case .teal:
            if #available(macOS 13.0, *) {
                return .systemMint
            } else {
                return .systemTeal
            }
        case .graphite:
            return .systemGray
        case .auto, .attention:
            return nil
        }
    }

    func swatchImage(selected: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { rect in
            let circleRect = rect.insetBy(dx: 1, dy: 1)
            let circlePath = NSBezierPath(ovalIn: circleRect)

            if self == .auto {
                Self.drawTrafficLight(in: circleRect)
            } else if self == .attention {
                Self.drawTrafficLight(in: circleRect, ring: true)
            } else if let fillColor = self.displayColor {
                fillColor.setFill()
                circlePath.fill()
            } else {
                NSColor.clear.setFill()
                circlePath.fill()
                NSColor.quaternaryLabelColor.setStroke()
                circlePath.lineWidth = 1
                circlePath.stroke()
            }

            if self == .none {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: circleRect.minX + 2, y: circleRect.minY + 2))
                slash.line(to: NSPoint(x: circleRect.maxX - 2, y: circleRect.maxY - 2))
                slash.lineWidth = 1.5
                NSColor.secondaryLabelColor.setStroke()
                slash.stroke()
            }

            if selected {
                let highlight = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                highlight.lineWidth = 2
                NSColor.controlAccentColor.setStroke()
                highlight.stroke()
            }

            return true
        }
    }

    /// A circle cut into the colors `auto` switches between. As a ring, for `attention`,
    /// which leaves most tabs empty.
    private static func drawTrafficLight(in rect: NSRect, ring: Bool = false) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let lights = ClaudeCodeLight.allCases
        let sweep = 360 / CGFloat(lights.count)
        let lineWidth: CGFloat = 3
        for (index, light) in lights.enumerated() {
            guard let color = light.tabColor.displayColor else { continue }
            let start = 90 - CGFloat(index) * sweep
            let slice = NSBezierPath()
            if ring {
                slice.appendArc(
                    withCenter: center,
                    radius: rect.width / 2 - lineWidth / 2,
                    startAngle: start - sweep,
                    endAngle: start)
                slice.lineWidth = lineWidth
                color.setStroke()
                slice.stroke()
            } else {
                slice.move(to: center)
                slice.appendArc(withCenter: center, radius: rect.width / 2, startAngle: start - sweep, endAngle: start)
                slice.close()
                color.setFill()
                slice.fill()
            }
        }
    }
}

// MARK: - Menu View

/// A SwiftUI view displaying a color palette for tab color selection.
/// Used as a custom view inside an NSMenuItem in the tab context menu.
struct TabColorMenuView: View {
    @State private var currentSelection: TerminalTabColor
    let onSelect: (TerminalTabColor) -> Void

    init(selectedColor: TerminalTabColor, onSelect: @escaping (TerminalTabColor) -> Void) {
        self._currentSelection = State(initialValue: selectedColor)
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Session Color")
                .padding(.bottom, 2)

            ForEach(Self.paletteRows, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(row, id: \.self) { color in
                        TabColorSwatch(
                            color: color,
                            isSelected: color == currentSelection
                        ) {
                            currentSelection = color
                            onSelect(color)
                        }
                    }
                }
            }
        }
        .padding(.leading, Self.leadingPadding)
        .padding(.trailing, 12)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    static let paletteRows: [[TerminalTabColor]] = [
        Array(TerminalTabColor.tabChoices.prefix(4)),
        Array(TerminalTabColor.tabChoices.dropFirst(4)),
    ]

    /// Leading padding to align with the menu's icon gutter.
    /// macOS 26 introduced icons in menus, requiring additional padding.
    private static var leadingPadding: CGFloat {
        if #available(macOS 26.0, *) {
            return 40
        } else {
            return 12
        }
    }
}

/// A single color swatch button in the tab color palette.
private struct TabColorSwatch: View {
    let color: TerminalTabColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if color.followsClaudeCode {
                    Image(nsImage: color.swatchImage(selected: isSelected))
                } else if color == .none {
                    Image(systemName: isSelected ? "circle.slash" : "circle")
                        .foregroundStyle(.secondary)
                } else if let displayColor = color.displayColor {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle.fill")
                        .foregroundStyle(Color(nsColor: displayColor))
                }
            }
            .font(.system(size: 16))
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(color.localizedName)
    }
}
