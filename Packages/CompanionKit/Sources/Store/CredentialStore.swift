import Foundation
import Pairing
import Security

/// Where pairing credentials live, keyed by the Apple TV's identifier.
public protocol CredentialStore: Sendable {
    func credentials(for deviceID: String) throws -> PairingCredentials?
    func save(_ credentials: PairingCredentials, for deviceID: String) throws
    func removeCredentials(for deviceID: String) throws
}

/// Stores credentials as generic passwords in the login Keychain, one item per Apple TV.
public struct KeychainCredentialStore: CredentialStore {
    public struct KeychainError: Error, Equatable {
        public let status: OSStatus
    }

    public static let defaultService = "com.ziggy46.clickr.pairing"

    let service: String

    public init(service: String = Self.defaultService) {
        self.service = service
    }

    public func credentials(for deviceID: String) throws -> PairingCredentials? {
        var query = baseQuery(deviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(PairingCredentials.self, from: data)
    }

    public func save(_ credentials: PairingCredentials, for deviceID: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery(deviceID) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(deviceID)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Clickr Apple TV pairing"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func removeCredentials(for deviceID: String) throws {
        let status = SecItemDelete(baseQuery(deviceID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func baseQuery(_ deviceID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID,
        ]
    }
}

/// Keeps credentials in memory. For tests and previews.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: PairingCredentials] = [:]

    public init() {}

    public func credentials(for deviceID: String) throws -> PairingCredentials? {
        lock.withLock { items[deviceID] }
    }

    public func save(_ credentials: PairingCredentials, for deviceID: String) throws {
        lock.withLock { items[deviceID] = credentials }
    }

    public func removeCredentials(for deviceID: String) throws {
        lock.withLock { items[deviceID] = nil }
    }
}
