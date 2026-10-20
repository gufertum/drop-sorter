import AppKit

/// The drop target at the bottom right of the screen. A non-activating panel: dragging onto it and
/// clicking it leave Finder the active app, so the shelf does not hide itself.
final class ShelfPanel: NSPanel {
    /// Width of the visible shelf (without the glow margin).
    static let width: CGFloat = 200
    /// Distance of the visible shelf from the right and bottom edge of the usable screen area.
    static let inset: CGFloat = 24
    /// A drop on the main spot; `.copy` when ⌥ was held.
    var onDrop: (([URL], TransferMode) -> Void)?
    /// A drop on a favorite spot: favorite, items, mode (⌥ or the favorite's own setting). No chooser.
    var onDropFavorite: ((Favorite, [URL], TransferMode) -> Void)?
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
    private weak var frameView: NSView?
    private let glow: GlowContainer
    private(set) var isShown = false

    init(menu: NSMenu) {
        let content = NSVisualEffectView()
        glow = GlowContainer(content: content, cornerRadius: 14)
        super.init(contentRect: NSRect(origin: .zero, size: NSSize(width: Self.width, height: 200)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false  // the glow replaces the window shadow
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        content.material = .popover
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 14
        content.layer?.masksToBounds = true
        // An accent frame, so the shelf stands out on dark backgrounds too.
        content.layer?.borderWidth = 1.5
        frameView = content
        content.menu = menu

        let title = NSTextField(labelWithString: "Drop Sorter")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
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

        spot.onDrop = { [weak self] urls, copy in self?.onDrop?(urls, copy ? .copy : .move) }
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
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -18),
            spot.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            spot.heightAnchor.constraint(equalToConstant: 150),
            favoriteStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
        ])
        contentView = glow
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
    func setFavorites(_ favorites: [Favorite], missing: Set<String>) {
        favoriteSpots.forEach { $0.removeFromSuperview() }
        favoriteSpots = zip(favorites, ShelfLabels.labels(favorites.map(\.folder))).map { fav, label in
            let path = fav.folder
            let f = DropSpot(symbol: fav.copy ? "plus.square.on.square" : "star", title: label, compact: true)
            f.alwaysCopy = fav.copy
            f.toolTip = (missing.contains(path) ? "\(path) (folder not found)" : path) + (fav.copy ? " · copies" : "")
            f.missing = missing.contains(path)
            f.enabled = spot.enabled && !f.missing
            f.onDrop = { [weak self] urls, copy in self?.onDropFavorite?(fav, urls, copy || fav.copy ? .copy : .move) }
            f.onHover = { [weak self] in self?.onDragOver?($0) }
            f.translatesAutoresizingMaskIntoConstraints = false
            favoriteStack.addArrangedSubview(f)
            f.widthAnchor.constraint(equalTo: favoriteStack.widthAnchor).isActive = true
            f.heightAnchor.constraint(equalToConstant: 38).isActive = true
            return f
        }
        favoriteStack.isHidden = favoriteSpots.isEmpty
        setContentSize(glow.fittingSize)
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
        // The window includes the glow margin; the visible shelf keeps `inset` from the edges.
        let pad = Self.inset - glow.margin
        return NSRect(x: screen.maxX - size.width - pad, y: screen.minY + pad, width: size.width, height: size.height)
    }

    /// Draws attention: the frame flashes in the accent colour a few times (first start, relaunch).
    func pulse() {
        guard let layer = frameView?.layer else { return }
        layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor
        let width = CABasicAnimation(keyPath: "borderWidth")
        width.fromValue = 1.5
        width.toValue = 5
        let color = CABasicAnimation(keyPath: "borderColor")
        color.toValue = NSColor.controlAccentColor.cgColor
        let group = CAAnimationGroup()
        group.animations = [width, color]
        let glowPulse = CABasicAnimation(keyPath: "shadowOpacity")
        glowPulse.toValue = 1
        glowPulse.duration = 0.45
        glowPulse.autoreverses = true
        glowPulse.repeatCount = 3
        glow.layer?.add(glowPulse, forKey: "pulse")
        group.duration = 0.45
        group.autoreverses = true
        group.repeatCount = 3
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(group, forKey: "pulse")
    }

    func slideIn() {
        // The accent colour can change in System Settings; take the current one.
        frameView?.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor
        guard !isShown else { return }
        isShown = true
        visibleGeneration += 1
        let target = shownFrame()
        if !isVisible {
            // Pops up from below the bottom edge.
            setFrame(target.offsetBy(dx: 0, dy: -(target.height + Self.inset)), display: false)
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
            animator().setFrame(frame.offsetBy(dx: 0, dy: -(frame.height + Self.inset)), display: true)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A slideIn during the animation wins.
            if self?.visibleGeneration == generation { self?.orderOut(nil) }
        })
    }
}

/// A drop spot: the large main spot, or a compact one-line favorite. Accepts file and folder URLs.
final class DropSpot: NSView {
    /// Items, and whether to copy (⌥ held while dropping).
    var onDrop: (([URL], Bool) -> Void)?
    var onHover: ((Bool) -> Void)?
    var enabled = true
    /// A favorite set to copy: the cursor shows the copy badge without ⌥.
    var alwaysCopy = false
    var missing = false { didSet { alphaValue = missing ? 0.4 : 1 } }
    private let compact: Bool
    private var highlighted = false {
        didSet {
            needsDisplay = true
            // A glow around the spot while files hover over it.
            layer?.shadowColor = NSColor.controlAccentColor.cgColor
            layer?.shadowOpacity = highlighted ? 0.9 : 0
        }
    }

    init(symbol: String, title: String, compact: Bool = false) {
        self.compact = compact
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowOffset = .zero
        layer?.shadowRadius = 8
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: compact ? 14 : 40, weight: compact ? .regular : .light)
        icon.contentTintColor = compact ? .systemYellow : .controlAccentColor
        // NSImageView registers itself for file drags; over the icon it would take the drag away from
        // the spot (highlight off, drop lost). Only the spot itself is a drop target.
        icon.unregisterDraggedTypes()
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: compact ? 12 : 13, weight: compact ? .medium : .regular)
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
        (highlighted ? NSColor.controlAccentColor
            : compact ? NSColor.tertiaryLabelColor : NSColor.controlAccentColor.withAlphaComponent(0.7)).setStroke()
        path.lineWidth = 1.5
        if !compact { path.setLineDash([5, 4], count: 2, phase: 0) }
        path.stroke()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard enabled else { return [] }
        highlighted = true
        onHover?(true)
        return operation()
    }
    /// Re-evaluated while the mouse moves, so pressing ⌥ mid-drag switches the cursor badge.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        enabled ? operation() : []
    }
    private func operation() -> NSDragOperation {
        alwaysCopy || Self.optionHeld ? .copy : .move
    }
    static var optionHeld: Bool { NSEvent.modifierFlags.contains(.option) }
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
        let copy = Self.optionHeld
        // Return to Finder first; the chooser opens after the drag session has ended.
        DispatchQueue.main.async { [weak self] in self?.onDrop?(urls, copy) }
        return true
    }
}
