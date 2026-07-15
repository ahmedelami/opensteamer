import XCTest
import Security
@testable import AudioStreamer

@MainActor
final class KeychainStoreTests: XCTestCase {
    func testProductionStorageIdentityRemainsCompatibleWithEarlierBuilds() {
        XCTAssertEqual(KeychainStore.remoteTokenItem.service, "org.example.AudioStreamer")
        XCTAssertEqual(KeychainStore.remoteTokenItem.account, "remote-token")
    }

    func testKeychainRoundTripSurvivesStoreRecreation() throws {
        let item = KeychainStore.Item(
            service: "org.example.AudioStreamer.persistence-tests",
            account: UUID().uuidString
        )
        let originalStore = KeychainStore(item: item)
        defer { try? originalStore.saveRemoteToken("") }

        try originalStore.saveRemoteToken("  update-stable-code  \n")

        let recreatedStore = KeychainStore(item: item)
        XCTAssertEqual(
            try recreatedStore.loadRemoteToken(),
            "update-stable-code"
        )
    }

    func testStoreReadsLegacyGenericPasswordItem() throws {
        let item = KeychainStore.Item(
            service: "org.example.AudioStreamer.legacy-tests",
            account: UUID().uuidString
        )
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data("legacy-code".utf8)
        ]
        defer { SecItemDelete(baseQuery(for: item) as CFDictionary) }
        XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)

        XCTAssertEqual(try KeychainStore(item: item).loadRemoteToken(), "legacy-code")
    }

    func testNewItemKeepsLegacyAccessibilityClass() throws {
        let item = KeychainStore.Item(
            service: "org.example.AudioStreamer.accessibility-tests",
            account: UUID().uuidString
        )
        let store = KeychainStore(item: item)
        defer { try? store.saveRemoteToken("") }
        try store.saveRemoteToken("code")

        var query = baseQuery(for: item)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    func testEmptyValueDeletesPersistedItem() throws {
        let item = KeychainStore.Item(
            service: "org.example.AudioStreamer.deletion-tests",
            account: UUID().uuidString
        )
        let store = KeychainStore(item: item)
        defer { try? store.saveRemoteToken("") }

        try store.saveRemoteToken("code")
        try store.saveRemoteToken("")

        XCTAssertNil(try store.loadRemoteToken())
    }

    func testInitialHydrationNeverWritesTheLoadedCredential() {
        let store = RemoteTokenStoreStub(loadResult: .success("existing-code"))
        let state = RemoteTokenState(store: store)

        state.loadIfNeeded()

        XCTAssertEqual(state.token, "existing-code")
        XCTAssertTrue(state.isStored)
        XCTAssertTrue(store.savedValues.isEmpty)
    }

    func testTransientReadFailureDoesNotDeleteSavedCredential() {
        let store = RemoteTokenStoreStub(loadResults: [.failure(TestFailure.load)])
        let state = RemoteTokenState(store: store)

        state.loadIfNeeded()
        state.persistNow()

        XCTAssertEqual(state.token, "")
        XCTAssertNotNil(state.storageError)
        XCTAssertTrue(store.savedValues.isEmpty)
    }

    func testTransientReadFailureCanRetryWithoutOverwritingCredential() {
        let store = RemoteTokenStoreStub(
            loadResults: [
                .failure(TestFailure.load),
                .success("existing-code")
            ]
        )
        let state = RemoteTokenState(store: store)

        state.loadIfNeeded()
        state.loadIfNeeded()

        XCTAssertEqual(state.token, "existing-code")
        XCTAssertTrue(state.isStored)
        XCTAssertNil(state.storageError)
        XCTAssertTrue(store.savedValues.isEmpty)
    }

    func testUserEditAfterHydrationPersists() {
        let store = RemoteTokenStoreStub(loadResult: .success(nil))
        let state = RemoteTokenState(store: store)
        state.loadIfNeeded()

        state.token = "new-code"

        XCTAssertEqual(store.savedValues, ["new-code"])
        XCTAssertTrue(state.isStored)
    }

    func testExplicitUserClearDeletesCredential() {
        let store = RemoteTokenStoreStub(loadResult: .success("existing-code"))
        let state = RemoteTokenState(store: store)
        state.loadIfNeeded()

        state.token = ""

        XCTAssertEqual(store.savedValues, [""])
        XCTAssertFalse(state.isStored)
    }
}

private func baseQuery(for item: KeychainStore.Item) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: item.service,
        kSecAttrAccount as String: item.account
    ]
}

private final class RemoteTokenStoreStub: RemoteTokenStoring {
    private var loadResults: [Result<String?, any Error>]
    private(set) var savedValues: [String] = []

    init(loadResult: Result<String?, any Error>) {
        loadResults = [loadResult]
    }

    init(loadResults: [Result<String?, any Error>]) {
        self.loadResults = loadResults
    }

    func loadRemoteToken() throws -> String? {
        guard !loadResults.isEmpty else { return nil }
        return try loadResults.removeFirst().get()
    }

    func saveRemoteToken(_ token: String) throws {
        savedValues.append(token)
    }
}

private enum TestFailure: Error {
    case load
}
