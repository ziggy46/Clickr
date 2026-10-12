import Network

/// An Apple TV found over Bonjour on `_companion-link._tcp`.
public struct DiscoveredDevice: Sendable, Hashable, Identifiable {
    /// `rpMRtID` from the TXT record when present (stable on tvOS 16+), otherwise the service name.
    public let id: String
    /// Service name, which is the name set on the TV, e.g. "Living Room".
    public let name: String
    public let endpoint: NWEndpoint
    /// TXT record with lowercased keys, since DNS-SD keys are case-insensitive.
    public let txt: [String: String]

    /// Raw model identifier from `rpMd`, e.g. "AppleTV11,1".
    public var modelIdentifier: String { txt["rpmd"] ?? "" }

    /// Human readable model, e.g. "Apple TV 4K".
    public var modelName: String { AppleTVModel.displayName(for: modelIdentifier) }

    /// Returns nil unless the TXT record says this is an Apple TV. Macs, iPhones, iPads
    /// and HomePods advertise the same service type.
    public init?(name: String, endpoint: NWEndpoint, txt: [String: String]) {
        let txt = Dictionary(txt.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        guard let model = txt["rpmd"], AppleTVModel.isAppleTV(model) else { return nil }

        let routeID = txt["rpmrtid"] ?? ""
        self.id = routeID.isEmpty ? name : routeID
        self.name = name
        self.endpoint = endpoint
        self.txt = txt
    }
}

enum AppleTVModel {
    static func isAppleTV(_ identifier: String) -> Bool {
        identifier.hasPrefix("AppleTV")
    }

    // Identifiers taken from pyatv's model table.
    static func displayName(for identifier: String) -> String {
        switch identifier {
        case "AppleTV5,3": "Apple TV HD"
        case "AppleTV6,2", "AppleTV11,1", "AppleTV14,1": "Apple TV 4K"
        default: "Apple TV"
        }
    }
}
