import AppKit
import SwiftUI

/// "Reopen Sessions from Backup…": the kept versions of the workspace, newest first,
/// each with how many of its sessions are open now and a button to reopen the rest
/// where they were. The versions kept because sessions were lost say so.
final class TerminalWorkspaceHistoryPanel {
    static let shared = TerminalWorkspaceHistoryPanel()

    private var window: NSWindow?

    private init() {}

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: TerminalWorkspaceHistoryView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Reopen Sessions from Backup"
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 420))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct TerminalWorkspaceHistoryView: View {
    struct Row: Identifiable {
        let entry: TerminalWorkspace.HistoryEntry
        let open: Int
        let missing: Int

        var id: URL { entry.url }
        var sessions: Int { open + missing }
    }

    @State private var rows: [Row] = []
    @State private var reopened: (count: Int, from: URL)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Every version of the workspace is kept for a while. Pick one to reopen the sessions in it that aren't open now, in their groups and folders.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(16)

            Divider()

            if rows.isEmpty {
                Text("No versions kept yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows) { row in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(row.entry.date, format: .dateTime.weekday(.wide).day().month().hour().minute().second())
                                if let lost = row.entry.lost {
                                    Text("\(lost) lost right after")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.orange.opacity(0.25)))
                                }
                            }
                            Text(summary(row))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(row.missing == 0 ? "All Open" : "Reopen \(row.missing)") {
                            reopen(row)
                        }
                        .disabled(row.missing == 0)
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider()

            HStack {
                if let reopened {
                    Text("Reopened \(reopened.count) sessions")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([TerminalWorkspace.historyDirectory])
                }
                Button("Refresh") { load() }
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 320)
        .onAppear(perform: load)
    }

    private func summary(_ row: Row) -> String {
        var parts = ["\(row.sessions) session\(row.sessions == 1 ? "" : "s")"]
        if row.missing > 0 { parts.append("\(row.missing) not open now") }
        return parts.joined(separator: " · ")
    }

    private func load() {
        rows = TerminalWorkspace.history().compactMap { entry in
            guard let data = try? Data(contentsOf: entry.url),
                  let counts = TerminalWorkspace.count(data) else { return nil }
            return Row(entry: entry, open: counts.open, missing: counts.missing)
        }
    }

    private func reopen(_ row: Row) {
        guard let data = try? Data(contentsOf: row.entry.url) else { return }
        let count = TerminalWorkspace.shared.reopenMissing(from: data)
        reopened = (count, row.entry.url)
        // The windows take a moment to open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { load() }
    }
}
