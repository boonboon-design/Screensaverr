import AppKit

/// SABnzbd: current speed with a live graph, queue progress and recent history.
///
/// Normally a slim one-row bar along the bottom of the screen; when SABnzbd is the only
/// service set up it becomes a large panel instead.
final class DownloadsView: NSView {
    var compact = true {
        didSet { if compact != oldValue { needsDisplay = true } }
    }

    var metrics = Metrics(size: CGSize(width: 1920, height: 1080)) {
        didSet { needsDisplay = true }
    }

    var state = PanelState<DownloadsData>() {
        didSet { needsDisplay = true }
    }

    var speedHistory: [SpeedSample] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var accent: NSColor { Theme.accent(.sabnzbd) }

    override func draw(_ dirtyRect: NSRect) {
        let m = metrics
        if compact {
            drawCompact(m: m)
            return
        }
        Draw.roundedRect(bounds, radius: m(26), fill: Theme.panelFill)
        Theme.hairline.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: m(26), yRadius: m(26))
        border.lineWidth = 1
        border.stroke()

        let inner = bounds.insetBy(dx: m(34), dy: m(28))
        let statsWidth = (inner.width * 0.36).rounded()
        let statsRect = CGRect(x: inner.minX, y: inner.minY, width: statsWidth, height: inner.height)
        let listRect = CGRect(x: statsRect.maxX + m(48), y: inner.minY,
                              width: inner.maxX - statsRect.maxX - m(48), height: inner.height)

        drawStats(in: statsRect, m: m)

        // Divider between the two halves.
        Theme.hairline.setFill()
        CGRect(x: statsRect.maxX + m(24), y: inner.minY, width: max(1, m(1.5)), height: inner.height).fill(using: .sourceOver)

