import XCTest
import Security
import RemoteSessionCore
@testable import AudioStreamer

@MainActor
final class KeychainStoreTests: XCTestCase {
    func testProductionStorageIdentityRemainsCompatibleWithEarlierBuilds() {
        XCTAssertEqual(KeychainStore.remoteTokenItem.service, "org.example.AudioStreamer")
        XCTAssertEqual(KeychainStore.remoteTokenItem.account, "remote-token")
        XCTAssertEqual(
            KeychainStore.worldwideInvitationCodeItem.service,
            "org.example.AudioStreamer"
        )
        XCTAssertEqual(
            KeychainStore.worldwideInvitationCodeItem.account,
            "worldwide-invitation-code"
        )
        XCTAssertEqual(
            KeychainStore.worldwideInvitationAdmissionMarkerItem.service,
            "org.example.AudioStreamer"
        )
        XCTAssertEqual(
            KeychainStore.worldwideInvitationAdmissionMarkerItem.account,
            "worldwide-invitation-admission-marker"
        )
        XCTAssertEqual(
            KeychainStore.viewerDeviceIdentityItem.service,
            "org.example.AudioStreamer"
        )
        XCTAssertEqual(
            KeychainStore.viewerDeviceIdentityItem.account,
            "worldwide-viewer-device-identity"
        )
        XCTAssertEqual(KeychainStore.pairedMacItem.service, "org.example.AudioStreamer")
        XCTAssertEqual(KeychainStore.pairedMacItem.account, "worldwide-paired-mac")
        XCTAssertNotEqual(
            KeychainStore.remoteTokenItem,
            KeychainStore.worldwideInvitationCodeItem
        )
        XCTAssertNotEqual(
            KeychainStore.worldwideInvitationCodeItem,
            KeychainStore.viewerDeviceIdentityItem
        )
        XCTAssertNotEqual(KeychainStore.viewerDeviceIdentityItem, KeychainStore.pairedMacItem)
    }

    func testKeychainRoundTripSurvivesStoreRecreation() throws {
        let item = KeychainStore.Item(
            service: "org.example.AudioStreamer.persistence-tests",
            account: UUID().uuidString
        )
        let originalStore = KeychainStore(item: item)
        defer { try? originalStore.deleteRemoteToken() }

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
        defer { try? store.deleteRemoteToken() }
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

    func testEmptyValueCannotDeletePersistedItem() throws {
        let item = KeychainStore.Item(
            service: "org.example.AudioStreamer.deletion-tests",
            account: UUID().uuidString
        )
        let store = KeychainStore(item: item)
        defer { try? store.deleteRemoteToken() }

        try store.saveRemoteToken("code")
        try store.saveRemoteToken("")

        XCTAssertEqual(try store.loadRemoteToken(), "code")
    }

    func testExplicitDeleteRemovesPersistedItem() throws {
        let item = KeychainStore.Item(
            service: "org.example.AudioStreamer.explicit-deletion-tests",
            account: UUID().uuidString
        )
        let store = KeychainStore(item: item)
        defer { try? store.deleteRemoteToken() }

        try store.saveRemoteToken("code")
        try store.deleteRemoteToken()

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

        state.persistNow()

        XCTAssertEqual(state.token, "")
        XCTAssertNotNil(state.storageError)
        XCTAssertTrue(store.savedValues.isEmpty)
        XCTAssertEqual(store.deleteCount, 0)
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

        state.token = ""

        XCTAssertTrue(store.savedValues.isEmpty)
        XCTAssertEqual(store.deleteCount, 0)
        XCTAssertTrue(state.isStored)

        state.clearSavedCode()

        XCTAssertEqual(store.deleteCount, 1)
        XCTAssertFalse(state.isStored)
    }

    func testAsyncConnectionFailureBeforeAcceptanceRetainsInvitation() throws {
        let store = RemoteTokenStoreStub(loadResult: .success("still-usable-code"))
        let state = RemoteTokenState(store: store, codeDisplayName: "invitation code")
        var acceptance = InvitationAcceptanceAction()
        let generation = UUID()
        acceptance.arm(generation: generation) { _ in
            state.clearSavedCode()
        }

        acceptance.cancel(generation: generation)
        let completed = try acceptance.completeAuthenticatedPairing(
            makePairedMacRecord(),
            generation: generation
        )

        XCTAssertFalse(completed)
        XCTAssertEqual(state.token, "still-usable-code")
        XCTAssertTrue(state.isStored)
        XCTAssertEqual(store.deleteCount, 0)
    }

    func testRendezvousReadyAloneDoesNotDeleteInvitation() throws {
        let store = RemoteTokenStoreStub(loadResult: .success("consumed-code"))
        let state = RemoteTokenState(store: store, codeDisplayName: "invitation code")
        var acceptance = InvitationAcceptanceAction()
        let generation = UUID()
        acceptance.arm(generation: generation) { _ in
            state.clearSavedCode()
        }

        try acceptance.rendezvousBecameReady(generation: generation)
        try acceptance.rendezvousBecameReady(generation: generation)

        XCTAssertEqual(state.token, "consumed-code")
        XCTAssertTrue(state.isStored)
        XCTAssertEqual(store.deleteCount, 0)
    }

    #if AUDIOSTREAMER_UPDATE_SEED
    func testSeedStableItemsForPhysicalUpdateValidation() throws {
        let activationStore = KeychainStore(item: KeychainStore.remoteTokenItem)
        let invitationStore = KeychainStore(item: KeychainStore.worldwideInvitationCodeItem)

        try? activationStore.deleteRemoteToken()
        try? invitationStore.deleteRemoteToken()
        try activationStore.saveRemoteToken("UPDATE-BOTTOM-20")
        try invitationStore.saveRemoteToken("UPDATE-TOP-20")

        XCTAssertEqual(try activationStore.loadRemoteToken(), "UPDATE-BOTTOM-20")
        XCTAssertEqual(try invitationStore.loadRemoteToken(), "UPDATE-TOP-20")
    }
    #endif

    #if AUDIOSTREAMER_UPDATE_VERIFY
    func testStableItemsSurvivePhysicalUpdate() throws {
        let activationStore = KeychainStore(item: KeychainStore.remoteTokenItem)
        let invitationStore = KeychainStore(item: KeychainStore.worldwideInvitationCodeItem)
        defer {
            try? activationStore.deleteRemoteToken()
            try? invitationStore.deleteRemoteToken()
        }

        XCTAssertEqual(try activationStore.loadRemoteToken(), "UPDATE-BOTTOM-20")
        XCTAssertEqual(try invitationStore.loadRemoteToken(), "UPDATE-TOP-20")
    }
    #endif
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
    private(set) var deleteCount = 0

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

    func deleteRemoteToken() throws {
        deleteCount += 1
    }
}

private enum TestFailure: Error {
    case load
}
