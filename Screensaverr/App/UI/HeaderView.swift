import AppKit

/// Clock, date and a row of service status lights.
final class HeaderView: NSView {
    var metrics = Metrics(size: CGSize(width: 1920, height: 1080)) {
        didSet { needsDisplay = true }
    }

    var statuses: [(kind: ServiceKind, health: ServiceHealth)] = [] {
        didSet { needsDisplay = true }
    }

    private var renderedMinute = ""

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return formatter
    }()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Redraws only when the displayed minute changes.
    func tick(_ now: Date) {
        let minute = timeFormatter.string(from: now)
        if minute != renderedMinute { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let m = metrics
        let now = Date()
        let time = timeFormatter.string(from: now)
        renderedMinute = time

        // Split "9:41 PM" so the AM/PM marker can be smaller.
        var mainTime = time
        var suffix = ""
        if let range = time.range(of: #"[^\d:]+$"#, options: .regularExpression) {
            mainTime = String(time[..<range.lowerBound])
            suffix = String(time[range]).trimmingCharacters(in: .whitespaces)
        }

        let clockFont = Theme.font(m(92), .light, monospacedDigits: true)
        let clockHeight = Draw.lineHeight(clockFont)
        let clockWidth = Draw.text(mainTime, in: CGRect(x: 0, y: 0, width: bounds.width * 0.6, height: clockHeight),
                                   font: clockFont, color: Theme.textPrimary)
        if !suffix.isEmpty {
            let suffixFont = Theme.font(m(30), .regular)
            let y = clockFont.ascender - suffixFont.ascender
            Draw.text(suffix, in: CGRect(x: clockWidth + m(12), y: y, width: m(120), height: Draw.lineHeight(suffixFont)),
                      font: suffixFont, color: Theme.textSecondary)
        }

        let dateFont = Theme.font(m(28), .medium)
        Draw.text(dateFormatter.string(from: now),
                  in: CGRect(x: m(4), y: clockHeight - m(6), width: bounds.width * 0.6, height: Draw.lineHeight(dateFont)),
                  font: dateFont, color: Theme.textSecondary)

        drawStatuses(m)
    }

    private func drawStatuses(_ m: Metrics) {
        let font = Theme.font(m(17), .medium)
        let dotRadius = m(5)
        let spacing = m(26)
        var x = bounds.width
        let y = m(30)
        for status in statuses.reversed() where status.health != .off {
            let name = status.kind.displayName
            let width = Draw.width(name, font: font)
            x -= width
            Draw.text(name, in: CGRect(x: x, y: y, width: width + 2, height: Draw.lineHeight(font)), font: font,
                      color: status.health == .error ? Theme.red : Theme.textTertiary)
            x -= dotRadius * 2 + m(8)
            let color: NSColor
            switch status.health {
            case .ok: color = Theme.green
            case .loading: color = Theme.amber
            case .error: color = Theme.red
            case .off: color = .clear
            }
            Draw.dot(at: CGPoint(x: x + dotRadius, y: y + Draw.lineHeight(font) / 2), radius: dotRadius, color: color)
            x -= spacing
        }
    }
}
