import Foundation
import Pairing
import Testing
@testable import Store

private let sample = PairingCredentials(
    deviceID: Data("controller".utf8),
    ourLTSK: Data(repeating: 1, count: 32),
    ourLTPK: Data(repeating: 2, count: 32),
    theirLTPK: Data(repeating: 3, count: 32),
    theirID: Data("AA:BB:CC:DD:EE:FF".utf8)
)

@Test func inMemoryStoreRoundTrips() throws {
    let store = InMemoryCredentialStore()
    #expect(try store.credentials(for: "tv") == nil)
    try store.save(sample, for: "tv")
    #expect(try store.credentials(for: "tv") == sample)
    try store.save(sample, for: "other")
    #expect(try store.pairedDeviceIDs() == ["other", "tv"])
    try store.removeCredentials(for: "tv")
    #expect(try store.credentials(for: "tv") == nil)
}

/// Uses the real login Keychain under a throwaway service name and cleans up after itself.
@Test func keychainStoreRoundTrips() throws {
    let store = KeychainCredentialStore(service: "com.ziggy46.clickr.tests.\(UUID().uuidString)")
    defer { try? store.removeCredentials(for: "tv") }

    #expect(try store.credentials(for: "tv") == nil)
    #expect(try store.pairedDeviceIDs() == [])
    try store.save(sample, for: "tv")
    #expect(try store.credentials(for: "tv") == sample)
    #expect(try store.pairedDeviceIDs() == ["tv"])

    var updated = sample
    updated.theirID = Data("11:22:33:44:55:66".utf8)
    try store.save(updated, for: "tv")
    #expect(try store.credentials(for: "tv") == updated)

    try store.removeCredentials(for: "tv")
    #expect(try store.credentials(for: "tv") == nil)
    try store.removeCredentials(for: "tv") // removing twice is fine
}
