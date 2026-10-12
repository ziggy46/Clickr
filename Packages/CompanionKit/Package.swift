// swift-tools-version: 6.0
import PackageDescription

// CompanionKit: the Apple TV Companion protocol stack. No UI; never imports SwiftUI or AppKit.
let package = Package(
    name: "CompanionKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "CompanionKit",
            targets: ["OPACK", "TLV8", "BigInt", "SRP", "Pairing", "Transport", "Discovery", "Session", "Store", "Plist", "MRP", "AirPlay", "Updates"]
        ),
    ],
    targets: [
        .target(name: "OPACK"),
        .target(name: "TLV8"),
        .target(name: "BigInt"),
        .target(name: "SRP", dependencies: ["BigInt"]),
        .target(name: "Pairing", dependencies: ["SRP", "TLV8", "OPACK"]),
        .target(name: "Transport"),
        .target(name: "Discovery"),
        .target(name: "Store", dependencies: ["Pairing"]),
        .target(name: "Plist"),
        .target(name: "MRP"),
        .target(name: "Updates"),
        .target(name: "AirPlay", dependencies: ["MRP", "Plist", "Pairing", "TLV8"]),
        .target(name: "Session", dependencies: ["Transport", "Pairing", "OPACK", "Store", "Discovery", "Plist", "MRP", "AirPlay"]),

        // Shared helpers for the test targets.
        .target(name: "TestSupport", dependencies: ["BigInt", "SRP"], path: "Tests/TestSupport"),

        .testTarget(name: "OPACKTests", dependencies: ["OPACK", "TestSupport"], resources: [.copy("Vectors")]),
        .testTarget(name: "TLV8Tests", dependencies: ["TLV8", "TestSupport"], resources: [.copy("Vectors")]),
        .testTarget(name: "BigIntTests", dependencies: ["BigInt", "TestSupport"], resources: [.copy("Vectors")]),
        .testTarget(name: "SRPTests", dependencies: ["SRP", "BigInt", "TestSupport"], resources: [.copy("Vectors")]),
        .testTarget(name: "PairingTests", dependencies: ["Pairing", "SRP", "OPACK", "TLV8", "TestSupport"], resources: [.copy("Vectors")]),
        .testTarget(name: "TransportTests", dependencies: ["Transport", "TestSupport"], resources: [.copy("Vectors")]),
        .testTarget(name: "DiscoveryTests", dependencies: ["Discovery"]),
        .testTarget(name: "StoreTests", dependencies: ["Store"]),
        .testTarget(name: "SessionTests", dependencies: ["Session", "Pairing", "Store", "Discovery", "OPACK", "TLV8", "Transport", "Plist", "TestSupport"], resources: [.copy("Vectors")]),

        .testTarget(name: "UpdatesTests", dependencies: ["Updates"]),
        .testTarget(name: "MRPTests", dependencies: ["MRP", "TestSupport"], resources: [.copy("Vectors")]),
        .testTarget(name: "AirPlayTests", dependencies: ["AirPlay", "MRP", "Plist", "Pairing", "TLV8", "TestSupport"], resources: [.copy("Vectors")]),

        // Talks to a real Apple TV. Skipped unless CLICKR_TV_HOST is set (see the test file).
        .testTarget(name: "IntegrationTests", dependencies: ["Transport"]),
    ]
)
