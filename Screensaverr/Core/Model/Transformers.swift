import Foundation

/// Turns raw API payloads into the items the screen saver draws.
enum Transformers {

    // MARK: Images

    /// Picks an image of the given type from an *arr `images` array.
    static func arrImage(_ images: [ArrImage]?, type: String, baseURL: URL?, service: ServiceKind) -> ImageRef? {
        guard let image = images?.first(where: { $0.coverType?.lowercased() == type }) else { return nil }
        let isPoster = type == "poster"
        let remote = image.remoteUrl.flatMap(URL.init(string:)).map { resizeTMDB($0, poster: isPoster) }
        var local: URL?
        if var path = image.url, !path.isEmpty, let baseURL {
            if isPoster {
                // Sonarr/Radarr keep pre-scaled copies next to the originals.
                path = path.replacingOccurrences(of: "/poster.jpg", with: "/poster-500.jpg")
            }
            local = resolve(path, against: baseURL)
        }
        guard remote != nil || local != nil else { return nil }
        return ImageRef(remoteURL: remote, localURL: local, service: service)
    }

    /// Resolves "/sonarr/MediaCover/1/poster.jpg?lastWrite=…" against the server's origin.
    /// The *arr apps already include their URL base in these paths.
    static func resolve(_ path: String, against baseURL: URL) -> URL? {
        if path.lowercased().hasPrefix("http://") || path.lowercased().hasPrefix("https://") {
            return URL(string: path)
        }
        guard var origin = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        origin.path = ""
        origin.query = nil
        guard let originURL = origin.url else { return nil }
        return URL(string: path.hasPrefix("/") ? path : "/" + path, relativeTo: originURL)?.absoluteURL
    }

    /// TMDB "original" artwork can be 3000px+; ask for a sensible size instead.
    static func resizeTMDB(_ url: URL, poster: Bool) -> URL {
        let text = url.absoluteString
        guard text.contains("image.tmdb.org/t/p/original/") else { return url }
        let size = poster ? "w500" : "w1280"
        return URL(string: text.replacingOccurrences(of: "/t/p/original/", with: "/t/p/\(size)/")) ?? url
    }

    static func tmdbImage(_ path: String?, size: String) -> ImageRef? {
        guard let path, !path.isEmpty else { return nil }
        let clean = path.hasPrefix("/") ? path : "/" + path
        guard let url = URL(string: "https://image.tmdb.org/t/p/\(size)\(clean)") else { return nil }
        return ImageRef(remoteURL: url, localURL: nil, service: nil)
    }

    // MARK: Sonarr

    /// Groups episodes of the same series airing at the same moment (streaming "season drops").
    static func tvItems(
        from episodes: [SonarrEpisode],
        baseURL: URL?,
        now: Date,
        calendar: Calendar = .current
    ) -> [TVItem] {
        let startOfToday = calendar.startOfDay(for: now)

        struct Entry {
            var episode: SonarrEpisode
            var date: Date
        }

        var groups: [String: [Entry]] = [:]
        var order: [String] = []
        for episode in episodes {
            guard let date = JSONSupport.parseDate(episode.airDateUtc) ?? JSONSupport.parseDate(episode.airDate),
                  date >= startOfToday
            else { continue }
            let seriesKey = episode.seriesId.map(String.init) ?? episode.series?.title ?? "?"
            let key = "\(seriesKey)|\(Int(date.timeIntervalSince1970))"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(Entry(episode: episode, date: date))
        }

        var items: [TVItem] = []
        for key in order {
            guard let entries = groups[key], let first = entries.first else { continue }
            let sorted = entries.sorted {
                (($0.episode.seasonNumber ?? 0), ($0.episode.episodeNumber ?? 0))
                    < (($1.episode.seasonNumber ?? 0), ($1.episode.episodeNumber ?? 0))
            }
            let lead = sorted[0].episode
            let series = sorted.lazy.compactMap { $0.episode.series }.first
            let count = sorted.count
            let title: String? = count == 1 ? cleanEpisodeTitle(lead.title) : "\(count) episodes"
            items.append(TVItem(
                id: "\(key)|\(lead.id ?? 0)",
                seriesTitle: series?.title ?? "Unknown series",
                episodeLabel: episodeLabel(for: sorted.map { $0.episode }),
                episodeTitle: title,
                airDate: first.date,
                network: series?.network,
                episodeCount: count,
                hasFile: sorted.allSatisfy { $0.episode.hasFile == true },
                isPremiere: lead.episodeNumber == 1,
                finaleType: sorted.last?.episode.finaleType,
                poster: arrImage(series?.images, type: "poster", baseURL: baseURL, service: .sonarr),
                fanart: arrImage(series?.images, type: "fanart", baseURL: baseURL, service: .sonarr)
            ))
        }
        return items.sorted { ($0.airDate, $0.seriesTitle) < ($1.airDate, $1.seriesTitle) }
    }

