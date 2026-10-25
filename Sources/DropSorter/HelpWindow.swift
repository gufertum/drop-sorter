import AppKit
import WebKit

/// The offline help (docs/user rendered into Contents/Resources/Help by build.sh) in a window of its own.
/// Pages inside the help open here; every other link goes to the default browser.
final class HelpWindow: NSWindowController, WKNavigationDelegate {
    private let folder: URL
    private let web: WKWebView

    init(folder: URL) {
        self.folder = folder.standardizedFileURL
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 820, height: 680), configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Drop Sorter Help"
        window.minSize = NSSize(width: 480, height: 360)
        window.contentView = web
        window.setFrameAutosaveName("DropSorterHelp")
        super.init(window: window)
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `page` (e.g. "index.html") and brings the window to the front.
    func show(page: String = "index.html") {
        web.loadFileURL(folder.appendingPathComponent(page), allowingReadAccessTo: folder)
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }

    @objc func goBack(_ sender: Any?) { web.goBack() }
    @objc func goForward(_ sender: Any?) { web.goForward() }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if Self.isInside(url, folder: folder) { return decisionHandler(.allow) }
        if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }

    /// A file inside the help folder (any page, image or anchor); everything else leaves the window.
    static func isInside(_ url: URL, folder: URL) -> Bool {
        guard url.isFileURL else { return false }
        let root = folder.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
