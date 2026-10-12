import Network
import Testing
@testable import Discovery

private func endpoint(_ name: String) -> NWEndpoint {
    .service(name: name, type: "_companion-link._tcp", domain: "local.", interface: nil)
}

// Same keys an Apple TV advertises (see pyatv's atvproxy); values are made up.
private let appleTVTXT = [
    "rpMac": "0", "rpHN": "cef88e5db6fa", "rpFl": "0x36782", "rpHA": "9948cfb6da55",
    "rpVr": "530.6", "rpMd": "AppleTV11,1", "rpHI": "91756a18d8e5", "rpAD": "3b2210518c58",
    "rpMRtID": "4B8D5A0C-1F2E-4C3B-9A7D-6E5F4A3B2C1D", "rpBA": "AA:BB:CC:DD:EE:FF",
]

@Suite struct DiscoveredDeviceTests {
    @Test func parsesAppleTV() throws {
        let device = try #require(DiscoveredDevice(name: "Living Room", endpoint: endpoint("Living Room"), txt: appleTVTXT))
        #expect(device.name == "Living Room")
        #expect(device.id == "4B8D5A0C-1F2E-4C3B-9A7D-6E5F4A3B2C1D")
        #expect(device.modelIdentifier == "AppleTV11,1")
        #expect(device.modelName == "Apple TV 4K")
        #expect(device.txt["rpfl"] == "0x36782")
    }

    @Test func txtKeysAreCaseInsensitive() throws {
        let device = try #require(DiscoveredDevice(name: "Den", endpoint: endpoint("Den"), txt: ["RPMD": "AppleTV5,3"]))
        #expect(device.modelName == "Apple TV HD")
    }

    @Test func fallsBackToNameWithoutRouteID() throws {
        let device = try #require(DiscoveredDevice(name: "Den", endpoint: endpoint("Den"), txt: ["rpMd": "AppleTV6,2"]))
        #expect(device.id == "Den")
    }

    @Test(arguments: ["MacBookPro18,3", "iPhone15,2", "iPad13,4", "AudioAccessory5,1", ""])
    func ignoresOtherCompanionDevices(model: String) {
        #expect(DiscoveredDevice(name: "Not a TV", endpoint: endpoint("Not a TV"), txt: ["rpMd": model]) == nil)
    }

    @Test func ignoresMissingModel() {
        #expect(DiscoveredDevice(name: "Unknown", endpoint: endpoint("Unknown"), txt: [:]) == nil)
    }

    @Test(arguments: [
        ("AppleTV5,3", "Apple TV HD"),
        ("AppleTV6,2", "Apple TV 4K"),
        ("AppleTV11,1", "Apple TV 4K"),
        ("AppleTV14,1", "Apple TV 4K"),
        ("AppleTV99,1", "Apple TV"),
    ])
    func modelNames(identifier: String, expected: String) {
        #expect(AppleTVModel.displayName(for: identifier) == expected)
    }
}

@Suite struct BrowseResultTests {
    // NWBrowser reports one result per interface (Wi-Fi and Ethernet) for the same TV.
    @Test func collapsesDuplicatesAcrossInterfaces() {
        let records = [
            BrowseRecord(name: "Living Room", interfaceName: "en1", endpoint: endpoint("Living Room"), txt: appleTVTXT),
            BrowseRecord(name: "Living Room", interfaceName: "en0", endpoint: endpoint("Living Room"), txt: appleTVTXT),
        ]
        #expect(DeviceBrowser.devices(from: records).map(\.name) == ["Living Room"])
    }

    @Test func filtersAndSorts() {
        let records = [
            BrowseRecord(name: "Living Room", interfaceName: "en0", endpoint: endpoint("Living Room"), txt: ["rpMd": "AppleTV14,1"]),
            BrowseRecord(name: "Someone's MacBook Pro", interfaceName: "en0", endpoint: endpoint("Someone's MacBook Pro"), txt: ["rpMd": "MacBookPro18,3"]),
            BrowseRecord(name: "Bedroom", interfaceName: "en0", endpoint: endpoint("Bedroom"), txt: ["rpMd": "AppleTV11,1"]),
            BrowseRecord(name: "Kitchen", interfaceName: "en0", endpoint: endpoint("Kitchen"), txt: ["rpMd": "AudioAccessory5,1"]),
        ]
        #expect(DeviceBrowser.devices(from: records).map(\.name) == ["Bedroom", "Living Room"])
    }

    @Test func emptyResults() {
        #expect(DeviceBrowser.devices(from: []).isEmpty)
    }
}

@Suite struct DeviceBrowserIsolationTests {
    // NWBrowser and NWPathMonitor callbacks run on the actor's queue and call
    // assumeIsolated. This checks that pattern holds at runtime without touching the network.
    @Test func callbacksOnQueueAreIsolated() async {
        let browser = DeviceBrowser()
        let isolated = await withCheckedContinuation { continuation in
            browser.queue.async {
                browser.assumeIsolated { _ in continuation.resume(returning: true) }
            }
        }
        #expect(isolated)
    }

    @Test func devicesStreamYieldsCurrentListFirst() async {
        let browser = DeviceBrowser()
        var iterator = await browser.devices.makeAsyncIterator()
        #expect(await iterator.next() == [])
    }
}
