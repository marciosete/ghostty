import Foundation

/// What this build is: Maggie, the Ghostty it was forked from, or a build under some
/// other bundle ID. `fork/package.sh` sets Maggie's.
enum Maggie {
    static let bundleID = "com.marciosete.maggie"

    /// Where releases are published, and the update feed with them.
    static let releasesURL = "https://github.com/marciosete/maggie/releases"
    static let feedURL = "\(releasesURL)/latest/download/appcast.xml"

    static var isMaggie: Bool {
        Bundle.main.bundleIdentifier == bundleID
    }

    static var isGhostty: Bool {
        Bundle.main.bundleIdentifier?.hasPrefix("com.mitchellh.ghostty") ?? false
    }
}
