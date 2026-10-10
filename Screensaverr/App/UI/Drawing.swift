import AppKit

/// Small Core Graphics / AppKit drawing helpers. All views using them are flipped (y grows down).
enum Draw {
    static func attributes(
        _ font: NSFont,
        _ color: NSColor,
        alignment: NSTextAlignment = .left,
        kern: CGFloat = 0
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        if kern != 0 { attributes[.kern] = kern }
        return attributes
    }

    /// Draws a single line, truncated with "…" to fit `rect.width`. Returns the drawn width.
    @discardableResult
    static func text(
        _ string: String,
        in rect: CGRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left,
        kern: CGFloat = 0
    ) -> CGFloat {
        guard rect.width > 1, !string.isEmpty else { return 0 }
        let attributed = NSAttributedString(string: string, attributes: attributes(font, color, alignment: alignment, kern: kern))
        let height = ceil(font.ascender - font.descender + font.leading) + 2
        let lineRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(rect.height, height))
        attributed.draw(with: lineRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return min(attributed.size().width, rect.width)
    }

    static func width(_ string: String, font: NSFont, kern: CGFloat = 0) -> CGFloat {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if kern != 0 { attributes[.kern] = kern }
        return ceil((string as NSString).size(withAttributes: attributes).width)
    }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    static func roundedRect(_ rect: CGRect, radius: CGFloat, fill: NSColor) {
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    /// Draws `image` cropped to fill `rect` (like `.resizeAspectFill`), clipped to rounded corners.
    static func image(_ image: NSImage, in rect: CGRect, radius: CGFloat, opacity: CGFloat = 1) {
        let size = image.size
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let cropSize = CGSize(width: rect.width / scale, height: rect.height / scale)
        let source = CGRect(
            x: (size.width - cropSize.width) / 2,
            y: (size.height - cropSize.height) / 2,
            width: cropSize.width,
            height: cropSize.height
        )
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        image.draw(in: rect, from: source, operation: .sourceOver, fraction: opacity, respectFlipped: true, hints: [
            .interpolation: NSNumber(value: NSImageInterpolation.high.rawValue),
        ])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Poster with a soft shadow and a hairline border; a monogram placeholder until artwork arrives.
    static func poster(_ image: NSImage?, title: String, in rect: CGRect, radius: CGFloat, accent: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = radius * 1.6
        shadow.shadowOffset = NSSize(width: 0, height: -radius * 0.4)
        shadow.set()
        roundedRect(rect, radius: radius, fill: Theme.placeholderBottom)
        NSGraphicsContext.restoreGraphicsState()

        if let image {
            Draw.image(image, in: rect, radius: radius)
        } else {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
            NSGradient(starting: Theme.placeholderTop, ending: Theme.placeholderBottom)?.draw(in: rect, angle: 90)
            let initials = title.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
            let font = Theme.roundedFont(rect.width * 0.32, .semibold)
            let height = lineHeight(font)
            text(initials, in: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
                 font: font, color: accent.withAlphaComponent(0.8), alignment: .center)
            NSGraphicsContext.restoreGraphicsState()
        }

        Theme.hairline.setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        border.stroke()
    }

    /// A capsule label, e.g. "Pending". Returns its width.
    @discardableResult
    static func pill(
        _ string: String,
        at origin: CGPoint,
        font: NSFont,
        color: NSColor,
        filled: Bool = false,
        height: CGFloat
    ) -> CGFloat {
        let padding = height * 0.5
        let width = Draw.width(string, font: font) + padding * 2
        let rect = CGRect(x: origin.x, y: origin.y, width: width, height: height)
        roundedRect(rect, radius: height / 2, fill: color.withAlphaComponent(filled ? 0.9 : 0.18))
        let lineHeight = Draw.lineHeight(font)
        text(string, in: CGRect(x: rect.minX, y: rect.midY - lineHeight / 2, width: width, height: lineHeight),
             font: font, color: filled ? Theme.background : color, alignment: .center)
        return width
    }

    static func progressBar(_ progress: Double, in rect: CGRect, color: NSColor) {
        roundedRect(rect, radius: rect.height / 2, fill: NSColor(white: 1, alpha: 0.10))
        let clamped = CGFloat(min(max(progress, 0), 1))
        guard clamped > 0 else { return }
        let filled = CGRect(x: rect.minX, y: rect.minY, width: max(rect.height, rect.width * clamped), height: rect.height)
        roundedRect(filled, radius: rect.height / 2, fill: color)
    }

    static func dot(at center: CGPoint, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
    }
}
