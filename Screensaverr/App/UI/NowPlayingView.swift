import AppKit

/// Tautulli: who's watching what right now. A small box in the bottom-right corner.
final class NowPlayingView: NSView {
    var metrics = Metrics(size: CGSize(width: 1920, height: 1080)) {
        didSet { needsDisplay = true }
    }

    var state = PanelState<NowPlayingData>() {
        didSet { needsDisplay = true }
    }

    private var requestedImages = Set<String>()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var accent: NSColor { Theme.accent(.tautulli) }

    override func draw(_ dirtyRect: NSRect) {
        let m = metrics
        Draw.panel(bounds, m: m)
        let inner = bounds.insetBy(dx: m(24), dy: m(20))
        let headerBottom = Draw.sectionLabel("NOW PLAYING", accent: accent, at: inner.origin, width: inner.width * 0.6, m: m)

        guard let data = state.value else {
            let title = state.error != nil ? "Can't reach Tautulli" : "Connecting to Tautulli…"
            Draw.message(title, detail: state.error, in: CGRect(x: inner.minX, y: headerBottom + m(14), width: inner.width,
                                                                  height: inner.maxY - headerBottom - m(14)), m: m)
            return
        }

        // Stream count, top right
        let countFont = Theme.font(m(14), .semibold)
        var count = data.streamCount == 1 ? "1 stream" : "\(data.streamCount) streams"
        if data.transcodeCount > 0 { count += " · \(data.transcodeCount) transcoding" }
        Draw.text(count, in: CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: Draw.lineHeight(countFont)),
                  font: countFont, color: data.streamCount > 0 ? Theme.textPrimary : Theme.textTertiary, alignment: .right)

        guard !data.sessions.isEmpty else {
            Draw.message("Nothing playing", detail: "Streams will show up here.",
                         in: CGRect(x: inner.minX, y: headerBottom + m(14), width: inner.width,
                                    height: inner.maxY - headerBottom - m(14)), m: m)
            return
        }

        let rowHeight = m(72)
        let rowSpacing = m(12)
        var y = headerBottom + m(14)
        let capacity = max(1, Int((inner.maxY - y + rowSpacing) / (rowHeight + rowSpacing)))
        let shown = data.sessions.prefix(capacity)
        for (index, session) in shown.enumerated() {
            let isLast = index == shown.count - 1
            let hidden = data.sessions.count - shown.count
            drawRow(session, at: y, in: inner, height: rowHeight, more: isLast && hidden > 0 ? hidden : 0, m: m)
            y += rowHeight + rowSpacing
        }
    }

    private func drawRow(_ stream: StreamItem, at y: CGFloat, in inner: CGRect, height: CGFloat, more: Int, m: Metrics) {
        let posterSize = CGSize(width: height * 2 / 3, height: height)
        let posterRect = CGRect(x: inner.minX, y: y, width: posterSize.width, height: posterSize.height)
        Draw.poster(image(for: stream.poster), title: stream.title, in: posterRect, radius: m(6), accent: accent)

        let x = posterRect.maxX + m(14)
        let width = inner.maxX - x
        let titleFont = Theme.font(m(17), .semibold)
        let subtitleFont = Theme.font(m(14), .regular)
        let metaFont = Theme.font(m(13), .medium)

        var lineY = y + m(1)
        Draw.text(stream.title, in: CGRect(x: x, y: lineY, width: width, height: Draw.lineHeight(titleFont)),
                  font: titleFont, color: Theme.textPrimary)
        lineY += Draw.lineHeight(titleFont)
        if let subtitle = stream.subtitle {
            Draw.text(subtitle, in: CGRect(x: x, y: lineY, width: width, height: Draw.lineHeight(subtitleFont)),
                      font: subtitleFont, color: Theme.textSecondary)
        }
        lineY = y + height - m(6) - Draw.lineHeight(metaFont)

        // "Jon · Direct Play · 1080p" with the user emphasised and transcodes in amber.
        var metaX = x
        metaX += Draw.text(stream.user, in: CGRect(x: metaX, y: lineY, width: width * 0.5, height: Draw.lineHeight(metaFont)),
                           font: Theme.font(m(13), .semibold), color: Theme.textPrimary)
        var details: [(String, NSColor)] = []
        if stream.isPaused { details.append(("Paused", Theme.amber)) }
        if let decision = stream.decision {
            details.append((decision, stream.isTranscoding ? Theme.amber : Theme.textTertiary))
        }
        if let quality = stream.quality { details.append((quality, Theme.textTertiary)) }
        if more > 0 { details.append(("+\(more) more", Theme.textTertiary)) }
        for (text, color) in details {
            let piece = "  ·  " + text
            let pieceWidth = Draw.width(piece, font: metaFont)
            guard metaX + pieceWidth <= inner.maxX else { break }
            Draw.text("  ·  ", in: CGRect(x: metaX, y: lineY, width: pieceWidth, height: Draw.lineHeight(metaFont)),
                      font: metaFont, color: Theme.textTertiary)
            Draw.text(text, in: CGRect(x: metaX + Draw.width("  ·  ", font: metaFont), y: lineY, width: pieceWidth,
                                       height: Draw.lineHeight(metaFont)),
                      font: metaFont, color: color)
            metaX += pieceWidth
        }

        // Playback progress along the bottom of the row.
        Draw.progressBar(stream.progress, in: CGRect(x: x, y: y + height - m(3), width: width, height: m(3)),
                         color: stream.isPaused ? Theme.textTertiary : accent)
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
