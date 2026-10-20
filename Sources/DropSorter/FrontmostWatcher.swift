import AppKit

/// Tracks the active app, and whether Finder has open windows, so the shelf can follow Finder.
final class FrontmostWatcher {
    var onChange: (() -> Void)?
    private(set) var frontmost: String?
    /// Only needed when the shelf must not show for the bare desktop; costs one window list per second.
    var watchFinderWindows = false
    private var lastFinderWindows = false
    private var observer: NSObjectProtocol?
    private var timer: Timer?

    func start() {
        frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontmost = app?.bundleIdentifier
            self?.onChange?()
        }
        // Opening or closing a Finder window does not change the active app, so poll while Finder is in front.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.watchFinderWindows, self.frontmost == ShelfVisibility.finderBundleID else { return }
            let now = Self.finderHasWindows()
            if now != self.lastFinderWindows {
                self.lastFinderWindows = now
                self.onChange?()
            }
        }
    }

    /// Finder windows are on layer 0; the desktop icons live on a lower layer and do not count.
    /// Needs no Screen Recording permission: only owner and layer are read, not window titles.
    static func finderHasWindows() -> Bool {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: ShelfVisibility.finderBundleID).first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return list.contains { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    }
}
