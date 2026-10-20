import AppKit

// MARK: - Toast

/// Clickable, non-activating overlay in the top-right corner. Stays while hovered.
final class Toast: NSObject {
    private var panel: NSPanel?
    private var timer: Timer?
    private var onClick: (() -> Void)?
    private var duration: TimeInterval = 8
    var onDismiss: (() -> Void)?
    var isShowing: Bool { panel != nil }

    func show(title: String, lines: [String], footer: String, isError: Bool, onClick: @escaping () -> Void) {
        dismiss(notify: false)
        self.onClick = onClick
        duration = isError ? 20 : 8
        let width: CGFloat = 400

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = isError ? .systemRed : .labelColor
        let body = NSTextField(wrappingLabelWithString: lines.joined(separator: "\n"))
        body.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        body.preferredMaxLayoutWidth = width - 32
        let foot = NSTextField(labelWithString: footer)
        foot.font = .systemFont(ofSize: 11)
        foot.textColor = .secondaryLabelColor
        [titleLabel, body, foot].forEach { $0.isSelectable = false }

        let stack = NSStackView(views: [titleLabel, body, foot])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = ClickView { [weak self] hovering in
            hovering ? self?.timer?.invalidate() : self?.startTimer()
        } onClick: { [weak self] in
            self?.onClick?()
            self?.dismiss(notify: true)
        }
        content.material = .popover
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
        let size = stack.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 16))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.dismiss(notify: true)
        }
    }

    func dismiss(notify: Bool) {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        if notify { onDismiss?() }
    }
}

final class ClickView: NSVisualEffectView {
    private let onHover: (Bool) -> Void
    private let onClick: () -> Void

    init(onHover: @escaping (Bool) -> Void, onClick: @escaping () -> Void) {
        self.onHover = onHover
        self.onClick = onClick
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
    override func mouseUp(with event: NSEvent) { onClick() }
}

// MARK: - Drop zone in the window

final class DropZone: NSBox {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fillColor = .selectedContentBackgroundColor.withAlphaComponent(0.2)
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { fillColor = .clear }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fillColor = .clear
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private let store = ConfigStore(resourceDirectory: Bundle.main.resourceURL!)
    private var config = DropConfig()
    private var launchedWithFiles = false
    private var finishedLaunching = false
    private let toast = Toast()

    private var window: NSWindow?
    private let targetLabel = NSTextField(labelWithString: "")
    private let patternField = NSTextField(string: "")
    private let previewLabel = NSTextField(labelWithString: "")

    /// The bundle's file name, so a renamed copy shows its own name.
    private var appName: String { Bundle.main.bundleURL.deletingPathExtension().lastPathComponent }
    private var targetURL: URL? { config.target.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        do {
            config = try store.load()
        } catch {
            alert("Cannot read configuration", "\(store.url.path)\n\n\(error.localizedDescription)\n\nUsing defaults until you change a setting.")
        }
        NSApp.applicationIconImage = IconRenderer.image(label: targetURL?.lastPathComponent)
        // Copies made by hand or whose icon was lost have a target but no labelled Finder icon yet.
        let customIcon = Bundle.main.bundleURL.appendingPathComponent("Icon\r")
        if config.target != nil && !FileManager.default.fileExists(atPath: customIcon.path) {
            updateIcons()
        }
        toast.onDismiss = { [weak self] in self?.quitIfIdle() }
    }

