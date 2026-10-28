import Foundation

/// Loads and saves `AppSettings` while keeping API keys out of the preferences file: they live in
/// a `SecretStore` (the login Keychain), and the file holds everything else as JSON.
///
/// Versions before 1.3.0 kept keys in the file. The first load moves any it finds into the store
/// and rewrites the file without them; if the store can't take them, they stay where they were
/// (so nothing is lost) and the move is tried again next time.
struct SettingsRepository {
    struct Loaded {
        var settings: AppSettings
        /// Why some keys couldn't be read or moved, for the Options sheet and the log.
        var problem: String?
    }

    var readPreferences: () -> String?
    var writePreferences: (String) -> Void
    var secrets: SecretStore

    func load() -> Loaded {
        var settings = readPreferences()
            .flatMap { try? JSONDecoder().decode(AppSettings.self, from: Data($0.utf8)) } ?? AppSettings()

        let keysInFile = ServiceKind.allCases.filter { !settings[$0].trimmedAPIKey.isEmpty }
        if !keysInFile.isEmpty {
            do {
                for kind in keysInFile {
                    try secrets.setSecret(settings[kind].trimmedAPIKey, for: kind.rawValue)
                }
            } catch {
                return Loaded(settings: settings,
                              problem: "Couldn't move API keys into the Keychain: \(error.localizedDescription)")
            }
            if let json = Self.encodeWithoutKeys(settings) { writePreferences(json) }
        }

        var problem: String?
        for kind in ServiceKind.allCases {
            do {
                settings[kind].apiKey = try secrets.secret(for: kind.rawValue) ?? ""
            } catch {
                settings[kind].apiKey = ""
                problem = problem ?? "Couldn't read the \(kind.displayName) API key from the Keychain: \(error.localizedDescription)"
            }
        }
        return Loaded(settings: settings, problem: problem)
    }

    /// Keys go to the store (an empty key removes it); the file is only written once they're safely there.
    func save(_ settings: AppSettings) throws {
        for kind in ServiceKind.allCases {
            let key = settings[kind].trimmedAPIKey
            if key.isEmpty {
                try secrets.removeSecret(for: kind.rawValue)
            } else {
                try secrets.setSecret(key, for: kind.rawValue)
            }
        }
        if let json = Self.encodeWithoutKeys(settings) { writePreferences(json) }
    }

    static func encodeWithoutKeys(_ settings: AppSettings) -> String? {
        var stripped = settings
        for kind in ServiceKind.allCases { stripped[kind].apiKey = "" }
        guard let data = try? JSONEncoder().encode(stripped) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
