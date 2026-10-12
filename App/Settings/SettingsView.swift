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

    /// The tab that was open last time.
    @AppStorage("SettingsTab") private var tab = Tab.general
    @AppStorage(AppSettings.playbackControls) private var playbackControls = true
    @AppStorage(AppSettings.trackpadSwipes) private var trackpadSwipes = true

    enum Tab: String {
        case general, remote, appleTVs, updates
    }

    var body: some View {
        TabView(selection: $tab) {
            page { general }
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            page { remote }
                .tabItem { Label("Remote", systemImage: "appletvremote.gen4") }
                .tag(Tab.remote)
            page { appleTVs }
                .tabItem { Label("Apple TVs", systemImage: "appletv") }
                .tag(Tab.appleTVs)
            page { updatesPage }
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                .tag(Tab.updates)
        }
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

    /// One tab's form, sized to its contents so the window fits each tab without scrolling.
    private func page(@ViewBuilder _ content: () -> some View) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Tabs

    @ViewBuilder
    private var general: some View {
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
        Section("Menu bar") {
            Toggle("Hide the menu bar icon when no Apple TV is found", isOn: $hideIconWithoutAppleTV)
            if hideIconWithoutAppleTV {
                Text("While it's hidden, open Clickr again from Applications to get back to Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var remote: some View {
        Section {
            Toggle(isOn: $playbackControls) {
                Text("Show playback controls")
                Text("Play, pause and skip on the now playing card, and drag its progress bar to jump around.")
            }
            Toggle(isOn: $trackpadSwipes) {
                Text("Swipe on the clickpad")
                Text("Swipe with two fingers on your trackpad while the pointer is over the clickpad, like the touch surface on a Siri Remote.")
            }
            Toggle("Show the keyboard hint", isOn: $showKeyboardHint)
        }
        Section("Keyboard") {
            LabeledContent("Open the remote") {
                ShortcutRecorder()
            }
        }
    }

    @ViewBuilder
    private var appleTVs: some View {
        Section {
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
    }

    @ViewBuilder
    private var updatesPage: some View {
        Section {
            Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
            Toggle(isOn: $updates.installsAutomatically) {
                Text("Install updates automatically")
                Text("Downloads new versions in the background and restarts Clickr when you're not using it.")
            }
            .disabled(!updates.checksAutomatically || updates.installBlocker != nil)
        } footer: {
            if let message = updateFooter {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Section {
            LabeledContent("Clickr \(updates.currentVersion)") {
                HStack(spacing: 8) {
                    if updates.installState == .preparing || updates.installState == .waitingToRestart {
                        ProgressView().controlSize(.small)
                    }
                    if !updateStatus.isEmpty {
                        Text(updateStatus).foregroundStyle(.secondary)
                    }
                    if updates.availableRelease == nil {
                        Button("Check Now") { updates.checkNow() }
                            .disabled(updates.status == .checking)
                    } else if updates.canInstallAvailableUpdate {
                        Button("Install and Restart") { updates.installNow() }
                            .disabled(updates.installState == .preparing)
                    } else {
                        Button("Download…") { updates.openReleasePage() }
                    }
                }
            }
        }
    }

    private var updateStatus: String {
        switch updates.status {
        case .idle: ""
        case .checking: "Checking…"
        case .upToDate: "Up to date"
        case .noReleases: "No releases yet"
        case .available(let release):
            switch updates.installState {
            case .preparing: "Downloading \(release.version)…"
            case .waitingToRestart: "Restarts when idle"
            default: "Version \(release.version) is available"
            }
        case .failed(let message): message
        }
    }

    /// Why installing didn't work, or why it can't happen from inside Clickr.
    private var updateFooter: String? {
        if case .failed(let message) = updates.installState { return message }
        return updates.installBlocker
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
