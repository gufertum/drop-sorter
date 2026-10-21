import Foundation

/// Decides whether the shelf is shown. Pure, so the rules are testable without AppKit.
struct ShelfVisibility {
    static let finderBundleID = "com.apple.finder"

    enum Decision: Equatable {
        case show
        /// Hide after the configured delay, so a quick app switch does not make the shelf flicker.
        case hideLater
        /// Leave the shelf as it is (Drop Sorter itself became active, e.g. for the chooser).
        case keep
    }

    var showOnDesktop = true
    var ownBundleID = "li.sudo.dropsorter"

    /// - Parameters:
    ///   - frontmost: bundle id of the active app.
    ///   - finderHasWindows: Finder has at least one open window (not just the desktop).
    ///   - pinned: just launched (or launched again, or Show Shelf); see `releasesPin`.
    ///   - busy: chooser open or a drag over the shelf.
    func decide(frontmost: String?, finderHasWindows: Bool, pinned: Bool, busy: Bool) -> Decision {
        if pinned || busy { return .show }
        if frontmost == ownBundleID { return .keep }
        if frontmost == Self.finderBundleID && (finderHasWindows || showOnDesktop) { return .show }
        return .hideLater
    }

    /// The launch pin lasts until the user moves on to another app: activating Finder or Drop Sorter
    /// itself (e.g. Settings on the first run) keeps it, any other app ends it. ✕ ends it at once.
    func releasesPin(activated: String?) -> Bool {
        guard let activated else { return false }
        return activated != Self.finderBundleID && activated != ownBundleID
    }
}
