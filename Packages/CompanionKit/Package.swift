// swift-tools-version: 6.0
import PackageDescription

// CompanionKit: the Apple TV Companion protocol stack. No UI; never imports SwiftUI or AppKit.
let package = Package(
    name: "CompanionKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "CompanionKit",
            targets: ["OPACK", "TLV8", "BigInt", "SRP", "Pairing", "Transport", "Discovery", "Session", "Store"]
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
        .target(name: "Session", dependencies: ["Transport", "Pairing", "OPACK", "Store", "Discovery"]),

        // Shared helpers for the test targets.
        .target(name: "TestSupport", dependencies: ["BigInt", "SRP"], path: "Tests/TestSupport"),

        .testTarget(name: "OPACKTests", dependencies: ["OPACK", "TestSupport"], resources: [.copy("Vectors")]),
        .testTarget(name: "TLV8Tests", dependencies: ["TLV8", "TestSupport"], resources: [.copy("Vectors")]),
        .testTarget(name: "BigIntTests", dependencies: ["BigInt", "TestSupport"], resources: [.copy("Vectors")]),
        .testTarget(name: "SRPTests", dependencies: ["SRP", "BigInt", "TestSupport"], resources: [.copy("Vectors")]),
        .testTarget(name: "PairingTests", dependencies: ["Pairing", "SRP", "OPACK", "TLV8", "TestSupport"], resources: [.copy("Vectors")]),
        .testTarget(name: "TransportTests", dependencies: ["Transport", "TestSupport"]),
        .testTarget(name: "DiscoveryTests", dependencies: ["Discovery"]),
        .testTarget(name: "StoreTests", dependencies: ["Store"]),
        .testTarget(name: "SessionTests", dependencies: ["Session", "Pairing", "Store", "Discovery", "OPACK", "TLV8", "Transport", "TestSupport"]),

        // Talks to a real Apple TV. Skipped unless CLICKR_TV_HOST is set (see the test file).
        .testTarget(name: "IntegrationTests", dependencies: ["Transport"]),
    ]
)
