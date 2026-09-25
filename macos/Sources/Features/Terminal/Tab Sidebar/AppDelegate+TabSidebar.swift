import AppKit

extension AppDelegate {
    /// Adds the tab sidebar items to the top of the View menu.
    func installTabSidebarMenuItems() {
        guard let viewMenu = NSApp.mainMenu?.items
            .first(where: { $0.submenu?.title == "View" })?
            .submenu else { return }

        let toggleSidebar = NSMenuItem(
            title: "Show Session Sidebar",
            action: #selector(TerminalController.toggleTabSidebar(_:)),
            keyEquivalent: "b")
        toggleSidebar.keyEquivalentModifierMask = [.command]
        toggleSidebar.setImageIfDesired(systemSymbolName: "sidebar.left")

        let verticalTabs = NSMenuItem(
            title: "Vertical Sessions",
            action: #selector(TerminalController.toggleVerticalTabs(_:)),
            keyEquivalent: "")

        let toggleSourceControl = NSMenuItem(
            title: "Show Source Control",
            action: #selector(TerminalController.toggleSourceControl(_:)),
            keyEquivalent: "l")
        toggleSourceControl.keyEquivalentModifierMask = [.command]
        toggleSourceControl.setImageIfDesired(systemSymbolName: "arrow.triangle.branch")

        let toggleUsage = NSMenuItem(
            title: "Show Usage",
            action: #selector(TerminalController.toggleUsage(_:)),
            keyEquivalent: "u")
        toggleUsage.keyEquivalentModifierMask = [.command]
        toggleUsage.setImageIfDesired(systemSymbolName: "chart.line.uptrend.xyaxis")

        viewMenu.insertItem(toggleSidebar, at: 0)
        viewMenu.insertItem(verticalTabs, at: 1)
        viewMenu.insertItem(toggleSourceControl, at: 2)
        viewMenu.insertItem(toggleUsage, at: 3)
        viewMenu.insertItem(.separator(), at: 4)

        let captureSystemPrompts = NSMenuItem(
            title: "Capture Claude Code System Prompts",
            action: #selector(AppDelegate.toggleSystemPromptCapture(_:)),
            keyEquivalent: "")
        let showSystemPrompts = NSMenuItem(
            title: "Show Captured System Prompts",
            action: #selector(AppDelegate.showCapturedSystemPrompts(_:)),
            keyEquivalent: "")

        viewMenu.insertItem(captureSystemPrompts, at: 5)
        viewMenu.insertItem(showSystemPrompts, at: 6)
        viewMenu.insertItem(.separator(), at: 7)
    }

    /// Takes effect in terminals opened afterwards.
    @IBAction func toggleSystemPromptCapture(_ sender: Any?) {
        let capture = SystemPromptCapture.shared
        capture.setEnabled(!capture.isEnabled)
    }

    @IBAction func showCapturedSystemPrompts(_ sender: Any?) {
        SystemPromptCapture.shared.revealInFinder()
    }
}
