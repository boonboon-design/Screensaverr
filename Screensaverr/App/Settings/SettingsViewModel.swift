import Foundation
import SwiftUI

@MainActor
final class SettingsViewModel: ObservableObject {
    enum TestResult: Equatable {
        case running
        case success(String)
        case failure(String)
    }

    @Published var settings: AppSettings
    @Published var testResults: [ServiceKind: TestResult] = [:]

    /// API keys typed into the sheet but not saved yet. Saved keys are never shown again:
    /// the sheet only says a key is saved, and offers to replace or remove it.
    @Published private var keyDrafts: [ServiceKind: String] = [:]
    @Published private var replacingKey: Set<ServiceKind> = []

    var onClose: () -> Void = {}

    private var testTasks: [ServiceKind: Task<Void, Never>] = [:]

    init(settings: AppSettings) {
        self.settings = settings
    }

    func binding(for kind: ServiceKind) -> Binding<ServiceConfig> {
        Binding(
            get: { self.settings[kind] },
            set: { newValue in
                self.settings[kind] = newValue
                self.testResults[kind] = nil
            }
        )
    }

    // MARK: API keys

    func hasSavedKey(_ kind: ServiceKind) -> Bool { !settings[kind].trimmedAPIKey.isEmpty }

    /// The key field shows when there's no saved key, or the user chose to replace it.
    func showsKeyField(_ kind: ServiceKind) -> Bool { !hasSavedKey(kind) || replacingKey.contains(kind) }

    /// Bound to the (always masked) key field; starts empty rather than showing the saved key.
    func keyDraft(for kind: ServiceKind) -> Binding<String> {
        Binding(
            get: { self.keyDrafts[kind] ?? "" },
            set: { newValue in
                self.keyDrafts[kind] = newValue
                self.testResults[kind] = nil
            }
        )
    }

    func replaceKey(_ kind: ServiceKind) {
        replacingKey.insert(kind)
        keyDrafts[kind] = nil
        testResults[kind] = nil
    }

    func keepSavedKey(_ kind: ServiceKind) {
        replacingKey.remove(kind)
        keyDrafts[kind] = nil
        testResults[kind] = nil
    }

    /// Takes effect on Save, like every other change in the sheet.
    func removeKey(_ kind: ServiceKind) {
        settings[kind].apiKey = ""
        replacingKey.remove(kind)
        keyDrafts[kind] = nil
        testResults[kind] = nil
    }

    /// A service's settings with any newly typed key in place of the saved one.
    private func effectiveConfig(_ kind: ServiceKind) -> ServiceConfig {
        var config = settings[kind]
        let draft = (keyDrafts[kind] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty { config.apiKey = draft }
        return config
    }

    // MARK: Testing and saving

    func canTest(_ kind: ServiceKind) -> Bool {
        let config = effectiveConfig(kind)
        return config.baseURL != nil && !config.trimmedAPIKey.isEmpty && testResults[kind] != .running
    }

    func test(_ kind: ServiceKind) {
        let config = effectiveConfig(kind)
        testTasks[kind]?.cancel()
        testResults[kind] = .running
        HTTPClient.shared.allowInvalidCertificates = settings.allowInvalidCertificates
        testTasks[kind] = Task { [weak self] in
            let result: TestResult
            do {
                result = .success(try await ConnectionTester.test(kind, config: config))
            } catch {
                result = .failure(ServiceError.describe(error))
            }
            guard !Task.isCancelled else { return }
            self?.testResults[kind] = result
        }
    }

    func save() {
        cancelTests()
        for kind in ServiceKind.allCases {
            settings[kind] = effectiveConfig(kind)
        }
        SettingsStore.save(settings)
        DashboardStore.shared.reloadSettings()
        onClose()
    }

    func cancel() {
        cancelTests()
        // Undo any certificate toggle made while testing.
        HTTPClient.shared.allowInvalidCertificates = SettingsStore.load().allowInvalidCertificates
        onClose()
    }

    private func cancelTests() {
        for task in testTasks.values { task.cancel() }
        testTasks = [:]
    }

    var versionString: String {
        let info = Bundle(for: ScreensaverrView.self).infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }
}
