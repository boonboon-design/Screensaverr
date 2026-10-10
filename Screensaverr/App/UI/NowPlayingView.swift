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

    /// Masks the scrolling list; the list itself moves inside it.
    private let clip = FlippedView(frame: .zero)
    private let list = StreamListView(frame: .zero)
    private let fadeMask = CAGradientLayer()
    private var scrollIndex = 0
    private var capacity = 2
    private var isAnimating = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        addSubview(clip)
        clip.addSubview(list)
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
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
        let rowsTop = headerBottom + metrics(14)
        let available = inner.maxY - rowsTop
        capacity = max(1, Int((available + pitch - rowHeight) / pitch))

        clip.isHidden = sessions.isEmpty
        guard !sessions.isEmpty else { return }

        let visibleHeight = CGFloat(capacity) * pitch - (pitch - rowHeight)
        clip.frame = CGRect(x: inner.minX, y: rowsTop - fade, width: inner.width, height: visibleHeight + fade * 2)

        // For a seamless loop, repeat the first screenful after the last stream.
        let rows = isScrolling ? sessions + Array(sessions.prefix(capacity)) : sessions
        list.metrics = metrics
        list.accent = accent
        list.rowHeight = rowHeight
        list.pitch = pitch
        list.rows = rows
        list.setFrameSize(NSSize(width: clip.bounds.width, height: CGFloat(rows.count) * pitch))

        if !isScrolling || scrollIndex >= sessions.count {
            scrollIndex = 0
        }
        if !isAnimating {
            list.setFrameOrigin(listOrigin)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isScrolling {
            let edge = Double(fade / clip.bounds.height)
            fadeMask.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
            fadeMask.frame = clip.bounds
            clip.layer?.mask = fadeMask
        } else {
            clip.layer?.mask = nil
        }
        CATransaction.commit()
    }

    private var listOrigin: NSPoint { NSPoint(x: 0, y: fade - CGFloat(scrollIndex) * pitch) }

    /// Called once a second by the dashboard; glides to the next stream every few seconds.
    func tick(_ ticks: Int) {
        // The first glide comes five seconds in, then one every `interval` seconds.
        guard isScrolling, !isAnimating, !isHiddenOrHasHiddenAncestor, ticks % interval == 5 else { return }
        scrollIndex += 1
        isAnimating = true
        let target = listOrigin
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = self.glideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.list.animator().setFrameOrigin(target)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.isAnimating = false
            // Reached the repeated copy of the first streams: jump back to the real ones,
            // which look identical, so the loop is seamless. Also re-syncs if streams changed mid-glide.
            if self.scrollIndex >= self.sessions.count { self.scrollIndex = 0 }
            self.list.setFrameOrigin(self.listOrigin)
        })
    }

    // MARK: Drawing (box, heading and messages; the rows live in `list`)

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

/// The stack of stream rows that scrolls inside `NowPlayingView`.
private final class StreamListView: NSView {
    var metrics = Metrics(size: CGSize(width: 1920, height: 1080))
    var accent = Theme.accent(.tautulli)
    var rowHeight: CGFloat = 72
    var pitch: CGFloat = 84
    var rows: [StreamItem] = [] {
        didSet { if rows != oldValue { needsDisplay = true } }
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

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, stream) in rows.enumerated() {
            let y = CGFloat(index) * pitch
            guard CGRect(x: 0, y: y, width: bounds.width, height: rowHeight).intersects(dirtyRect) else { continue }
            drawRow(stream, at: y)
        }
    }

    private func drawRow(_ stream: StreamItem, at y: CGFloat) {
        let m = metrics
        let height = rowHeight
        let posterRect = CGRect(x: 0, y: y, width: height * 2 / 3, height: height)
        Draw.poster(image(for: stream.poster), title: stream.title, in: posterRect, radius: m(6), accent: accent)

        let x = posterRect.maxX + m(14)
        let width = bounds.width - x
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
            guard metaX + pieceWidth <= bounds.width else { break }
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
                if image != nil { self?.needsDisplay = true }
            }
        }
        return nil
    }
}
