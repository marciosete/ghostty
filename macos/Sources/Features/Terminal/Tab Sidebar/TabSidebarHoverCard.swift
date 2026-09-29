import AppKit
import SwiftUI

/// A card with a session's details, shown next to the sidebar while the pointer rests on
/// the session's row.
///
/// It is a panel of its own rather than a popover, so it never takes the keyboard from
/// the terminal, and it lets clicks through.
final class TabSidebarHoverCard {
    static let shared = TabSidebarHoverCard()

    /// How long the pointer rests on a row before its card shows. Moving to another row
    /// while a card shows swaps it at once.
    private static let delay: TimeInterval = 0.6

    /// The gap between the sidebar and the card.
    private static let gap: CGFloat = 6

    private var panel: NSPanel?
    private var shownID: ObjectIdentifier?
    private var pending: DispatchWorkItem?
    private var pendingID: ObjectIdentifier?

    private init() {}

    /// Shows the card of the row `id` of the sidebar in `window`, after a moment.
    func show<Content: View>(
        _ id: ObjectIdentifier,
        from window: NSWindow?,
        sidebarWidth: CGFloat,
        @ViewBuilder content: @escaping () -> Content
    ) {
        guard let window else { return }
        pending?.cancel()

        // The pointer's height when the row was entered places the card.
        let mouse = NSEvent.mouseLocation
        let item = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window, window.isKeyWindow || window.isMainWindow else { return }
            self.present(id, in: window, sidebarWidth: sidebarWidth, at: mouse.y, content: AnyView(content()))
        }
        pending = item
        pendingID = id
        let immediate = panel?.isVisible == true
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : Self.delay), execute: item)
    }

    /// Hides the card of the row `id`, if it is the one shown or about to be.
    func hide(_ id: ObjectIdentifier) {
        if pendingID == id {
            pending?.cancel()
            pending = nil
            pendingID = nil
        }
        guard shownID == id else { return }
        hideNow()
    }

    /// Hides whichever card is shown.
    func hideNow() {
        pending?.cancel()
        pending = nil
        pendingID = nil
        shownID = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func present(_ id: ObjectIdentifier, in window: NSWindow, sidebarWidth: CGFloat, at mouseY: CGFloat, content: AnyView) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let hosting = TabSidebarHoverCardHostingView(rootView: TabSidebarHoverCardChrome { content })
        panel.contentView = hosting
        let size = hosting.fittingSize

        // Beside the sidebar, its top a little above the pointer, kept on the screen.
        var origin = NSPoint(
            x: window.frame.minX + sidebarWidth + Self.gap,
            y: mouseY + 14 - size.height)
        if let screen = window.screen?.visibleFrame {
            origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        shownID = id
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        return panel
    }
}

/// Resizes the card to its content as it changes, such as once the usage is added up,
/// keeping its top edge where it is.
private final class TabSidebarHoverCardHostingView<Content: View>: NSHostingView<Content> {
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard let window else { return }
        let size = fittingSize
        var frame = window.frame
        guard frame.size != size else { return }
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true)
    }
}

/// The card's rounded, translucent background.
private struct TabSidebarHoverCardChrome<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(12)
            .frame(width: 280, alignment: .leading)
            .background(TabSidebarHoverCardBackground())
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }
}

private struct TabSidebarHoverCardBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// What the card says about a session: its title, what its Claude Code is doing, the model
/// it is using, where it works, and the tokens and cost of each model it used.
struct TabSidebarHoverCardView: View {
    let tab: TabSidebarModel.Tab
    let info: TabSidebarSessionInfo?
    let tint: Color?

    /// Nil while it is being added up.
    @State private var usage: [ClaudeCodeSessionCost.ModelUsage]?
    @State private var usageRead = false

    /// The model of the session's last response, once the transcript is read.
    @State private var model: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tab.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)

            if let state = tab.claudeCodeState {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    row(state.light.symbolName, state.summary(tab.claudeCodeActivity, lastActive: info?.lastActive, at: context.date), tint: tint)
                }
            }

            if let model {
                row("cpu", Self.shortName(model))
            }

            if let info {
                if let directory = info.abbreviatedDirectory {
                    row("folder", directory, truncation: .middle)
                }
                if let branch = info.branch {
                    row(info.isLinkedWorktree ? "square.stack.3d.up" : "arrow.triangle.branch", branch)
                }
                if let session = info.claudeSessions.first {
                    row("sparkle", "Session \(session.id.uuidString.lowercased().prefix(8))")
                }
                if !info.claudeSessions.isEmpty {
                    if let usage, !usage.isEmpty {
                        usageTable(usage)
                    } else {
                        row("dollarsign.circle", usageRead ? "No usage yet" : "Adding up usage…")
                    }
                }
            }
        }
        .font(.system(size: 12))
        .onAppear {
            loadModel()
            loadUsage()
        }
    }

    /// A row per model, and their total when there are several.
    private func usageTable(_ usage: [ClaudeCodeSessionCost.ModelUsage]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            GridRow {
                Text("Model")
                Text("Tokens").gridColumnAlignment(.trailing)
                Text("Cost").gridColumnAlignment(.trailing)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)

            ForEach(usage, id: \.model) { model in
                GridRow {
                    Text(Self.shortName(model.model))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(UsageFormat.tokens(model.tokens))
                    Text(model.cost.map(UsageFormat.usd) ?? "–")
                }
            }

            if usage.count > 1 {
                Divider().gridCellColumns(3)
                GridRow {
                    Text("Total")
                    Text(UsageFormat.tokens(usage.reduce(0) { $0 + $1.tokens }))
                    // A model without a rate makes the total a floor.
                    Text(UsageFormat.usd(usage.reduce(0) { $0 + ($1.cost ?? 0) })
                        + (usage.contains { $0.cost == nil } ? "+" : ""))
                }
                .fontWeight(.semibold)
            }
        }
        .monospacedDigit()
        .foregroundStyle(.primary.opacity(0.85))
        .padding(.top, 2)
    }

    /// The model's name without the `claude-` every one of them starts with, or the date
    /// some end with.
    static func shortName(_ model: String) -> String {
        var name = model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
        if let range = name.range(of: #"-\d{8}$"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        return name
    }

    private func row(_ symbol: String, _ text: String, tint: Color? = nil, truncation: Text.TruncationMode = .tail) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint ?? Color.secondary)
                .frame(width: 14)
            Text(text)
                .lineLimit(1)
                .truncationMode(truncation)
                .foregroundStyle(.primary.opacity(0.85))
        }
    }

    private func loadModel() {
        guard let transcript = info?.claudeSessions.first?.transcript else { return }
        DispatchQueue.global(qos: .utility).async {
            let read = ClaudeCodeResponse.model(inTranscript: transcript)
            DispatchQueue.main.async { model = read }
        }
    }

    private func loadUsage() {
        guard let sessions = info?.claudeSessions, !sessions.isEmpty else { return }
        ClaudeCodeSessionCost.usage(of: sessions) { read in
            usage = read
            usageRead = true
        }
    }
}
