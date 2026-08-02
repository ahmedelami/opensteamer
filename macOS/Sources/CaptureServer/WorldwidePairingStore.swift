import Foundation
import RemoteSessionCore
import Security

/// Minimal persistence boundary for encoded worldwide identity and pairing records.
protocol WorldwidePairingDataStore: Sendable {
    func data(for account: String) throws -> Data?
    func set(_ data: Data, for account: String) throws
    func removeData(for account: String) throws
}

/// Validates and persists the Mac identity and its single durable viewer binding.
///
/// Records are accepted only when role, local device identity, and local signing key
/// match the host identity. This prevents a stale or substituted record from granting
/// durable access to a different host key.
struct WorldwidePairingStore: Sendable {
    static let identityAccount = "worldwide-host-identity-v1"
    static let pairedViewerAccount = "worldwide-paired-viewer-v1"

    private let dataStore: any WorldwidePairingDataStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Creates a store with deterministic JSON and a Keychain-backed default boundary.
    init(dataStore: any WorldwidePairingDataStore = WorldwideKeychainDataStore()) {
        self.dataStore = dataStore
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        decoder = JSONDecoder()
    }

    /// Loads the durable host identity or generates and persists it once.
    func loadOrCreateHostIdentity(displayName: String?) throws -> RemoteDeviceIdentity {
        if let data = try dataStore.data(for: Self.identityAccount) {
            let identity = try decode(RemoteDeviceIdentity.self, from: data)
            guard identity.role == .host else {
                throw WorldwidePairingStoreError.identityRoleMismatch
            }
            return identity
        }

        let identity = try RemoteDeviceIdentity.generate(role: .host, displayName: displayName)
        try dataStore.set(try encode(identity), for: Self.identityAccount)
        return identity
    }

    /// Loads and validates the viewer record against the supplied host identity.
    func loadPairedViewer(
        for identity: RemoteDeviceIdentity
    ) throws -> RemotePairedDeviceRecord? {
        guard let data = try dataStore.data(for: Self.pairedViewerAccount) else { return nil }
        let record = try decode(RemotePairedDeviceRecord.self, from: data)
        try validate(record, for: identity)
        return record
    }

    /// Validates the cryptographic binding before replacing the stored viewer record.
    func savePairedViewer(
        _ record: RemotePairedDeviceRecord,
        for identity: RemoteDeviceIdentity
    ) throws {
        try validate(record, for: identity)
        try dataStore.set(try encode(record), for: Self.pairedViewerAccount)
    }

    /// Removes only the viewer binding; the long-lived host identity remains intact.
    func resetPairedViewer() throws {
        try dataStore.removeData(for: Self.pairedViewerAccount)
    }

    /// Enforces role and local-key invariants at every persistence boundary.
    private func validate(
        _ record: RemotePairedDeviceRecord,
        for identity: RemoteDeviceIdentity
    ) throws {
        guard identity.role == .host,
              record.localRole == .host,
              record.remoteRole == .viewer,
              record.localDeviceID == identity.deviceID,
              record.localSigningPublicKey == identity.signingPublicKey else {
            throw WorldwidePairingStoreError.identityRecordMismatch
        }
    }

    /// Encodes a bounded record while collapsing serialization details into store errors.
    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            let data = try encoder.encode(value)
            guard !data.isEmpty, data.count <= WorldwideKeychainDataStore.maximumItemBytes else {
                throw WorldwidePairingStoreError.invalidPersistedData
            }
            return data
        } catch let error as WorldwidePairingStoreError {
            throw error
        } catch {
            throw WorldwidePairingStoreError.encodingFailed
        }
    }

    /// Rejects empty, oversized, or malformed persisted data before use.
    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        guard !data.isEmpty, data.count <= WorldwideKeychainDataStore.maximumItemBytes else {
            throw WorldwidePairingStoreError.invalidPersistedData
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw WorldwidePairingStoreError.invalidPersistedData
        }
    }
}

/// Keychain implementation scoped to this device and macOS account.
///
/// Items use `AfterFirstUnlockThisDeviceOnly`, never synchronize through iCloud, and
/// are capped before Security.framework allocation or JSON decoding.
struct WorldwideKeychainDataStore: WorldwidePairingDataStore {
    static let maximumItemBytes = 64 * 1_024

    // Existing installations already own pairing secrets in this service. Keeping the legacy
    // value is what makes the opensteamer host an in-place upgrade instead of a newly paired Mac.
    static let legacyPairingService =
        "com.elamin.AudioStreamer.CaptureServer.WorldwidePairing.v1"
    private let service: String

    init(service: String = Self.legacyPairingService) {
        self.service = service
    }

    /// Reads one generic-password item's raw bytes, returning `nil` when absent.
    func data(for account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  !data.isEmpty,
                  data.count <= Self.maximumItemBytes else {
                throw WorldwidePairingStoreError.invalidPersistedData
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw WorldwidePairingStoreError.keychain(status)
        }
    }

    /// Upserts one bounded item and resolves a concurrent-create race by retrying update.
    func set(_ data: Data, for account: String) throws {
        guard !data.isEmpty, data.count <= Self.maximumItemBytes else {
            throw WorldwidePairingStoreError.invalidPersistedData
        }

        let query = baseQuery(account: account)
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addition as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                let retryStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw WorldwidePairingStoreError.keychain(retryStatus)
                }
            } else if addStatus != errSecSuccess {
                throw WorldwidePairingStoreError.keychain(addStatus)
            }
        default:
            throw WorldwidePairingStoreError.keychain(updateStatus)
        }
    }

    /// Deletes one account idempotently.
    func removeData(for account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WorldwidePairingStoreError.keychain(status)
        }
    }

    /// Builds the non-synchronizing generic-password identity shared by all operations.
    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// Validation, encoding, and Keychain failures at the pairing persistence boundary.
enum WorldwidePairingStoreError: LocalizedError, Equatable {
    case identityRoleMismatch
    case identityRecordMismatch
    case invalidPersistedData
    case encodingFailed
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .identityRoleMismatch:
            "The saved worldwide identity does not belong to a Mac host."
        case .identityRecordMismatch:
            "The paired iPhone record does not match this Mac identity."
        case .invalidPersistedData:
            "The saved worldwide pairing data is invalid."
        case .encodingFailed:
            "The worldwide pairing data could not be encoded."
        case .keychain(let status):
            "The worldwide pairing Keychain operation failed (OSStatus \(status))."
        }
    }
}
