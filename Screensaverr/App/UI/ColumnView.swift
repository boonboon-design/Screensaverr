import AppKit
import QuartzCore

/// One line in a column: poster, title, subtitle and a detail line with badges.
struct RowModel: Equatable {
    struct Badge: Equatable {
        var text: String
        var color: NSColor
        var filled = false
    }

    var id: String
    var title: String
    var subtitle: String?
    var detail: String?
    var detailColor: NSColor
    var badges: [Badge] = []
    var detailSuffix: String?
    var poster: ImageRef?
}

/// A titled list ("UPCOMING TV") that pages through its rows when they don't all fit.
final class ColumnView: NSView {
    let kind: ServiceKind

    var metrics = Metrics(size: CGSize(width: 1920, height: 1080)) {
        didSet { if metrics.scale != oldValue.scale { needsDisplay = true } }
    }

    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var summary: String? { didSet { if summary != oldValue { needsDisplay = true } } }
    var warning: String? { didSet { if warning != oldValue { needsDisplay = true } } }
    /// Shown instead of rows (loading / empty / error).
    var message: (title: String, detail: String?)? {
        didSet {
            if message?.title != oldValue?.title || message?.detail != oldValue?.detail { needsDisplay = true }
        }
    }

    var rows: [RowModel] = [] {
        didSet {
            guard rows != oldValue else { return }
            if page >= pageCount { page = 0 }
            needsDisplay = true
        }
    }

    private(set) var page = 0
    private var requestedImages = Set<String>()

    override var isFlipped: Bool { true }

