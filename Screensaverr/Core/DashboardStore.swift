import Foundation

/// Polls the configured services and holds the latest data for every screen.
///
/// One store is shared by all screen-saver views in the process (one per display), so each
/// service is polled once no matter how many monitors there are.
@MainActor
final class DashboardStore {
    static let shared = DashboardStore()

    /// Reads the saved settings. Set by the screen saver at startup.
    var settingsLoader: () -> AppSettings = { AppSettings() }

    private(set) var settings = AppSettings()
    private(set) var tv = PanelState<[TVItem]>()
    private(set) var movies = PanelState<[MovieItem]>()
    private(set) var requests = PanelState<RequestsData>()
    private(set) var downloads = PanelState<DownloadsData>()
    private(set) var speedHistory: [SpeedSample] = []

    static let speedHistoryWindow: TimeInterval = 5 * 60

    private let http: HTTPClient
    private let cache: SnapshotCache?
    private var observers: [UUID: () -> Void] = [:]
    private var activeClients = 0
    private var pollers: [ServiceKind: Task<Void, Never>] = [:]
    private var seerrDetails: [String: SeerrMediaDetails] = [:]
    private var sabHistory: SABHistory?
    private var lastHistoryFetch: Date?
    private var didRestoreCache = false
    private var saveScheduled = false

    init(http: HTTPClient = .shared, cache: SnapshotCache? = SnapshotCache()) {
        self.http = http
        self.cache = cache
    }

    // MARK: Observation

    @discardableResult
    func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func notify() {
        for handler in observers.values { handler() }
    }

    // MARK: Lifecycle

    /// Called when a view starts animating. Polling runs while at least one view is active.
    func activate() {
        activeClients += 1
        guard activeClients == 1 else { return }
        Log.general.info("Starting to poll services")
        apply(settingsLoader(), force: true)
        if !didRestoreCache {
            didRestoreCache = true
            restoreCache()
        }
        startPolling()
        notify()
    }

    func deactivate() {
        activeClients = max(0, activeClients - 1)
        guard activeClients == 0 else { return }
        Log.general.info("Stopping polling")
        stopPolling()
    }

    /// Stops everything immediately (the screen saver is going away).
    func shutdown() {
        activeClients = 0
        stopPolling()
        saveNow()
    }

    /// Re-reads settings (after the user saves the Options sheet).
    func reloadSettings() {
        apply(settingsLoader(), force: false)
    }

    private func apply(_ newSettings: AppSettings, force: Bool) {
        guard force || newSettings != settings else { return }
        let old = settings
        settings = newSettings
        http.allowInvalidCertificates = newSettings.allowInvalidCertificates

        for kind in ServiceKind.allCases where old[kind] != newSettings[kind] {
            reset(kind)
        }
        if old.clampedTVDays != newSettings.clampedTVDays { tv.value = nil }
        if old.clampedMovieDays != newSettings.clampedMovieDays { movies.value = nil }
        tv.isConfigured = newSettings.sonarr.isConfigured
        movies.isConfigured = newSettings.radarr.isConfigured
        requests.isConfigured = newSettings.seerr.isConfigured
        downloads.isConfigured = newSettings.sabnzbd.isConfigured

        if activeClients > 0 && !force {
            stopPolling()
            startPolling()
        }
        notify()
    }

    private func reset(_ kind: ServiceKind) {
        switch kind {
        case .sonarr: tv = PanelState()
        case .radarr: movies = PanelState()
        case .seerr:
            requests = PanelState()
            seerrDetails = [:]
        case .sabnzbd:
            downloads = PanelState()
            speedHistory = []
            sabHistory = nil
            lastHistoryFetch = nil
        }
    }

    // MARK: Polling

    private static func interval(_ kind: ServiceKind, succeeded: Bool) -> TimeInterval {
        switch kind {
        case .sonarr: return succeeded ? 5 * 60 : 30
        case .radarr: return succeeded ? 10 * 60 : 30
        case .seerr: return succeeded ? 2 * 60 : 30
        case .sabnzbd: return succeeded ? 3 : 10
        }
    }

