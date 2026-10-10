import AppKit
import QuartzCore

/// Tautulli: who's watching what right now. A small box in the bottom-right corner.
///
/// When there are more streams than fit, the list glides upwards one stream at a time,
/// fading in and out at the edges, and loops back to the top seamlessly.
final class NowPlayingView: NSView {
    var metrics = Metrics(size: CGSize(width: 1920, height: 1080)) {
        didSet {
            needsDisplay = true
            if metrics.scale != oldValue.scale { updateRows() }
        }
    }

    var state = PanelState<NowPlayingData>() {
        didSet {
            needsDisplay = true
            updateRows()
        }
    }

    /// The stream rows, which glide upwards when there are more than fit.
    private let strip = StreamStripView(frame: .zero)
    private var scrollIndex = 0
    private var capacity = 2

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(strip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var accent: NSColor { Theme.accent(.tautulli) }

    // MARK: Geometry

    private var inner: CGRect { bounds.insetBy(dx: metrics(24), dy: metrics(20)) }
    private var headerBottom: CGFloat { inner.minY + Draw.lineHeight(Theme.font(metrics(14), .semibold)) }
    private var rowHeight: CGFloat { metrics(72) }
    private var pitch: CGFloat { rowHeight + metrics(12) }
    /// Space above and below the rows where they fade in and out while scrolling.
    private var fade: CGFloat { metrics(14) }
    /// Room either side so poster shadows aren't clipped.
    private var gutter: CGFloat { metrics(12) }
    /// Seconds between glides (one stream at a time), and how long each glide takes.
    private let interval = 7
    private let glideDuration: TimeInterval = 1.6

    private var sessions: [StreamItem] { state.value?.sessions ?? [] }
    private var isScrolling: Bool { sessions.count > capacity }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateRows()
    }

    private func updateRows() {
        let inner = self.inner
        let rowsTop = headerBottom + metrics(14)
        let available = inner.maxY - rowsTop
        // Before layout the box has zero size, so `inner` is a null rect at infinity.
        guard !sessions.isEmpty, !inner.isNull, available.isFinite, available > 0 else {
            strip.isHidden = true
            return
        }
        capacity = max(1, Int((available + pitch - rowHeight) / pitch))
        strip.isHidden = false

        let visibleHeight = CGFloat(capacity) * pitch - (pitch - rowHeight)
        strip.frame = CGRect(x: inner.minX - gutter, y: rowsTop - fade,
                             width: inner.width + gutter * 2, height: visibleHeight + fade * 2)

        // For a seamless loop, repeat the first screenful after the last stream.
        // Resting on that copy (index == sessions.count) looks the same as index 0.
        if !isScrolling || scrollIndex > sessions.count { scrollIndex = 0 }
        strip.configure(rows: isScrolling ? sessions + Array(sessions.prefix(capacity)) : sessions,
                        metrics: metrics, accent: accent, rowHeight: rowHeight, pitch: pitch,
                        fade: fade, gutter: gutter, fadesEdges: isScrolling)
        strip.place(at: scrollIndex)
    }

    /// Called once a second by the dashboard; glides to the next stream every few seconds.
    func tick(_ ticks: Int) {
        // The first glide comes five seconds in, then one every `interval` seconds.
        guard isScrolling, !strip.isHiddenOrHasHiddenAncestor, ticks % interval == 5 else { return }
        if scrollIndex >= sessions.count {
            // On the repeated copy of the first streams: jump back to the real ones, which look identical.
            scrollIndex = 0
            strip.place(at: 0)
        }
        scrollIndex += 1
        strip.glide(from: scrollIndex - 1, to: scrollIndex, duration: glideDuration)
    }

    // MARK: Drawing (box, heading and messages; the rows live in `strip`)

    override func draw(_ dirtyRect: NSRect) {
        let m = metrics
        let inner = self.inner
        Draw.panel(bounds, m: m)
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

        if data.sessions.isEmpty {
            Draw.message("Nothing playing", detail: "Streams will show up here.",
                         in: CGRect(x: inner.minX, y: headerBottom + m(14), width: inner.width,
                                    height: inner.maxY - headerBottom - m(14)), m: m)
        }
    }
}

