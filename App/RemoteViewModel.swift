import Discovery
import Foundation
import Observation
import os
import Session

/// Owns discovery (and, from Milestone 6, the session) and maps UI actions to commands.
@MainActor
@Observable
final class RemoteViewModel {
    private(set) var devices: [DiscoveredDevice] = []
    private(set) var selectedDeviceID: DiscoveredDevice.ID?
    private(set) var connectionState: ConnectionState = .disconnected

    /// Set after a wrong PIN so the pairing view can show the error line.
    private(set) var pairingFailed = false

    private let browser = DeviceBrowser()
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
        }
    }

    // MARK: - Actions
    // There's no session yet, so these only log. Milestone 6 wires them to AppleTVSession.

    func select(_ device: DiscoveredDevice) {
        selectedDeviceID = device.id
    }

    func retry() {
        log.debug("Retry tapped")
    }

    func press(_ button: RemoteButton, hold: Bool = false) {
        log.debug("Pressed \(String(describing: button), privacy: .public)\(hold ? " (hold)" : "", privacy: .public)")
    }

    /// Returns whether the TV accepted the PIN.
    func submitPIN(_ pin: String) async -> Bool {
        log.debug("PIN submitted")
        pairingFailed = true
        return false
    }

    func cancelPairing() {
        pairingFailed = false
    }

    #if DEBUG
    private func apply(_ preview: PreviewOverrides) {
        devices = preview.devices
        connectionState = preview.state
        pairingFailed = preview.pairingFailed
    }
    #endif
}