        if let data = state.value {
            if data.items.isEmpty {
                drawHistory(data, in: listRect, m: m)
            } else {
                drawQueue(data, in: listRect, m: m)
            }
        } else {
            let title = state.error != nil ? "Can't reach SABnzbd" : "Connecting to SABnzbd…"
            drawMessage(title, detail: state.error, in: listRect, m: m)
        }
    }


    // MARK: Compact bar

    private func drawCompact(m: Metrics) {
        let radius = m(20)
        Draw.roundedRect(bounds, radius: radius, fill: Theme.panelFill)
        Theme.hairline.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        border.stroke()

        let inner = bounds.insetBy(dx: m(28), dy: m(16))
        let gap = m(40)
        let statsRect = CGRect(x: inner.minX, y: inner.minY, width: (inner.width * 0.33).rounded(), height: inner.height)
        let summaryWidth = (inner.width * 0.22).rounded()
        let summaryRect = CGRect(x: inner.maxX - summaryWidth, y: inner.minY, width: summaryWidth, height: inner.height)
        let itemRect = CGRect(x: statsRect.maxX + gap, y: inner.minY,
                              width: max(0, summaryRect.minX - gap - statsRect.maxX - gap), height: inner.height)

        Theme.hairline.setFill()
        for x in [statsRect.maxX + gap / 2, summaryRect.minX - gap / 2] {
            CGRect(x: x, y: inner.minY + m(4), width: max(1, m(1.5)), height: inner.height - m(8)).fill(using: .sourceOver)
        }

        drawCompactStats(in: statsRect, m: m)

        guard let data = state.value else {
            let title = state.error != nil ? "Can't reach SABnzbd" : "Connecting to SABnzbd…"
            drawTwoLines(title, state.error, in: itemRect, m: m)
            return
        }
        drawCompactItem(data, in: itemRect, m: m)
        drawCompactSummary(data, in: summaryRect, m: m)
    }

    private func drawCompactStats(in rect: CGRect, m: Metrics) {
        let data = state.value

        // Line 1: label + state
        let labelFont = Theme.font(m(14), .semibold)
        let labelHeight = Draw.lineHeight(labelFont)
        let dotRadius = m(4.5)
        Draw.dot(at: CGPoint(x: rect.minX + dotRadius, y: rect.minY + labelHeight / 2 + m(1)), radius: dotRadius, color: accent)
        var labelRight = rect.minX + dotRadius * 2 + m(10)
        labelRight += Draw.text("DOWNLOADS", in: CGRect(x: labelRight, y: rect.minY, width: rect.width, height: labelHeight),
                                font: labelFont, color: Theme.textSecondary, kern: m(1.8))
        if let data {
            let color: NSColor
            switch data.state {
            case .downloading: color = Theme.green
            case .paused: color = Theme.amber
            case .idle: color = Theme.textTertiary
            }
            let pillHeight = m(20)
            labelRight += m(10)
            labelRight += Draw.pill(data.state.label, at: CGPoint(x: labelRight, y: rect.minY + (labelHeight - pillHeight) / 2),
                                    font: Theme.font(m(12), .bold), color: color, height: pillHeight)
        }

        // Line 2: speed
        let speed = Formatting.speedParts(data?.bytesPerSecond ?? 0)
        let speedFont = Theme.roundedFont(m(38), .semibold)
        let unitFont = Theme.font(m(17), .medium)
        let speedY = rect.maxY - Draw.lineHeight(speedFont) + m(4)
        let numberWidth = Draw.text(speed.value, in: CGRect(x: rect.minX - m(2), y: speedY, width: rect.width, height: Draw.lineHeight(speedFont)),
                                    font: speedFont, color: Theme.textPrimary)
        let unitX = rect.minX + numberWidth + m(6)
        let unitWidth = Draw.text(speed.unit, in: CGRect(x: unitX, y: speedY + speedFont.ascender - unitFont.ascender,
                                                         width: rect.width, height: Draw.lineHeight(unitFont)),
                                  font: unitFont, color: Theme.textSecondary)

        // Sparkline fills the rest of the segment.
        let graphX = max(labelRight, unitX + unitWidth) + m(24)
        let graphRect = CGRect(x: graphX, y: rect.minY + m(6), width: rect.maxX - graphX, height: rect.height - m(8))
        if graphRect.width > m(60) { drawGraph(in: graphRect, m: m) }
    }

    private func drawCompactItem(_ data: DownloadsData, in rect: CGRect, m: Metrics) {
        guard let item = data.items.first(where: { $0.isActive }) ?? data.items.first else {
            let last = data.recent.first.map { item -> String in
                let when = item.completedAt.map { " · \(Formatting.ago($0, now: Date()))" } ?? ""
                return "\(item.failed ? "Failed" : "Last"): \(cleanName(item.name))\(when)"
            }
            drawTwoLines("Queue is empty", last, in: rect, m: m)
            return
        }

        let active = item.isActive && data.state == .downloading
        let nameFont = Theme.font(m(19), .semibold)
        let nameHeight = Draw.lineHeight(nameFont)
        let metaFont = Theme.font(m(15), .medium, monospacedDigits: true)
        let blockHeight = nameHeight + m(15) + Draw.lineHeight(metaFont)
        let top = rect.minY + max(0, (rect.height - blockHeight) / 2)
        let percentFont = Theme.font(m(18), .semibold, monospacedDigits: true)
        let percent = "\(Int((item.progress * 100).rounded()))%"
        let percentWidth = Draw.width(percent, font: percentFont) + m(4)
        Draw.text(percent, in: CGRect(x: rect.maxX - percentWidth, y: top, width: percentWidth, height: nameHeight),
                  font: percentFont, color: active ? accent : Theme.textSecondary, alignment: .right)
        Draw.text(cleanName(item.name), in: CGRect(x: rect.minX, y: top, width: rect.width - percentWidth - m(12), height: nameHeight),
                  font: nameFont, color: Theme.textPrimary)

        let barY = top + nameHeight + m(5)
        Draw.progressBar(item.progress, in: CGRect(x: rect.minX, y: barY, width: rect.width, height: m(5)),
                         color: active ? accent : Theme.textTertiary)

        var meta: [String] = []
        if item.totalBytes > 0 {
            meta.append("\(Formatting.bytes(item.totalBytes - item.remainingBytes)) of \(Formatting.bytes(item.totalBytes))")
        }
        if active, let timeLeft = item.timeLeft, timeLeft > 0 {
            meta.append("\(Formatting.duration(timeLeft)) left")
        } else if !active {
            meta.append(item.status)
        }
        if let category = item.category { meta.append(category) }
        Draw.text(meta.joined(separator: "  ·  "), in: CGRect(x: rect.minX, y: barY + m(10), width: rect.width, height: Draw.lineHeight(metaFont)),
                  font: metaFont, color: Theme.textTertiary)
    }

    private func drawCompactSummary(_ data: DownloadsData, in rect: CGRect, m: Metrics) {
        let titleFont = Theme.font(m(19), .semibold)
        let lineFont = Theme.font(m(15), .medium)
        let queued = data.itemCount == 1 ? "1 in queue" : "\(data.itemCount) in queue"
        var y = rect.minY
        Draw.text(data.itemCount == 0 ? "Queue empty" : queued,
                  in: CGRect(x: rect.minX, y: y, width: rect.width, height: Draw.lineHeight(titleFont)),
                  font: titleFont, color: Theme.textPrimary, alignment: .right)
        y += Draw.lineHeight(titleFont) + m(2)

        var left: [String] = []
        if data.remainingBytes > 0 { left.append("\(Formatting.bytes(data.remainingBytes)) left") }
        if let timeLeft = data.timeLeft, data.state == .downloading { left.append(Formatting.duration(timeLeft)) }
        if !left.isEmpty {
            Draw.text(left.joined(separator: " · "), in: CGRect(x: rect.minX, y: y, width: rect.width, height: Draw.lineHeight(lineFont)),
                      font: lineFont, color: Theme.textSecondary, alignment: .right)
            y += Draw.lineHeight(lineFont) + m(1)
        }
        if let today = data.downloadedToday {
            Draw.text("\(today) today", in: CGRect(x: rect.minX, y: y, width: rect.width, height: Draw.lineHeight(lineFont)),
                      font: lineFont, color: Theme.textTertiary, alignment: .right)
        }
    }

    private func drawTwoLines(_ title: String, _ detail: String?, in rect: CGRect, m: Metrics) {
        let titleFont = Theme.font(m(19), .semibold)
        let detailFont = Theme.font(m(15), .regular)
        let titleHeight = Draw.lineHeight(titleFont)
        let total = titleHeight + (detail == nil ? 0 : Draw.lineHeight(detailFont) + m(4))
        var y = rect.midY - total / 2
        Draw.text(title, in: CGRect(x: rect.minX, y: y, width: rect.width, height: titleHeight),
                  font: titleFont, color: Theme.textSecondary)
        y += titleHeight + m(4)
        if let detail {
            Draw.text(detail, in: CGRect(x: rect.minX, y: y, width: rect.width, height: Draw.lineHeight(detailFont)),
                      font: detailFont, color: Theme.textTertiary)
        }
    }

    // MARK: Left half: speed

    private func drawStats(in rect: CGRect, m: Metrics) {
        let labelFont = Theme.font(m(18), .semibold)
        let labelHeight = Draw.lineHeight(labelFont)
        let dotRadius = m(5.5)
        Draw.dot(at: CGPoint(x: rect.minX + dotRadius, y: rect.minY + labelHeight / 2 + m(1)), radius: dotRadius, color: accent)
        let labelWidth = Draw.text("DOWNLOADS", in: CGRect(x: rect.minX + dotRadius * 2 + m(12), y: rect.minY, width: rect.width, height: labelHeight),
                                   font: labelFont, color: Theme.textPrimary, kern: m(2.2))

        let data = state.value
        if let data {
            let color: NSColor
            switch data.state {
            case .downloading: color = Theme.green
            case .paused: color = Theme.amber
            case .idle: color = Theme.textTertiary
            }
            let pillHeight = m(25)
            Draw.pill(data.state.label, at: CGPoint(x: rect.minX + dotRadius * 2 + m(12) + labelWidth + m(14), y: rect.minY + (labelHeight - pillHeight) / 2),
                      font: Theme.font(m(14), .bold), color: color, height: pillHeight)
        }

        // Big speed readout.
        let speed = Formatting.speedParts(data?.bytesPerSecond ?? 0)
        let speedFont = Theme.roundedFont(m(78), .semibold)
        let unitFont = Theme.font(m(30), .medium)
        let speedY = rect.minY + labelHeight + m(8)
        let speedHeight = Draw.lineHeight(speedFont)
        let numberWidth = Draw.text(speed.value, in: CGRect(x: rect.minX - m(3), y: speedY, width: rect.width, height: speedHeight),
                                    font: speedFont, color: Theme.textPrimary)
        Draw.text(speed.unit, in: CGRect(x: rect.minX + numberWidth + m(10), y: speedY + speedFont.ascender - unitFont.ascender,
                                         width: rect.width - numberWidth, height: Draw.lineHeight(unitFont)),
                  font: unitFont, color: Theme.textSecondary)

        let peak = speedHistory.map(\.bytesPerSecond).max() ?? 0
        if peak > 0 {
            let peakFont = Theme.font(m(16), .medium)
            Draw.text("peak \(Formatting.speed(peak))",
                      in: CGRect(x: rect.minX, y: speedY + speedFont.ascender - peakFont.ascender,
                                 width: rect.width, height: Draw.lineHeight(peakFont)),
                      font: peakFont, color: Theme.textTertiary, alignment: .right)
        }

        // Summary line at the bottom.
        let summaryFont = Theme.font(m(19), .medium)
        let summaryHeight = Draw.lineHeight(summaryFont)
        let summaryY = rect.maxY - summaryHeight
        var parts: [String] = []
        if let data {
            if data.remainingBytes > 0 { parts.append("\(Formatting.bytes(data.remainingBytes)) left") }
            if let timeLeft = data.timeLeft, data.state == .downloading { parts.append(Formatting.duration(timeLeft)) }
            if let today = data.downloadedToday { parts.append("\(today) today") }
        }
        Draw.text(parts.joined(separator: "  ·  "), in: CGRect(x: rect.minX, y: summaryY, width: rect.width, height: summaryHeight),
                  font: summaryFont, color: Theme.textSecondary)

        // Speed graph between the readout and the summary.
        let graphTop = speedY + speedHeight + m(4)
        let graphRect = CGRect(x: rect.minX, y: graphTop, width: rect.width, height: max(0, summaryY - m(12) - graphTop))
        if graphRect.height > m(20) { drawGraph(in: graphRect, m: m) }
    }

    private func drawGraph(in rect: CGRect, m: Metrics) {
        let now = Date()
        let samples = speedHistory.filter { now.timeIntervalSince($0.time) <= DashboardStore.speedHistoryWindow + 5 }
        // The history starts empty each time the screen saver starts, so stretch whatever
        // we have across the full width (up to the 5-minute window).
        let oldest = samples.first.map { now.timeIntervalSince($0.time) } ?? 0
        let window = min(DashboardStore.speedHistoryWindow, max(20, oldest))

        // Baseline
        NSColor(white: 1, alpha: 0.08).setFill()
        CGRect(x: rect.minX, y: rect.maxY - max(1, m(1.5)), width: rect.width, height: max(1, m(1.5))).fill(using: .sourceOver)
        guard samples.count >= 2 else { return }

        let peak = max(samples.map(\.bytesPerSecond).max() ?? 0, 1024 * 1024)
        func point(_ sample: SpeedSample) -> CGPoint {
            let age = now.timeIntervalSince(sample.time)
            let x = rect.maxX - CGFloat(age / window) * rect.width
            let y = rect.maxY - CGFloat(sample.bytesPerSecond / peak) * rect.height * 0.92
            return CGPoint(x: max(rect.minX, x), y: y)
        }

        let line = NSBezierPath()
        line.lineWidth = max(1, m(2.6))
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        let points = samples.map(point)
        line.move(to: points[0])
        for p in points.dropFirst() { line.line(to: p) }

        let area = line.copy() as! NSBezierPath
        area.line(to: CGPoint(x: points.last!.x, y: rect.maxY))
        area.line(to: CGPoint(x: points[0].x, y: rect.maxY))
        area.close()

        NSGraphicsContext.saveGraphicsState()
        area.addClip()
        // Angle 90 runs from minY to maxY, i.e. top to bottom in this flipped view.
        NSGradient(starting: accent.withAlphaComponent(0.38), ending: accent.withAlphaComponent(0.0))?.draw(in: rect, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        accent.setStroke()
        line.stroke()

        if let last = points.last {
            Draw.dot(at: last, radius: m(5), color: accent)
        }


    }

    // MARK: Right half: queue

    private func drawQueue(_ data: DownloadsData, in rect: CGRect, m: Metrics) {
        let nameFont = Theme.font(m(22), .semibold)
        let metaFont = Theme.font(m(16), .medium, monospacedDigits: true)
        let percentFont = Theme.font(m(20), .semibold, monospacedDigits: true)
        let rowHeight = m(66)
        let moreHeight = m(22)

        var capacity = max(1, Int(rect.height / rowHeight))
        if data.itemCount > capacity, capacity > 1, CGFloat(capacity) * rowHeight + moreHeight > rect.height {
            capacity -= 1
        }

        var y = rect.minY
        for item in data.items.prefix(capacity) {
            let nameHeight = Draw.lineHeight(nameFont)
            let active = item.isActive && data.state == .downloading
            let percent = "\(Int((item.progress * 100).rounded()))%"
            let percentWidth = Draw.width(percent, font: percentFont) + m(4)
            Draw.text(percent, in: CGRect(x: rect.maxX - percentWidth, y: y, width: percentWidth, height: nameHeight),
                      font: percentFont, color: active ? accent : Theme.textSecondary, alignment: .right)
            Draw.text(cleanName(item.name), in: CGRect(x: rect.minX, y: y, width: rect.width - percentWidth - m(16), height: nameHeight),
                      font: nameFont, color: Theme.textPrimary)

            let barY = y + nameHeight + m(5)
            Draw.progressBar(item.progress, in: CGRect(x: rect.minX, y: barY, width: rect.width, height: m(7)),
                             color: active ? accent : Theme.textTertiary)

            var meta: [String] = []
            if item.totalBytes > 0 {
                meta.append("\(Formatting.bytes(item.totalBytes - item.remainingBytes)) of \(Formatting.bytes(item.totalBytes))")
            }
            if active, let timeLeft = item.timeLeft, timeLeft > 0 {
                meta.append("\(Formatting.duration(timeLeft)) left")
            } else if !active {
                meta.append(item.status)
            }
            if let category = item.category { meta.append(category) }
            Draw.text(meta.joined(separator: "  ·  "), in: CGRect(x: rect.minX, y: barY + m(11), width: rect.width, height: Draw.lineHeight(metaFont)),
                      font: metaFont, color: Theme.textTertiary)
            y += rowHeight
        }

        let remaining = data.itemCount - min(capacity, data.items.count)
        if remaining > 0 {
            let font = Theme.font(m(17), .medium)
            Draw.text("+ \(remaining) more in queue", in: CGRect(x: rect.minX, y: y, width: rect.width, height: Draw.lineHeight(font)),
                      font: font, color: Theme.textTertiary)
        }
    }

    private func drawHistory(_ data: DownloadsData, in rect: CGRect, m: Metrics) {
        let titleFont = Theme.font(m(22), .semibold)
        Draw.text("Queue is empty", in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: Draw.lineHeight(titleFont)),
                  font: titleFont, color: Theme.textSecondary)
        guard !data.recent.isEmpty else { return }

        let headingFont = Theme.font(m(15), .semibold)
        var y = rect.minY + Draw.lineHeight(titleFont) + m(14)
        Draw.text("RECENTLY FINISHED", in: CGRect(x: rect.minX, y: y, width: rect.width, height: Draw.lineHeight(headingFont)),
                  font: headingFont, color: Theme.textTertiary, kern: m(1.6))
        y += Draw.lineHeight(headingFont) + m(8)

        let nameFont = Theme.font(m(19), .medium)
        let metaFont = Theme.font(m(16), .regular)
        let rowHeight = m(34)
        let now = Date()
        for item in data.recent where y + rowHeight <= rect.maxY + m(4) {
            let dotColor = item.failed ? Theme.red : Theme.green
            Draw.dot(at: CGPoint(x: rect.minX + m(5), y: y + Draw.lineHeight(nameFont) / 2), radius: m(4.5), color: dotColor)
            let meta = [item.failed ? "Failed" : nil, item.completedAt.map { Formatting.ago($0, now: now) }]
                .compactMap { $0 }.joined(separator: " · ")
            let metaWidth = Draw.width(meta, font: metaFont) + m(4)
            Draw.text(meta, in: CGRect(x: rect.maxX - metaWidth, y: y + m(2), width: metaWidth, height: Draw.lineHeight(metaFont)),
                      font: metaFont, color: Theme.textTertiary, alignment: .right)
            Draw.text(cleanName(item.name), in: CGRect(x: rect.minX + m(20), y: y, width: rect.width - metaWidth - m(32), height: Draw.lineHeight(nameFont)),
                      font: nameFont, color: Theme.textSecondary)
            y += rowHeight
        }
    }

    private func drawMessage(_ title: String, detail: String?, in rect: CGRect, m: Metrics) {
        let titleFont = Theme.font(m(22), .semibold)
        Draw.text(title, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: Draw.lineHeight(titleFont)),
                  font: titleFont, color: Theme.textSecondary)
        if let detail {
            let font = Theme.font(m(18), .regular)
            NSAttributedString(string: detail, attributes: [.font: font, .foregroundColor: Theme.textTertiary])
                .draw(with: CGRect(x: rect.minX, y: rect.minY + Draw.lineHeight(titleFont) + m(8), width: rect.width, height: m(120)),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// "Some.Show.S01E02.1080p.WEB.h264-GROUP" reads better with spaces.
    private func cleanName(_ name: String) -> String {
        guard !name.contains(" ") else { return name }
        return name.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
    }
}