/// The stream rows that scroll inside `NowPlayingView`.
///
/// Layer-hosting, like the backdrop: all rows are rendered into one image on a plain layer that
/// glides up. (A clipped, layer-backed NSView only paints the part that's visible at its final
/// position, so rows blank out mid-glide.) Layers here are unflipped: y = 0 is the bottom.
private final class StreamStripView: NSView {
    private let strip = CALayer()
    private let fadeMask = CAGradientLayer()
    private var metrics = Metrics(size: CGSize(width: 1920, height: 1080))
    private var accent = Theme.accent(.tautulli)
    private var rowHeight: CGFloat = 72
    private var pitch: CGFloat = 84
    private var fade: CGFloat = 14
    private var gutter: CGFloat = 12
    private var rows: [StreamItem] = []
    private var renderedSize = CGSize.zero
    private var renderedScale: CGFloat = 0
    private var requestedImages = Set<String>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        root.masksToBounds = true
        layer = root
        wantsLayer = true
        strip.anchorPoint = .zero
        strip.contentsGravity = .resize
        root.addSublayer(strip)
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    func configure(rows: [StreamItem], metrics: Metrics, accent: NSColor, rowHeight: CGFloat, pitch: CGFloat,
                   fade: CGFloat, gutter: CGFloat, fadesEdges: Bool) {
        let rowsChanged = rows != self.rows
        self.rows = rows
        self.metrics = metrics
        self.accent = accent
        self.rowHeight = rowHeight
        self.pitch = pitch
        self.fade = fade
        self.gutter = gutter

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: CGFloat(rows.count) * pitch)
        if fadesEdges, bounds.height > 0 {
            let edge = Double(fade / bounds.height)
            fadeMask.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
            fadeMask.frame = bounds
            layer?.mask = fadeMask
        } else {
            layer?.mask = nil
        }
        CATransaction.commit()

        if rowsChanged || strip.bounds.size != renderedSize || backingScale != renderedScale { render() }
    }

    /// Where the strip sits with `index` rows scrolled off the top.
    private func position(for index: Int) -> CGPoint {
        CGPoint(x: 0, y: bounds.height - fade + CGFloat(index) * pitch - strip.bounds.height)
    }

    func place(at index: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.position = position(for: index)
        CATransaction.commit()
    }

    func glide(from: Int, to: Int, duration: TimeInterval) {
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = NSValue(point: position(for: from))
        animation.toValue = NSValue(point: position(for: to))
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.position = position(for: to)
        strip.add(animation, forKey: "glide")
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render()
    }

    /// Draws every row, top to bottom, into the strip's image.
    private func render() {
        let size = strip.bounds.size
        let scale = backingScale
        renderedSize = size
        renderedScale = scale
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            strip.contents = nil
            return
        }
        // Top-left origin, like the other views' drawing code expects.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for (index, stream) in rows.enumerated() {
            drawRow(stream, at: CGFloat(index) * pitch)
        }
        NSGraphicsContext.restoreGraphicsState()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.contents = context.makeImage()
        strip.contentsScale = scale
        CATransaction.commit()
    }

    private func drawRow(_ stream: StreamItem, at y: CGFloat) {
        let m = metrics
        let height = rowHeight
        let posterRect = CGRect(x: gutter, y: y, width: height * 2 / 3, height: height)
        Draw.poster(image(for: stream.poster), title: stream.title, in: posterRect, radius: m(6), accent: accent)

        let x = posterRect.maxX + m(14)
        let right = strip.bounds.width - gutter
        let width = right - x
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
        let separator = "  ·  "
        for (text, color) in details {
            let pieceWidth = Draw.width(separator + text, font: metaFont)
            guard metaX + pieceWidth <= right else { break }
            Draw.text(separator, in: CGRect(x: metaX, y: lineY, width: pieceWidth, height: Draw.lineHeight(metaFont)),
                      font: metaFont, color: Theme.textTertiary)
            Draw.text(text, in: CGRect(x: metaX + Draw.width(separator, font: metaFont), y: lineY, width: pieceWidth,
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
                if image != nil { self?.render() }
            }
        }
        return nil
    }
}
