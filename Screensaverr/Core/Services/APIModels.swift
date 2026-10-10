import Foundation

// Wire formats for the four APIs. Every field is optional so a schema change in one
// release of Sonarr/Radarr/Seerr/SABnzbd degrades a single field instead of the whole screen.

// MARK: - Sonarr / Radarr (v3 API)

struct ArrImage: Decodable, Equatable {
    var coverType: String?
    var url: String?
    var remoteUrl: String?
}

struct ArrSystemStatus: Decodable {
    var appName: String?
    var instanceName: String?
    var version: String?
}

struct SonarrSeries: Decodable {
    var id: Int?
    var title: String?
    var network: String?
    var year: Int?
    var images: [ArrImage]?
}

struct SonarrEpisode: Decodable {
    var id: Int?
    var seriesId: Int?
    var seasonNumber: Int?
    var episodeNumber: Int?
    var title: String?
    var airDate: String?
    var airDateUtc: String?
    var runtime: Int?
    var finaleType: String?
    var hasFile: Bool?
    var monitored: Bool?
    var series: SonarrSeries?
}

struct RadarrMovie: Decodable {
    var id: Int?
    var tmdbId: Int?
    var title: String?
    var year: Int?
    var studio: String?
    var runtime: Int?
    var certification: String?
    var genres: [String]?
    var inCinemas: String?
    var digitalRelease: String?
    var physicalRelease: String?
    var hasFile: Bool?
    var isAvailable: Bool?
    var monitored: Bool?
    var images: [ArrImage]?
}

// MARK: - Seerr (Overseerr / Jellyseerr compatible, API v1)

struct SeerrStatus: Decodable {
    var version: String?
    var commitTag: String?
}

struct SeerrRequestCount: Decodable {
    var total: Int?
    var movie: Int?
    var tv: Int?
    var pending: Int?
    var approved: Int?
    var declined: Int?
    var processing: Int?
    var available: Int?
    var completed: Int?
}

struct SeerrPageInfo: Decodable {
    var pages: Int?
    var pageSize: Int?
    var results: Int?
    var page: Int?
}

struct SeerrRequestPage: Decodable {
    var pageInfo: SeerrPageInfo?
    var results: LossyArray<SeerrRequest>?
}

struct SeerrRequest: Decodable {
    var id: Int
    var status: Int?
    var type: String?
    var createdAt: String?
    var updatedAt: String?
    var is4k: Bool?
    var media: SeerrMedia?
    var requestedBy: SeerrUser?
    var seasons: [SeerrSeasonRequest]?
}

struct SeerrMedia: Decodable {
    var tmdbId: Int?
    var tvdbId: Int?
    var mediaType: String?
    var status: Int?
    var status4k: Int?
}

struct SeerrUser: Decodable {
    var displayName: String?
    var username: String?
    var plexUsername: String?
    var jellyfinUsername: String?
    var email: String?
}

struct SeerrSeasonRequest: Decodable {
    var seasonNumber: Int?
}

/// The subset of `/api/v1/movie/{id}` and `/api/v1/tv/{id}` we need.
struct SeerrMediaDetails: Codable, Equatable {
    var title: String?
    var name: String?
    var posterPath: String?
    var backdropPath: String?
    var releaseDate: String?
    var firstAirDate: String?
}

// MARK: - SABnzbd

struct SABErrorEnvelope: Decodable {
    var status: FlexibleBool?
    var error: String?
}

struct SABVersionResponse: Decodable {
    var version: String?
}

struct SABQueueResponse: Decodable {
    var queue: SABQueue?
}

struct SABQueue: Decodable {
    var status: String?
    var paused: FlexibleBool?
    var kbpersec: FlexibleDouble?
    var speed: String?
    var speedlimit: FlexibleDouble?
    var mb: FlexibleDouble?
    var mbleft: FlexibleDouble?
    var timeleft: String?
    var noofslots: FlexibleDouble?
    var noofslotsTotal: FlexibleDouble?
    var slots: LossyArray<SABQueueSlot>?

