import AppKit

/// The drop target at the screen edge. A non-activating panel: dragging onto it and clicking it
/// leave Finder the active app, so the shelf does not hide itself.
final class ShelfPanel: NSPanel {
    static let size = NSSize(width: 132, height: 156)
    var onDrop: (([URL]) -> Void)?
    var onDragOver: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    private let spot = DropSpot()
    private let closeButton = NSButton()
    private let pinLabel = NSTextField(labelWithString: "pinned")
    private var visibleGeneration = 0
    private(set) var isShown = false

    init(menu: NSMenu) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let content = NSVisualEffectView()
        content.material = .popover
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 14
        content.layer?.masksToBounds = true
        content.menu = menu

        let title = NSTextField(labelWithString: "Drop Sorter")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        pinLabel.font = .systemFont(ofSize: 9, weight: .medium)
        pinLabel.textColor = .tertiaryLabelColor
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close shelf")
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [title, pinLabel, spacer, closeButton])
        header.spacing = 4

        spot.onDrop = { [weak self] in self?.onDrop?($0) }
        spot.onHover = { [weak self] in self?.onDragOver?($0) }

        let stack = NSStackView(views: [header, spot])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        spot.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -18),
            spot.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
        ])
        contentView = content
        setPinned(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var acceptsDrops: Bool {
        get { spot.enabled }
        set { spot.enabled = newValue }
    }

    func setPinned(_ pinned: Bool) {
        closeButton.isHidden = !pinned
        pinLabel.isHidden = !pinned
    }

    @objc private func closeClicked() { onClose?() }

    // MARK: Slide in and out at the right screen edge

    private func shownFrame() -> NSRect {
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSRect(x: screen.maxX - Self.size.width - 8, y: screen.midY - Self.size.height / 2,
                      width: Self.size.width, height: Self.size.height)
    }

    func slideIn() {
        guard !isShown else { return }
        isShown = true
        visibleGeneration += 1
        let target = shownFrame()
        if !isVisible {
            setFrame(target.offsetBy(dx: Self.size.width + 16, dy: 0), display: false)
            alphaValue = 0
            orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            animator().setFrame(target, display: true)
            animator().alphaValue = 1
        }
    }

    func slideOut() {
        guard isShown else { return }
        isShown = false
        visibleGeneration += 1
        let generation = visibleGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            animator().setFrame(frame.offsetBy(dx: Self.size.width + 16, dy: 0), display: true)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A slideIn during the animation wins.
            if self?.visibleGeneration == generation { self?.orderOut(nil) }
        })
    }
}

/// The main drop spot. Accepts file and folder URLs.
final class DropSpot: NSView {
    var onDrop: (([URL]) -> Void)?
    var onHover: ((Bool) -> Void)?
    var enabled = true
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        let icon = NSImageView(image: NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 30, weight: .light)
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: "Drop to sort")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        if highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            path.fill()
        }
        (highlighted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        path.lineWidth = 1.5
        path.setLineDash([5, 4], count: 2, phase: 0)
        path.stroke()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard enabled else { return [] }
        highlighted = true
        onHover?(true)
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false
        onHover?(false)
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        if highlighted { highlighted = false; onHover?(false) }
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        onHover?(false)
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard enabled, !urls.isEmpty else { return false }
        // Return to Finder first; the chooser opens after the drag session has ended.
        DispatchQueue.main.async { [weak self] in self?.onDrop?(urls) }
        return true
    }
}
