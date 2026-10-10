import XCTest
@testable import ScreensaverrCore

final class SettingsTests: XCTestCase {
    func testURLNormalization() {
        func normalized(_ text: String) -> String? { ServiceConfig.normalizeBaseURL(text)?.absoluteString }
        XCTAssertEqual(normalized("192.168.1.10:8989"), "http://192.168.1.10:8989")
        XCTAssertEqual(normalized("  http://nas.local:8989/  "), "http://nas.local:8989")
        XCTAssertEqual(normalized("HTTPS://media.example.com/sonarr/"), "https://media.example.com/sonarr")
        XCTAssertEqual(normalized("http://10.0.0.2:7878/radarr/api/v3"), "http://10.0.0.2:7878/radarr")
        XCTAssertEqual(normalized("http://10.0.0.2:5055/api/v1/"), "http://10.0.0.2:5055")
        XCTAssertEqual(normalized("http://10.0.0.2:8080/sabnzbd/api?mode=queue"), "http://10.0.0.2:8080/sabnzbd")
        XCTAssertNil(normalized(""))
        XCTAssertNil(normalized("ftp://server"))
        XCTAssertNil(normalized("http://"))
    }

    func testEndpointKeepsURLBaseAndEncodesQuery() {
        let config = ServiceConfig(url: "http://nas:8989/sonarr", apiKey: "k")
        let url = config.endpoint("/api/v3/calendar", query: [
            URLQueryItem(name: "start", value: "2026-10-10T00:00:00Z"),
            URLQueryItem(name: "tags", value: "a+b"),
        ])
        XCTAssertEqual(url?.absoluteString, "http://nas:8989/sonarr/api/v3/calendar?start=2026-10-10T00:00:00Z&tags=a%2Bb")
    }

    func testIsConfigured() {
        XCTAssertFalse(ServiceConfig().isConfigured)
        XCTAssertFalse(ServiceConfig(url: "http://x:1", apiKey: "   ").isConfigured)
        XCTAssertFalse(ServiceConfig(enabled: false, url: "http://x:1", apiKey: "k").isConfigured)
        XCTAssertTrue(ServiceConfig(url: "x:1", apiKey: " k ").isConfigured)
        XCTAssertEqual(ServiceConfig(url: "x:1", apiKey: " k \n").trimmedAPIKey, "k")
    }

    func testSettingsDecodeWithMissingKeys() throws {
        let json = #"{"sonarr": {"url": "http://a:1", "apiKey": "k"}, "tvDaysAhead": 14}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.sonarr.url, "http://a:1")
        XCTAssertTrue(settings.sonarr.enabled)
        XCTAssertEqual(settings.tvDaysAhead, 14)
        XCTAssertEqual(settings.movieDaysAhead, AppSettings().movieDaysAhead)
        XCTAssertFalse(settings.radarr.isConfigured)
        XCTAssertTrue(settings.hasAnyConfiguredService)
    }

    func testSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings[.sabnzbd] = ServiceConfig(url: "http://sab:8080", apiKey: "abc")
        settings.allowInvalidCertificates = true
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }
}

final class FormattingTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let locale = Locale(identifier: "en_US")
    private let now = Date(timeIntervalSince1970: 1_791_633_600) // Sat 2026-10-10 12:00 UTC

    func testBytesAndSpeed() {
        XCTAssertEqual(Formatting.bytes(0), "0 B")
        XCTAssertEqual(Formatting.bytes(512), "512 B")
        XCTAssertEqual(Formatting.bytes(1536), "1.5 KB")
        XCTAssertEqual(Formatting.bytes(2048 * 1024 * 1024), "2.0 GB")
        XCTAssertEqual(Formatting.bytes(150 * 1024 * 1024), "150 MB")
        XCTAssertEqual(Formatting.speed(43315.62 * 1024).replacingOccurrences(of: ",", with: "."), "42.3 MB/s")
        XCTAssertEqual(Formatting.speedParts(0).unit, "B/s")
    }

    func testSABSizes() {
        XCTAssertEqual(Formatting.sabSize("34.2 G"), "34.2 GB")
        XCTAssertEqual(Formatting.sabSize("850.0 M"), "850.0 MB")
        XCTAssertEqual(Formatting.sabSize("0 "), "0 B")
        XCTAssertNil(Formatting.sabSize(""))
    }

    func testDurations() {
        XCTAssertEqual(Formatting.parseSABTime("0:12:34"), 754)
        XCTAssertEqual(Formatting.parseSABTime("1:02:03:04"), 93_784)
        XCTAssertNil(Formatting.parseSABTime("soon"))
        XCTAssertEqual(Formatting.duration(45), "45s")
        XCTAssertEqual(Formatting.duration(754), "12m")
        XCTAssertEqual(Formatting.duration(3_900), "1h 05m")
        XCTAssertEqual(Formatting.duration(93_784), "1d 2h")
        XCTAssertEqual(Formatting.duration(166 * 60), "2h 46m")
    }

    func testDayLabels() {
        func label(_ hours: Double) -> String {
            Formatting.dayLabel(for: now.addingTimeInterval(hours * 3600), now: now, calendar: utc, locale: locale)
        }
        XCTAssertEqual(label(9), "Today")
        XCTAssertEqual(label(-11), "Today")
        XCTAssertEqual(label(13), "Tomorrow")
        XCTAssertEqual(label(-13), "Yesterday")
        XCTAssertEqual(label(24 * 3), "Tuesday")
        XCTAssertEqual(label(24 * 11), "Oct 21")
        XCTAssertEqual(label(24 * 120), "Feb 7, 2027")
    }

    func testAirLabelIncludesTimeForTheComingWeek() {
        let tonight = now.addingTimeInterval(9 * 3600)
        let label = Formatting.airLabel(for: tonight, now: now, calendar: utc, locale: locale)
        XCTAssertTrue(label.hasPrefix("Today · 9:00"), label)
        let later = Formatting.airLabel(for: now.addingTimeInterval(24 * 3600 * 11), now: now, calendar: utc, locale: locale)
        XCTAssertEqual(later, "Oct 21")
    }

    func testAgo() {
        XCTAssertEqual(Formatting.ago(now.addingTimeInterval(-30), now: now), "just now")
        XCTAssertEqual(Formatting.ago(now.addingTimeInterval(-300), now: now), "5m ago")
        XCTAssertEqual(Formatting.ago(now.addingTimeInterval(-3 * 3600), now: now), "3h ago")
        XCTAssertEqual(Formatting.ago(now.addingTimeInterval(-2 * 86_400), now: now), "2d ago")
    }
}
