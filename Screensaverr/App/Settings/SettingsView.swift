import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screensaverr")
                        .font(.title2.weight(.semibold))
                    Text("Upcoming TV, movies, requests and downloads from your media server.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(model.versionString)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)

            Form {
                ForEach(ServiceKind.allCases) { kind in
                    Section {
                        ServiceSection(kind: kind, model: model)
                    } header: {
                        Text(kind.displayName)
                    }
                }

                Section {
                    Stepper(value: $model.settings.tvDaysAhead, in: 1...60) {
                        Text("Upcoming TV: next \(model.settings.clampedTVDays) days")
                    }
                    Stepper(value: $model.settings.movieDaysAhead, in: 7...365, step: 7) {
                        Text("Upcoming movies: next \(model.settings.clampedMovieDays) days")
                    }
                    Stepper(value: $model.settings.requestCount, in: 3...40) {
                        Text("Requests to show: \(model.settings.clampedRequestCount)")
                    }
                    Toggle("Show artwork in the background", isOn: $model.settings.showBackdrop)
                    Toggle("Allow self-signed HTTPS certificates", isOn: $model.settings.allowInvalidCertificates)
                } header: {
                    Text("Display")
                } footer: {
                    Text("Settings, including API keys, are stored only on this Mac. Saved API keys are never shown again.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.save() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(16)
        }
        .frame(width: 560, height: 720)
    }
}

private struct ServiceSection: View {
    let kind: ServiceKind
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        let config = model.binding(for: kind)

        Toggle("Show \(kind.displayName)", isOn: config.enabled)

        TextField("URL", text: config.url, prompt: Text(kind.urlPlaceholder))
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)

        // API keys are write-only: once saved they're never shown again, only replaced or removed.
        if model.showsKeyField(kind) {
            HStack(spacing: 6) {
                SecureField("API Key", text: model.keyDraft(for: kind),
                            prompt: Text(model.hasSavedKey(kind) ? "Paste the new API key" : "Paste the API key"))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                if model.hasSavedKey(kind) {
                    Button("Cancel") { model.keepSavedKey(kind) }
                        .help("Keep the saved API key")
                }
            }
        } else {
            LabeledContent("API Key") {
                HStack(spacing: 8) {
                    Label("Saved", systemImage: "lock.fill")
                        .foregroundColor(.secondary)
                        .help("For security, a saved API key can't be shown again.")
                    Button("Replace…") { model.replaceKey(kind) }
                    Button("Remove", role: .destructive) { model.removeKey(kind) }
                }
            }
        }

        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button("Test Connection") { model.test(kind) }
                .disabled(!model.canTest(kind))
            TestResultLabel(result: model.testResults[kind])
            Spacer(minLength: 0)
        }

        Text("Find the key in \(kind.displayName): \(kind.apiKeyHint)")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}

private struct TestResultLabel: View {
    let result: SettingsViewModel.TestResult?

    var body: some View {
        switch result {
        case .none:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").foregroundColor(.secondary)
            }
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .lineLimit(2)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
