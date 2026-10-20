import AppKit

/// The drop target at the screen edge. A non-activating panel: dragging onto it and clicking it
/// leave Finder the active app, so the shelf does not hide itself.
final class ShelfPanel: NSPanel {
    static let width: CGFloat = 140
    var onDrop: (([URL]) -> Void)?
    /// A drop on a favorite spot: folder path, items. Moves at once, no chooser.
    var onDropFavorite: ((String, [URL]) -> Void)?
    var onDragOver: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    var onSettings: (() -> Void)?
    private let spot = DropSpot(symbol: "tray.and.arrow.down", title: "Drop to sort")
    private let favoriteStack = NSStackView()
    private var favoriteSpots: [DropSpot] = []
    private let closeButton = NSButton()
    private let settingsButton = NSButton()
    private let pinLabel = NSTextField(labelWithString: "pinned")
    private var visibleGeneration = 0
    private(set) var isShown = false

    init(menu: NSMenu) {
        super.init(contentRect: NSRect(origin: .zero, size: NSSize(width: Self.width, height: 156)),
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
        settingsButton.bezelStyle = .inline
        settingsButton.isBordered = false
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        settingsButton.contentTintColor = .tertiaryLabelColor
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [title, pinLabel, spacer, settingsButton, closeButton])
        header.spacing = 4

        spot.onDrop = { [weak self] in self?.onDrop?($0) }
        spot.onHover = { [weak self] in self?.onDragOver?($0) }

        favoriteStack.orientation = .vertical
        favoriteStack.spacing = 4
        favoriteStack.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [header, spot, favoriteStack])
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
            spot.heightAnchor.constraint(equalToConstant: 110),
            favoriteStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
        ])
        contentView = content
        setPinned(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var acceptsDrops: Bool {
        get { spot.enabled }
        set {
            spot.enabled = newValue
            favoriteSpots.forEach { $0.enabled = newValue && !$0.missing }
        }
    }

    /// One spot per favorite. `missing` folders are shown dimmed and refuse drops.
    func setFavorites(_ paths: [String], missing: Set<String>) {
        favoriteSpots.forEach { $0.removeFromSuperview() }
        favoriteSpots = zip(paths, ShelfLabels.labels(paths)).map { path, label in
            let f = DropSpot(symbol: "star", title: label, compact: true)
            f.toolTip = missing.contains(path) ? "\(path) (folder not found)" : path
            f.missing = missing.contains(path)
            f.enabled = spot.enabled && !f.missing
            f.onDrop = { [weak self] in self?.onDropFavorite?(path, $0) }
            f.onHover = { [weak self] in self?.onDragOver?($0) }
            f.translatesAutoresizingMaskIntoConstraints = false
            favoriteStack.addArrangedSubview(f)
            f.widthAnchor.constraint(equalTo: favoriteStack.widthAnchor).isActive = true
            f.heightAnchor.constraint(equalToConstant: 30).isActive = true
            return f
        }
        favoriteStack.isHidden = favoriteSpots.isEmpty
        let height = contentView?.fittingSize.height ?? 156
        setContentSize(NSSize(width: Self.width, height: height))
        if isShown { setFrame(shownFrame(), display: true) }
    }

    @objc private func settingsClicked() { onSettings?() }

    func setPinned(_ pinned: Bool) {
        closeButton.isHidden = !pinned
        pinLabel.isHidden = !pinned
    }

    @objc private func closeClicked() { onClose?() }

    // MARK: Slide in and out at the right screen edge

    private func shownFrame() -> NSRect {
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let size = frame.size
        return NSRect(x: screen.maxX - size.width - 8, y: screen.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    func slideIn() {
        guard !isShown else { return }
        isShown = true
        visibleGeneration += 1
        let target = shownFrame()
        if !isVisible {
            setFrame(target.offsetBy(dx: Self.width + 16, dy: 0), display: false)
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
            animator().setFrame(frame.offsetBy(dx: Self.width + 16, dy: 0), display: true)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A slideIn during the animation wins.
            if self?.visibleGeneration == generation { self?.orderOut(nil) }
        })
    }
}

/// A drop spot: the large main spot, or a compact one-line favorite. Accepts file and folder URLs.
final class DropSpot: NSView {
    var onDrop: (([URL]) -> Void)?
    var onHover: ((Bool) -> Void)?
    var enabled = true
    var missing = false { didSet { alphaValue = missing ? 0.4 : 1 } }
    private let compact: Bool
    private var highlighted = false { didSet { needsDisplay = true } }

    init(symbol: String, title: String, compact: Bool = false) {
        self.compact = compact
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: compact ? 11 : 30, weight: compact ? .regular : .light)
        icon.contentTintColor = compact ? .systemYellow : .secondaryLabelColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: compact ? .medium : .regular)
        label.textColor = compact ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingHead
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, label])
        stack.orientation = compact ? .horizontal : .vertical
        stack.spacing = compact ? 5 : 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate(compact ? [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ] : [
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = compact ? 7 : 10
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        if highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            path.fill()
        }
        (highlighted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        path.lineWidth = 1.5
        if !compact { path.setLineDash([5, 4], count: 2, phase: 0) }
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
