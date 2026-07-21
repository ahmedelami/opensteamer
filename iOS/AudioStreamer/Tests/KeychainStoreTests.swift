import CryptoKit
import XCTest
import Security
@testable import RemoteSessionCore
@testable import AudioStreamer

/// Validates credential durability, this-device-only accessibility, and install-over-update
/// behavior at the real Security.framework boundary.
///
/// Ordinary tests use uniquely named Keychain items and delete them afterward. Physical-update
/// phases deliberately use production-shaped state and external metadata so a missing credential,
/// silently regenerated identity, or mismatched paired record is an observable failure.
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

    func testRecoverablePairingBoundaryDoesNotDeleteInvitation() throws {
        let store = RemoteTokenStoreStub(loadResult: .success("consumed-code"))
        let state = RemoteTokenState(store: store, codeDisplayName: "invitation code")
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let recoverableRecord = try makePairedMacRecord(
            localIdentity: identity,
            pairingState: .acceptedIssued
        )
        var acceptance = InvitationAcceptanceAction()
        let generation = UUID()
        acceptance.arm(generation: generation) { _ in
            state.clearSavedCode()
        }

        try acceptance.persistAdmissionAfterRecoverablePairing(
            recoverableRecord,
            generation: generation
        )
        try acceptance.persistAdmissionAfterRecoverablePairing(
            recoverableRecord,
            generation: generation
        )

        XCTAssertEqual(state.token, "consumed-code")
        XCTAssertTrue(state.isStored)
        XCTAssertEqual(store.deleteCount, 0)
    }

    func testPhysicalUpdateVerificationRejectsSemanticallyEquivalentIdentityReencoding() throws {
        let fixture = try makePhysicalUpdatePairingFixture()
        let items = makePhysicalUpdateKeychainItems(testName: #function)
        let identityStore = KeychainStore(item: items.identity)
        let pairedMacStore = KeychainStore(item: items.pairedMac)
        defer {
            try? identityStore.deleteData()
            try? pairedMacStore.deleteData()
        }

        var identityObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixture.identityData) as? [String: Any]
        )
        identityObject["futureMetadata"] = ["ignored": true]
        let semanticallyEquivalentData = try JSONSerialization.data(
            withJSONObject: identityObject,
            options: [.sortedKeys]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteDeviceIdentity.self, from: semanticallyEquivalentData),
            fixture.identity,
            "The mutation must remain semantically equivalent so only the raw-byte guard rejects it"
        )
        XCTAssertNotEqual(semanticallyEquivalentData, fixture.identityData)

        try identityStore.saveData(semanticallyEquivalentData)
        try pairedMacStore.saveData(fixture.pairedMacData)

        XCTAssertThrowsError(
            try loadExactPhysicalUpdatePairingFixture(
                identityStore: identityStore,
                pairedMacStore: pairedMacStore,
                expected: fixture.expectation
            )
        ) { error in
            XCTAssertEqual(
                error as? PhysicalUpdateValidationError,
                .viewerIdentityBlobDigestMismatch
            )
        }
    }

    func testPhysicalUpdateVerificationRejectsSemanticallyEquivalentPairedMacByteMutation() throws {
        let fixture = try makePhysicalUpdatePairingFixture()
        let items = makePhysicalUpdateKeychainItems(testName: #function)
        let identityStore = KeychainStore(item: items.identity)
        let pairedMacStore = KeychainStore(item: items.pairedMac)
        defer {
            try? identityStore.deleteData()
            try? pairedMacStore.deleteData()
        }

        var mutatedPairedMacData = fixture.pairedMacData
        mutatedPairedMacData.append(0x20)
        XCTAssertEqual(
            try JSONDecoder().decode(RemotePairedDeviceRecord.self, from: mutatedPairedMacData),
            fixture.pairedMac,
            "Trailing JSON whitespace must remain decodable so the digest is the rejecting check"
        )

        try identityStore.saveData(fixture.identityData)
        try pairedMacStore.saveData(mutatedPairedMacData)

        XCTAssertThrowsError(
            try loadExactPhysicalUpdatePairingFixture(
                identityStore: identityStore,
                pairedMacStore: pairedMacStore,
                expected: fixture.expectation
            )
        ) { error in
            XCTAssertEqual(
                error as? PhysicalUpdateValidationError,
                .pairedMacBlobDigestMismatch
            )
        }
    }

    func testPhysicalUpdateVerificationMissingIdentityDoesNotWriteKeychainItems() throws {
        let fixture = try makePhysicalUpdatePairingFixture()
        let items = makePhysicalUpdateKeychainItems(testName: #function)
        let identityStore = KeychainStore(item: items.identity)
        let pairedMacStore = KeychainStore(item: items.pairedMac)
        defer {
            try? identityStore.deleteData()
            try? pairedMacStore.deleteData()
        }
        try pairedMacStore.saveData(fixture.pairedMacData)
        XCTAssertNil(try identityStore.loadData())

        XCTAssertThrowsError(
            try loadExactPhysicalUpdatePairingFixture(
                identityStore: identityStore,
                pairedMacStore: pairedMacStore,
                expected: fixture.expectation
            )
        ) { error in
            XCTAssertEqual(error as? PhysicalUpdateValidationError, .missingViewerIdentityBlob)
        }

        XCTAssertNil(try identityStore.loadData(), "Verification must not create an identity")
        XCTAssertEqual(
            try pairedMacStore.loadData(),
            fixture.pairedMacData,
            "Verification must not rewrite the other credential when identity is absent"
        )
    }

    func testPhysicalUpdateVerificationMissingPairedMacDoesNotWriteKeychainItems() throws {
        let fixture = try makePhysicalUpdatePairingFixture()
        let items = makePhysicalUpdateKeychainItems(testName: #function)
        let identityStore = KeychainStore(item: items.identity)
        let pairedMacStore = KeychainStore(item: items.pairedMac)
        defer {
            try? identityStore.deleteData()
            try? pairedMacStore.deleteData()
        }
        try identityStore.saveData(fixture.identityData)
        XCTAssertNil(try pairedMacStore.loadData())

        XCTAssertThrowsError(
            try loadExactPhysicalUpdatePairingFixture(
                identityStore: identityStore,
                pairedMacStore: pairedMacStore,
                expected: fixture.expectation
            )
        ) { error in
            XCTAssertEqual(error as? PhysicalUpdateValidationError, .missingPairedMacBlob)
        }

        XCTAssertEqual(
            try identityStore.loadData(),
            fixture.identityData,
            "Verification must not replace or re-encode the existing identity"
        )
        XCTAssertNil(try pairedMacStore.loadData(), "Verification must not create a paired Mac")
    }

    #if AUDIOSTREAMER_UPDATE_SEED
    func testSeedStableItemsForPhysicalUpdateValidation() throws {
        XCTAssertTrue(AudioStreamerAppRootMode.isPhysicalUpdateValidationHost)
        let runtime = try requirePhysicalUpdateRuntime(phase: .seed)
        let activationStore = KeychainStore(item: KeychainStore.remoteTokenItem)
        let invitationStore = KeychainStore(item: KeychainStore.worldwideInvitationCodeItem)
        let identityStore = KeychainStore(item: KeychainStore.viewerDeviceIdentityItem)
        let pairedMacDataStore = KeychainStore(item: KeychainStore.pairedMacItem)
        let expectationStore = KeychainStore(
            item: PhysicalUpdatePairingExpectation.keychainItem
        )
        let missingCredentialExpectationStore = KeychainStore(
            item: PhysicalUpdateMissingCredentialExpectation.keychainItem
        )

        // A cleanup error is evidence that the seed is not isolated. KeychainStore.deleteData
        // accepts only success/item-not-found, so no other OSStatus may be ignored here.
        try deletePhysicalUpdateFixture(
            activationStore: activationStore,
            invitationStore: invitationStore,
            identityStore: identityStore,
            pairedMacDataStore: pairedMacDataStore,
            expectationStore: expectationStore,
            missingCredentialExpectationStore: missingCredentialExpectationStore
        )
        try assertPhysicalUpdateValidationStoresAreEmpty(
            activationStore: activationStore,
            invitationStore: invitationStore,
            identityStore: identityStore,
            pairedMacDataStore: pairedMacDataStore,
            expectationStore: expectationStore,
            missingCredentialExpectationStore: missingCredentialExpectationStore
        )

        let seedNonce = UUID()
        let activationCode = "UPDATE-ACTIVATION-\(seedNonce.uuidString)"
        let invitationCode = "UPDATE-INVITATION-\(seedNonce.uuidString)"
        try activationStore.saveRemoteToken(activationCode)
        try invitationStore.saveRemoteToken(invitationCode)

        XCTAssertEqual(try activationStore.loadRemoteToken(), activationCode)
        XCTAssertEqual(try invitationStore.loadRemoteToken(), invitationCode)

        // Use the exact default store and production pairing flow that the dev app uses.
        let pairingStore = ViewerPairingKeychainStore()
        let identity = try pairingStore.loadOrCreateViewerIdentity()
        var pairedMac = try makePairedMacRecord(localIdentity: identity)
        for _ in 1..<PhysicalUpdatePairingExpectation.expectedNextOutboundReconnectSequence {
            _ = try pairedMac.beginReconnect(using: identity)
        }
        try pairingStore.savePairedMac(pairedMac, for: identity)

        // Bind the expectation to the exact bytes written by the production stores. Building
        // these digests from a fresh encoding would only prove semantic equivalence and could
        // hide an update that rewrote either long-lived credential.
        let identityData = try XCTUnwrap(identityStore.loadData())
        let pairedMacData = try XCTUnwrap(pairedMacDataStore.loadData())
        let expectation = try PhysicalUpdatePairingExpectation(
            seedNonce: seedNonce,
            seedRuntime: runtime,
            activationCode: activationCode,
            invitationCode: invitationCode,
            identity: identity,
            identityData: identityData,
            pairedMac: pairedMac,
            pairedMacData: pairedMacData
        )
        try expectationStore.saveData(try expectation.encoded())
        try assertPhysicalUpdatePairingFixture(
            identityStore: identityStore,
            pairedMacStore: pairedMacDataStore,
            expected: expectation
        )
    }
    #endif

    #if AUDIOSTREAMER_UPDATE_VERIFY
    func testStableItemsSurvivePhysicalUpdate() throws {
        XCTAssertTrue(AudioStreamerAppRootMode.isPhysicalUpdateValidationHost)
        _ = try requirePhysicalUpdateRuntime(phase: .verify)
        let activationStore = KeychainStore(item: KeychainStore.remoteTokenItem)
        let invitationStore = KeychainStore(item: KeychainStore.worldwideInvitationCodeItem)
        let identityStore = KeychainStore(item: KeychainStore.viewerDeviceIdentityItem)
        let pairedMacDataStore = KeychainStore(item: KeychainStore.pairedMacItem)
        let expectationStore = KeychainStore(
            item: PhysicalUpdatePairingExpectation.keychainItem
        )
        let missingCredentialExpectationStore = KeychainStore(
            item: PhysicalUpdateMissingCredentialExpectation.keychainItem
        )
        defer {
            XCTAssertNoThrow(
                try deletePhysicalUpdateFixture(
                    activationStore: activationStore,
                    invitationStore: invitationStore,
                    identityStore: identityStore,
                    pairedMacDataStore: pairedMacDataStore,
                    expectationStore: expectationStore,
                    missingCredentialExpectationStore: missingCredentialExpectationStore
                )
            )
        }

        let expectationData = try XCTUnwrap(expectationStore.loadData())
        let expectation = try PhysicalUpdatePairingExpectation(decoding: expectationData)
        XCTAssertEqual(try activationStore.loadRemoteToken(), expectation.activationCode)
        XCTAssertEqual(try invitationStore.loadRemoteToken(), expectation.invitationCode)
        try assertPhysicalUpdatePairingFixture(
            identityStore: identityStore,
            pairedMacStore: pairedMacDataStore,
            expected: expectation
        )
    }
    #endif

    #if AUDIOSTREAMER_UPDATE_MISSING_IDENTITY_SEED
    func testSeedMissingIdentityForPhysicalUpdateValidation() throws {
        XCTAssertTrue(AudioStreamerAppRootMode.isPhysicalUpdateValidationHost)
        let runtime = try requirePhysicalUpdateRuntime(phase: .missingIdentitySeed)
        let stores = PhysicalUpdateProductionStores()
        try stores.deleteAll()
        try assertPhysicalUpdateValidationStoresAreEmpty(stores: stores)

        let fixture = try makePhysicalUpdatePairingFixture()
        try ViewerPairingKeychainStore().savePairedMac(
            fixture.pairedMac,
            for: fixture.identity
        )
        let pairedMacData = try XCTUnwrap(stores.pairedMac.loadData())
        XCTAssertEqual(pairedMacData, fixture.pairedMacData)
        XCTAssertNil(try stores.identity.loadData())

        let expectation = PhysicalUpdateMissingCredentialExpectation(
            scenario: .missingIdentity,
            seedRuntime: runtime,
            identityData: fixture.identityData,
            pairedMacData: pairedMacData
        )
        try stores.missingCredentialExpectation.saveData(try expectation.encoded())
        XCTAssertNil(try stores.identity.loadData())
        XCTAssertEqual(
            physicalUpdateSHA256(try XCTUnwrap(stores.pairedMac.loadData())),
            expectation.pairedMacBlobSHA256
        )
    }
    #endif

    #if AUDIOSTREAMER_UPDATE_MISSING_IDENTITY_VERIFY
    func testVerifyHostDoesNotCreateMissingIdentity() throws {
        let stores = PhysicalUpdateProductionStores()
        defer { XCTAssertNoThrow(try stores.deleteAll()) }

        // This is deliberately the first Keychain access in the test process. A normal app root
        // would already have manufactured an identity before XCTest entered this method.
        let identityAtTestEntry = try stores.identity.loadData()
        XCTAssertNil(identityAtTestEntry)
        XCTAssertTrue(AudioStreamerAppRootMode.isPhysicalUpdateValidationHost)
        _ = try requirePhysicalUpdateRuntime(phase: .missingIdentityVerify)

        let expectation = try PhysicalUpdateMissingCredentialExpectation(
            decoding: XCTUnwrap(try stores.missingCredentialExpectation.loadData()),
            expectedScenario: .missingIdentity
        )
        XCTAssertThrowsError(
            try loadExactPhysicalUpdatePairingFixture(
                identityStore: stores.identity,
                pairedMacStore: stores.pairedMac,
                expectedIdentityDigest: expectation.viewerIdentityBlobSHA256,
                expectedPairedMacDigest: expectation.pairedMacBlobSHA256
            )
        ) { error in
            XCTAssertEqual(error as? PhysicalUpdateValidationError, .missingViewerIdentityBlob)
        }

        XCTAssertNil(try stores.identity.loadData())
        XCTAssertEqual(
            physicalUpdateSHA256(try XCTUnwrap(stores.pairedMac.loadData())),
            expectation.pairedMacBlobSHA256
        )
    }
    #endif

    #if AUDIOSTREAMER_UPDATE_MISSING_PAIR_SEED
    func testSeedMissingPairedMacForPhysicalUpdateValidation() throws {
        XCTAssertTrue(AudioStreamerAppRootMode.isPhysicalUpdateValidationHost)
        let runtime = try requirePhysicalUpdateRuntime(phase: .missingPairedMacSeed)
        let stores = PhysicalUpdateProductionStores()
        try stores.deleteAll()
        try assertPhysicalUpdateValidationStoresAreEmpty(stores: stores)

        let pairingStore = ViewerPairingKeychainStore()
        let identity = try pairingStore.loadOrCreateViewerIdentity()
        var pairedMac = try makePairedMacRecord(localIdentity: identity)
        for _ in 1..<PhysicalUpdatePairingExpectation.expectedNextOutboundReconnectSequence {
            _ = try pairedMac.beginReconnect(using: identity)
        }
        let identityData = try XCTUnwrap(stores.identity.loadData())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let pairedMacData = try encoder.encode(pairedMac)
        XCTAssertNil(try stores.pairedMac.loadData())

        let expectation = PhysicalUpdateMissingCredentialExpectation(
            scenario: .missingPairedMac,
            seedRuntime: runtime,
            identityData: identityData,
            pairedMacData: pairedMacData
        )
        try stores.missingCredentialExpectation.saveData(try expectation.encoded())
        XCTAssertEqual(
            physicalUpdateSHA256(try XCTUnwrap(stores.identity.loadData())),
            expectation.viewerIdentityBlobSHA256
        )
        XCTAssertNil(try stores.pairedMac.loadData())
    }
    #endif

    #if AUDIOSTREAMER_UPDATE_MISSING_PAIR_VERIFY
    func testVerifyHostDoesNotCreateMissingPairedMac() throws {
        let stores = PhysicalUpdateProductionStores()
        defer { XCTAssertNoThrow(try stores.deleteAll()) }

        // Read the deliberately absent item before any validation helper can touch pairing state.
        let pairedMacAtTestEntry = try stores.pairedMac.loadData()
        XCTAssertNil(pairedMacAtTestEntry)
        XCTAssertTrue(AudioStreamerAppRootMode.isPhysicalUpdateValidationHost)
        _ = try requirePhysicalUpdateRuntime(phase: .missingPairedMacVerify)

        let expectation = try PhysicalUpdateMissingCredentialExpectation(
            decoding: XCTUnwrap(try stores.missingCredentialExpectation.loadData()),
            expectedScenario: .missingPairedMac
        )
        XCTAssertThrowsError(
            try loadExactPhysicalUpdatePairingFixture(
                identityStore: stores.identity,
                pairedMacStore: stores.pairedMac,
                expectedIdentityDigest: expectation.viewerIdentityBlobSHA256,
                expectedPairedMacDigest: expectation.pairedMacBlobSHA256
            )
        ) { error in
            XCTAssertEqual(error as? PhysicalUpdateValidationError, .missingPairedMacBlob)
        }

        XCTAssertEqual(
            physicalUpdateSHA256(try XCTUnwrap(stores.identity.loadData())),
            expectation.viewerIdentityBlobSHA256
        )
        XCTAssertNil(try stores.pairedMac.loadData())
    }
    #endif
}

// MARK: - Physical install-over-update fixture contract

/// Driver-selected phase for seeding or verifying one side of an app replacement boundary.
private enum PhysicalUpdateValidationPhase {
    case seed
    case verify
    case missingIdentitySeed
    case missingIdentityVerify
    case missingPairedMacSeed
    case missingPairedMacVerify

    var expectedBuild: String {
        switch self {
        case .seed: PhysicalUpdatePairingExpectation.expectedSeedBuild
        case .verify: PhysicalUpdatePairingExpectation.expectedVerifyBuild
        case .missingIdentitySeed:
            PhysicalUpdateMissingCredentialScenario.missingIdentity.seedBuild
        case .missingIdentityVerify:
            PhysicalUpdateMissingCredentialScenario.missingIdentity.verifyBuild
        case .missingPairedMacSeed:
            PhysicalUpdateMissingCredentialScenario.missingPairedMac.seedBuild
        case .missingPairedMacVerify:
            PhysicalUpdateMissingCredentialScenario.missingPairedMac.verifyBuild
        }
    }
}

private struct PhysicalUpdateRuntimeMetadata: Codable, Equatable {
    let bundleIdentifier: String
    let build: String
}

private struct PhysicalUpdateViewerIdentityExpectation: Codable, Equatable {
    let version: UInt8
    let deviceID: UUID
    let role: RemotePeerRole
    let displayName: String?
    let signingPublicKey: Data

    init(_ identity: RemoteDeviceIdentity) {
        version = identity.version
        deviceID = identity.deviceID
        role = identity.role
        displayName = identity.displayName
        signingPublicKey = identity.signingPublicKey
    }
}

private struct PhysicalUpdatePairedMacExpectation: Codable, Equatable {
    let version: UInt8
    let pairID: UUID
    let commitID: UUID
    let localDeviceID: UUID
    let localRole: RemotePeerRole
    let localSigningPublicKey: Data
    let remoteDeviceID: UUID
    let remoteRole: RemotePeerRole
    let remoteSigningPublicKey: Data
    let remoteDisplayName: String?
    let createdAt: Date
    let pairingState: RemotePairingPersistenceState
    let nextOutboundReconnectSequence: UInt64
    let highestAcceptedReconnectSequence: UInt64
    let recoveryCommit: RemotePairingCommit

    init(_ record: RemotePairedDeviceRecord) throws {
        guard case .resend(let recoveryCommit) = record.recoveryAction else {
            throw PhysicalUpdateValidationError.unexpectedRecoveryAction
        }
        version = record.version
        pairID = record.pairID
        commitID = record.commitID
        localDeviceID = record.localDeviceID
        localRole = record.localRole
        localSigningPublicKey = record.localSigningPublicKey
        remoteDeviceID = record.remoteDeviceID
        remoteRole = record.remoteRole
        remoteSigningPublicKey = record.remoteSigningPublicKey
        remoteDisplayName = record.remoteDisplayName
        createdAt = record.createdAt
        pairingState = record.pairingState
        nextOutboundReconnectSequence = record.nextOutboundReconnectSequence
        highestAcceptedReconnectSequence = record.highestAcceptedReconnectSequence
        self.recoveryCommit = recoveryCommit
    }
}

private struct PhysicalUpdatePairingExpectation: Codable, Equatable {
    static let keychainItem = KeychainStore.Item(
        service: "org.example.AudioStreamer.update-validation",
        account: "viewer-pairing-expectation"
    )
    static let currentSchemaVersion = 3
    static let expectedBundleIdentifier = "org.example.AudioStreamer.dev"
    static let expectedSeedBuild = "2901"
    static let expectedVerifyBuild = "2902"
    static let expectedRemoteDisplayName = "Test Mac"
    static let expectedNextOutboundReconnectSequence: UInt64 = 4
    static let expectedHighestAcceptedReconnectSequence: UInt64 = 0
    static let digestByteCount = 32
    static let identityChallenge = Data(
        "AudioStreamer.PhysicalUpdate.ViewerIdentityChallenge.v1".utf8
    )

    let schemaVersion: Int
    let seedNonce: UUID
    let seedRuntime: PhysicalUpdateRuntimeMetadata
    let activationCode: String
    let invitationCode: String
    let viewerIdentityBlobSHA256: Data
    let pairedMacBlobSHA256: Data
    let viewerIdentity: PhysicalUpdateViewerIdentityExpectation
    let pairedMac: PhysicalUpdatePairedMacExpectation
    let identityChallengeSignature: Data

    init(
        seedNonce: UUID,
        seedRuntime: PhysicalUpdateRuntimeMetadata,
        activationCode: String,
        invitationCode: String,
        identity: RemoteDeviceIdentity,
        identityData: Data,
        pairedMac: RemotePairedDeviceRecord,
        pairedMacData: Data
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.seedNonce = seedNonce
        self.seedRuntime = seedRuntime
        self.activationCode = activationCode
        self.invitationCode = invitationCode
        viewerIdentityBlobSHA256 = physicalUpdateSHA256(identityData)
        pairedMacBlobSHA256 = physicalUpdateSHA256(pairedMacData)
        viewerIdentity = PhysicalUpdateViewerIdentityExpectation(identity)
        self.pairedMac = try PhysicalUpdatePairedMacExpectation(pairedMac)
        identityChallengeSignature = try identity.signature(for: Self.identityChallenge)
    }

    init(decoding data: Data) throws {
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        guard decoded.schemaVersion == Self.currentSchemaVersion,
              decoded.seedRuntime == PhysicalUpdateRuntimeMetadata(
                  bundleIdentifier: Self.expectedBundleIdentifier,
                  build: Self.expectedSeedBuild
              ),
              decoded.viewerIdentityBlobSHA256.count == Self.digestByteCount,
              decoded.pairedMacBlobSHA256.count == Self.digestByteCount else {
            throw PhysicalUpdateValidationError.invalidExpectation
        }
        self = decoded
    }

    func validateCredentialSemantics() throws {
        guard viewerIdentity.role == .viewer,
              viewerIdentity.signingPublicKey.count == 32,
              pairedMac.localRole == .viewer,
              pairedMac.remoteRole == .host,
              pairedMac.localSigningPublicKey.count == 32,
              pairedMac.remoteSigningPublicKey.count == 32,
              pairedMac.pairingState == .active,
              pairedMac.recoveryCommit.phase == .activationAcknowledgement,
              identityChallengeSignature.count == 64 else {
            throw PhysicalUpdateValidationError.invalidExpectation
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

private enum PhysicalUpdateMissingCredentialScenario: String, Codable {
    case missingIdentity
    case missingPairedMac

    var seedBuild: String {
        switch self {
        case .missingIdentity: "2903"
        case .missingPairedMac: "2905"
        }
    }

    var verifyBuild: String {
        switch self {
        case .missingIdentity: "2904"
        case .missingPairedMac: "2906"
        }
    }
}

private struct PhysicalUpdateMissingCredentialExpectation: Codable, Equatable {
    static let keychainItem = KeychainStore.Item(
        service: "org.example.AudioStreamer.update-validation",
        account: "missing-credential-expectation"
    )
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let scenario: PhysicalUpdateMissingCredentialScenario
    let seedRuntime: PhysicalUpdateRuntimeMetadata
    let viewerIdentityBlobSHA256: Data
    let pairedMacBlobSHA256: Data

    init(
        scenario: PhysicalUpdateMissingCredentialScenario,
        seedRuntime: PhysicalUpdateRuntimeMetadata,
        identityData: Data,
        pairedMacData: Data
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.scenario = scenario
        self.seedRuntime = seedRuntime
        viewerIdentityBlobSHA256 = physicalUpdateSHA256(identityData)
        pairedMacBlobSHA256 = physicalUpdateSHA256(pairedMacData)
    }

    init(
        decoding data: Data,
        expectedScenario: PhysicalUpdateMissingCredentialScenario
    ) throws {
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        guard decoded.schemaVersion == Self.currentSchemaVersion,
              decoded.scenario == expectedScenario,
              decoded.seedRuntime == PhysicalUpdateRuntimeMetadata(
                  bundleIdentifier: PhysicalUpdatePairingExpectation.expectedBundleIdentifier,
                  build: expectedScenario.seedBuild
              ),
              decoded.viewerIdentityBlobSHA256.count ==
                  PhysicalUpdatePairingExpectation.digestByteCount,
              decoded.pairedMacBlobSHA256.count ==
                  PhysicalUpdatePairingExpectation.digestByteCount else {
            throw PhysicalUpdateValidationError.invalidExpectation
        }
        self = decoded
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

private enum PhysicalUpdateValidationError: Error, Equatable {
    case invalidRuntime
    case invalidExpectation
    case unexpectedRecoveryAction
    case missingViewerIdentityBlob
    case viewerIdentityBlobDigestMismatch
    case missingPairedMacBlob
    case pairedMacBlobDigestMismatch
    case invalidViewerIdentityBlob
    case invalidPairedMacBlob
}

private func requirePhysicalUpdateRuntime(
    phase: PhysicalUpdateValidationPhase,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> PhysicalUpdateRuntimeMetadata {
    let actual = PhysicalUpdateRuntimeMetadata(
        bundleIdentifier: try XCTUnwrap(Bundle.main.bundleIdentifier, file: file, line: line),
        build: try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            file: file,
            line: line
        )
    )
    let expected = PhysicalUpdateRuntimeMetadata(
        bundleIdentifier: PhysicalUpdatePairingExpectation.expectedBundleIdentifier,
        build: phase.expectedBuild
    )
    XCTAssertEqual(actual, expected, file: file, line: line)
    guard actual == expected else { throw PhysicalUpdateValidationError.invalidRuntime }
    return actual
}

private func deletePhysicalUpdateFixture(
    activationStore: KeychainStore,
    invitationStore: KeychainStore,
    identityStore: KeychainStore,
    pairedMacDataStore: KeychainStore,
    expectationStore: KeychainStore,
    missingCredentialExpectationStore: KeychainStore
) throws {
    try activationStore.deleteRemoteToken()
    try invitationStore.deleteRemoteToken()
    try identityStore.deleteData()
    try pairedMacDataStore.deleteData()
    try expectationStore.deleteData()
    try missingCredentialExpectationStore.deleteData()
}

private struct PhysicalUpdateProductionStores {
    let activation = KeychainStore(item: KeychainStore.remoteTokenItem)
    let invitation = KeychainStore(item: KeychainStore.worldwideInvitationCodeItem)
    let identity = KeychainStore(item: KeychainStore.viewerDeviceIdentityItem)
    let pairedMac = KeychainStore(item: KeychainStore.pairedMacItem)
    let expectation = KeychainStore(item: PhysicalUpdatePairingExpectation.keychainItem)
    let missingCredentialExpectation = KeychainStore(
        item: PhysicalUpdateMissingCredentialExpectation.keychainItem
    )

    func deleteAll() throws {
        try deletePhysicalUpdateFixture(
            activationStore: activation,
            invitationStore: invitation,
            identityStore: identity,
            pairedMacDataStore: pairedMac,
            expectationStore: expectation,
            missingCredentialExpectationStore: missingCredentialExpectation
        )
    }
}

private func assertPhysicalUpdateValidationStoresAreEmpty(
    activationStore: KeychainStore,
    invitationStore: KeychainStore,
    identityStore: KeychainStore,
    pairedMacDataStore: KeychainStore,
    expectationStore: KeychainStore,
    missingCredentialExpectationStore: KeychainStore,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    XCTAssertNil(try activationStore.loadRemoteToken(), file: file, line: line)
    XCTAssertNil(try invitationStore.loadRemoteToken(), file: file, line: line)
    XCTAssertNil(try identityStore.loadData(), file: file, line: line)
    XCTAssertNil(try pairedMacDataStore.loadData(), file: file, line: line)
    XCTAssertNil(try expectationStore.loadData(), file: file, line: line)
    XCTAssertNil(
        try missingCredentialExpectationStore.loadData(),
        file: file,
        line: line
    )
}

private func assertPhysicalUpdateValidationStoresAreEmpty(
    stores: PhysicalUpdateProductionStores,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    try assertPhysicalUpdateValidationStoresAreEmpty(
        activationStore: stores.activation,
        invitationStore: stores.invitation,
        identityStore: stores.identity,
        pairedMacDataStore: stores.pairedMac,
        expectationStore: stores.expectation,
        missingCredentialExpectationStore: stores.missingCredentialExpectation,
        file: file,
        line: line
    )
}

private struct LoadedPhysicalUpdatePairingFixture {
    let identity: RemoteDeviceIdentity
    let pairedMac: RemotePairedDeviceRecord
}

private func loadExactPhysicalUpdatePairingFixture(
    identityStore: KeychainStore,
    pairedMacStore: KeychainStore,
    expected expectation: PhysicalUpdatePairingExpectation
) throws -> LoadedPhysicalUpdatePairingFixture {
    try loadExactPhysicalUpdatePairingFixture(
        identityStore: identityStore,
        pairedMacStore: pairedMacStore,
        expectedIdentityDigest: expectation.viewerIdentityBlobSHA256,
        expectedPairedMacDigest: expectation.pairedMacBlobSHA256
    )
}

private func loadExactPhysicalUpdatePairingFixture(
    identityStore: KeychainStore,
    pairedMacStore: KeychainStore,
    expectedIdentityDigest: Data,
    expectedPairedMacDigest: Data
) throws -> LoadedPhysicalUpdatePairingFixture {
    // Read-only Keychain access is deliberate. In particular, this path must never call
    // loadOrCreateViewerIdentity(): absence after an update is a verification failure, not an
    // opportunity to manufacture a credential that makes the update appear successful.
    guard let identityData = try identityStore.loadData() else {
        throw PhysicalUpdateValidationError.missingViewerIdentityBlob
    }
    guard let pairedMacData = try pairedMacStore.loadData() else {
        throw PhysicalUpdateValidationError.missingPairedMacBlob
    }

    // Both byte-exact checks precede every Codable decode and every semantic/signature/counter
    // assertion below. An update that merely re-encodes equivalent JSON must fail here.
    guard physicalUpdateSHA256(identityData) == expectedIdentityDigest else {
        throw PhysicalUpdateValidationError.viewerIdentityBlobDigestMismatch
    }
    guard physicalUpdateSHA256(pairedMacData) == expectedPairedMacDigest else {
        throw PhysicalUpdateValidationError.pairedMacBlobDigestMismatch
    }

    let decoder = JSONDecoder()
    let identity: RemoteDeviceIdentity
    do {
        identity = try decoder.decode(RemoteDeviceIdentity.self, from: identityData)
    } catch {
        throw PhysicalUpdateValidationError.invalidViewerIdentityBlob
    }
    let pairedMac: RemotePairedDeviceRecord
    do {
        pairedMac = try decoder.decode(RemotePairedDeviceRecord.self, from: pairedMacData)
    } catch {
        throw PhysicalUpdateValidationError.invalidPairedMacBlob
    }
    return LoadedPhysicalUpdatePairingFixture(identity: identity, pairedMac: pairedMac)
}

private func assertPhysicalUpdatePairingFixture(
    identityStore: KeychainStore,
    pairedMacStore: KeychainStore,
    expected expectation: PhysicalUpdatePairingExpectation,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let loaded = try loadExactPhysicalUpdatePairingFixture(
        identityStore: identityStore,
        pairedMacStore: pairedMacStore,
        expected: expectation
    )
    // Expectation semantics are deliberately checked only after raw credential hashes match.
    // That keeps role/commit/signature validation from masking a byte-preservation failure.
    try expectation.validateCredentialSemantics()
    let identity = loaded.identity
    XCTAssertEqual(
        PhysicalUpdateViewerIdentityExpectation(identity),
        expectation.viewerIdentity,
        file: file,
        line: line
    )

    // The stored signature proves that the seed process possessed the matching private key.
    // Signature byte equality is deliberately not asserted: the signing API promises validity,
    // not deterministic output. A fresh signature below independently proves that the strictly
    // loaded private identity remains usable in this process.
    XCTAssertTrue(
        remoteVerifySignature(
            expectation.identityChallengeSignature,
            for: PhysicalUpdatePairingExpectation.identityChallenge,
            publicKey: expectation.viewerIdentity.signingPublicKey
        ),
        "The seed-process signature must verify under the exact expected viewer identity",
        file: file,
        line: line
    )
    let freshChallengeSignature = try identity.signature(
        for: PhysicalUpdatePairingExpectation.identityChallenge
    )
    XCTAssertTrue(
        remoteVerifySignature(
            freshChallengeSignature,
            for: PhysicalUpdatePairingExpectation.identityChallenge,
            publicKey: expectation.viewerIdentity.signingPublicKey
        ),
        "The strictly loaded private viewer identity must sign the fixed challenge",
        file: file,
        line: line
    )

    let record = loaded.pairedMac
    XCTAssertEqual(
        try PhysicalUpdatePairedMacExpectation(record),
        expectation.pairedMac,
        file: file,
        line: line
    )
    XCTAssertEqual(record.localDeviceID, identity.deviceID, file: file, line: line)
    XCTAssertEqual(record.localSigningPublicKey, identity.signingPublicKey, file: file, line: line)
    XCTAssertEqual(record.pairingState, .active, file: file, line: line)
    XCTAssertEqual(
        record.remoteDisplayName,
        PhysicalUpdatePairingExpectation.expectedRemoteDisplayName,
        file: file,
        line: line
    )
    XCTAssertEqual(
        record.nextOutboundReconnectSequence,
        PhysicalUpdatePairingExpectation.expectedNextOutboundReconnectSequence,
        file: file,
        line: line
    )
    XCTAssertEqual(
        record.highestAcceptedReconnectSequence,
        PhysicalUpdatePairingExpectation.expectedHighestAcceptedReconnectSequence,
        file: file,
        line: line
    )
}

private func physicalUpdateSHA256(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
}

private struct PhysicalUpdatePairingTestFixture {
    let identity: RemoteDeviceIdentity
    let pairedMac: RemotePairedDeviceRecord
    let identityData: Data
    let pairedMacData: Data
    let expectation: PhysicalUpdatePairingExpectation
}

private func makePhysicalUpdatePairingFixture() throws -> PhysicalUpdatePairingTestFixture {
    let identity = try RemoteDeviceIdentity.generate(role: .viewer)
    var pairedMac = try makePairedMacRecord(localIdentity: identity)
    for _ in 1..<PhysicalUpdatePairingExpectation.expectedNextOutboundReconnectSequence {
        _ = try pairedMac.beginReconnect(using: identity)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let identityData = try encoder.encode(identity)
    let pairedMacData = try encoder.encode(pairedMac)
    let seedNonce = UUID()
    let expectation = try PhysicalUpdatePairingExpectation(
        seedNonce: seedNonce,
        seedRuntime: PhysicalUpdateRuntimeMetadata(
            bundleIdentifier: PhysicalUpdatePairingExpectation.expectedBundleIdentifier,
            build: PhysicalUpdatePairingExpectation.expectedSeedBuild
        ),
        activationCode: "UPDATE-ACTIVATION-\(seedNonce.uuidString)",
        invitationCode: "UPDATE-INVITATION-\(seedNonce.uuidString)",
        identity: identity,
        identityData: identityData,
        pairedMac: pairedMac,
        pairedMacData: pairedMacData
    )
    return PhysicalUpdatePairingTestFixture(
        identity: identity,
        pairedMac: pairedMac,
        identityData: identityData,
        pairedMacData: pairedMacData,
        expectation: expectation
    )
}

private struct PhysicalUpdateTestKeychainItems {
    let identity: KeychainStore.Item
    let pairedMac: KeychainStore.Item
}

private func makePhysicalUpdateKeychainItems(
    testName: String
) -> PhysicalUpdateTestKeychainItems {
    let nonce = UUID().uuidString
    let service = "org.example.AudioStreamer.raw-update-validation-tests.\(testName)"
    return PhysicalUpdateTestKeychainItems(
        identity: KeychainStore.Item(service: service, account: "identity-\(nonce)"),
        pairedMac: KeychainStore.Item(service: service, account: "paired-mac-\(nonce)")
    )
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
