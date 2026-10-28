import Foundation
import ScreenSaver

/// Persists `AppSettings`: API keys in the login Keychain, everything else with ScreenSaverDefaults,
/// which works inside the sandboxed `legacyScreenSaver` host (both the System Settings preview and
/// the real screen saver). See `SettingsRepository`.
enum SettingsStore {
    private static let key = "settings.v1"

    static var moduleName: String {
        Bundle(for: ScreensaverrView.self).bundleIdentifier ?? "com.boonboondesign.Screensaverr"
    }

    private static var repository: SettingsRepository? {
        guard let defaults = ScreenSaverDefaults(forModuleWithName: moduleName) else { return nil }
        return SettingsRepository(
            readPreferences: {
                defaults.synchronize()
                return defaults.string(forKey: key)
            },
            writePreferences: { json in
                defaults.set(json, forKey: key)
                defaults.synchronize()
            },
            secrets: KeychainSecretStore(service: moduleName)
        )
    }

    static func load() -> AppSettings {
        loadReportingProblems().settings
    }

    static func loadReportingProblems() -> SettingsRepository.Loaded {
        guard let repository else { return SettingsRepository.Loaded(settings: AppSettings()) }
        let loaded = repository.load()
        if let problem = loaded.problem { Log.general.error("\(problem, privacy: .public)") }
        return loaded
    }

    /// Throws if the Keychain won't take the keys; they're never written anywhere else.
    static func save(_ settings: AppSettings) throws {
        try repository?.save(settings)
    }
}
