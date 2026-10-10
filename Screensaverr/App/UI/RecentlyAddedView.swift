import AppKit
import QuartzCore

/// A shelf of posters for what was most recently added to the library (from Seerr).
final class RecentlyAddedView: NSView {
    var metrics = Metrics(size: CGSize(width: 1920, height: 1080)) {
        didSet { if metrics.scale != oldValue.scale { needsDisplay = true } }
    }

    var items: [RecentItem] = [] {
        didSet {
            guard items != oldValue else { return }
            if page >= pageCount { page = 0 }
            needsDisplay = true
        }
    }

    /// Shown instead of posters (loading / empty / error).
    var message: (title: String, detail: String?)? {
        didSet {
            if message?.title != oldValue?.title || message?.detail != oldValue?.detail { needsDisplay = true }
        }
    }

    private(set) var page = 0
    private var requestedImages = Set<String>()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if page >= pageCount { page = 0 }
        needsDisplay = true
    }

    // MARK: Geometry

    private var headerHeight: CGFloat { metrics(36) }
    private var captionHeight: CGFloat { metrics(42) }
    /// Room under the captions for the page dots.
    private var dotsHeight: CGFloat { metrics(16) }
    private var spacing: CGFloat { metrics(18) }

    private var posterSize: CGSize {
        let height = max(1, bounds.height - headerHeight - captionHeight - dotsHeight)
        return CGSize(width: (height * 2 / 3).rounded(), height: height)
    }

    var perPage: Int {
        max(1, Int((bounds.width + spacing) / (posterSize.width + spacing)))
    }

    var pageCount: Int { max(1, Int(ceil(Double(items.count) / Double(perPage)))) }

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
        let accent = Theme.accent(.seerr)

        // Everything in this section is centred: heading, posters and page dots.
        let title = "RECENTLY ADDED"
        let labelWidth = m(4.5) * 2 + m(10) + Draw.width(title, font: Theme.font(m(14), .semibold), kern: m(1.8))
        Draw.sectionLabel(title, accent: accent, at: CGPoint(x: ((bounds.width - labelWidth) / 2).rounded(), y: m(2)),
                          width: labelWidth + m(4), m: m)

        if let message {
            let titleFont = Theme.font(m(17), .semibold)
            let detailFont = Theme.font(m(14), .regular)
            var y = headerHeight + m(30)
            Draw.text(message.title, in: CGRect(x: 0, y: y, width: bounds.width, height: Draw.lineHeight(titleFont)),
                      font: titleFont, color: Theme.textSecondary, alignment: .center)
            y += Draw.lineHeight(titleFont) + m(4)
            if let detail = message.detail {
                Draw.text(detail, in: CGRect(x: 0, y: y, width: bounds.width, height: Draw.lineHeight(detailFont)),
                          font: detailFont, color: Theme.textTertiary, alignment: .center)
            }
            return
        }

        if pageCount > 1 { drawPageDots(m: m, accent: accent) }

        let size = posterSize
        let titleFont = Theme.font(m(15), .semibold)
        let detailFont = Theme.font(m(13), .regular)
        let now = Date()
        let visible = items.dropFirst(page * perPage).prefix(perPage)
        let rowWidth = CGFloat(visible.count) * size.width + CGFloat(max(0, visible.count - 1)) * spacing
        var x = ((bounds.width - rowWidth) / 2).rounded()
        for item in visible {
            let posterRect = CGRect(x: x, y: headerHeight, width: size.width, height: size.height)
            Draw.poster(image(for: item.poster), title: item.title, in: posterRect, radius: m(8), accent: accent)

            var y = posterRect.maxY + m(7)
            Draw.text(item.title, in: CGRect(x: x, y: y, width: size.width, height: Draw.lineHeight(titleFont)),
                      font: titleFont, color: Theme.textPrimary)
            y += Draw.lineHeight(titleFont)
            let detail = item.addedAt.map { Formatting.ago($0, now: now) } ?? item.year.map(String.init) ?? ""
            Draw.text(detail, in: CGRect(x: x, y: y, width: size.width, height: Draw.lineHeight(detailFont)),
                      font: detailFont, color: Theme.textTertiary)
            x += size.width + spacing
        }
    }

    /// Centred under the posters.
    private func drawPageDots(m: Metrics, accent: NSColor) {
        let radius = m(3.5)
        let gap = m(12)
        var x = bounds.width / 2 - CGFloat(pageCount - 1) * gap / 2
        let y = bounds.height - dotsHeight / 2
        for index in 0..<pageCount {
            Draw.dot(at: CGPoint(x: x, y: y), radius: radius,
                     color: index == page ? accent : NSColor(white: 1, alpha: 0.18))
            x += gap
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
