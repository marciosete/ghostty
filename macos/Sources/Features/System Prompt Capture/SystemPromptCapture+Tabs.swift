import AppKit

extension SystemPromptCapture {
    /// The name of the tab running Claude Code session `id`, as the session sidebar shows
    /// it, without the status Claude Code puts in front of it.
    static func tabName(ofSession id: String) -> String? {
        MainActor.assumeIsolated {
            for window in NSApp.windows {
                guard let controller = (window as? TerminalWindow)?.terminalController else { continue }
                let surfaces = controller.surfaceTree.root?.leaves() ?? []
                let runsSession = surfaces.contains { surface in
                    guard let pid = surface.surfaceModel?.foregroundPID else { return false }
                    return ClaudeCodeSession.id(ofRunning: pid)?.uuidString.lowercased() == id
                }
                guard runsSession else { continue }

                let name = controller.renameDraft
                return name.hasPrefix("🔔 ") ? String(name.dropFirst(2)) : name
            }
            return nil
        }
    }
}
