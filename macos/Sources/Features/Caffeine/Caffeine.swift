import AppKit
import Combine
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Keeps the Mac awake, and its network up, while the screen is off and the lid is closed.
///
/// A power assertion keeps the Mac from sleeping when it's left alone. Closing the lid
/// sleeps it anyway, unless sleep is disabled with `pmset -a disablesleep 1`, which needs
/// root. The first run installs a sudoers rule, after asking for an administrator
/// password once, that lets this user run exactly `pmset -a disablesleep 0` and `1`.
///
/// Each run stops by itself when its time limit is up, when the battery runs low, and
/// when the app quits. A run left behind by a crash is undone on the next launch.
@MainActor
final class Caffeine: ObservableObject {
    static let shared = Caffeine()

    struct Run: Equatable {
        let startedAt: Date

        /// When the run stops by itself, or nil to run until it is turned off.
        let until: Date?

        /// The battery percentage at which the run stops while on battery, or nil.
        let minimumBattery: Int?

        /// Whether sleep is disabled, so the Mac stays awake with the lid closed too.
        /// False when the administrator prompt was cancelled.
        let coversClosedLid: Bool
    }

    enum StopReason: Equatable {
        case timeLimit
        case battery(Int)
    }

    /// The current run, or nil while the Mac sleeps as usual.
    @Published private(set) var run: Run?

    /// Why the last run stopped by itself, until the next one starts.
    @Published private(set) var lastStop: StopReason?

    /// The choices for the next run, remembered from the last one. 0 means no limit.
    @Published var hours: Int {
        didSet { UserDefaults.ghostty.set(hours, forKey: Self.hoursKey) }
    }

    @Published var minimumBattery: Int {
        didSet { UserDefaults.ghostty.set(minimumBattery, forKey: Self.minimumBatteryKey) }
    }

    static let hourChoices = [1, 2, 4, 8, 12, 0]
    static let batteryChoices = [0, 10, 20, 30, 50]

    private static let hoursKey = "CaffeineHours"
    private static let minimumBatteryKey = "CaffeineMinimumBattery"

    /// Set while this app has disabled sleep, so a crash can be undone on the next launch.
    private static let sleepDisabledKey = "CaffeineSleepDisabled"

    private static let checkInterval: TimeInterval = 30
    private static let sudoersFile = "/etc/sudoers.d/ghostty-pro-caffeine"

    private var assertion: IOPMAssertionID = 0
    private var checkTimer: Timer?

    private init() {
        let defaults = UserDefaults.ghostty
        hours = defaults.object(forKey: Self.hoursKey) as? Int ?? 8
        minimumBattery = defaults.object(forKey: Self.minimumBatteryKey) as? Int ?? 20
    }

    // MARK: Turning on and off

    /// Undoes sleep being disabled by a run that didn't stop, because the app crashed.
    func restoreAfterLaunch() {
        guard UserDefaults.ghostty.bool(forKey: Self.sleepDisabledKey) else { return }
        if Self.pmsetDisableSleep(false) {
            UserDefaults.ghostty.removeObject(forKey: Self.sleepDisabledKey)
        }
    }

    /// Starts a run with the chosen time limit and battery floor.
    func start() {
        guard run == nil else { return }
        lastStop = nil

        let coversClosedLid = Self.pmsetDisableSleep(true) || (Self.installSudoersRule() && Self.pmsetDisableSleep(true))
        if coversClosedLid {
            UserDefaults.ghostty.set(true, forKey: Self.sleepDisabledKey)
        }

        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Ghostty Pro keeps this Mac awake" as CFString,
            &assertion)

        let now = Date()
        run = Run(
            startedAt: now,
            until: hours > 0 ? now.addingTimeInterval(TimeInterval(hours) * 3600) : nil,
            minimumBattery: minimumBattery > 0 ? minimumBattery : nil,
            coversClosedLid: coversClosedLid)

        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { _ in
            MainActor.assumeIsolated { Caffeine.shared.check() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
        check()
    }

    /// Stops the run, if there is one, and lets the Mac sleep as usual.
    func stop() {
        checkTimer?.invalidate()
        checkTimer = nil

        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }

        if run?.coversClosedLid == true || UserDefaults.ghostty.bool(forKey: Self.sleepDisabledKey) {
            if Self.pmsetDisableSleep(false) {
                UserDefaults.ghostty.removeObject(forKey: Self.sleepDisabledKey)
            }
        }
        run = nil
    }

    private func check() {
        guard let run else { return }
        guard let reason = Self.stopReason(for: run, now: Date(), battery: Self.battery()) else { return }
        stop()
        lastStop = reason
    }

    /// Why `run` should stop now, if it should.
    static func stopReason(for run: Run, now: Date, battery: (percent: Int, onBattery: Bool)?) -> StopReason? {
        if let until = run.until, now >= until { return .timeLimit }
        if let minimum = run.minimumBattery, let battery, battery.onBattery, battery.percent <= minimum {
            return .battery(battery.percent)
        }
        return nil
    }

    // MARK: Battery

    /// The internal battery's charge and whether the Mac runs on it, or nil without one.
    static func battery() -> (percent: Int, onBattery: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0 else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            return (current * 100 / maximum, onBattery)
        }
        return nil
    }

    // MARK: Sleep with the lid closed

    /// Runs `pmset -a disablesleep` through the sudoers rule, without asking for a password.
    private static func pmsetDisableSleep(_ disable: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", disable ? "1" : "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// The sudoers rule that lets `user` disable and enable sleep, and nothing else. Nil
    /// for a user name that can't be put in the rule safely.
    static func sudoersRule(for user: String) -> String? {
        guard !user.isEmpty,
              user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else { return nil }
        return "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
    }

    /// Asks for an administrator password and installs the sudoers rule. The rule is
    /// checked with `visudo` before it goes in place, so a bad one can't break sudo.
    private static func installSudoersRule() -> Bool {
        guard let rule = sudoersRule(for: NSUserName()) else { return false }
        let script = [
            "tmp=$(/usr/bin/mktemp)",
            "/usr/bin/printf '%s\\n' '\(rule)' > \"$tmp\"",
            "/usr/sbin/visudo -cf \"$tmp\"",
            "/usr/bin/install -m 0440 -o root -g wheel \"$tmp\" \(sudoersFile)",
            "/bin/rm -f \"$tmp\"",
        ].joined(separator: " && ")

        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let prompt = "Ghostty Pro needs your password once to keep this Mac awake with the lid closed."
        let source = "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"

        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }
}
