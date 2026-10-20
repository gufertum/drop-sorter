import AppKit

/// Transparent container that draws an accent-coloured glow around a rounded child view (shelf,
/// chooser, toast), so they stand out on dark backgrounds. The window must be `margin` larger on every
/// side than the child; the window's own shadow is turned off, the glow replaces it.
final class GlowContainer: NSView {
    let margin: CGFloat
    private let cornerRadius: CGFloat

    init(content: NSView, margin: CGFloat = 16, cornerRadius: CGFloat) {
        self.margin = margin
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowOffset = .zero
        layer?.shadowRadius = 12
        setGlow(0.6)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            content.topAnchor.constraint(equalTo: topAnchor, constant: margin),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margin),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// 0 = no glow, 1 = full.
    func setGlow(_ opacity: Float) {
        layer?.shadowColor = NSColor.controlAccentColor.cgColor
        layer?.shadowOpacity = opacity
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: margin, dy: margin),
                                   cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }

    /// Accent colour may change in System Settings while the app runs.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.shadowColor = NSColor.controlAccentColor.cgColor
    }
}