    enum CodingKeys: String, CodingKey {
        case status, paused, kbpersec, speed, speedlimit, mb, mbleft, timeleft, noofslots, slots
        case noofslotsTotal = "noofslots_total"
    }
}

struct SABQueueSlot: Decodable {
    var nzoId: String?
    var filename: String?
    var status: String?
    var cat: String?
    var percentage: FlexibleDouble?
    var mb: FlexibleDouble?
    var mbleft: FlexibleDouble?
    var timeleft: String?

    enum CodingKeys: String, CodingKey {
        case nzoId = "nzo_id"
        case filename, status, cat, percentage, mb, mbleft, timeleft
    }
}

struct SABHistoryResponse: Decodable {
    var history: SABHistory?
}

struct SABHistory: Decodable {
    var slots: LossyArray<SABHistorySlot>?
}

struct SABHistorySlot: Decodable {
    var nzoId: String?
    var name: String?
    var status: String?
    var category: String?
    var completed: FlexibleDouble?
    var bytes: FlexibleDouble?
    var failMessage: String?

    enum CodingKeys: String, CodingKey {
        case nzoId = "nzo_id"
        case name, status, category, completed, bytes
        case failMessage = "fail_message"
    }
}

// MARK: - Seerr media list (Recently Added)

struct SeerrMediaPage: Decodable {
    var results: LossyArray<SeerrMediaItem>?
}

struct SeerrMediaItem: Decodable {
    var id: Int?
    var tmdbId: Int?
    var mediaType: String?
    var status: Int?
    var mediaAddedAt: String?
}

// MARK: - Tautulli (API v2)

struct TautulliEnvelope<Payload: Decodable>: Decodable {
    struct Response: Decodable {
        var result: String?
        var message: String?
        var data: Payload?
    }

    var response: Response?
}

struct TautulliInfo: Decodable {
    var tautulliVersion: String?

    enum CodingKeys: String, CodingKey {
        case tautulliVersion = "tautulli_version"
    }
}

struct TautulliActivity: Decodable {
    var streamCount: FlexibleDouble?
    var streamCountDirectPlay: FlexibleDouble?
    var streamCountDirectStream: FlexibleDouble?
    var streamCountTranscode: FlexibleDouble?
    var totalBandwidth: FlexibleDouble?
    var sessions: LossyArray<TautulliSession>?

    enum CodingKeys: String, CodingKey {
        case streamCount = "stream_count"
        case streamCountDirectPlay = "stream_count_direct_play"
        case streamCountDirectStream = "stream_count_direct_stream"
        case streamCountTranscode = "stream_count_transcode"
        case totalBandwidth = "total_bandwidth"
        case sessions
    }
}

struct TautulliSession: Decodable {
    var sessionKey: String?
    var sessionId: String?
    var friendlyName: String?
    var user: String?
    var username: String?
    var mediaType: String?
    var title: String?
    var fullTitle: String?
    var grandparentTitle: String?
    var parentTitle: String?
    var parentMediaIndex: FlexibleDouble?
    var mediaIndex: FlexibleDouble?
    var year: FlexibleDouble?
    var state: String?
    var progressPercent: FlexibleDouble?
    var transcodeDecision: String?
    var player: String?
    var product: String?
    var streamVideoFullResolution: String?
    var thumb: String?
    var parentThumb: String?
    var grandparentThumb: String?
    var live: FlexibleBool?
    var channelTitle: String?

    enum CodingKeys: String, CodingKey {
        case sessionKey = "session_key"
        case sessionId = "session_id"
        case friendlyName = "friendly_name"
        case user, username, title, year, state, player, product, thumb, live
        case mediaType = "media_type"
        case fullTitle = "full_title"
        case grandparentTitle = "grandparent_title"
        case parentTitle = "parent_title"
        case parentMediaIndex = "parent_media_index"
        case mediaIndex = "media_index"
        case progressPercent = "progress_percent"
        case transcodeDecision = "transcode_decision"
        case streamVideoFullResolution = "stream_video_full_resolution"
        case parentThumb = "parent_thumb"
        case grandparentThumb = "grandparent_thumb"
        case channelTitle = "channel_title"
    }
}
