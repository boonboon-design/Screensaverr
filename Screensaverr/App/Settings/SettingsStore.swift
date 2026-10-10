import Foundation
import ScreenSaver

/// Persists `AppSettings` with ScreenSaverDefaults, which works inside the sandboxed
/// `legacyScreenSaver` host (both the System Settings preview and the real screen saver).
enum SettingsStore {
    private static let key = "settings.v1"

    static var moduleName: String {
        Bundle(for: ScreensaverrView.self).bundleIdentifier ?? "com.boonboondesign.Screensaverr"
    }

    private static var defaults: ScreenSaverDefaults? {
        ScreenSaverDefaults(forModuleWithName: moduleName)
    }

    static func load() -> AppSettings {
        guard let defaults else { return AppSettings() }
        defaults.synchronize()
        guard let json = defaults.string(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        else { return AppSettings() }
        return settings
    }

    static func save(_ settings: AppSettings) {
        guard let defaults,
              let data = try? JSONEncoder().encode(settings),
              let json = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(json, forKey: key)
        defaults.synchronize()
    }
}
