import Foundation

// MARK: - Sonarr

struct SonarrClient {
    let requester: APIRequester

    init(config: ServiceConfig, http: HTTPClient = .shared) {
        requester = APIRequester(config: config, http: http)
    }

    func status() async throws -> ArrSystemStatus {
        try await requester.getJSON(ArrSystemStatus.self, "/api/v3/system/status", serviceName: "Sonarr")
    }

    func upcoming(daysAhead: Int, now: Date = Date(), calendar: Calendar = .current) async throws -> [TVItem] {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: daysAhead + 1, to: start) ?? now
        let query = [
            URLQueryItem(name: "start", value: ISO8601.string(start)),
            URLQueryItem(name: "end", value: ISO8601.string(end)),
            URLQueryItem(name: "unmonitored", value: "false"),
            URLQueryItem(name: "includeSeries", value: "true"),
        ]
        let episodes = try await requester.getJSON(
            LossyArray<SonarrEpisode>.self, "/api/v3/calendar", query: query, serviceName: "Sonarr")
        return Transformers.tvItems(from: episodes.elements, baseURL: requester.config.baseURL, now: now, calendar: calendar)
    }
}

// MARK: - Radarr

struct RadarrClient {
    let requester: APIRequester

    init(config: ServiceConfig, http: HTTPClient = .shared) {
        requester = APIRequester(config: config, http: http)
    }

    func status() async throws -> ArrSystemStatus {
        try await requester.getJSON(ArrSystemStatus.self, "/api/v3/system/status", serviceName: "Radarr")
    }

    func upcoming(daysAhead: Int, now: Date = Date(), calendar: Calendar = .current) async throws -> [MovieItem] {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: daysAhead + 1, to: start) ?? now
        let query = [
            URLQueryItem(name: "start", value: ISO8601.string(start)),
            URLQueryItem(name: "end", value: ISO8601.string(end)),
            URLQueryItem(name: "unmonitored", value: "false"),
        ]
        let movies = try await requester.getJSON(
            LossyArray<RadarrMovie>.self, "/api/v3/calendar", query: query, serviceName: "Radarr")
        return Transformers.movieItems(
            from: movies.elements, baseURL: requester.config.baseURL, now: now, daysAhead: daysAhead, calendar: calendar)
    }
}

// MARK: - Seerr

struct SeerrClient {
    let requester: APIRequester

    init(config: ServiceConfig, http: HTTPClient = .shared) {
        requester = APIRequester(config: config, http: http)
    }

    func status() async throws -> SeerrStatus {
        try await requester.getJSON(SeerrStatus.self, "/api/v1/status", authenticated: false, serviceName: "Seerr")
    }

    func counts() async throws -> SeerrRequestCount {
        try await requester.getJSON(SeerrRequestCount.self, "/api/v1/request/count", serviceName: "Seerr")
    }

    func recentRequests(count: Int) async throws -> [SeerrRequest] {
        let query = [
            URLQueryItem(name: "take", value: String(count)),
            URLQueryItem(name: "skip", value: "0"),
            URLQueryItem(name: "filter", value: "all"),
            URLQueryItem(name: "sort", value: "added"),
            URLQueryItem(name: "sortDirection", value: "desc"),
        ]
        let page = try await requester.getJSON(SeerrRequestPage.self, "/api/v1/request", query: query, serviceName: "Seerr")
        return page.results?.elements ?? []
    }

    /// What Seerr's home page shows under "Recently Added".
    func recentlyAdded(count: Int) async throws -> [SeerrMediaItem] {
        let query = [
            URLQueryItem(name: "filter", value: "allavailable"),
            URLQueryItem(name: "take", value: String(count)),
            URLQueryItem(name: "sort", value: "mediaAdded"),
        ]
        let page = try await requester.getJSON(SeerrMediaPage.self, "/api/v1/media", query: query, serviceName: "Seerr")
        return page.results?.elements ?? []
    }

    func details(mediaKind: MediaKind, tmdbId: Int) async throws -> SeerrMediaDetails {
        let path = mediaKind == .tv ? "/api/v1/tv/\(tmdbId)" : "/api/v1/movie/\(tmdbId)"
        return try await requester.getJSON(SeerrMediaDetails.self, path, serviceName: "Seerr")
    }
}

// MARK: - SABnzbd

struct SABnzbdClient {
    let requester: APIRequester

    init(config: ServiceConfig, http: HTTPClient = .shared) {
        var requester = APIRequester(config: config, http: http)
        requester.sendsKeyHeader = false // SABnzbd takes the key as a query parameter.
        requester.timeout = 10
        self.requester = requester
    }