    private static func cleanEpisodeTitle(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
        // Sonarr's placeholder for unannounced titles.
        if title == "TBA" || title == "TBD" { return nil }
        return title
    }

    static func episodeLabel(for episodes: [SonarrEpisode]) -> String {
        func code(_ season: Int?, _ episode: Int?) -> String {
            String(format: "S%02dE%02d", season ?? 0, episode ?? 0)
        }
        guard let first = episodes.first else { return "" }
        guard episodes.count > 1, let last = episodes.last else {
            return code(first.seasonNumber, first.episodeNumber)
        }
        if first.seasonNumber == last.seasonNumber {
            return code(first.seasonNumber, first.episodeNumber) + String(format: "–E%02d", last.episodeNumber ?? 0)
        }
        return code(first.seasonNumber, first.episodeNumber) + "–" + code(last.seasonNumber, last.episodeNumber)
    }

    // MARK: Radarr

    /// Keeps each movie's next release (cinema, digital or physical) inside the window.
    static func movieItems(
        from movies: [RadarrMovie],
        baseURL: URL?,
        now: Date,
        daysAhead: Int,
        calendar: Calendar = .current
    ) -> [MovieItem] {
        let startOfToday = calendar.startOfDay(for: now)
        guard let windowEnd = calendar.date(byAdding: .day, value: daysAhead + 1, to: startOfToday) else { return [] }

        var items: [MovieItem] = []
        for movie in movies {
            let candidates: [(ReleaseKind, String?)] = [
                (.cinemas, movie.inCinemas),
                (.digital, movie.digitalRelease),
                (.physical, movie.physicalRelease),
            ]
            let upcoming = candidates.compactMap { candidate -> (ReleaseKind, Date)? in
                let (kind, text) = candidate
                guard let date = releaseDay(text, calendar: calendar),
                      date >= startOfToday, date < windowEnd
                else { return nil }
                return (kind, date)
            }
            guard let next = upcoming.min(by: { $0.1 < $1.1 }) else { continue }
            items.append(MovieItem(
                id: "\(movie.id ?? movie.tmdbId ?? 0)",
                title: movie.title ?? "Untitled",
                year: movie.year.flatMap { $0 > 0 ? $0 : nil },
                releaseKind: next.0,
                releaseDate: next.1,
                hasFile: movie.hasFile == true,
                studio: movie.studio.flatMap { $0.isEmpty ? nil : $0 },
                runtimeMinutes: movie.runtime.flatMap { $0 > 0 ? $0 : nil },
                genres: movie.genres ?? [],
                certification: movie.certification.flatMap { $0.isEmpty ? nil : $0 },
                poster: arrImage(movie.images, type: "poster", baseURL: baseURL, service: .radarr),
                fanart: arrImage(movie.images, type: "fanart", baseURL: baseURL, service: .radarr)
            ))
        }
        return items.sorted { ($0.releaseDate, $0.title) < ($1.releaseDate, $1.title) }
    }

