import Discovery
import Foundation
import Observation
import os
import Pairing
import Session
import Store

/// Owns discovery and the session for the selected TV, and maps UI actions to commands.
@MainActor
@Observable
final class RemoteViewModel {
    private(set) var devices: [DiscoveredDevice] = []
    private(set) var selectedDeviceID: DiscoveredDevice.ID?
    private(set) var connectionState: ConnectionState = .disconnected

    /// Replaces the pairing view's instructions after a failed attempt.
    private(set) var pairingMessage: String?

    /// True while the "Type on the TV" field has focus, so remote shortcuts stand aside.
    var isTyping = false

    /// Whether the selected TV says it's asleep.
    private(set) var isAsleep = false

    /// The "Type on the TV" text. Follows the TV: emptied when its keyboard goes away,
    /// filled with what's already there when a text field gains focus.
    var tvText = ""
    /// The text the TV is known to have, so updates that came from the TV aren't sent back.
    private var syncedText = ""

    /// True once no Apple TV has been on the network for a few seconds (for hiding the icon).
    private(set) var noAppleTVFound = false
    private var noAppleTVTimer: Task<Void, Never>?

    /// TVs with saved pairing keys (for Settings).
    private(set) var pairedDeviceIDs: [String] = []

    /// The TV to select at launch; nil means the last one used.
    var defaultDeviceID: String? = UserDefaults.standard.string(forKey: RemoteViewModel.defaultDeviceKey) {
        didSet { UserDefaults.standard.set(defaultDeviceID, forKey: Self.defaultDeviceKey) }
    }

    /// Last known name for each TV we've seen, so Settings can name TVs that are off right now.
    private var deviceNames: [String: String] = UserDefaults.standard.dictionary(forKey: RemoteViewModel.deviceNamesKey) as? [String: String] ?? [:]
    private static let defaultDeviceKey = "DefaultDeviceID"
    private static let deviceNamesKey = "DeviceNames"

    private let browser = DeviceBrowser()
    private let store: CredentialStore = KeychainCredentialStore()
    private var sessions: [DiscoveredDevice.ID: AppleTVSession] = [:]
    private var observedDeviceID: DiscoveredDevice.ID?
    private var stateTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var pairingStart: Task<Void, Error>?
    private var isPreview = false
    private let log = Logger(subsystem: "com.ziggy46.clickr", category: "Remote")

    /// The last version of the selected TV we saw, so a TV that briefly drops out of
    /// discovery doesn't make the selection jump to another one.
    private var lastSelectedDevice: DiscoveredDevice?
    private static let selectedDeviceKey = "SelectedDeviceID"
    /// True until the user picks a TV (now or in an earlier launch).
    private var selectionIsAutomatic = true

    var selectedDevice: DiscoveredDevice? {
        guard let selectedDeviceID else { return nil }
        return devices.first { $0.id == selectedDeviceID } ?? lastSelectedDevice
    }

    init() {
        #if DEBUG
        if let preview = PreviewOverrides.current {
            apply(preview)
            return
        }
        #endif
        Task { await watchDevices() }
    }

    private func watchDevices() async {
        await browser.start()
        refreshPairedDevices()
        selectedDeviceID = defaultDeviceID ?? UserDefaults.standard.string(forKey: Self.selectedDeviceKey)
        selectionIsAutomatic = selectedDeviceID == nil
        for await devices in await browser.devices {
            self.devices = devices
            rememberNames(of: devices)
            trackWhetherAnyTVIsAround()
            // Until the user chooses, follow the preferred TV, so a paired TV that shows up
            // a moment after an unpaired one still wins. Never move off a paired TV to an
            // unpaired one, though: a sleeping TV can drop out of discovery for a moment.
            if selectionIsAutomatic, let preferred = preferredDevice(in: devices),
               selectedDeviceID == nil || isPaired(preferred.id) || !isPaired(selectedDeviceID!) {
                selectedDeviceID = preferred.id
            }
            if let current = devices.first(where: { $0.id == selectedDeviceID }) {
                lastSelectedDevice = current
            }
            observeSelectedDevice()
        }
    }

    // MARK: - Devices and sessions

    func select(_ device: DiscoveredDevice) {
        selectionIsAutomatic = false
        selectedDeviceID = device.id
        lastSelectedDevice = device
        UserDefaults.standard.set(device.id, forKey: Self.selectedDeviceKey)
        observeSelectedDevice()
    }

    /// With nothing selected yet, prefer a TV we're already paired with.
    private func preferredDevice(in devices: [DiscoveredDevice]) -> DiscoveredDevice? {
        devices.first { isPaired($0.id) } ?? devices.first
    }

    private func isPaired(_ deviceID: String) -> Bool {
        pairedDeviceIDs.contains(deviceID)
    }

    private var selectedSession: AppleTVSession? {
        guard !isPreview, let device = selectedDevice else { return nil }
        if let session = sessions[device.id] { return session }
        let session = AppleTVSession(device: device, store: store)
        sessions[device.id] = session
        return session
    }

    /// Follows the selected TV's connection state.
    private func observeSelectedDevice() {
        guard selectedDevice?.id != observedDeviceID else { return }
        observedDeviceID = selectedDevice?.id
        stateTask?.cancel()
        updatesTask?.cancel()
        isAsleep = false
        receivedFromTV("")
        guard let session = selectedSession else {
            connectionState = .disconnected
            return
        }
        stateTask = Task { [weak self] in
            for await state in await session.state {
                self?.connectionState = state
            }
        }
        updatesTask = Task { [weak self] in
            for await update in await session.updates {
                switch update {
                case .asleep(let asleep):
                    self?.log.info("TV reports \(asleep ? "asleep" : "awake", privacy: .public)")
                    self?.isAsleep = asleep
                case .keyboardShown(let text): self?.receivedFromTV(text)
                case .keyboardHidden: self?.receivedFromTV("")
                }
            }
        }
        // Paired TVs connect right away; an unpaired one waits for the pairing view.
        Task { await session.connect() }
    }

