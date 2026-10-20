import AppKit

/// Optional menu-bar icon: Show Shelf, Settings, Quit. Dropping files on it opens the chooser.
final class MenuBarItem: NSObject, NSWindowDelegate, NSDraggingDestination {
    var onDrop: (([URL]) -> Void)?
    private let item: NSStatusItem

    init(menu: NSMenu) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "Drop Sorter")
        item.menu = menu
        // The status bar button has no drag hooks of its own; its window forwards them to the delegate.
        item.button?.window?.registerForDraggedTypes([.fileURL])
        item.button?.window?.delegate = self
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        item.button?.highlight(true)
        return .move
    }
    func draggingExited(_ sender: NSDraggingInfo?) { item.button?.highlight(false) }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        item.button?.highlight(false)
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        DispatchQueue.main.async { [weak self] in self?.onDrop?(urls) }
        return true
    }
}
