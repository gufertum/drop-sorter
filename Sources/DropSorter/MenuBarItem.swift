import AppKit

/// Optional menu-bar icon: Show Shelf, Settings, Quit. Dropping files on it opens the chooser.
final class MenuBarItem: NSObject, NSWindowDelegate, NSDraggingDestination {
    var onDrop: (([URL], TransferMode) -> Void)?
    var onReceiveFailed: ((Error) -> Void)?
    private let item: NSStatusItem

    init(menu: NSMenu) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "Drop Sorter")
        item.menu = menu
        // The status bar button has no drag hooks of its own; its window forwards them to the delegate.
        item.button?.window?.registerForDraggedTypes(DroppedFiles.draggedTypes)
        item.button?.window?.delegate = self
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        item.button?.highlight(true)
        return operation(sender)
    }
    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }
    private func operation(_ sender: NSDraggingInfo) -> NSDragOperation {
        DroppedFiles.operation(sender, wanted: DropSpot.optionHeld ? .copy : .move)
    }
    func draggingExited(_ sender: NSDraggingInfo?) { item.button?.highlight(false) }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        item.button?.highlight(false)
        let pasteboard = sender.draggingPasteboard
        let urls = DroppedFiles.fileURLs(pasteboard)
        if urls.isEmpty {
            guard DroppedFiles.hasPromises(pasteboard) else { return false }
            // Received files are moved out of the staging folder.
            DroppedFiles.receivePromises(pasteboard) { [weak self] result in
                switch result {
                case .success(let received): self?.onDrop?(received, .move)
                case .failure(let error): self?.onReceiveFailed?(error)
                }
            }
            return true
        }
        let mode: TransferMode = DropSpot.optionHeld || operation(sender) == .copy ? .copy : .move
        DispatchQueue.main.async { [weak self] in self?.onDrop?(urls, mode) }
        return true
    }
}
