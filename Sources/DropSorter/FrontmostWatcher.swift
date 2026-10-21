import AppKit

/// Tracks the active app, and whether Finder has open windows, so the shelf can follow Finder.
final class FrontmostWatcher {
    var onChange: (() -> Void)?
    private(set) var frontmost: String?
    /// Also report Finder windows opening or closing (only needed when the shelf must not show for the
    /// bare desktop).
    var watchFinderWindows = false
    private var lastFinderWindows = false
    private var lastFinderScreen: Int?
    private var observer: NSObjectProtocol?
    private var timer: Timer?

    func start() {
        frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontmost = app?.bundleIdentifier
            self?.lastFinderScreen = Self.finderScreenIndex()
            self?.onChange?()
        }
        // Opening, closing or switching Finder windows does not change the active app, so poll while
        // Finder is in front: one window list per second.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.frontmost == ShelfVisibility.finderBundleID else { return }
            let windows = Self.finderWindows()
            let screen = Self.screenIndex(of: windows.first)
            let hasWindows = !windows.isEmpty
            if screen != self.lastFinderScreen || (self.watchFinderWindows && hasWindows != self.lastFinderWindows) {
                self.lastFinderScreen = screen
                self.lastFinderWindows = hasWindows
                self.onChange?()
            }
        }
    }

    static func finderHasWindows() -> Bool { !finderWindows().isEmpty }

    /// The screen of the frontmost Finder window, so the shelf shows where Finder is (which need not
    /// be the screen with the mouse). Nil without a Finder window.
    static func finderScreen() -> NSScreen? {
        finderScreenIndex().map { NSScreen.screens[$0] }
    }

    private static func finderScreenIndex() -> Int? { screenIndex(of: finderWindows().first) }

    private static func screenIndex(of window: CGRect?) -> Int? {
        guard let window else { return nil }
        return ShelfVisibility.screenIndex(forWindow: window, screens: NSScreen.screens.map(\.frame))
    }

    /// Bounds of Finder's windows, frontmost first (the window list is in front-to-back order). Finder
    /// windows are on layer 0; the desktop icons live on a lower layer and do not count.
    /// Needs no Screen Recording permission: only owner, layer and bounds are read, not window titles.
    static func finderWindows() -> [CGRect] {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: ShelfVisibility.finderBundleID).first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { info -> CGRect? in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
            return rect
        }
    }
}