    /// Radarr stores release *days* as midnight UTC. Re-anchor them to local midnight so
    /// "2026-10-17T00:00:00Z" shows as the 17th everywhere, not the 16th in the Americas.
    static func releaseDay(_ text: String?, calendar: Calendar) -> Date? {
        guard let date = JSONSupport.parseDate(text) else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        return calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))
    }

    // MARK: Seerr

    static func requestItem(_ request: SeerrRequest, details: SeerrMediaDetails?) -> RequestItem {
        let kind: MediaKind = (request.type ?? request.media?.mediaType) == "tv" ? .tv : .movie
        let fallbackTitle = request.media?.tmdbId.map { "TMDB #\($0)" } ?? "Request #\(request.id)"
        let title = details?.title ?? details?.name ?? fallbackTitle
        let yearText = (details?.releaseDate ?? details?.firstAirDate).map { String($0.prefix(4)) }
        let user = request.requestedBy
        let requester = [user?.displayName, user?.username, user?.plexUsername, user?.jellyfinUsername, user?.email]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "Someone"

        return RequestItem(
            id: request.id,
            title: title,
            year: yearText.flatMap { Int($0) },
            mediaKind: kind,
            requestedBy: requester,
            requestedAt: JSONSupport.parseDate(request.createdAt),
            status: requestStatus(request),
            seasonsLabel: kind == .tv ? seasonsLabel(request.seasons?.compactMap { $0.seasonNumber } ?? []) : nil,
            is4K: request.is4k == true,
            poster: tmdbImage(details?.posterPath, size: "w342"),
            backdrop: tmdbImage(details?.backdropPath, size: "w1280")
        )
    }

    static func requestStatus(_ request: SeerrRequest) -> RequestStatus {
        let mediaStatus = request.is4k == true ? request.media?.status4k : request.media?.status
        switch request.status {
        case 1: return .pendingApproval
        case 3: return .declined
        case 4: return .failed
        default:
            switch mediaStatus {
            case 5: return .available
            case 4: return .partiallyAvailable
            case 7: return .deleted
            case 3: return .processing
            default: return request.status == 5 ? .available : .approved
            }
        }
    }

    static func seasonsLabel(_ seasons: [Int]) -> String? {
        let numbers = Array(Set(seasons)).sorted()
        guard let first = numbers.first, let last = numbers.last else { return nil }
        if numbers.count == 1 { return "Season \(first)" }
        if last - first == numbers.count - 1 { return "Seasons \(first)–\(last)" }
        if numbers.count <= 4 { return "Seasons " + numbers.map(String.init).joined(separator: ", ") }
        return "\(numbers.count) seasons"
    }

    static func recentItem(_ media: SeerrMediaItem, details: SeerrMediaDetails?) -> RecentItem? {
        guard let tmdbId = media.tmdbId else { return nil }
        let kind: MediaKind = media.mediaType == "tv" ? .tv : .movie
        let yearText = (details?.releaseDate ?? details?.firstAirDate).map { String($0.prefix(4)) }
        return RecentItem(
            id: "\(kind.rawValue)-\(tmdbId)",
            title: details?.title ?? details?.name ?? "TMDB #\(tmdbId)",
            year: yearText.flatMap { Int($0) },
            mediaKind: kind,
            addedAt: JSONSupport.parseDate(media.mediaAddedAt),
            poster: tmdbImage(details?.posterPath, size: "w342"),
            backdrop: tmdbImage(details?.backdropPath, size: "w1280")
        )
    }

    // MARK: Tautulli

    /// Builds the Now Playing list. Posters go through Tautulli's image proxy, which needs
    /// the API key in the query string.
    static func nowPlaying(_ activity: TautulliActivity, baseURL: URL?, apiKey: String) -> NowPlayingData {
        let sessions = (activity.sessions?.elements ?? []).enumerated().map { index, session -> StreamItem in
            let type = session.mediaType?.lowercased() ?? ""
            var title = session.fullTitle ?? session.title ?? "Unknown"
            var subtitle: String?
            var thumb = session.thumb
            switch type {
            case "episode":
                title = session.grandparentTitle ?? title
                var parts: [String] = []
                if let season = session.parentMediaIndex?.value, let episode = session.mediaIndex?.value {
                    parts.append(String(format: "S%02dE%02d", Int(season), Int(episode)))
                }
                if let episodeTitle = session.title, !episodeTitle.isEmpty { parts.append(episodeTitle) }
                subtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
                thumb = session.grandparentThumb ?? session.parentThumb ?? session.thumb
            case "movie":
                title = session.title ?? title
                subtitle = session.year?.value.map { String(Int($0)) }
            case "track":
                title = session.grandparentTitle ?? title
                subtitle = [session.title, session.parentTitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                thumb = session.parentThumb ?? session.thumb
            default:
                if session.live?.value == true, let channel = session.channelTitle, !channel.isEmpty {
                    subtitle = channel
                }
            }

            let decision: String?
            switch session.transcodeDecision?.lowercased() {
            case "transcode": decision = "Transcode"
            case "copy": decision = "Direct Stream"
            case "direct play": decision = "Direct Play"
            default: decision = nil
            }

            let user = [session.friendlyName, session.user, session.username]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? "Someone"

            return StreamItem(
                id: session.sessionKey ?? session.sessionId ?? "stream-\(index)",
                title: title,
                subtitle: subtitle?.isEmpty == true ? nil : subtitle,
                user: user,
                state: session.state ?? "playing",
                progress: min(max((session.progressPercent?.value ?? 0) / 100, 0), 1),
                decision: decision,
                quality: session.streamVideoFullResolution.flatMap { $0.isEmpty ? nil : $0 },
                player: session.player ?? session.product,
                poster: tautulliImage(thumb, baseURL: baseURL, apiKey: apiKey)
            )
        }
        let count = activity.streamCount?.value.map { Int($0) } ?? sessions.count
        return NowPlayingData(
            streamCount: max(count, sessions.count),
            transcodeCount: Int(activity.streamCountTranscode?.value ?? 0),
            sessions: sessions
        )
    }

    static func tautulliImage(_ path: String?, baseURL: URL?, apiKey: String) -> ImageRef? {
        guard let path, !path.isEmpty, let baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.path += "/api/v2"
        components.queryItems = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "cmd", value: "pms_image_proxy"),
            URLQueryItem(name: "img", value: path),
            URLQueryItem(name: "width", value: "300"),
            URLQueryItem(name: "height", value: "450"),
            URLQueryItem(name: "fallback", value: "poster"),
        ]
        guard let url = components.url else { return nil }
        return ImageRef(remoteURL: nil, localURL: url, service: nil)
    }

    // MARK: SABnzbd

    static let mebibyte = 1024.0 * 1024.0

    static func downloads(queue: SABQueue, history: SABHistory?) -> DownloadsData {
        let bytesPerSecond = max(0, (queue.kbpersec?.value ?? 0) * 1024)
        let state: QueueState
        if queue.paused?.value == true || queue.status?.lowercased() == "paused" {
            state = .paused
        } else if queue.status?.lowercased() == "downloading" || bytesPerSecond > 0 {
            state = .downloading
        } else {
            state = .idle
        }

        let slots = queue.slots?.elements ?? []
        let items: [DownloadItem] = slots.enumerated().map { index, slot in
            let total = max(0, (slot.mb?.value ?? 0) * mebibyte)
            let remaining = max(0, (slot.mbleft?.value ?? 0) * mebibyte)
            var progress: Double
            if let percentage = slot.percentage?.value {
                progress = percentage / 100
            } else if total > 0 {
                progress = (total - remaining) / total
            } else {
                progress = 0
            }
            progress = min(max(progress, 0), 1)
            return DownloadItem(
                id: slot.nzoId ?? "slot-\(index)",
                name: slot.filename ?? "Unnamed job",
                status: slot.status ?? "Queued",
                category: slot.cat.flatMap { $0 == "*" || $0.lowercased() == "none" ? nil : $0 },
                progress: progress,
                totalBytes: total,
                remainingBytes: remaining,
                timeLeft: Formatting.parseSABTime(slot.timeleft)
            )
        }

        let recent: [HistoryItem] = (history?.slots?.elements ?? []).enumerated().map { index, slot in
            HistoryItem(
                id: slot.nzoId ?? "history-\(index)",
                name: slot.name ?? "Unnamed job",
                status: slot.status ?? "Completed",
                completedAt: slot.completed?.value.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                sizeBytes: slot.bytes?.value
            )
        }

        let remaining = max(0, (queue.mbleft?.value ?? 0) * mebibyte)
        let timeLeft = Formatting.parseSABTime(queue.timeleft)
        return DownloadsData(
            state: state,
            bytesPerSecond: state == .paused ? 0 : bytesPerSecond,
            remainingBytes: remaining,
            totalBytes: max(0, (queue.mb?.value ?? 0) * mebibyte),
            timeLeft: (timeLeft ?? 0) > 0 ? timeLeft : nil,
            itemCount: Int(queue.noofslotsTotal?.value ?? queue.noofslots?.value ?? Double(items.count)),
            items: items,
            recent: recent,
            downloadedToday: history?.daySize.flatMap { Formatting.sabSize($0) }
        )
    }
}