    init(kind: ServiceKind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Geometry (reference units, scaled by `metrics`)

    private var headerHeight: CGFloat { metrics(58) }
    private var rowHeight: CGFloat { metrics(128) }
    private var rowSpacing: CGFloat { metrics(14) }
    private var posterSize: CGSize { CGSize(width: metrics(80), height: metrics(120)) }

    var rowsPerPage: Int {
        // Leave room for the page dots at the bottom.
        let available = bounds.height - headerHeight - metrics(14)
        return max(1, Int((available + rowSpacing) / (rowHeight + rowSpacing)))
    }

    var pageCount: Int { max(1, Int(ceil(Double(rows.count) / Double(rowsPerPage)))) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if page >= pageCount { page = 0 }
        needsDisplay = true
    }

    /// Moves to the next page with a cross-fade. Returns false if there's only one page.
    @discardableResult
    func advancePage() -> Bool {
        guard message == nil, pageCount > 1 else { return false }
        page = (page + 1) % pageCount
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.9
        layer?.add(transition, forKey: "page")
        needsDisplay = true
        return true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let m = metrics
        let accent = Theme.accent(kind)

        // Header
        let titleFont = Theme.font(m(18), .semibold)
        let titleHeight = Draw.lineHeight(titleFont)
        let dotRadius = m(5.5)
        Draw.dot(at: CGPoint(x: dotRadius, y: titleHeight / 2 + m(1)), radius: dotRadius, color: accent)
        let titleWidth = Draw.text(title.uppercased(), in: CGRect(x: dotRadius * 2 + m(12), y: 0, width: bounds.width * 0.6, height: titleHeight),
                                   font: titleFont, color: Theme.textPrimary, kern: m(2.2))

        let summaryFont = Theme.font(m(17), .medium)
        let summaryX = dotRadius * 2 + m(12) + titleWidth + m(16)
        if let warning {
            Draw.text(warning, in: CGRect(x: summaryX, y: m(1), width: bounds.width - summaryX, height: titleHeight),
                      font: summaryFont, color: Theme.amber, alignment: .right)
        } else if let summary {
            Draw.text(summary, in: CGRect(x: summaryX, y: m(1), width: bounds.width - summaryX, height: titleHeight),
                      font: summaryFont, color: Theme.textTertiary, alignment: .right)
        }

        Theme.hairline.setFill()
        CGRect(x: 0, y: m(40), width: bounds.width, height: max(1, m(1.5))).fill(using: .sourceOver)

        if let message {
            drawMessage(message, m: m)
            return
        }

        // Rows
        let perPage = rowsPerPage
        let start = page * perPage
        let visible = rows.dropFirst(start).prefix(perPage)
        var y = headerHeight
        for row in visible {
            drawRow(row, at: y, m: m, accent: accent)
            y += rowHeight + rowSpacing
        }

        if pageCount > 1 { drawPageDots(m: m, accent: accent) }
    }

    private func drawMessage(_ message: (title: String, detail: String?), m: Metrics) {
        let titleFont = Theme.font(m(24), .semibold)
        let detailFont = Theme.font(m(19), .regular)
        var y = headerHeight + m(24)
        Draw.text(message.title, in: CGRect(x: 0, y: y, width: bounds.width, height: Draw.lineHeight(titleFont)),
                  font: titleFont, color: Theme.textSecondary)
        y += Draw.lineHeight(titleFont) + m(8)
        if let detail = message.detail {
            let attributed = NSAttributedString(string: detail, attributes: [
                .font: detailFont,
                .foregroundColor: Theme.textTertiary,
            ])
            attributed.draw(with: CGRect(x: 0, y: y, width: bounds.width, height: m(200)),
                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func drawRow(_ row: RowModel, at y: CGFloat, m: Metrics, accent: NSColor) {
        let poster = posterSize
        let posterRect = CGRect(x: 0, y: y + (rowHeight - poster.height) / 2, width: poster.width, height: poster.height)
        Draw.poster(image(for: row.poster), title: row.title, in: posterRect, radius: m(9), accent: accent)

        let textX = poster.width + m(24)
        let textWidth = bounds.width - textX
        let titleFont = Theme.font(m(26), .semibold)
        let subtitleFont = Theme.font(m(20), .regular)
        let detailFont = Theme.font(m(19), .medium)
        let badgeFont = Theme.font(m(14), .bold)

        let lines = row.subtitle == nil ? 2 : 3
        let blockHeight = Draw.lineHeight(titleFont) + (lines == 3 ? m(34) : 0) + m(36)
        var lineY = y + (rowHeight - blockHeight) / 2

        Draw.text(row.title, in: CGRect(x: textX, y: lineY, width: textWidth, height: Draw.lineHeight(titleFont)),
                  font: titleFont, color: Theme.textPrimary)
        lineY += Draw.lineHeight(titleFont) + m(4)

        if let subtitle = row.subtitle {
            Draw.text(subtitle, in: CGRect(x: textX, y: lineY, width: textWidth, height: Draw.lineHeight(subtitleFont)),
                      font: subtitleFont, color: Theme.textSecondary)
            lineY += m(34)
        }

        var x = textX
        let detailHeight = Draw.lineHeight(detailFont)
        if let detail = row.detail {
            let width = Draw.text(detail, in: CGRect(x: x, y: lineY, width: bounds.width - x, height: detailHeight),
                                  font: detailFont, color: row.detailColor)
            x += width + m(12)
        }
        let pillHeight = m(25)
        for badge in row.badges {
            let needed = Draw.width(badge.text, font: badgeFont) + pillHeight
            guard x + needed <= bounds.width else { break }
            x += Draw.pill(badge.text, at: CGPoint(x: x, y: lineY + (detailHeight - pillHeight) / 2), font: badgeFont,
                           color: badge.color, filled: badge.filled, height: pillHeight) + m(8)
        }
        if let suffix = row.detailSuffix, x < bounds.width - m(40) {
            Draw.text(suffix, in: CGRect(x: x + m(2), y: lineY, width: bounds.width - x - m(2), height: detailHeight),
                      font: Theme.font(m(18), .regular), color: Theme.textTertiary)
        }
    }

    private func drawPageDots(m: Metrics, accent: NSColor) {
        let radius = m(4)
        let spacing = m(14)
        let count = pageCount
        let totalWidth = CGFloat(count - 1) * spacing
        let y = bounds.height - radius - m(2)
        var x = bounds.width / 2 - totalWidth / 2
        for index in 0..<count {
            Draw.dot(at: CGPoint(x: x, y: y), radius: radius,
                     color: index == page ? accent : NSColor(white: 1, alpha: 0.18))
            x += spacing
        }
    }

    private func image(for ref: ImageRef?) -> NSImage? {
        guard let ref else { return nil }
        if let image = ImageStore.shared.cachedImage(ref, variant: .poster) { return image }
        if let key = ref.cacheKey, !requestedImages.contains(key) {
            requestedImages.insert(key)
            ImageStore.shared.load(ref, variant: .poster) { [weak self] image in
                if image != nil { self?.needsDisplay = true }
            }
        }
        return nil
    }
}
