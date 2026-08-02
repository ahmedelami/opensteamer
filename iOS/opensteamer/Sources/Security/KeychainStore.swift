import Foundation
import Security

/// Persistence boundary for the legacy remote activation credential.
/// Implementations distinguish explicit deletion from transient empty UI state.
protocol RemoteTokenStoring {
    func loadRemoteToken() throws -> String?
    func saveRemoteToken(_ token: String) throws
    func deleteRemoteToken() throws
}

/// Thin generic-password Keychain adapter used by activation and pairing stores.
/// Every new item is `AfterFirstUnlockThisDeviceOnly`: it is available to background playback
/// after the first unlock, cannot migrate to another device, and survives ordinary app updates.
struct KeychainStore: RemoteTokenStoring {
    /// Stable Keychain namespace independent of application build or payload schema versions.
    struct Item: Equatable, Sendable {
        let service: String
        let account: String
    }

    // The legacy service spelling is the persistence boundary for already-installed builds.
    // Rebranding this literal would hide activation and pairing state from an updated app.
    static let remoteTokenItem = Item(
        service: "org.example.AudioStreamer",
        account: "remote-token"
    )

    // The worldwide invitation remains expiring and consume-once. Persisting the
    // currently entered value in this-device-only Keychain storage only prevents an
    // in-place update or process restart from erasing it before use.
    static let worldwideInvitationCodeItem = Item(
        service: "org.example.AudioStreamer",
        account: "worldwide-invitation-code"
    )

    // Records the admission boundary only after a recoverable viewer pairing record is durable.
    // The value is a domain-separated digest of the normalized code, never the invitation itself.
    // Keeping this item version-independent prevents a relaunch or update from retrying a code
    // that the service has consumed; the paired-device record is then the relaunch route.
    static let worldwideInvitationAdmissionMarkerItem = Item(
        service: "org.example.AudioStreamer",
        account: "worldwide-invitation-admission-marker"
    )

    // These stable account names deliberately do not include an app or protocol version.
    // Codable payloads carry their own versions, while the Keychain identity must survive
    // ordinary app updates. Both payloads contain secrets and are this-device-only.
    static let viewerDeviceIdentityItem = Item(
        service: "org.example.AudioStreamer",
        account: "worldwide-viewer-device-identity"
    )

    static let pairedMacItem = Item(
        service: "org.example.AudioStreamer",
        account: "worldwide-paired-mac"
    )

    // The production bundle used this service before build 34. Only the paired viewer identity
    // and Mac record participate in the compatibility fallback; activation and invitation state
    // remain owned by their current items above. The selector in ViewerPairingStore.swift never
    // combines one of these payloads with a payload from the current service.
    static let legacyViewerDeviceIdentityItem = Item(
        service: "com.elamin.AudioStreamer",
        account: "worldwide-viewer-device-identity"
    )

    static let legacyPairedMacItem = Item(
        service: "com.elamin.AudioStreamer",
        account: "worldwide-paired-mac"
    )

    private let item: Item

    init(item: Item = Self.remoteTokenItem) {
        self.item = item
    }

    func loadRemoteToken() throws -> String? {
        guard let data = try loadData() else { return nil }
        guard let token = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidStoredValue
        }
        return token
    }

    func saveRemoteToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty SwiftUI binding can be transient during view/app replacement. Never
        // interpret it as credential deletion; callers must use the explicit delete API.
        guard !trimmed.isEmpty else { return }
        try saveData(Data(trimmed.utf8))
    }

    func deleteRemoteToken() throws {
        try deleteData()
    }

    func loadData() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainStoreError.invalidStoredValue
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.operationFailed(status)
        }
    }

    func saveData(_ data: Data) throws {
        // Update first to preserve the accessibility class of a previously shipped item. Only a
        // genuinely missing item is inserted with the current this-device-only policy.
        let updateAttributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            updateAttributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.operationFailed(updateStatus)
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.operationFailed(addStatus)
        }
    }

    /// Inserts a new item without overwriting an item that appeared after the caller's read.
    ///
    /// Pairing-namespace migration uses this compare-before-insert boundary when promoting an
    /// existing identity. A duplicate result is returned to the caller for an exact re-read so a
    /// concurrently created, different identity can never be replaced.
    @discardableResult
    func insertDataIfAbsent(_ data: Data) throws -> Bool {
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecDuplicateItem:
            return false
        default:
            throw KeychainStoreError.operationFailed(status)
        }
    }

    func deleteData() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.operationFailed(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account
        ]
    }
}

/// Failures returned by the generic-password storage boundary.
enum KeychainStoreError: Error, Equatable {
    case invalidStoredValue
    case operationFailed(OSStatus)
}