    private func startPolling() {
        for kind in ServiceKind.allCases where settings[kind].isConfigured && pollers[kind] == nil {
            pollers[kind] = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let succeeded = await self.refresh(kind)
                    let delay = Self.interval(kind, succeeded: succeeded)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
    }

    private func stopPolling() {
        for task in pollers.values { task.cancel() }
        pollers = [:]
    }

    /// Fetches one service. Returns false on failure so the poller retries sooner.
    @discardableResult
    func refresh(_ kind: ServiceKind) async -> Bool {
        let config = settings[kind]
        guard config.isConfigured else { return false }
        switch kind {
        case .sonarr:
            let days = settings.clampedTVDays
            return await load(kind, config: config, cacheable: true, read: { self.tv }, write: { self.tv = $0 }) {
                try await SonarrClient(config: config, http: self.http).upcoming(daysAhead: days)
            }
        case .radarr:
            let days = settings.clampedMovieDays
            return await load(kind, config: config, cacheable: true, read: { self.movies }, write: { self.movies = $0 }) {
                try await RadarrClient(config: config, http: self.http).upcoming(daysAhead: days)
            }
        case .seerr:
            let count = settings.clampedRequestCount
            return await load(kind, config: config, cacheable: true, read: { self.requests }, write: { self.requests = $0 }) {
                try await self.fetchRequests(config: config, count: count)
            }
        case .sabnzbd:
            return await load(kind, config: config, cacheable: false, read: { self.downloads }, write: { self.downloads = $0 }) {
                try await self.fetchDownloads(config: config)
            }
        }
    }

    private func load<Value>(
        _ kind: ServiceKind,
        config: ServiceConfig,
        cacheable: Bool,
        read: () -> PanelState<Value>,
        write: (PanelState<Value>) -> Void,
        fetch: () async throws -> Value
    ) async -> Bool {
        var state = read()
        state.isLoading = true
        write(state)
        let started = Date()
        Log.general.debug("\(kind.displayName, privacy: .public) refresh started")
        do {
            let value = try await fetch()
            Log.general.debug("\(kind.displayName, privacy: .public) refresh finished in \(Date().timeIntervalSince(started), privacy: .public)s")
            // Settings may have changed while we were waiting.
            guard !Task.isCancelled, settings[kind] == config else { return false }
            state = read()
            state.value = value
            state.lastUpdated = Date()
            state.error = nil
            state.isFromCache = false
            state.isLoading = false
            write(state)
            if cacheable { scheduleSave() }
            notify()
            return true
        } catch {
            guard !Task.isCancelled, settings[kind] == config else { return false }
            if error is CancellationError || (error as? HTTPError) == .cancelled { return false }
            let message = ServiceError.describe(error)
            Log.general.error("\(kind.displayName, privacy: .public) refresh failed: \(message, privacy: .public)")
            state = read()
            state.error = message
            state.isLoading = false
            write(state)
            notify()
            return false
        }
    }

    private func fetchRequests(config: ServiceConfig, count: Int) async throws -> RequestsData {
        let client = SeerrClient(config: config, http: http)
        let raw = try await client.recentRequests(count: count)
        let counts = try? await client.counts()

        struct Missing {
            var key: String
            var kind: MediaKind
            var tmdbId: Int
        }
        var missing: [Missing] = []
        for request in raw {
            guard let tmdbId = request.media?.tmdbId else { continue }
            let kind: MediaKind = (request.type ?? request.media?.mediaType) == "tv" ? .tv : .movie
            let key = Self.detailsKey(kind, tmdbId)
            if seerrDetails[key] == nil && !missing.contains(where: { $0.key == key }) {
                missing.append(Missing(key: key, kind: kind, tmdbId: tmdbId))
            }
        }
        if !missing.isEmpty {
            let fetched: [(String, SeerrMediaDetails)] = await withTaskGroup(of: (String, SeerrMediaDetails?).self) { group in
                for item in missing {
                    group.addTask {
                        (item.key, try? await client.details(mediaKind: item.kind, tmdbId: item.tmdbId))
                    }
                }
                var results: [(String, SeerrMediaDetails)] = []
                for await (key, details) in group {
                    if let details { results.append((key, details)) }
                }
                return results
            }
            for (key, details) in fetched { seerrDetails[key] = details }
        }

        let items = raw.map { request -> RequestItem in
            let kind: MediaKind = (request.type ?? request.media?.mediaType) == "tv" ? .tv : .movie
            let details = request.media?.tmdbId.flatMap { seerrDetails[Self.detailsKey(kind, $0)] }
            return Transformers.requestItem(request, details: details)
        }
        let summary = counts.map {
            RequestCounts(
                total: $0.total ?? 0,
                pending: $0.pending ?? 0,
                processing: $0.processing ?? 0,
                available: $0.available ?? 0
            )
        }
        return RequestsData(items: items, counts: summary)
    }

    private static func detailsKey(_ kind: MediaKind, _ tmdbId: Int) -> String { "\(kind.rawValue)-\(tmdbId)" }

    private func fetchDownloads(config: ServiceConfig) async throws -> DownloadsData {
        let client = SABnzbdClient(config: config, http: http)
        let queue = try await client.queue(limit: 8)
        let now = Date()
        if lastHistoryFetch.map({ now.timeIntervalSince($0) > 60 }) ?? true {
            lastHistoryFetch = now
            if let history = try? await client.history(limit: 5) { sabHistory = history }
        }
        let data = Transformers.downloads(queue: queue, history: sabHistory)
        speedHistory.append(SpeedSample(time: now, bytesPerSecond: data.bytesPerSecond))
        let cutoff = now.addingTimeInterval(-Self.speedHistoryWindow - 10)
        speedHistory.removeAll { $0.time < cutoff }
        return data
    }

    // MARK: Disk cache (so the screen has content the instant it appears)

    private func fingerprint(_ kind: ServiceKind) -> String? {
        let config = settings[kind]
        guard config.isConfigured, let url = config.baseURL else { return nil }
        return url.absoluteString
    }

    private func restoreCache() {
        guard let snapshot = cache?.load(), Date().timeIntervalSince(snapshot.savedAt) < 3 * 86_400 else { return }
        if let panel = snapshot.tv, panel.source == fingerprint(.sonarr), panel.option == settings.clampedTVDays, tv.value == nil {
            tv.value = panel.value
            tv.lastUpdated = panel.updated
            tv.isFromCache = true
        }
        if let panel = snapshot.movies, panel.source == fingerprint(.radarr), panel.option == settings.clampedMovieDays,
           movies.value == nil {
            movies.value = panel.value
            movies.lastUpdated = panel.updated
            movies.isFromCache = true
        }
        if let panel = snapshot.requests, panel.source == fingerprint(.seerr), requests.value == nil {
            requests.value = panel.value
            requests.lastUpdated = panel.updated
            requests.isFromCache = true
        }
        if snapshot.seerrSource == fingerprint(.seerr), let details = snapshot.seerrDetails {
            seerrDetails.merge(details) { current, _ in current }
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.saveNow()
        }
    }

    private func saveNow() {
        saveScheduled = false
        guard let cache else { return }
        func panel<Value: Codable>(_ state: PanelState<Value>, _ kind: ServiceKind, option: Int?) -> CachedPanel<Value>? {
            guard let value = state.value, !state.isFromCache, let source = fingerprint(kind) else { return nil }
            return CachedPanel(source: source, option: option, updated: state.lastUpdated ?? Date(), value: value)
        }
        var snapshot = cache.load() ?? DashboardSnapshot(savedAt: Date())
        snapshot.savedAt = Date()
        if let tvPanel = panel(tv, .sonarr, option: settings.clampedTVDays) { snapshot.tv = tvPanel }
        if let moviePanel = panel(movies, .radarr, option: settings.clampedMovieDays) { snapshot.movies = moviePanel }
        if let requestPanel = panel(requests, .seerr, option: nil) { snapshot.requests = requestPanel }
        if let source = fingerprint(.seerr), !seerrDetails.isEmpty {
            snapshot.seerrSource = source
            snapshot.seerrDetails = seerrDetails
        }
        cache.save(snapshot)
    }
}

// MARK: - Snapshot cache

struct CachedPanel<Value: Codable>: Codable {
    /// Base URL of the server the data came from.
    var source: String
    /// The "days ahead" setting the data was fetched with, where relevant.
    var option: Int?
    var updated: Date
    var value: Value
}

struct DashboardSnapshot: Codable {
    var savedAt: Date
    var tv: CachedPanel<[TVItem]>?
    var movies: CachedPanel<[MovieItem]>?
    var requests: CachedPanel<RequestsData>?
    var seerrSource: String?
    var seerrDetails: [String: SeerrMediaDetails]?
}

final class SnapshotCache: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "Screensaverr.SnapshotCache")

    init?(directory: URL? = SnapshotCache.defaultDirectory) {
        guard let directory else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("snapshot.json")
    }

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Screensaverr", isDirectory: true)
    }

    func load() -> DashboardSnapshot? {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try? decoder.decode(DashboardSnapshot.self, from: data)
        }
    }

    func save(_ snapshot: DashboardSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(snapshot) else { return }
        queue.sync {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
