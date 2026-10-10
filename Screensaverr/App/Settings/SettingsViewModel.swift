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

    func canTest(_ kind: ServiceKind) -> Bool {
        let config = settings[kind]
        return config.baseURL != nil && !config.trimmedAPIKey.isEmpty && testResults[kind] != .running
    }

    func test(_ kind: ServiceKind) {
        let config = settings[kind]
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
