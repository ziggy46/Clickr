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

    private let browser = DeviceBrowser()
    private let store: CredentialStore = KeychainCredentialStore()
    private var sessions: [DiscoveredDevice.ID: AppleTVSession] = [:]
    private var observedDeviceID: DiscoveredDevice.ID?
    private var stateTask: Task<Void, Never>?
    private var pairingStart: Task<Void, Error>?
    private var isPreview = false
    private let log = Logger(subsystem: "com.ziggy46.clickr", category: "Remote")

    var selectedDevice: DiscoveredDevice? {
        devices.first { $0.id == selectedDeviceID } ?? devices.first
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
        for await devices in await browser.devices {
            self.devices = devices
            observeSelectedDevice()
        }
    }

    // MARK: - Devices and sessions

    func select(_ device: DiscoveredDevice) {
        selectedDeviceID = device.id
        observeSelectedDevice()
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
        guard let session = selectedSession else {
            connectionState = .disconnected
            return
        }
        stateTask = Task { [weak self] in
            for await state in await session.state {
                self?.connectionState = state
            }
        }
    }

    // MARK: - Remote actions
    // Milestone 6 connects with pair-verify and sends these to the TV. For now they only log.

    func retry() {
        log.debug("Retry tapped")
    }

    func press(_ button: RemoteButton, hold: Bool = false) {
        log.debug("Pressed \(String(describing: button), privacy: .public)\(hold ? " (hold)" : "", privacy: .public)")
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
            return true
        } catch PairSetup.PairingError.wrongPIN {
            pairingMessage = "That code didn't match. Try again."
        } catch {
            log.error("Pairing failed: \(String(describing: error), privacy: .public)")
            pairingMessage = "Pairing didn't work. Try again with the new code."
        }
        await startPairing()
        return false
    }

    /// Cancel button, or the popover closing: the TV takes the PIN off the screen.
    func cancelPairing() {
        pairingStart?.cancel()
        guard let session = selectedSession else { return }
        Task { await session.cancelPairing() }
    }

    #if DEBUG
    private func apply(_ preview: PreviewOverrides) {
        isPreview = true
        devices = preview.devices
        connectionState = preview.state
        pairingMessage = preview.pairingFailed ? "That code didn't match. Try again." : nil
    }
    #endif
}
