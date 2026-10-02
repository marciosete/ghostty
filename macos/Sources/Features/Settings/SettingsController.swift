import AppKit
import SwiftUI

/// The Settings window, opened with ⌘, . One for the app, made when first opened.
@MainActor
final class SettingsController: NSWindowController {
    static let shared = SettingsController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = Maggie.branded("Ghostty Settings")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(openConfiguration: {
            (NSApp.delegate as? AppDelegate)?.openConfig(nil)
        }))
        window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension AppDelegate {
    /// Puts "Settings…" (⌘,) in the app menu, above "Preferences…", which keeps opening
    /// the configuration file under a name that says so.
    func installSettingsMenuItem() {
        guard let preferences = NSApp.mainMenu.flatMap({ Maggie.item(withAction: #selector(openConfig(_:)), in: $0) }),
              let menu = preferences.menu else { return }

        preferences.title = "Open Configuration File…"
        preferences.keyEquivalent = ""

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.insertItem(settings, at: menu.index(of: preferences))
    }

    @IBAction func openSettings(_ sender: Any?) {
        SettingsController.shared.show()
    }
}
