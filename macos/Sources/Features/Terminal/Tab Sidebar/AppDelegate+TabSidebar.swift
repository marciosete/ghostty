import AppKit

extension AppDelegate {
    /// Adds the tab sidebar items to the top of the View menu.
    func installTabSidebarMenuItems() {
        guard let viewMenu = NSApp.mainMenu?.items
            .first(where: { $0.submenu?.title == "View" })?
            .submenu else { return }

        let toggleSidebar = NSMenuItem(
            title: "Show Tab Sidebar",
            action: #selector(TerminalController.toggleTabSidebar(_:)),
            keyEquivalent: "b")
        toggleSidebar.keyEquivalentModifierMask = [.command]
        toggleSidebar.setImageIfDesired(systemSymbolName: "sidebar.left")

        let verticalTabs = NSMenuItem(
            title: "Vertical Tabs",
            action: #selector(TerminalController.toggleVerticalTabs(_:)),
            keyEquivalent: "")

        let toggleSourceControl = NSMenuItem(
            title: "Show Source Control",
            action: #selector(TerminalController.toggleSourceControl(_:)),
            keyEquivalent: "l")
        toggleSourceControl.keyEquivalentModifierMask = [.command]
        toggleSourceControl.setImageIfDesired(systemSymbolName: "arrow.triangle.branch")

        viewMenu.insertItem(toggleSidebar, at: 0)
        viewMenu.insertItem(verticalTabs, at: 1)
        viewMenu.insertItem(toggleSourceControl, at: 2)
        viewMenu.insertItem(.separator(), at: 3)
    }
}
