import AppKit

/// Draws the 🎯 app icon, optionally with a banner naming the target folder,
/// so copies of the app can be told apart in Finder, its preview pane and the Dock.
enum IconRenderer {
    static func image(label: String?, size: CGFloat = 1024) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(label: label, in: rect)
            return true
        }
    }

    /// Bitmap at an exact pixel size (for .iconset generation).
    static func png(label: String?, pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(label: label, in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func draw(label: String?, in rect: NSRect) {
        let s = rect.width
        let emoji = NSAttributedString(string: "🎯", attributes: [.font: NSFont.systemFont(ofSize: s * 0.78)])
        let e = emoji.size()
        emoji.draw(at: NSPoint(x: rect.midX - e.width / 2, y: rect.midY - e.height / 2 + (label == nil ? 0 : s * 0.06)))

        guard let label, !label.isEmpty else { return }
        let banner = NSRect(x: s * 0.03, y: s * 0.04, width: s * 0.94, height: s * 0.24)
        NSColor(calibratedWhite: 0.1, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: banner, xRadius: s * 0.06, yRadius: s * 0.06).fill()

        // Shrink the font until the label fits; very long names get truncated.
        var fontSize = s * 0.15
        var text: NSAttributedString
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        style.alignment = .center
        repeat {
            text = NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: style,
            ])
            fontSize -= s * 0.005
        } while text.size().width > banner.width * 0.92 && fontSize > s * 0.07
        let h = text.size().height
        text.draw(in: NSRect(x: banner.minX + banner.width * 0.04, y: banner.midY - h / 2,
                             width: banner.width * 0.92, height: h))
    }
}
