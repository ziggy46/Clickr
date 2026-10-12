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

        .testTarget(name: "OPACKTests", dependencies: ["OPACK"]),
        .testTarget(name: "TLV8Tests", dependencies: ["TLV8"]),
        .testTarget(name: "BigIntTests", dependencies: ["BigInt"]),
        .testTarget(name: "SRPTests", dependencies: ["SRP"]),
        .testTarget(name: "PairingTests", dependencies: ["Pairing"]),
        .testTarget(name: "TransportTests", dependencies: ["Transport"]),
        .testTarget(name: "DiscoveryTests", dependencies: ["Discovery"]),
        .testTarget(name: "StoreTests", dependencies: ["Store"]),
        .testTarget(name: "SessionTests", dependencies: ["Session"]),
    ]
)
