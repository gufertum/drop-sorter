import AppKit

/// Non-activating overlay in the top-right corner with action buttons (Undo, Reveal).
/// Stays while hovered; errors stay longer.
final class SortToast: NSObject {
    struct Action {
        let title: String
        let run: () -> Void
    }

    private var panel: NSPanel?
    private var timer: Timer?
    private var duration: TimeInterval = 8

    /// `isWarning`: orange and as long as an error, for things the user should decide (identical files).
    func show(title: String, lines: [String], isError: Bool, isWarning: Bool = false, actions: [Action]) {
        dismiss()
        duration = isError || isWarning ? 20 : 8
        let width: CGFloat = 400

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = isError ? .systemRed : isWarning ? .systemOrange : .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        let body = NSTextField(wrappingLabelWithString: lines.joined(separator: "\n"))
        body.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        body.preferredMaxLayoutWidth = width - 32
        body.isSelectable = false

        var views: [NSView] = [titleLabel]
        if !lines.isEmpty { views.append(body) }
        if !actions.isEmpty {
            let buttons = actions.map { a -> NSButton in
                let b = ActionButton(title: a.title) { [weak self] in
                    a.run()
                    self?.dismiss()
                }
                b.bezelStyle = .rounded
                b.controlSize = .small
                return b
            }
            views.append(NSStackView(views: buttons))
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = HoverView { [weak self] hovering in
            hovering ? self?.timer?.invalidate() : self?.startTimer()
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
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: width - 32),
        ])
        let glow = GlowContainer(content: content, cornerRadius: 12)
        if isError { glow.color = .systemRed } else if isWarning { glow.color = .systemOrange }
        let size = glow.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // the glow replaces the window shadow
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = glow
        if let screen = NSScreen.main?.visibleFrame {
            // The visible toast keeps 16 pt from the top right corner; the glow margin lies outside.
            let pad = 16 - glow.margin
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - pad, y: screen.maxY - size.height - pad))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in self?.dismiss() }
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// A button that reacts to the first click in an inactive, non-activating panel.
final class ActionButton: NSButton {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func fire() { run() }
}

final class HoverView: NSVisualEffectView {
    private let onHover: (Bool) -> Void
    init(onHover: @escaping (Bool) -> Void) {
        self.onHover = onHover
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
}
