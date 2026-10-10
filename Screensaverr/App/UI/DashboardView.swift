import AppKit

/// The whole screen: backdrop, header, up to three columns and the downloads panel.
final class DashboardView: NSView {
    private let backdrop = BackdropView(frame: .zero)
    private let content = FlippedView(frame: .zero)
    private let header = HeaderView(frame: .zero)
    private let tvColumn = ColumnView(kind: .sonarr)
    private let movieColumn = ColumnView(kind: .radarr)
    private let requestColumn = ColumnView(kind: .seerr)
    private let downloads = DownloadsView(frame: .zero)
    private let nowPlaying = NowPlayingView(frame: .zero)
    private let recentlyAdded = RecentlyAddedView(frame: .zero)
    private let welcome = WelcomeView(frame: .zero)

    private let store: DashboardStore
    private var observerID: UUID?
    private var timer: Timer?
    private var ticks = 0
    private var driftOffset = CGPoint.zero
    private var backdropIndex = -1
    private var lastLayoutSignature = ""

    override var isFlipped: Bool { true }

    init(frame frameRect: NSRect, store: DashboardStore = .shared) {
        self.store = store
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor

        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
        content.wantsLayer = true
        addSubview(content)
        for view in [header, tvColumn, movieColumn, requestColumn, downloads, nowPlaying, recentlyAdded, welcome] as [NSView] {
            content.addSubview(view)
        }

        tvColumn.title = "Upcoming TV"
        movieColumn.title = "Upcoming Movies"
        requestColumn.title = "Requests"
        reloadFromStore()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Lifecycle

    func start() {
        if observerID == nil {
            observerID = store.observe { [weak self] in self?.reloadFromStore() }
        }
        reloadFromStore()
        if timer == nil {
            let timer = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        rotateBackdrop()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observerID { store.removeObserver(observerID) }
        observerID = nil
    }

    @objc private func tick() {
        ticks += 1
        let now = Date()
        header.tick(now)

        // Stagger page flips so the columns don't all change at once.
        let columns = visibleColumns
        for (index, column) in columns.enumerated() where (ticks + index * 5) % 15 == 0 {
            column.advancePage()
        }
        if ticks % 20 == 10 { recentlyAdded.advancePage() }
        if ticks % 45 == 0 { rotateBackdrop() }
        if ticks % 60 == 0 {
            drift()
            // Relative labels ("Tomorrow", "3h ago") age over time.
            reloadFromStore()
        }
    }

    // MARK: Layout

    private var visibleColumns: [ColumnView] {
        var columns: [ColumnView] = []
        if store.tv.isConfigured { columns.append(tvColumn) }
        if store.movies.isConfigured { columns.append(movieColumn) }
        if store.requests.isConfigured { columns.append(requestColumn) }
        return columns
    }

    override func layout() {
        super.layout()
        let m = Metrics(size: bounds.size)
        backdrop.frame = bounds
        content.frame = bounds.offsetBy(dx: driftOffset.x, dy: driftOffset.y)

        let margin = m(72)
        let gap = m(52)
        let width = bounds.width - margin * 2
        header.frame = CGRect(x: margin, y: m(54), width: width, height: m(140))
        header.metrics = m

        let columns = visibleColumns
        let showDownloads = store.downloads.isConfigured
        let showNowPlaying = store.nowPlaying.isConfigured
        let showRecent = store.requests.isConfigured
        var top = header.frame.maxY + m(20)
        var bottom = bounds.height - m(56)

        // When SABnzbd is the only service, give it a big panel instead of the corner box.
        let downloadsOnly = showDownloads && columns.isEmpty && !showNowPlaying
        downloads.isHidden = !showDownloads
        nowPlaying.isHidden = !showNowPlaying
        recentlyAdded.isHidden = !showRecent || downloadsOnly

        if downloadsOnly {
            let height = min(bottom - top, m(420))
            top += max(0, (bottom - top - height) / 2)
            downloads.style = .panel
            downloads.frame = CGRect(x: margin, y: bottom - height, width: width, height: height)
            downloads.metrics = m
        } else if showDownloads || showNowPlaying || showRecent {
            // Bottom row: downloads box (left) · recently added (middle) · now playing box (right)
            let rowHeight = m(236)
            let rowY = bottom - rowHeight
            let rowGap = m(40)
            var shelfLeft = margin
            var shelfRight = margin + width
            if showDownloads {
                downloads.style = .box
                downloads.frame = CGRect(x: margin, y: rowY, width: m(430), height: rowHeight)
                downloads.metrics = m
                shelfLeft = downloads.frame.maxX + rowGap
            }
            if showNowPlaying {
                nowPlaying.frame = CGRect(x: margin + width - m(470), y: rowY, width: m(470), height: rowHeight)
                nowPlaying.metrics = m
                shelfRight = nowPlaying.frame.minX - rowGap
            }
            if showRecent {
                recentlyAdded.frame = CGRect(x: shelfLeft, y: rowY, width: max(0, shelfRight - shelfLeft), height: rowHeight)
                recentlyAdded.metrics = m
            }
            bottom = rowY - m(34)
        }

        for column in [tvColumn, movieColumn, requestColumn] {
            column.isHidden = !columns.contains(column)
        }
        if !columns.isEmpty {
            let count = CGFloat(columns.count)
            let columnWidth = ((width - gap * (count - 1)) / count).rounded(.down)
            for (index, column) in columns.enumerated() {
                column.frame = CGRect(x: margin + CGFloat(index) * (columnWidth + gap), y: top,
                                      width: columnWidth, height: max(0, bottom - top))
                column.metrics = m
            }
        }

        welcome.isHidden = store.settings.hasAnyConfiguredService
        welcome.frame = bounds
        welcome.metrics = m
    }

    /// Nudges everything by a few points every minute so nothing burns in on OLED/plasma screens.
    private func drift() {
        let m = Metrics(size: bounds.size)
        let t = Double(ticks)
        let amplitude = Double(m(14))
        driftOffset = CGPoint(x: sin(t / 600 * 2 * .pi) * amplitude, y: cos(t / 420 * 2 * .pi) * amplitude * 0.7)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 3
            content.animator().setFrameOrigin(driftOffset)
        }
    }

    // MARK: Data → views

    private func reloadFromStore() {
        let now = Date()
        let settings = store.settings

        let signature = [store.tv.isConfigured, store.movies.isConfigured, store.requests.isConfigured,
                         store.downloads.isConfigured, store.nowPlaying.isConfigured,
                         settings.hasAnyConfiguredService].map { $0 ? "1" : "0" }.joined()
        if signature != lastLayoutSignature {
            lastLayoutSignature = signature
            needsLayout = true
        }

        header.statuses = [
            (.sonarr, store.tv.health),
            (.radarr, store.movies.health),
            (.seerr, store.requests.health),
            (.sabnzbd, store.downloads.health),
            (.tautulli, store.nowPlaying.health),
        ]

        // TV
        configure(tvColumn, state: store.tv, serviceName: "Sonarr",
                  emptyText: "Nothing airing in the next \(settings.clampedTVDays) days", now: now)
        tvColumn.summary = "Next \(settings.clampedTVDays) days"
        tvColumn.rows = (store.tv.value ?? []).map { tvRow($0, now: now) }

        // Movies
        configure(movieColumn, state: store.movies, serviceName: "Radarr",
                  emptyText: "No releases in the next \(settings.clampedMovieDays) days", now: now)
        movieColumn.summary = "Next \(settings.clampedMovieDays) days"
        movieColumn.rows = (store.movies.value ?? []).map { movieRow($0, now: now) }

        // Requests
        configure(requestColumn, state: store.requests, serviceName: "Seerr", emptyText: "No requests yet", now: now)
        if let counts = store.requests.value?.counts {
            var parts: [String] = []
            if counts.pending > 0 { parts.append("\(counts.pending) pending") }
            if counts.processing > 0 { parts.append("\(counts.processing) processing") }
            requestColumn.summary = parts.isEmpty ? "\(counts.total) total" : parts.joined(separator: " · ")
        } else {
            requestColumn.summary = nil
        }
        requestColumn.rows = (store.requests.value?.items ?? []).map { requestRow($0, now: now) }

        // Recently added (from Seerr)
        let recent = store.requests.value?.recentlyAdded ?? []
        recentlyAdded.items = recent
        if store.requests.value == nil {
            if let error = store.requests.error {
                recentlyAdded.message = ("Can't reach Seerr", error)
            } else {
                recentlyAdded.message = ("Loading…", nil)
            }
        } else {
            recentlyAdded.message = recent.isEmpty ? ("Nothing added recently", nil) : nil
        }

        // Downloads and streams
        downloads.speedHistory = store.speedHistory
        downloads.state = store.downloads
        nowPlaying.state = store.nowPlaying

        if backdropIndex < 0 { rotateBackdrop() }
    }

    private func configure<Value: Collection>(
        _ column: ColumnView,
        state: PanelState<Value>,
        serviceName: String,
        emptyText: String,
        now: Date
    ) {
        if let value = state.value {
            column.message = value.isEmpty ? (emptyText, nil) : nil
            if state.error != nil {
                let age = state.lastUpdated.map { " · updated \(Formatting.ago($0, now: now))" } ?? ""
                column.warning = "Offline\(age)"
            } else {
                column.warning = nil
            }
        } else if let error = state.error {
            column.message = ("Can't reach \(serviceName)", error)
            column.warning = nil
        } else {
            column.message = ("Loading…", nil)
            column.warning = nil
        }
    }

    private func configure(
        _ column: ColumnView,
        state: PanelState<RequestsData>,
        serviceName: String,
        emptyText: String,
        now: Date
    ) {
        var itemsState = PanelState<[RequestItem]>()
        itemsState.isConfigured = state.isConfigured
        itemsState.value = state.value?.items
        itemsState.error = state.error
        itemsState.lastUpdated = state.lastUpdated
        configure(column, state: itemsState, serviceName: serviceName, emptyText: emptyText, now: now)
    }

    private func tvRow(_ item: TVItem, now: Date) -> RowModel {
        var badges: [RowModel.Badge] = []
        if item.hasFile { badges.append(.init(text: "Downloaded", color: Theme.green)) }
        if let finale = item.finaleType, !finale.isEmpty {
            badges.append(.init(text: finale == "series" ? "Series Finale" : "Finale", color: Theme.red))
        } else if item.isPremiere {
            badges.append(.init(text: item.episodeLabel.hasPrefix("S01E01") ? "Series Premiere" : "Premiere", color: Theme.blue))
        }
        let aired = item.airDate < now
        let subtitle = [item.episodeLabel, item.episodeTitle].compactMap { $0 }.joined(separator: " · ")
        return RowModel(
            id: item.id,
            title: item.seriesTitle,
            subtitle: subtitle,
            detail: Formatting.airLabel(for: item.airDate, now: now),
            detailColor: aired ? Theme.textSecondary : Theme.accent(.sonarr),
            badges: badges,
            detailSuffix: item.network,
            poster: item.poster
        )
    }

    private func movieRow(_ item: MovieItem, now: Date) -> RowModel {
        var subtitleParts: [String] = []
        if let year = item.year { subtitleParts.append(String(year)) }
        if !item.genres.isEmpty { subtitleParts.append(item.genres.prefix(2).joined(separator: ", ")) }
        if let runtime = item.runtimeMinutes { subtitleParts.append(Formatting.duration(TimeInterval(runtime * 60))) }
        var badges: [RowModel.Badge] = []
        if item.hasFile { badges.append(.init(text: "Downloaded", color: Theme.green)) }
        return RowModel(
            id: item.id,
            title: item.title,
            subtitle: subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · "),
            detail: "\(item.releaseKind.label) · \(Formatting.dayLabel(for: item.releaseDate, now: now))",
            detailColor: Theme.accent(.radarr),
            badges: badges,
            detailSuffix: nil,
            poster: item.poster
        )
    }

    private func requestRow(_ item: RequestItem, now: Date) -> RowModel {
        var subtitle = "Requested by \(item.requestedBy)"
        if let date = item.requestedAt { subtitle += " · \(Formatting.ago(date, now: now))" }
        var badges = [RowModel.Badge(text: item.status.label, color: Theme.color(for: item.status))]
        if item.is4K { badges.append(.init(text: "4K", color: Theme.violet)) }
        let kindText = item.mediaKind == .tv ? (item.seasonsLabel ?? "TV") : "Movie"
        let title = item.year.map { "\(item.title) (\($0))" } ?? item.title
        return RowModel(
            id: String(item.id),
            title: title,
            subtitle: subtitle,
            detail: nil,
            detailColor: Theme.textTertiary,
            badges: badges,
            detailSuffix: kindText,
            poster: item.poster
        )
    }

    // MARK: Backdrop

    private var backdropCandidates: [ImageRef] {
        let tv = (store.tv.isConfigured ? store.tv.value ?? [] : []).prefix(12).compactMap(\.fanart)
        let movies = (store.movies.isConfigured ? store.movies.value ?? [] : []).prefix(12).compactMap(\.fanart)
        let requests = (store.requests.isConfigured ? store.requests.value?.items ?? [] : []).prefix(12).compactMap(\.backdrop)
        let recent = (store.requests.isConfigured ? store.requests.value?.recentlyAdded ?? [] : []).prefix(12).compactMap(\.backdrop)
        // Interleave so consecutive backdrops come from different sources.
        var result: [ImageRef] = []
        var seen = Set<String>()
        for index in 0..<max(tv.count, movies.count, requests.count, recent.count) {
            for list in [tv, movies, requests, recent] where index < list.count {
                let ref = list[index]
                if let key = ref.cacheKey, seen.insert(key).inserted { result.append(ref) }
            }
        }
        return result
    }

    private func rotateBackdrop() {
        guard store.settings.showBackdrop else {
            backdrop.show(nil, key: nil)
            return
        }
        let candidates = backdropCandidates
        guard !candidates.isEmpty else { return }
        backdropIndex = (backdropIndex + 1) % candidates.count
        let ref = candidates[backdropIndex]
        ImageStore.shared.load(ref, variant: .backdrop) { [weak self] image in
            guard let self, let image else { return }
            self.backdrop.show(image, key: ref.cacheKey)
        }
    }
}

/// A plain container with a top-left origin, matching the layout math above.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Shown until at least one service is set up.
final class WelcomeView: NSView {
    var metrics = Metrics(size: CGSize(width: 1920, height: 1080)) {
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

    override func draw(_ dirtyRect: NSRect) {
        let m = metrics
        let titleFont = Theme.roundedFont(m(64), .bold)
        let bodyFont = Theme.font(m(26), .regular)
        let width = min(bounds.width - m(120), m(1100))
        let x = (bounds.width - width) / 2
        var y = bounds.height * 0.42

        Draw.text("Screensaverr", in: CGRect(x: x, y: y, width: width, height: Draw.lineHeight(titleFont)),
                  font: titleFont, color: Theme.textPrimary, alignment: .center)
        y += Draw.lineHeight(titleFont) + m(18)

        let body = "Open System Settings › Screen Saver, choose Screensaverr and click Options… "
            + "to add your Sonarr, Radarr, Seerr, SABnzbd and Tautulli servers."
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = m(6)
        NSAttributedString(string: body, attributes: [
            .font: bodyFont,
            .foregroundColor: Theme.textSecondary,
            .paragraphStyle: paragraph,
        ]).draw(with: CGRect(x: x, y: y, width: width, height: m(200)), options: [.usesLineFragmentOrigin])

        let accents = ServiceKind.allCases.map(Theme.accent)
        let dotRadius = m(7)
        let spacing = m(30)
        var dotX = bounds.width / 2 - spacing * CGFloat(accents.count - 1) / 2
        let dotY = bounds.height * 0.42 - m(46)
        for color in accents {
            Draw.dot(at: CGPoint(x: dotX, y: dotY), radius: dotRadius, color: color)
            dotX += spacing
        }
    }
}