    // Files dropped on the app icon arrive here, before applicationDidFinishLaunching on a cold start.
    func application(_ application: NSApplication, open urls: [URL]) {
        if !finishedLaunching { launchedWithFiles = true }
        handle(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishedLaunching = true
        if !launchedWithFiles { showWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        commitPattern()
        window = nil
        quitIfIdle()
    }

    /// Drop-only launches quit once the toast is gone; an open window keeps the app alive.
    private func quitIfIdle() {
        if window == nil && !toast.isShowing { NSApp.terminate(nil) }
    }

    // MARK: Drop handling

    private func handle(_ urls: [URL]) {
        guard let target = targetURL else {
            showWindow()
            alert("No target folder set", "Choose a target folder for \(appName) first.")
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
            showWindow()
            alert("Target folder not found", target.path)
            return
        }
        let result = Mover.move(urls, to: target, pattern: config.pattern)
        showToast(result, target: target)
    }

    private func showToast(_ r: MoveResult, target: URL) {
        let maxLines = 6
        var lines = r.moved.prefix(maxLines).map { "→ " + $0.lastPathComponent }
        if r.moved.count > maxLines { lines.append("… and \(r.moved.count - maxLines) more") }
        lines += r.failures.map { "✗ \($0.name): \($0.reason)" }
        let title = r.failures.isEmpty
            ? "Moved \(r.moved.count) item\(r.moved.count == 1 ? "" : "s") to \(target.lastPathComponent)"
            : "\(r.failures.count) of \(r.moved.count + r.failures.count) item(s) failed"
        toast.show(title: title, lines: lines, footer: "Click to show in Finder: \(target.path)",
                   isError: !r.failures.isEmpty) {
            if r.moved.isEmpty {
                NSWorkspace.shared.open(target)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(r.moved)
            }
        }
    }

    // MARK: Window

    private func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let heading = { (s: String) -> NSTextField in
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 12, weight: .semibold)
            return l
        }
        let small = { (s: String) -> NSTextField in
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            return l
        }

        targetLabel.lineBreakMode = .byTruncatingMiddle
        targetLabel.isSelectable = true
        targetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chooseButton = NSButton(title: "Choose…", target: self, action: #selector(chooseTarget))
        let openButton = NSButton(title: "Show in Finder", target: self, action: #selector(openTarget))
        let targetRow = NSStackView(views: [targetLabel, chooseButton, openButton])

        patternField.delegate = self
        patternField.placeholderString = Renamer.defaultPattern
        patternField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let resetButton = NSButton(title: "Default", target: self, action: #selector(resetPattern))
        let patternRow = NSStackView(views: [patternField, resetButton])
        previewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        previewLabel.lineBreakMode = .byTruncatingMiddle

        let drop = DropZone()
        drop.boxType = .custom
        drop.borderColor = .tertiaryLabelColor
        drop.borderWidth = 1
        drop.cornerRadius = 10
        drop.titlePosition = .noTitle
        drop.onDrop = { [weak self] in self?.handle($0) }
        let dropLabel = small("Drop files or folders here or onto the app icon")
        dropLabel.alignment = .center
        dropLabel.translatesAutoresizingMaskIntoConstraints = false
        drop.contentView?.addSubview(dropLabel)
        drop.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            heading("Target folder"), targetRow,
            heading("Rename pattern"), patternRow, previewLabel,
            small("Tokens: " + Renamer.tokenHelp),
            drop,
            small("Settings belong to this copy only (\(Bundle.main.bundleURL.lastPathComponent)).")
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: targetRow)
        stack.setCustomSpacing(16, after: stack.views[5])
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 560),
            targetRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            patternRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            previewLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            drop.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            drop.heightAnchor.constraint(equalToConstant: 80),
            dropLabel.centerXAnchor.constraint(equalTo: drop.centerXAnchor),
            dropLabel.centerYAnchor.constraint(equalTo: drop.centerYAnchor),
        ])

        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = appName
        w.contentView = container
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        refreshUI()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshUI() {
        targetLabel.stringValue = config.target ?? "— not set —"
        targetLabel.textColor = config.target == nil ? .systemRed : .labelColor
        patternField.stringValue = config.pattern
        updatePreview()
    }

    private func updatePreview() {
        let pattern = patternField.stringValue
        do {
            let file = try Renamer.render(pattern, originalName: "invoice.pdf", isDirectory: false, date: Date())
            let dir = try Renamer.render(pattern, originalName: "Scans", isDirectory: true, date: Date())
            previewLabel.stringValue = "invoice.pdf → \(file)    Scans/ → \(dir)/"
            previewLabel.textColor = .secondaryLabelColor
        } catch {
            previewLabel.stringValue = error.localizedDescription
            previewLabel.textColor = .systemRed
        }
    }

    func controlTextDidChange(_ obj: Notification) { updatePreview() }
    func controlTextDidEndEditing(_ obj: Notification) { commitPattern() }

    private func commitPattern() {
        let pattern = patternField.stringValue
        guard pattern != config.pattern,
              (try? Renamer.render(pattern, originalName: "x.pdf", isDirectory: false, date: Date())) != nil
        else { return }
        var updated = config
        updated.pattern = pattern
        save(updated)
    }

    @objc private func resetPattern() {
        patternField.stringValue = Renamer.defaultPattern
        updatePreview()
        commitPattern()
    }

    @objc private func chooseTarget() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use as Target"
        panel.message = "Dropped files are moved into this folder."
        panel.directoryURL = targetURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var updated = config
        updated.target = url.path
        save(updated)
    }

    @objc private func openTarget() {
        guard let targetURL else { return chooseTarget() }
        NSWorkspace.shared.open(targetURL)
    }

    private func save(_ updated: DropConfig) {
        do {
            try store.save(updated)
            let targetChanged = updated.target != config.target
            config = updated
            if targetChanged { updateIcons() }
        } catch {
            alert("Cannot save configuration", "\(store.url.path)\n\n\(error.localizedDescription)")
        }
        refreshUI()
    }

    /// Dock icon plus the Finder icon of this copy, labelled with the target folder name.
    private func updateIcons() {
        let icon = IconRenderer.image(label: targetURL?.lastPathComponent)
        NSApp.applicationIconImage = icon
        if !NSWorkspace.shared.setIcon(icon, forFile: Bundle.main.bundlePath, options: []) {
            NSLog("DropMover: could not set Finder icon on '%@'", Bundle.main.bundlePath)
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appItem.submenu?.addItem(.separator())
        appItem.submenu?.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        windowItem.submenu = NSMenu(title: "Window")
        windowItem.submenu?.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(windowItem)
        return main
    }

    @objc private func showSettings() { showWindow() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