    // MARK: - Settings

    func name(for deviceID: String) -> String {
        devices.first { $0.id == deviceID }?.name ?? deviceNames[deviceID] ?? "Apple TV"
    }

    func refreshPairedDevices() {
        pairedDeviceIDs = (try? store.pairedDeviceIDs()) ?? []
    }

    /// Removes the pairing key. The TV keeps its "Clickr" entry until removed there.
    func forget(_ deviceID: String) {
        if let session = sessions.removeValue(forKey: deviceID) {
            Task { await session.disconnect() }
        }
        do {
            try store.removeCredentials(for: deviceID)
        } catch {
            log.error("Couldn't remove the pairing key: \(String(describing: error), privacy: .public)")
        }
        if defaultDeviceID == deviceID { defaultDeviceID = nil }
        refreshPairedDevices()
        if observedDeviceID == deviceID {
            observedDeviceID = nil
            observeSelectedDevice()
        }
    }

    private func rememberNames(of devices: [DiscoveredDevice]) {
        var changed = false
        for device in devices where deviceNames[device.id] != device.name {
            deviceNames[device.id] = device.name
            changed = true
        }
        if changed { UserDefaults.standard.set(deviceNames, forKey: Self.deviceNamesKey) }
    }

    // MARK: - Remote actions

    func retry() {
        guard let session = selectedSession else { return }
        Task { await session.connect() }
    }

    func press(_ button: RemoteButton, hold: Bool = false) {
        guard let session = selectedSession else { return }
        Task {
            do {
                try await session.press(button, hold: hold)
            } catch {
                log.error("Press \(String(describing: button), privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Sleeps the TV, or wakes it if it says it's asleep.
    func togglePower() {
        guard let session = selectedSession else { return }
        let wake = isAsleep
        log.info("Power held: sending \(wake ? "Wake" : "Sleep", privacy: .public)")
        Task {
            do {
                try await session.setPower(on: wake)
                log.info("TV accepted \(wake ? "Wake" : "Sleep", privacy: .public)")
            } catch {
                log.error("Power failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func receivedFromTV(_ text: String) {
        syncedText = text
        tvText = text
    }

    /// After a few seconds with no Apple TV on the network, report none found. A TV showing
    /// up again counts right away.
    private func trackWhetherAnyTVIsAround() {
        noAppleTVTimer?.cancel()
        if !devices.isEmpty {
            noAppleTVFound = false
            return
        }
        noAppleTVTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.noAppleTVFound = true
        }
    }

    /// Makes the TV's focused text field match `text`.
    func typeOnTV(_ text: String) {
        guard text != syncedText, let session = selectedSession else { return }
        syncedText = text
        Task {
            do {
                try await session.sendText(text)
            } catch AppleTVSession.SessionError.noTextField {
                log.info("No text field has focus on the TV")
            } catch {
                log.error("Typing failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Pairing

    /// Called when the pairing view appears: connects and asks the TV to show a PIN.
    func beginPairing() async {
        pairingMessage = nil
        await startPairing()
    }

    private func startPairing() async {
        guard let session = selectedSession else { return }
        let start = Task { try await session.beginPairing() }
        pairingStart = start
        do {
            try await start.value
        } catch {
            log.error("Couldn't start pairing: \(String(describing: error), privacy: .public)")
            pairingMessage = "Couldn't reach \(selectedDevice?.name ?? "the Apple TV"). Close and try again."
        }
    }

    /// Returns whether the TV accepted the PIN. After a failure a new attempt starts right
    /// away, so the TV shows a fresh PIN.
    func submitPIN(_ pin: String) async -> Bool {
        guard let session = selectedSession else { return false }
        _ = try? await pairingStart?.value
        do {
            try await session.finishPairing(pin: pin)
            pairingMessage = nil
            refreshPairedDevices()
            await session.connect()
            return true
        } catch PairSetup.PairingError.wrongPIN {
            pairingMessage = "That code didn't match. Try again."
        } catch let error as KeychainCredentialStore.KeychainError {
            // The TV did pair; only saving failed. Starting over would just leave another
            // pairing on the TV, so stop here.
            log.error("Paired, but saving failed: \(error.status)")
            pairingMessage = "Paired, but couldn't save the pairing key to the Keychain."
            return false
        } catch {
            log.error("Pairing failed: \(String(describing: error), privacy: .public)")
            pairingMessage = "Pairing didn't work. Try again with the new code."
        }
        await startPairing()
        return false
    }

    /// Cancel button, or the popover closing: the TV takes the PIN off the screen. Stops
    /// pairing on every TV, in case the selection moved while one was in progress.
    func cancelPairing() {
        pairingStart?.cancel()
        for session in sessions.values {
            Task { await session.cancelPairing() }
        }
    }

    #if DEBUG
    private func apply(_ preview: PreviewOverrides) {
        isPreview = true
        devices = preview.devices
        selectedDeviceID = preview.devices.first?.id
        connectionState = preview.state
        pairingMessage = preview.pairingFailed ? "That code didn't match. Try again." : nil
    }
    #endif
}