    private func call<T: Decodable>(_ type: T.Type, mode: String, extra: [URLQueryItem] = [], authenticated: Bool = true) async throws -> T {
        var query = [URLQueryItem(name: "mode", value: mode), URLQueryItem(name: "output", value: "json")]
        query += extra
        if authenticated {
            query.append(URLQueryItem(name: "apikey", value: requester.config.trimmedAPIKey))
        }
        let response = try await requester.get("/api", query: query, authenticated: false)
        // SABnzbd answers auth problems with HTTP 200 and {"status": false, "error": "API Key Incorrect"}
        // (or, in some versions, plain text).
        if let envelope = try? JSONDecoder().decode(SABErrorEnvelope.self, from: response.body),
           envelope.status?.value == false, let message = envelope.error {
            if message.lowercased().contains("api key") { throw ServiceError.unauthorized(200) }
            throw ServiceError.server("SABnzbd: \(message)")
        }
        let snippet = response.bodySnippet.lowercased()
        if snippet.hasPrefix("api key") { throw ServiceError.unauthorized(200) }
        return try JSONSupport.decode(type, from: response, serviceName: "SABnzbd")
    }

    func version() async throws -> String? {
        try await call(SABVersionResponse.self, mode: "version", authenticated: false).version
    }

    func queue(limit: Int = 8) async throws -> SABQueue {
        let response = try await call(SABQueueResponse.self, mode: "queue", extra: [
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        guard let queue = response.queue else {
            throw ServiceError.unexpectedResponse("SABnzbd didn't return a queue.")
        }
        return queue
    }

    func history(limit: Int = 5) async throws -> SABHistory? {
        try await call(SABHistoryResponse.self, mode: "history", extra: [
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]).history
    }
}

// MARK: - Tautulli

struct TautulliClient {
    let requester: APIRequester

    init(config: ServiceConfig, http: HTTPClient = .shared) {
        var requester = APIRequester(config: config, http: http)
        requester.sendsKeyHeader = false // Tautulli takes the key as a query parameter.
        requester.timeout = 10
        self.requester = requester
    }

    private func call<T: Decodable>(_ type: T.Type, cmd: String) async throws -> T {
        let query = [
            URLQueryItem(name: "apikey", value: requester.config.trimmedAPIKey),
            URLQueryItem(name: "cmd", value: cmd),
        ]
        let response = try await requester.get("/api/v2", query: query, authenticated: false)
        let envelope = try JSONSupport.decode(TautulliEnvelope<T>.self, from: response, serviceName: "Tautulli")
        if let result = envelope.response?.result, result.lowercased() != "success" {
            let message = envelope.response?.message ?? "Tautulli returned an error."
            if message.lowercased().contains("apikey") { throw ServiceError.unauthorized(response.statusCode) }
            throw ServiceError.server("Tautulli: \(message)")
        }
        guard let data = envelope.response?.data else {
            throw ServiceError.unexpectedResponse("Couldn't read the response from Tautulli.")
        }
        return data
    }

    func info() async throws -> TautulliInfo {
        try await call(TautulliInfo.self, cmd: "get_tautulli_info")
    }

    func activity() async throws -> NowPlayingData {
        let activity = try await call(TautulliActivity.self, cmd: "get_activity")
        return Transformers.nowPlaying(activity, baseURL: requester.config.baseURL, apiKey: requester.config.trimmedAPIKey)
    }
}

// MARK: - Connection test (used by the Options sheet)

enum ConnectionTester {
    /// Returns a short success message such as "Connected to Sonarr 4.0.15".
    static func test(_ kind: ServiceKind, config: ServiceConfig, http: HTTPClient = .shared) async throws -> String {
        guard config.baseURL != nil else { throw ServiceError.unexpectedResponse("Enter a URL first.") }
        guard !config.trimmedAPIKey.isEmpty else { throw ServiceError.unexpectedResponse("Enter an API key first.") }

        switch kind {
        case .sonarr, .radarr:
            let status: ArrSystemStatus
            if kind == .sonarr {
                status = try await SonarrClient(config: config, http: http).status()
            } else {
                status = try await RadarrClient(config: config, http: http).status()
            }
            let appName = status.appName ?? kind.displayName
            if appName.lowercased() != kind.displayName.lowercased() {
                throw ServiceError.unexpectedResponse("That URL is \(appName), not \(kind.displayName).")
            }
            return "Connected to \(appName) \(status.version ?? "")".trimmingCharacters(in: .whitespaces)

        case .seerr:
            let client = SeerrClient(config: config, http: http)
            let status = try await client.status()
            let counts = try await client.counts()
            var message = "Connected to Seerr \(status.version ?? "")".trimmingCharacters(in: .whitespaces)
            if let total = counts.total { message += " · \(total) requests" }
            return message

        case .sabnzbd:
            let client = SABnzbdClient(config: config, http: http)
            let version = try await client.version()
            _ = try await client.queue(limit: 1)
            return "Connected to SABnzbd \(version ?? "")".trimmingCharacters(in: .whitespaces)

        case .tautulli:
            let client = TautulliClient(config: config, http: http)
            let info = try await client.info()
            let activity = try await client.activity()
            var message = "Connected to Tautulli \(info.tautulliVersion ?? "")".trimmingCharacters(in: .whitespaces)
            message += activity.streamCount == 1 ? " · 1 stream" : " · \(activity.streamCount) streams"
            return message
        }
    }
}

enum ISO8601 {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    static func string(_ date: Date) -> String { formatter.string(from: date) }
}
