import Foundation

/// What pair-setup leaves behind: our long-term Ed25519 key pair and the TV's. Pair-verify
/// uses these on every connection.
public struct PairingCredentials: Codable, Hashable, Sendable {
    /// Our pairing identifier, sent to the TV as the controller ID.
    public var deviceID: Data
    /// Our long-term Ed25519 private key (32-byte seed).
    public var ourLTSK: Data
    /// Our long-term Ed25519 public key.
    public var ourLTPK: Data
    /// The TV's long-term Ed25519 public key.
    public var theirLTPK: Data
    /// The TV's pairing identifier.
    public var theirID: Data

    public init(deviceID: Data, ourLTSK: Data, ourLTPK: Data, theirLTPK: Data, theirID: Data) {
        self.deviceID = deviceID
        self.ourLTSK = ourLTSK
        self.ourLTPK = ourLTPK
        self.theirLTPK = theirLTPK
        self.theirID = theirID
    }
}
