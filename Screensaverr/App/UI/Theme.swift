import AppKit

enum Theme {
    static let background = NSColor(srgbRed: 0.035, green: 0.043, blue: 0.067, alpha: 1)
    static let textPrimary = NSColor(white: 1, alpha: 0.96)
    static let textSecondary = NSColor(white: 1, alpha: 0.66)
    static let textTertiary = NSColor(white: 1, alpha: 0.42)
    static let hairline = NSColor(white: 1, alpha: 0.09)
    static let panelFill = NSColor(white: 1, alpha: 0.055)
    static let placeholderTop = NSColor(srgbRed: 0.20, green: 0.22, blue: 0.30, alpha: 1)
    static let placeholderBottom = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.16, alpha: 1)

    static let green = NSColor(srgbRed: 0.27, green: 0.84, blue: 0.53, alpha: 1)
    static let amber = NSColor(srgbRed: 1.00, green: 0.76, blue: 0.28, alpha: 1)
    static let red = NSColor(srgbRed: 1.00, green: 0.42, blue: 0.42, alpha: 1)
    static let blue = NSColor(srgbRed: 0.38, green: 0.65, blue: 1.00, alpha: 1)
    static let teal = NSColor(srgbRed: 0.30, green: 0.82, blue: 0.85, alpha: 1)
    static let violet = NSColor(srgbRed: 0.62, green: 0.53, blue: 1.00, alpha: 1)
    static let orange = NSColor(srgbRed: 1.00, green: 0.60, blue: 0.22, alpha: 1)

    static func accent(_ kind: ServiceKind) -> NSColor {
        switch kind {
        case .sonarr: return NSColor(srgbRed: 0.24, green: 0.75, blue: 0.98, alpha: 1)
        case .radarr: return NSColor(srgbRed: 1.00, green: 0.78, blue: 0.24, alpha: 1)
        case .seerr: return violet
        case .sabnzbd: return green
        case .tautulli: return orange
        }
    }

    static func color(for status: RequestStatus) -> NSColor {
        switch status {
        case .pendingApproval: return amber
        case .approved, .processing: return blue
        case .partiallyAvailable: return teal
        case .available: return green
        case .declined, .failed: return red
        case .deleted: return textTertiary
        }
    }

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, monospacedDigits: Bool = false) -> NSFont {
        monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: descriptor, size: size) ?? base
        }
        return base
    }
}

/// Everything is laid out on a 1920×1080 reference canvas and scaled to the real screen,
/// so the same design works on a 6K display and in the tiny System Settings preview.
struct Metrics {
    let scale: CGFloat

    init(size: CGSize) {
        scale = max(0.05, min(size.width / 1920, size.height / 1080))
    }

    func callAsFunction(_ value: CGFloat) -> CGFloat { value * scale }
}
