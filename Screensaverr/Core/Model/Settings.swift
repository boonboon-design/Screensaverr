import Foundation

/// The four services Screensaverr can talk to.
enum ServiceKind: String, Codable, CaseIterable, Identifiable {
    case sonarr
    case radarr
    case seerr
    case sabnzbd

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sonarr: return "Sonarr"
        case .radarr: return "Radarr"
        case .seerr: return "Seerr"
        case .sabnzbd: return "SABnzbd"
        }
    }

    var urlPlaceholder: String {
        switch self {
        case .sonarr: return "http://192.168.1.10:8989"
        case .radarr: return "http://192.168.1.10:7878"
        case .seerr: return "http://192.168.1.10:5055"
        case .sabnzbd: return "http://192.168.1.10:8080"
        }
    }

    /// Where to find the API key in each app's web UI.
    var apiKeyHint: String {
        switch self {
        case .sonarr, .radarr: return "Settings → General → Security → API Key"
        case .seerr: return "Settings → General → API Key"
        case .sabnzbd: return "Config → General → Security → API Key"
        }
    }
}

/// Connection details for a single service.
struct ServiceConfig: Codable, Equatable {
    var enabled: Bool
    var url: String
    var apiKey: String

    init(enabled: Bool = true, url: String = "", apiKey: String = "") {
        self.enabled = enabled
        self.url = url
        self.apiKey = apiKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
    }

    var baseURL: URL? { ServiceConfig.normalizeBaseURL(url) }

    var trimmedAPIKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// True when the service is switched on and has both a usable URL and an API key.
    var isConfigured: Bool { enabled && baseURL != nil && !trimmedAPIKey.isEmpty }

    /// Turns whatever the user typed ("nas.local:8989/", "http://10.0.0.2:7878/radarr/api/v3")
    /// into a clean base URL ("http://nas.local:8989", "http://10.0.0.2:7878/radarr").
    static func normalizeBaseURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }

        components.scheme = scheme
        components.query = nil
        components.fragment = nil

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/api/v3", "/api/v1", "/api"] where path.lowercased().hasSuffix(suffix) {
            path.removeLast(suffix.count)
            break
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.url
    }

    /// Builds `<base><path>?<query>` while keeping any URL base (e.g. `/sonarr`).
    func endpoint(_ path: String, query: [URLQueryItem] = []) -> URL? {
        guard let base = baseURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return nil }
        components.path = components.path + (path.hasPrefix("/") ? path : "/" + path)
        if !query.isEmpty {
            components.queryItems = query
            // URLComponents leaves '+' alone, which servers decode as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url
    }
}

/// Everything the user can change in the Options sheet.
struct AppSettings: Codable, Equatable {
    var sonarr = ServiceConfig()
    var radarr = ServiceConfig()
    var seerr = ServiceConfig()
    var sabnzbd = ServiceConfig()

    var tvDaysAhead: Int = 7
    var movieDaysAhead: Int = 60
    var requestCount: Int = 12
    var showBackdrop: Bool = true
    var allowInvalidCertificates: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        sonarr = try c.decodeIfPresent(ServiceConfig.self, forKey: .sonarr) ?? defaults.sonarr
        radarr = try c.decodeIfPresent(ServiceConfig.self, forKey: .radarr) ?? defaults.radarr
        seerr = try c.decodeIfPresent(ServiceConfig.self, forKey: .seerr) ?? defaults.seerr
        sabnzbd = try c.decodeIfPresent(ServiceConfig.self, forKey: .sabnzbd) ?? defaults.sabnzbd
        tvDaysAhead = try c.decodeIfPresent(Int.self, forKey: .tvDaysAhead) ?? defaults.tvDaysAhead
        movieDaysAhead = try c.decodeIfPresent(Int.self, forKey: .movieDaysAhead) ?? defaults.movieDaysAhead
        requestCount = try c.decodeIfPresent(Int.self, forKey: .requestCount) ?? defaults.requestCount
        showBackdrop = try c.decodeIfPresent(Bool.self, forKey: .showBackdrop) ?? defaults.showBackdrop
        allowInvalidCertificates = try c.decodeIfPresent(Bool.self, forKey: .allowInvalidCertificates)
            ?? defaults.allowInvalidCertificates
    }

    subscript(kind: ServiceKind) -> ServiceConfig {
        get {
            switch kind {
            case .sonarr: return sonarr
            case .radarr: return radarr
            case .seerr: return seerr
            case .sabnzbd: return sabnzbd
            }
        }
        set {
            switch kind {
            case .sonarr: sonarr = newValue
            case .radarr: radarr = newValue
            case .seerr: seerr = newValue
            case .sabnzbd: sabnzbd = newValue
            }
        }
    }

    var hasAnyConfiguredService: Bool { ServiceKind.allCases.contains { self[$0].isConfigured } }

    var clampedTVDays: Int { min(max(tvDaysAhead, 1), 60) }
    var clampedMovieDays: Int { min(max(movieDaysAhead, 1), 365) }
    var clampedRequestCount: Int { min(max(requestCount, 1), 40) }
}
