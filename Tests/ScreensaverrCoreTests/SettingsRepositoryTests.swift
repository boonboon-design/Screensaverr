import XCTest
@testable import ScreensaverrCore

/// An in-memory `SecretStore` that can be told to fail.
private final class MemorySecretStore: SecretStore {
    var secrets: [String: String] = [:]
    var failWrites = false
    var failReads = false

    struct Failure: LocalizedError {
        var errorDescription: String? { "store unavailable" }
    }

    func secret(for account: String) throws -> String? {
        if failReads { throw Failure() }
        return secrets[account]
    }

    func setSecret(_ value: String, for account: String) throws {
        if failWrites { throw Failure() }
        secrets[account] = value
    }

    func removeSecret(for account: String) throws {
        if failWrites { throw Failure() }
        secrets[account] = nil
    }
}

final class SettingsRepositoryTests: XCTestCase {
    private var file: String?
    private var store = MemorySecretStore()

    private var repository: SettingsRepository {
        SettingsRepository(readPreferences: { self.file }, writePreferences: { self.file = $0 }, secrets: store)
    }

    override func setUp() {
        super.setUp()
        file = nil
        store = MemorySecretStore()
    }

    /// Preferences as written by versions before 1.3.0, with keys in plain text.
    private func legacyFile() throws -> String {
        var settings = AppSettings()
        settings.sonarr = ServiceConfig(url: "http://nas:8989", apiKey: "sonarr-secret")
        settings.tautulli = ServiceConfig(url: "http://nas:8181", apiKey: " tautulli-secret ")
        settings.requestCount = 9
        return String(data: try JSONEncoder().encode(settings), encoding: .utf8)!
    }

    func testFirstLoadMovesPlainTextKeysIntoTheStore() throws {
        file = try legacyFile()

        let loaded = repository.load()

        XCTAssertNil(loaded.problem)
        XCTAssertEqual(loaded.settings.sonarr.apiKey, "sonarr-secret")
        XCTAssertEqual(loaded.settings.tautulli.apiKey, "tautulli-secret")
        XCTAssertEqual(loaded.settings.requestCount, 9)
        XCTAssertEqual(store.secrets, ["sonarr": "sonarr-secret", "tautulli": "tautulli-secret"])
        let rewritten = try XCTUnwrap(file)
        XCTAssertFalse(rewritten.contains("secret"), rewritten)
        let kept = try JSONDecoder().decode(AppSettings.self, from: Data(rewritten.utf8))
        XCTAssertEqual(kept.sonarr.url, "http://nas:8989", "everything but the keys stays in the file")
        XCTAssertEqual(kept.requestCount, 9)
    }

    func testKeysStayPutWhenTheStoreCantTakeThem() throws {
        let original = try legacyFile()
        file = original
        store.failWrites = true

        let loaded = repository.load()

        XCTAssertEqual(loaded.problem, "Couldn't move API keys into the Keychain: store unavailable")
        XCTAssertEqual(loaded.settings.sonarr.apiKey, "sonarr-secret", "keys still work this time")
        XCTAssertEqual(file, original, "and aren't lost: the move is retried next load")

        store.failWrites = false
        XCTAssertNil(repository.load().problem)
        XCTAssertFalse(try XCTUnwrap(file).contains("secret"))
    }

    func testSaveNeverWritesKeysToTheFile() throws {
        var settings = AppSettings()
        settings.radarr = ServiceConfig(url: "http://nas:7878", apiKey: "radarr-secret")
        store.secrets["sonarr"] = "old-key"

        try repository.save(settings)

        XCTAssertEqual(store.secrets, ["radarr": "radarr-secret"], "an empty key removes the stored one")
        let saved = try XCTUnwrap(file)
        XCTAssertFalse(saved.contains("secret"), saved)
        XCTAssertEqual(repository.load().settings, settings)
    }

    func testFailedSaveLeavesTheFileAlone() throws {
        var settings = AppSettings()
        settings.seerr = ServiceConfig(url: "http://nas:5055", apiKey: "seerr-secret")
        store.failWrites = true

        XCTAssertThrowsError(try repository.save(settings))
        XCTAssertNil(file)
    }

    func testUnreadableKeysAreReported() throws {
        try repository.save({
            var settings = AppSettings()
            settings.sabnzbd = ServiceConfig(url: "http://nas:8080", apiKey: "sab-secret")
            return settings
        }())
        store.failReads = true

        let loaded = repository.load()

        XCTAssertEqual(loaded.settings.sabnzbd.apiKey, "")
        XCTAssertEqual(loaded.settings.sabnzbd.url, "http://nas:8080")
        XCTAssertEqual(loaded.problem, "Couldn't read the Sonarr API key from the Keychain: store unavailable")
    }

    func testEmptyPreferencesLoadDefaults() {
        let loaded = repository.load()
        XCTAssertNil(loaded.problem)
        XCTAssertEqual(loaded.settings, AppSettings())
        XCTAssertNil(file)
    }
}

/// The real login Keychain (CI sets up an unlocked one for this).
final class KeychainSecretStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let store = KeychainSecretStore(service: "com.boonboondesign.Screensaverr.tests.\(UUID().uuidString)")
        defer { try? store.removeSecret(for: "sonarr") }

        XCTAssertNil(try store.secret(for: "sonarr"))
        try store.setSecret("first", for: "sonarr")
        XCTAssertEqual(try store.secret(for: "sonarr"), "first")
        try store.setSecret("second", for: "sonarr")
        XCTAssertEqual(try store.secret(for: "sonarr"), "second")
        try store.removeSecret(for: "sonarr")
        XCTAssertNil(try store.secret(for: "sonarr"))
        try store.removeSecret(for: "sonarr")
    }
}
