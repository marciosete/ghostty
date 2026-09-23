import AppKit
import Combine

/// Per-window bookkeeping for the tab sidebar. This lives in its own type so that
/// `TerminalWindow` only needs a single stored property for it.
struct TabSidebarWindowState {
    /// True if we added `.fullSizeContentView` to the style mask (so we know to remove it).
    var addedFullSizeContentView = false

    /// The value of `titlebarAppearsTransparent` before the sidebar changed it.
    var originalTitlebarAppearsTransparent: Bool?

    var cancellables: Set<AnyCancellable> = []

    var contentLayoutObservation: NSKeyValueObservation?
}

extension TerminalWindow {
    /// True when this window shows the vertical tab sidebar instead of the native tab bar.
    var isTabSidebarActive: Bool {
        supportsTabSidebar && TabSidebarSettings.shared.isEnabled
    }

    func setupTabSidebar() {
        guard supportsTabSidebar else { return }

        let settings = TabSidebarSettings.shared
        settings.$isEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncTabSidebar() }
            .store(in: &tabSidebarState.cancellables)

        settings.$isCollapsed
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncTabSidebarToggleButton() }
            .store(in: &tabSidebarState.cancellables)

        // The source control panel only watches its repository while it's shown.
        SourceControlSettings.shared.$isVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in self?.sourceControlModel.setVisible(visible) }
            .store(in: &tabSidebarState.cancellables)

        // The titlebar height changes with the style mask, toolbars and fullscreen.
        tabSidebarState.contentLayoutObservation = observe(\.contentLayoutRect, options: []) { window, _ in
            DispatchQueue.main.async { window.syncTabSidebarTitlebarHeight() }
        }
        let center = NotificationCenter.default
        Publishers.MergeMany(
            center.publisher(for: NSWindow.didEnterFullScreenNotification, object: self),
            center.publisher(for: NSWindow.didExitFullScreenNotification, object: self),
            center.publisher(for: NSWindow.didResizeNotification, object: self)
        )
        .sink { [weak self] _ in self?.syncTabSidebarTitlebarHeight() }
        .store(in: &tabSidebarState.cancellables)

        syncTabSidebar()
    }

    /// Measures how much of the top of the content view is covered by the titlebar.
    func syncTabSidebarTitlebarHeight() {
        guard let contentView else { return }
        let height = max(0, contentView.bounds.height - contentLayoutRect.maxY)
        if tabSidebarModel.titlebarHeight != height {
            tabSidebarModel.titlebarHeight = height
        }
    }

    /// Applies the current sidebar setting to this window.
    func syncTabSidebar() {
        guard supportsTabSidebar else { return }
        let active = isTabSidebarActive
        tabSidebarModel.isActive = active

        if active {
            // The sidebar runs the full height of the window, under the titlebar.
            if !styleMask.contains(.fullSizeContentView) {
                styleMask.insert(.fullSizeContentView)
                tabSidebarState.addedFullSizeContentView = true
            }

            if tabSidebarState.originalTitlebarAppearsTransparent == nil {
                tabSidebarState.originalTitlebarAppearsTransparent = titlebarAppearsTransparent
            }
            titlebarAppearsTransparent = true
        } else {
            if tabSidebarState.addedFullSizeContentView {
                styleMask.remove(.fullSizeContentView)
                tabSidebarState.addedFullSizeContentView = false
            }

            if let original = tabSidebarState.originalTitlebarAppearsTransparent {
                titlebarAppearsTransparent = original
                tabSidebarState.originalTitlebarAppearsTransparent = nil
            }
        }

        syncNativeTabBarVisibility()
        syncTabSidebarToggleButton()
        syncTabSidebarTitlebarHeight()

        // Titlebar colors depend on whether the sidebar is active.
        terminalController?.syncAppearance()
    }

    /// Hides the native tab bar while the sidebar is active, and shows it again otherwise.
    func syncNativeTabBarVisibility() {
        let hide = isTabSidebarActive
        var hasTabBar = false
        for controller in titlebarAccessoryViewControllers where controller.identifier == Self.tabBarIdentifier {
            hasTabBar = true
            if controller.isHidden != hide { controller.isHidden = hide }
        }

        if hide || !hasTabBar {
            tabBarDidDisappear()
        } else {
            tabBarDidAppear()
        }
    }

    /// Sets the color painted in the titlebar area above the terminal. With the sidebar,
    /// the real titlebar is transparent so the sidebar can show through it.
    func syncTabSidebarTitlebarColor(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        guard isTabSidebarActive else { return }

        if surfaceConfig.backgroundBlur.isGlassStyle {
            tabSidebarModel.titlebarColor = nil
        } else if isOpaque {
            tabSidebarModel.titlebarColor = preferredBackgroundColor?.withAlphaComponent(1)
        } else {
            tabSidebarModel.titlebarColor = preferredBackgroundColor
        }
    }

    func postTabSidebarItemDidChange() {
        NotificationCenter.default.post(name: .terminalTabSidebarItemDidChange, object: self)
    }

    // MARK: Toggle Button

    private func syncTabSidebarToggleButton() {
        let accessory = tabSidebarToggleAccessory
        let installed = titlebarAccessoryViewControllers.contains(accessory)

        guard isTabSidebarActive, styleMask.contains(.titled) else {
            if let index = titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                removeTitlebarAccessoryViewController(at: index)
            }
            return
        }

        if !installed {
            let button = NSButton(
                image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Session Sidebar")!,
                target: nil,
                action: #selector(TerminalController.toggleTabSidebar(_:)))
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.contentTintColor = .secondaryLabelColor
            button.translatesAutoresizingMaskIntoConstraints = false

            // Center the button vertically in the titlebar, just after the traffic lights.
            let container = NSView()
            container.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
                button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 20),
                button.heightAnchor.constraint(equalToConstant: 20),
            ])
            container.frame = NSRect(x: 0, y: 0, width: 32, height: 28)

            accessory.layoutAttribute = .left
            accessory.view = container
            addTitlebarAccessoryViewController(accessory)
        }

        let collapsed = TabSidebarSettings.shared.isCollapsed
        accessory.view.subviews
            .compactMap { $0 as? NSButton }
            .forEach { $0.toolTip = collapsed ? "Show Session Sidebar (⌘B)" : "Hide Session Sidebar (⌘B)" }
    }
}
