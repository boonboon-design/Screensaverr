import Foundation

/// Artwork for an item: a public CDN URL (TMDB/TVDB) and/or the copy cached by Sonarr/Radarr.
struct ImageRef: Codable, Hashable {
    var remoteURL: URL?
    /// Served by the *arr app itself; needs the API key.
    var localURL: URL?
    var service: ServiceKind?

    var cacheKey: String? { (remoteURL ?? localURL)?.absoluteString }
}

struct TVItem: Codable, Hashable, Identifiable {
    var id: String
    var seriesTitle: String
    /// "S02E05" or "S01E01–E08" for a batch drop.
    var episodeLabel: String
    var episodeTitle: String?
    var airDate: Date
    var network: String?
    var episodeCount: Int
    /// Every episode in the group is already downloaded.
    var hasFile: Bool
    var isPremiere: Bool
    /// "series", "season" or "midseason" when Sonarr knows it's a finale.
    var finaleType: String?
    var poster: ImageRef?
    var fanart: ImageRef?
}

enum ReleaseKind: String, Codable, Hashable {
    case cinemas
    case digital
    case physical

    var label: String {
        switch self {
        case .cinemas: return "In Cinemas"
        case .digital: return "Digital"
        case .physical: return "Physical"
        }
    }
}

struct MovieItem: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var year: Int?
    var releaseKind: ReleaseKind
    /// Local midnight of the release day (Radarr release dates are whole days).
    var releaseDate: Date
    var hasFile: Bool
    var studio: String?
    var runtimeMinutes: Int?
    var genres: [String]
    var certification: String?
    var poster: ImageRef?
    var fanart: ImageRef?
}

enum MediaKind: String, Codable, Hashable {
    case movie
    case tv
}

enum RequestStatus: String, Codable, Hashable {
    case pendingApproval
    case approved
    case processing
    case partiallyAvailable
    case available
    case declined
    case failed
    case deleted

    var label: String {
        switch self {
        case .pendingApproval: return "Pending"
        case .approved: return "Approved"
        case .processing: return "Processing"
        case .partiallyAvailable: return "Partially Available"
        case .available: return "Available"
        case .declined: return "Declined"
        case .failed: return "Failed"
        case .deleted: return "Deleted"
        }
    }
}

struct RequestItem: Codable, Hashable, Identifiable {
    var id: Int
    var title: String
    var year: Int?
    var mediaKind: MediaKind
    var requestedBy: String
    var requestedAt: Date?
    var status: RequestStatus
    var seasonsLabel: String?
    var is4K: Bool
    var poster: ImageRef?
    var backdrop: ImageRef?
}

struct RequestCounts: Codable, Hashable {
    var total: Int
    var pending: Int
    var processing: Int
    var available: Int
}

struct RequestsData: Codable, Hashable {
    var items: [RequestItem]
    var counts: RequestCounts?
}

enum QueueState: String, Codable, Hashable {
    case downloading
    case paused
    case idle

    var label: String {
        switch self {
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .idle: return "Idle"
        }
    }
}

struct DownloadItem: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var status: String
    var category: String?
    /// 0…1
    var progress: Double
    var totalBytes: Double
    var remainingBytes: Double
    var timeLeft: TimeInterval?

    var isActive: Bool { status.lowercased() == "downloading" }
}

struct HistoryItem: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var status: String
    var completedAt: Date?
    var sizeBytes: Double?

    var failed: Bool { status.lowercased() == "failed" }
}

struct DownloadsData: Codable, Hashable {
    var state: QueueState
    var bytesPerSecond: Double
    var remainingBytes: Double
    var totalBytes: Double
    var timeLeft: TimeInterval?
    var itemCount: Int
    var items: [DownloadItem]
    var recent: [HistoryItem]
    var downloadedToday: String?
}

struct SpeedSample: Codable, Hashable {
    var time: Date
    var bytesPerSecond: Double
}

/// What a panel shows: the last good value plus loading/error status.
struct PanelState<Value> {
    var isConfigured = false
    var value: Value?
    var lastUpdated: Date?
    var error: String?
    var isLoading = false
    /// The value came from the on-disk cache and hasn't been refreshed yet.
    var isFromCache = false

    var health: ServiceHealth {
        if !isConfigured { return .off }
        if error != nil { return .error }
        if value == nil || isFromCache { return .loading }
        return .ok
    }
}

enum ServiceHealth {
    case off
    case loading
    case ok
    case error
}
