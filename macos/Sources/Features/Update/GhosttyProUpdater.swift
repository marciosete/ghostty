import AppKit

/// Updates Ghostty Pro, this fork installed by `fork/install-ghostty-pro.sh`, from the
/// checkout it was built from: builds and stages the new version while this one keeps
/// running, then quits and leaves the script to put the new version in place and open it.
/// The workspace is saved on quit, so windows, tabs and Claude Code sessions come back.
@MainActor
final class GhosttyProUpdater: NSObject {
    static let shared = GhosttyProUpdater()

    /// Set by the install script: the checkout the app was built from.
    static let sourceRootKey = "GhosttyProSourceRoot"

    private weak var menuItem: NSMenuItem?
    private var build: Process?

    /// The install script of the checkout the app was built from, if it has one.
    static var installScript: URL? {
        guard let root = Bundle.main.object(forInfoDictionaryKey: sourceRootKey) as? String else { return nil }
        let script = URL(fileURLWithPath: root).appendingPathComponent("fork/install-ghostty-pro.sh")
        return FileManager.default.isExecutableFile(atPath: script.path) ? script : nil
    }

    /// Where the build and install write what they do.
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(appName)/update.log")
    }

    /// Adds "Update Ghostty Pro…" to `menu` after `item`, if the app knows its checkout.
    func installMenuItem(in menu: NSMenu, after item: NSMenuItem?) {
        guard Self.installScript != nil else { return }

        let updateItem = NSMenuItem(title: Self.idleTitle, action: #selector(update(_:)), keyEquivalent: "")
        updateItem.target = self
        let index = item.map { menu.index(of: $0) + 1 } ?? 1
        menu.insertItem(updateItem, at: index)
        menuItem = updateItem
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Ghostty Pro"
    }

    private static var idleTitle: String { "Update \(appName)…" }

    @objc private func update(_ sender: Any?) {
        guard build == nil, let script = Self.installScript else { return }

        let alert = NSAlert()
        alert.messageText = "Update \(Self.appName)?"
        alert.informativeText = """
            Builds the latest version from \(script.deletingLastPathComponent().deletingLastPathComponent().path). \
            That takes a few minutes, and \(Self.appName) keeps working meanwhile. Then it restarts, \
            and your windows, tabs and Claude Code sessions open again.
            """
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        startBuild(script)
    }

    // MARK: Build

    private func startBuild(_ script: URL) {
        guard let log = Self.openLog(truncating: true) else {
            showFailure("The update log couldn't be created at \(Self.logURL.path).")
            return
        }

        let process = Self.loginShell(running: script, arguments: ["--build-only"], output: log)
        process.terminationHandler = { finished in
            DispatchQueue.main.async {
                try? log.close()
                self.buildFinished(script, status: finished.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            try? log.close()
            showFailure("The build couldn't start: \(error.localizedDescription)")
            return
        }

        build = process
        menuItem?.title = "Updating \(Self.appName)…"
        menuItem?.action = nil
    }

    private func buildFinished(_ script: URL, status: Int32) {
        build = nil
        menuItem?.title = Self.idleTitle
        menuItem?.action = #selector(update(_:))

        guard status == 0 else {
            showFailure("The new version didn't build, so \(Self.appName) wasn't changed.")
            return
        }

        // The installer outlives this app: it waits for it to quit, replaces it and opens
        // the new version.
        guard let log = Self.openLog(truncating: false) else {
            showFailure("The update log couldn't be opened at \(Self.logURL.path).")
            return
        }
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let installer = Self.loginShell(
            running: script, arguments: ["--install-staged", "--after", pid], output: log)
        // Started from a shell that exits at once, so the installer isn't this app's child
        // and nothing ties it to the app while it quits.
        installer.arguments = ["-c", "\"$@\" &", "sh", "/bin/zsh"] + (installer.arguments ?? [])
        installer.executableURL = URL(fileURLWithPath: "/bin/sh")
        do {
            try installer.run()
        } catch {
            try? log.close()
            showFailure("The new version built, but its installer couldn't start: \(error.localizedDescription)")
            return
        }
        try? log.close()

        NSApp.terminate(nil)
    }

    /// Runs `script` from a login shell, so it finds the tools (zig, git) on the PATH the
    /// user's shell sets up, which an app opened from the Dock doesn't get.
    private static func loginShell(running script: URL, arguments: [String], output: FileHandle) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec \"$0\" \"$@\"", script.path] + arguments
        process.currentDirectoryURL = script.deletingLastPathComponent()

        // Update this app where it is, under its own name, rather than the script's
        // default install.
        var environment = ProcessInfo.processInfo.environment
        environment["APP_NAME"] = appName
        environment["BUNDLE_ID"] = Bundle.main.bundleIdentifier
        environment["DEST"] = Bundle.main.bundleURL.deletingLastPathComponent().path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        return process
    }

    private static func openLog(truncating: Bool) -> FileHandle? {
        let url = logURL
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if truncating || !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else { return nil }
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

    private func showFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(Self.appName) wasn't updated"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show Log")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(Self.logURL)
        }
    }
}
