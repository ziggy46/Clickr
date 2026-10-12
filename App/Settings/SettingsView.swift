import SwiftUI
import Updates

/// Clickr's Settings window, opened from the menu bar icon's right-click menu.
struct SettingsView: View {
    let model: RemoteViewModel
    @Bindable var updates: UpdateController
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var deviceToForget: String?
    @AppStorage(AppSettings.showKeyboardHint) private var showKeyboardHint = true
    @AppStorage(AppSettings.hideIconWithoutAppleTV) private var hideIconWithoutAppleTV = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.secondary)
                } else if LaunchAtLogin.needsApproval {
                    Text("Allow Clickr in System Settings > General > Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Remote") {
                Toggle("Show the keyboard hint", isOn: $showKeyboardHint)
                Toggle("Hide the menu bar icon when no Apple TV is found", isOn: $hideIconWithoutAppleTV)
                if hideIconWithoutAppleTV {
                    Text("While it's hidden, open Clickr again from Applications to get back to Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Apple TV") {
                Picker("Default Apple TV", selection: defaultDevice) {
                    Text("Last used").tag(String?.none)
                    ForEach(model.pairedDeviceIDs, id: \.self) { id in
                        Text(model.name(for: id)).tag(String?.some(id))
                    }
                }
            }

            Section("Paired Apple TVs") {
                if model.pairedDeviceIDs.isEmpty {
                    Text("None yet. Open the remote to pair an Apple TV.").foregroundStyle(.secondary)
                }
                ForEach(model.pairedDeviceIDs, id: \.self) { id in
                    HStack {
                        Text(model.name(for: id))
                        Spacer()
                        Button("Forget…") { deviceToForget = id }
                    }
                }
            }

            Section("Keyboard") {
                LabeledContent("Open the remote") {
                    ShortcutRecorder()
                }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
                LabeledContent("Clickr \(updates.currentVersion)") {
                    HStack(spacing: 8) {
                        if !updateStatus.isEmpty {
                            Text(updateStatus).foregroundStyle(.secondary)
                        }
                        if updates.availableRelease != nil {
                            Button("Download…") { updates.openReleasePage() }
                        } else {
                            Button("Check Now") { updates.checkNow() }
                                .disabled(updates.status == .checking)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Size the window to the whole form instead of scrolling inside it.
        .scrollDisabled(true)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refreshPairedDevices() }
        .alert(
            "Forget \(deviceToForget.map(model.name(for:)) ?? "this Apple TV")?",
            isPresented: Binding(get: { deviceToForget != nil }, set: { if !$0 { deviceToForget = nil } })
        ) {
            Button("Forget", role: .destructive) {
                if let deviceToForget { model.forget(deviceToForget) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clickr removes its pairing key from your Keychain. To remove Clickr from the TV too, open Settings > Remotes and Devices on the Apple TV.")
        }
    }

    private var updateStatus: String {
        switch updates.status {
        case .idle: ""
        case .checking: "Checking…"
        case .upToDate: "Up to date"
        case .noReleases: "No releases yet"
        case .available(let release): "Version \(release.version) is available"
        case .failed(let message): message
        }
    }

    private var defaultDevice: Binding<String?> {
        Binding(get: { model.defaultDeviceID }, set: { model.defaultDeviceID = $0 })
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchError = nil
        } catch {
            launchError = "Couldn't change the login item: \(error.localizedDescription)"
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}
