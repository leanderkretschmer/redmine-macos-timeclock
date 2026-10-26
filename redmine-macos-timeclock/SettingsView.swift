import AppKit
import ServiceManagement
import SwiftUI

/// Configuration pane: Redmine server, API key and/or login.
struct SettingsView: View {
    let model: AppModel
    @State private var draft: ConnectionSettings
    @State private var isTesting = false
    @State private var resultMessage: String?
    @State private var succeeded = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Einstellungen")
                    .font(.headline)
                Spacer()
                if model.isConfigured {
                    Button("Fertig") { model.showingSettings = false }
                        .buttonStyle(.borderless)
                }
            }

            Form {
                TextField("Server", text: $draft.serverURL, prompt: Text("https://redmine.example.com"))
                    .textContentType(.URL)
                SecureField("API-Key", text: $draft.apiKey)
                Divider()
                TextField("Benutzer", text: $draft.username)
                    .textContentType(.username)
                SecureField("Passwort", text: $draft.password)
                    .textContentType(.password)
            }
            .formStyle(.columns)

            Text("API-Key: „Mein Konto“ → „API-Zugriffsschlüssel“. Damit funktionieren Tickets und Ein-/Ausstempeln über die Quick-Schnittstelle des HR-Plugins.\nBenutzer/Passwort (optional): zusätzlich Pause, Live-Status der Arbeitszeit und die Ticket-Stoppuhr. Zugangsdaten liegen im Schlüsselbund.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Beim Anmelden starten", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    setLaunchAtLogin(enabled)
                }
            if let launchAtLoginError {
                Label(launchAtLoginError, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let resultMessage {
                Label(resultMessage, systemImage: succeeded ? "checkmark.circle" : "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(succeeded ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Beenden") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                Spacer()
                if isTesting {
                    ProgressView().controlSize(.small)
                }
                Button("Speichern & verbinden") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.clientConfiguration == nil || isTesting)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func save() async {
        isTesting = true
        resultMessage = nil
        let error = await model.apply(draft)
        isTesting = false
        succeeded = error == nil
        resultMessage = error ?? "Verbunden als \(model.userName ?? "?")"
    }

    /// Registers or removes the app as a login item; reverts the toggle if the system refuses.
    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        guard enabled != (service.status == .enabled) else { return }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            launchAtLogin = service.status == .enabled
        }
    }
}
