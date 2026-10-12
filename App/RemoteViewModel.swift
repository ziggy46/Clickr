import Discovery
import Observation

@MainActor
@Observable
final class RemoteViewModel {
    private(set) var devices: [DiscoveredDevice] = []

    private let browser = DeviceBrowser()

    init() {
        Task { await watchDevices() }
    }

    private func watchDevices() async {
        await browser.start()
        for await devices in await browser.devices {
            self.devices = devices
        }
    }
}
