import XCTest
@testable import ScreensaverrCore

final class TransformerTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-10-10 12:00 UTC
    private let now = Date(timeIntervalSince1970: 1_791_633_600)

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func response(_ name: String) throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: try fixture(name))
    }

    func testNowFixtureIsWhatWeThinkItIs() {
        XCTAssertEqual(ISO8601.string(now), "2026-10-10T12:00:00Z")
    }

    // MARK: Sonarr

    func testSonarrCalendarGroupsAndFilters() throws {
        let episodes = try JSONSupport.decode(LossyArray<SonarrEpisode>.self, from: response("sonarr_calendar"), serviceName: "Sonarr")
        XCTAssertEqual(episodes.elements.count, 6, "the malformed element is skipped")

        let base = URL(string: "http://nas.local:8989/sonarr")!
        let items = Transformers.tvItems(from: episodes.elements, baseURL: base, now: now, calendar: utc)
        XCTAssertEqual(items.map(\.seriesTitle), ["The Last Frontier", "Night Shift", "The Last Frontier"])

        let tonight = items[0]
        XCTAssertEqual(tonight.episodeLabel, "S02E05")
        XCTAssertEqual(tonight.episodeTitle, "Into the Storm")
        XCTAssertEqual(tonight.network, "Apple TV+")
        XCTAssertFalse(tonight.isPremiere)
        XCTAssertEqual(tonight.poster?.remoteURL?.absoluteString, "https://artworks.thetvdb.com/banners/posters/1.jpg")
        XCTAssertEqual(tonight.poster?.localURL?.absoluteString,
                       "http://nas.local:8989/sonarr/MediaCover/1/poster-500.jpg?lastWrite=638")
        XCTAssertEqual(tonight.fanart?.localURL?.absoluteString,
                       "http://nas.local:8989/sonarr/MediaCover/1/fanart.jpg?lastWrite=638")
        XCTAssertEqual(tonight.poster?.service, .sonarr)

        let drop = items[1]
        XCTAssertEqual(drop.episodeLabel, "S01E01–E03")
        XCTAssertEqual(drop.episodeTitle, "3 episodes")
        XCTAssertEqual(drop.episodeCount, 3)
        XCTAssertTrue(drop.isPremiere)
        XCTAssertFalse(drop.hasFile, "one of the three episodes is missing")
        XCTAssertEqual(drop.poster?.remoteURL?.absoluteString, "https://image.tmdb.org/t/p/w500/night.jpg")

        let finale = items[2]
        XCTAssertEqual(finale.finaleType, "season")
        XCTAssertNil(finale.episodeTitle, "TBA titles are hidden")
    }

    // MARK: Radarr

    func testRadarrPicksNextReleaseInWindow() throws {
        let movies = try JSONSupport.decode(LossyArray<RadarrMovie>.self, from: response("radarr_calendar"), serviceName: "Radarr")
        let items = Transformers.movieItems(from: movies.elements, baseURL: URL(string: "http://10.0.0.5:7878")!,
                                            now: now, daysAhead: 90, calendar: utc)
        XCTAssertEqual(items.map(\.title), ["Out Today", "Quiet Harbor", "Dune: Part Three"])
        XCTAssertEqual(items.map(\.releaseKind), [.physical, .digital, .cinemas])

        XCTAssertTrue(items[0].hasFile)
        XCTAssertNil(items[0].studio)
        XCTAssertNil(items[1].runtimeMinutes)

        let dune = items[2]
        XCTAssertEqual(utc.dateComponents([.year, .month, .day], from: dune.releaseDate),
                       DateComponents(year: 2026, month: 12, day: 18))
        XCTAssertEqual(dune.poster?.remoteURL?.absoluteString, "https://image.tmdb.org/t/p/w500/dune3.jpg")
        XCTAssertEqual(dune.fanart?.remoteURL?.absoluteString, "https://image.tmdb.org/t/p/w1280/dune3-fanart.jpg")
        XCTAssertEqual(dune.poster?.localURL?.absoluteString, "http://10.0.0.5:7878/MediaCover/10/poster-500.jpg?lastWrite=1")
        XCTAssertEqual(dune.genres.count, 3)
    }

    func testRadarrReleaseDayIgnoresLocalTimeZone() throws {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let day = try XCTUnwrap(Transformers.releaseDay("2026-10-17T00:00:00Z", calendar: losAngeles))
        XCTAssertEqual(losAngeles.dateComponents([.month, .day, .hour], from: day), DateComponents(month: 10, day: 17, hour: 0))
    }

    func testShortWindowExcludesLaterReleases() throws {
        let movies = try JSONSupport.decode(LossyArray<RadarrMovie>.self, from: response("radarr_calendar"), serviceName: "Radarr")
        let items = Transformers.movieItems(from: movies.elements, baseURL: nil, now: now, daysAhead: 7, calendar: utc)
        XCTAssertEqual(items.map(\.title), ["Out Today", "Quiet Harbor"])
        XCTAssertNil(items[0].poster)
    }

    // MARK: Seerr

    func testSeerrRequestsMapping() throws {
        let page = try JSONSupport.decode(SeerrRequestPage.self, from: response("seerr_requests"), serviceName: "Seerr")
        let requests = try XCTUnwrap(page.results?.elements)
        XCTAssertEqual(requests.count, 5)

        let movieDetails = try JSONDecoder().decode(SeerrMediaDetails.self, from: fixture("seerr_movie"))
        let tvDetails = try JSONDecoder().decode(SeerrMediaDetails.self, from: fixture("seerr_tv"))

        let pending = Transformers.requestItem(requests[0], details: movieDetails)
        XCTAssertEqual(pending.title, "Paper Moons")
        XCTAssertEqual(pending.year, 2026)
        XCTAssertEqual(pending.status, .pendingApproval)
        XCTAssertEqual(pending.requestedBy, "Alice")
        XCTAssertEqual(pending.mediaKind, .movie)
        XCTAssertEqual(pending.poster?.remoteURL?.absoluteString, "https://image.tmdb.org/t/p/w342/poster100.jpg")
        XCTAssertEqual(pending.backdrop?.remoteURL?.absoluteString, "https://image.tmdb.org/t/p/w1280/backdrop100.jpg")
        XCTAssertEqual(pending.requestedAt, JSONSupport.parseDate("2026-10-10T10:00:00Z"))

        let show = Transformers.requestItem(requests[1], details: tvDetails)
        XCTAssertEqual(show.title, "Glass Houses")
        XCTAssertEqual(show.year, 2024)
        XCTAssertEqual(show.mediaKind, .tv)
        XCTAssertEqual(show.status, .processing)
        XCTAssertEqual(show.requestedBy, "bob")
        XCTAssertEqual(show.seasonsLabel, "Seasons 1–2")
        XCTAssertEqual(show.poster?.remoteURL?.absoluteString, "https://image.tmdb.org/t/p/w342/poster200.jpg")
        XCTAssertNil(show.backdrop)

        let available = Transformers.requestItem(requests[2], details: nil)
        XCTAssertEqual(available.status, .available)
        XCTAssertEqual(available.requestedBy, "carol")
        XCTAssertEqual(available.title, "TMDB #300")

        XCTAssertEqual(Transformers.requestItem(requests[3], details: nil).status, .declined)
        XCTAssertEqual(Transformers.requestItem(requests[3], details: nil).requestedBy, "dan@example.com")

        let fourK = Transformers.requestItem(requests[4], details: nil)
        XCTAssertTrue(fourK.is4K)
        XCTAssertEqual(fourK.status, .processing, "4K requests follow status4k")
        XCTAssertEqual(fourK.requestedBy, "Someone")
    }

    func testSeasonsLabel() {
        XCTAssertNil(Transformers.seasonsLabel([]))
        XCTAssertEqual(Transformers.seasonsLabel([3]), "Season 3")
        XCTAssertEqual(Transformers.seasonsLabel([3, 1, 2, 2]), "Seasons 1–3")
        XCTAssertEqual(Transformers.seasonsLabel([1, 3]), "Seasons 1, 3")
        XCTAssertEqual(Transformers.seasonsLabel([1, 3, 5, 7, 9]), "5 seasons")
    }

    // MARK: SABnzbd

    func testSABQueueAndHistory() throws {
        let queue = try XCTUnwrap(JSONSupport.decode(SABQueueResponse.self, from: response("sab_queue"), serviceName: "SABnzbd").queue)
        let history = try JSONSupport.decode(SABHistoryResponse.self, from: response("sab_history"), serviceName: "SABnzbd").history
        let data = Transformers.downloads(queue: queue, history: history)

        XCTAssertEqual(data.state, .downloading)
        XCTAssertEqual(data.bytesPerSecond, 43315.62 * 1024, accuracy: 0.01)
        XCTAssertEqual(data.remainingBytes, 2048 * 1024 * 1024, accuracy: 1)
        XCTAssertEqual(data.timeLeft, 48)
        XCTAssertEqual(data.itemCount, 5)
        XCTAssertEqual(data.items.count, 2)
        XCTAssertEqual(data.items[0].progress, 0.64, accuracy: 0.0001)
        XCTAssertEqual(data.items[0].category, "tv")
        XCTAssertTrue(data.items[0].isActive)
        XCTAssertNil(data.items[1].category, "\"*\" means no category")
        XCTAssertEqual(data.downloadedToday, "34.2 GB")
        XCTAssertEqual(data.recent.count, 2)
        XCTAssertTrue(data.recent[1].failed)
        XCTAssertEqual(data.recent[0].completedAt, Date(timeIntervalSince1970: 1_791_626_400))
    }

    func testSABPausedState() throws {
        var queue = try XCTUnwrap(JSONSupport.decode(SABQueueResponse.self, from: response("sab_queue"), serviceName: "SABnzbd").queue)
        queue.paused = FlexibleBool(true)
        queue.status = "Paused"
        let data = Transformers.downloads(queue: queue, history: nil)
        XCTAssertEqual(data.state, .paused)
        XCTAssertEqual(data.bytesPerSecond, 0)
        XCTAssertNil(data.downloadedToday)
    }

    func testSABBadKeyEnvelope() throws {
        let envelope = try JSONDecoder().decode(SABErrorEnvelope.self, from: fixture("sab_bad_key"))
        XCTAssertEqual(envelope.status?.value, false)
        XCTAssertEqual(envelope.error, "API Key Incorrect")
    }

    // MARK: JSON helpers

    func testDateParsing() {
        XCTAssertEqual(JSONSupport.parseDate("2026-10-10T12:00:00Z"), now)
        XCTAssertEqual(JSONSupport.parseDate("2026-10-10T12:00:00.000Z"), now)
        XCTAssertEqual(JSONSupport.parseDate("2026-10-10T12:00:00.0000000Z"), now)
        XCTAssertEqual(JSONSupport.parseDate("2026-10-10T14:00:00+02:00"), now)
        XCTAssertEqual(JSONSupport.parseDate("2026-10-10T12:00:00"), now)
        XCTAssertEqual(JSONSupport.parseDate("2026-10-10"), now.addingTimeInterval(-12 * 3600))
        XCTAssertNil(JSONSupport.parseDate("not a date"))
        XCTAssertNil(JSONSupport.parseDate(""))
        XCTAssertNil(JSONSupport.parseDate(nil))
    }

    func testHTMLResponseGivesHelpfulError() {
        let html = HTTPResponse(statusCode: 200, headers: [:], body: Data("<!DOCTYPE html><html>login</html>".utf8))
        XCTAssertThrowsError(try JSONSupport.decode(ArrSystemStatus.self, from: html, serviceName: "Sonarr")) { error in
            XCTAssertTrue(ServiceError.describe(error).contains("web page"), ServiceError.describe(error))
        }
    }

    func testFlexibleNumbers() throws {
        struct Box: Decodable { var a: FlexibleDouble; var b: FlexibleDouble; var c: FlexibleBool; var d: FlexibleBool }
        let box = try JSONDecoder().decode(Box.self, from: Data(#"{"a": "12.5", "b": 3, "c": "True", "d": 0}"#.utf8))
        XCTAssertEqual(box.a.value, 12.5)
        XCTAssertEqual(box.b.value, 3)
        XCTAssertEqual(box.c.value, true)
        XCTAssertEqual(box.d.value, false)
    }
}
