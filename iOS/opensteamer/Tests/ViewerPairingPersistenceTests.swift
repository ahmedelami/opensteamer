import Foundation
import RemoteSessionCore
import Security
import XCTest
@testable import opensteamer

/// End-to-end unit coverage for crash-safe pairing persistence and paired reconnect arbitration.
///
/// In-memory transports model each distributed-commit interruption and availability race. The
/// durable record, operation ID, pair ID, retry deadline, and telemetry terminal event are the
/// authoritative oracles; UI text alone is never accepted as proof of a saved pair.
@MainActor
final class ViewerPairingPersistenceTests: XCTestCase {
    func testViewerIdentityAndPairedMacSurviveStateReconstruction() throws {
        let items = makeKeychainItems(testName: #function)
        let firstStore = ViewerPairingKeychainStore(
            identityItem: items.identity,
            pairedMacItem: items.pairedMac
        )
        defer { deleteKeychainItems(items) }

        let firstState = ViewerPairingState(store: firstStore)
        let identity = try XCTUnwrap(firstState.viewerIdentity)
        let record = try makePairedMacRecord(localIdentity: identity)
        try firstState.saveAuthenticatedPairing(record)

        let reconstructedState = ViewerPairingState(
            store: ViewerPairingKeychainStore(
                identityItem: items.identity,
                pairedMacItem: items.pairedMac
            )
        )

        XCTAssertEqual(reconstructedState.viewerIdentity, identity)
        XCTAssertEqual(reconstructedState.pairedMac, record)
        XCTAssertTrue(reconstructedState.isPaired)
        XCTAssertNil(reconstructedState.storageError)
    }

    func testFailedHydrationCanRetryAfterProtectedDataBecomesAvailable() throws {
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let record = try makePairedMacRecord(localIdentity: identity)
        let store = ViewerPairingStoreStub(identity: identity)
        store.record = record
        store.loadIdentityError = PairingTestFailure.load

        let state = ViewerPairingState(store: store)

        XCTAssertNil(state.viewerIdentity)
        XCTAssertNil(state.pairingRecord)
        XCTAssertNotNil(state.storageError)
        XCTAssertEqual(store.identityLoadCount, 1)

        store.loadIdentityError = nil
        state.retryHydrationIfNeeded()

        XCTAssertEqual(state.viewerIdentity, identity)
        XCTAssertEqual(state.pairedMac, record)
        XCTAssertNil(state.storageError)
        XCTAssertEqual(store.identityLoadCount, 2)
        XCTAssertEqual(store.deleteCount, 0)

        state.retryHydrationIfNeeded()
        XCTAssertEqual(store.identityLoadCount, 2)
    }

    func testPairingKeychainItemsAreThisDeviceOnly() throws {
        let items = makeKeychainItems(testName: #function)
        let store = ViewerPairingKeychainStore(
            identityItem: items.identity,
            pairedMacItem: items.pairedMac
        )
        defer { deleteKeychainItems(items) }

        let identity = try store.loadOrCreateViewerIdentity()
        try store.savePairedMac(
            makePairedMacRecord(localIdentity: identity),
            for: identity
        )
        let invitation = try RemoteInvitationCode.generate()
        let admissionStore = WorldwideInvitationAdmissionKeychainStore(
            item: items.admissionMarker
        )
        try admissionStore.saveAdmittedInvitationDigest(
            WorldwideInvitationAdmissionKeychainStore.digest(
                for: invitation.exportedCode
            )
        )

        try assertThisDeviceOnly(item: items.identity)
        try assertThisDeviceOnly(item: items.pairedMac)
        try assertThisDeviceOnly(item: items.admissionMarker)
    }

    func testStoredHostIdentityIsRejectedInsteadOfSilentlyReplaced() throws {
        let items = makeKeychainItems(testName: #function)
        defer { deleteKeychainItems(items) }
        let hostIdentity = try RemoteDeviceIdentity.generate(role: .host)
        try KeychainStore(item: items.identity).saveData(JSONEncoder().encode(hostIdentity))

        let store = ViewerPairingKeychainStore(
            identityItem: items.identity,
            pairedMacItem: items.pairedMac
        )
        XCTAssertThrowsError(try store.loadOrCreateViewerIdentity()) { error in
            XCTAssertEqual(error as? ViewerPairingStoreError, .invalidViewerIdentity)
        }

        let persisted = try XCTUnwrap(KeychainStore(item: items.identity).loadData())
        XCTAssertEqual(try JSONDecoder().decode(RemoteDeviceIdentity.self, from: persisted), hostIdentity)
    }

    func testPairedMacMustBeBoundToExactViewerIdentity() throws {
        let items = makeKeychainItems(testName: #function)
        defer { deleteKeychainItems(items) }
        let firstIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let otherIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let otherRecord = try makePairedMacRecord(localIdentity: otherIdentity)
        let store = ViewerPairingKeychainStore(
            identityItem: items.identity,
            pairedMacItem: items.pairedMac
        )

        XCTAssertThrowsError(try store.savePairedMac(otherRecord, for: firstIdentity)) { error in
            XCTAssertEqual(error as? ViewerPairingStoreError, .invalidPairedMacRecord)
        }
        XCTAssertNil(try KeychainStore(item: items.pairedMac).loadData())
    }

    func testPendingViewerRecordHydratesOnlyAsRecoveryState() throws {
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let pendingRecord = try makePairedMacRecord(
            localIdentity: identity,
            pairingState: .pending
        )
        let store = ViewerPairingStoreStub(identity: identity)
        let state = ViewerPairingState(store: store)

        try state.savePairingRecord(pendingRecord)

        XCTAssertEqual(state.pairingRecord, pendingRecord)
        XCTAssertEqual(state.recoveryAction, .awaitProposal)
        XCTAssertNil(state.pairedMac)
        XCTAssertFalse(state.isPaired)
    }

    func testAcceptedIssuedRecordSurvivesRelaunchForCommitRecovery() throws {
        let items = makeKeychainItems(testName: #function)
        defer { deleteKeychainItems(items) }
        let store = ViewerPairingKeychainStore(
            identityItem: items.identity,
            pairedMacItem: items.pairedMac
        )
        let identity = try store.loadOrCreateViewerIdentity()
        let acceptedIssued = try makePairedMacRecord(
            localIdentity: identity,
            pairingState: .acceptedIssued
        )
        try store.savePairedMac(acceptedIssued, for: identity)

        let relaunched = ViewerPairingState(
            store: ViewerPairingKeychainStore(
                identityItem: items.identity,
                pairedMacItem: items.pairedMac
            )
        )

        XCTAssertEqual(relaunched.viewerIdentity, identity)
        XCTAssertEqual(relaunched.pairingRecord, acceptedIssued)
        guard case .resend(let acknowledgement) = relaunched.recoveryAction else {
            return XCTFail("Expected the durable pairing acknowledgement to be recoverable")
        }
        XCTAssertEqual(acknowledgement.phase, .acknowledgement)
        XCTAssertNil(relaunched.pairedMac)
        XCTAssertFalse(relaunched.isPaired)
    }

    func testHostOnlyAcceptedReceivedStateIsRejectedByViewerStore() throws {
        let items = makeKeychainItems(testName: #function)
        defer { deleteKeychainItems(items) }
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let hostOnlyRecord = try makePairingRecords(
            viewerIdentity: identity
        ).hostAcceptedReceived
        let store = ViewerPairingKeychainStore(
            identityItem: items.identity,
            pairedMacItem: items.pairedMac
        )

        XCTAssertThrowsError(try store.savePairedMac(hostOnlyRecord, for: identity)) { error in
            XCTAssertEqual(error as? ViewerPairingStoreError, .invalidPairedMacRecord)
        }
    }

    func testForgetDeletesPairButPreservesViewerIdentity() throws {
        let items = makeKeychainItems(testName: #function)
        defer { deleteKeychainItems(items) }
        let makeStore = {
            ViewerPairingKeychainStore(
                identityItem: items.identity,
                pairedMacItem: items.pairedMac
            )
        }
        let state = ViewerPairingState(store: makeStore())
        let identity = try XCTUnwrap(state.viewerIdentity)
        try state.saveAuthenticatedPairing(makePairedMacRecord(localIdentity: identity))

        try state.forgetPairedMac()

        XCTAssertEqual(state.viewerIdentity, identity)
        XCTAssertNil(state.pairedMac)
        XCTAssertFalse(state.isPaired)
        let reconstructedState = ViewerPairingState(store: makeStore())
        XCTAssertEqual(reconstructedState.viewerIdentity, identity)
        XCTAssertNil(reconstructedState.pairedMac)
    }

    func testNamespaceSelectorPrefersCompletePrimaryPairWithoutProbingLegacy() throws {
        let primaryIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let primaryRecord = try makePairedMacRecord(localIdentity: primaryIdentity)
        let legacyIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let legacyRecord = try makePairedMacRecord(localIdentity: legacyIdentity)
        let primary = PairingNamespaceStoreSpy(
            snapshot: try pairingNamespaceSnapshot(
                identity: primaryIdentity,
                record: primaryRecord
            )
        )
        let legacy = PairingNamespaceStoreSpy(
            snapshot: try pairingNamespaceSnapshot(
                identity: legacyIdentity,
                record: legacyRecord
            )
        )

        let state = ViewerPairingState(
            store: ViewerPairingNamespaceSelectorStore(
                primaryStore: primary,
                legacyStore: legacy
            )
        )

        XCTAssertEqual(state.viewerIdentity, primaryIdentity)
        XCTAssertEqual(state.pairedMac, primaryRecord)
        XCTAssertEqual(primary.snapshotLoadCount, 1)
        XCTAssertEqual(legacy.snapshotLoadCount, 0)
        XCTAssertEqual(primary.createIdentityCount, 0)
        XCTAssertEqual(legacy.createIdentityCount, 0)
    }

    func testPrimaryIdentityOnlyIsExplicitlyUnpairedAndDoesNotProbeLegacy() throws {
        let primaryIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let legacyIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let legacyRecord = try makePairedMacRecord(localIdentity: legacyIdentity)
        let primary = PairingNamespaceStoreSpy(
            snapshot: try pairingNamespaceSnapshot(
                identity: primaryIdentity,
                record: nil
            )
        )
        let legacy = PairingNamespaceStoreSpy(
            snapshot: try pairingNamespaceSnapshot(
                identity: legacyIdentity,
                record: legacyRecord
            )
        )

        let state = ViewerPairingState(
            store: ViewerPairingNamespaceSelectorStore(
                primaryStore: primary,
                legacyStore: legacy
            )
        )

        XCTAssertEqual(state.viewerIdentity, primaryIdentity)
        XCTAssertNil(state.pairingRecord)
        XCTAssertFalse(state.isPaired)
        XCTAssertEqual(legacy.snapshotLoadCount, 0)
        XCTAssertEqual(primary.createIdentityCount, 0)
        XCTAssertEqual(legacy.saveCount, 0)
    }

    func testNamespaceSelectorUsesCompleteLegacyPairOnlyWhenPrimaryIsEmpty() throws {
        let legacyIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let legacyRecord = try makePairedMacRecord(localIdentity: legacyIdentity)
        let primary = PairingNamespaceStoreSpy(
            snapshot: .empty,
            identityToCreate: try RemoteDeviceIdentity.generate(role: .viewer)
        )
        let legacy = PairingNamespaceStoreSpy(
            snapshot: try pairingNamespaceSnapshot(
                identity: legacyIdentity,
                record: legacyRecord
            )
        )

        let state = ViewerPairingState(
            store: ViewerPairingNamespaceSelectorStore(
                primaryStore: primary,
                legacyStore: legacy
            )
        )

        XCTAssertEqual(state.viewerIdentity, legacyIdentity)
        XCTAssertEqual(state.pairedMac, legacyRecord)
        XCTAssertEqual(primary.snapshotLoadCount, 1)
        XCTAssertEqual(legacy.snapshotLoadCount, 1)
        XCTAssertEqual(primary.createIdentityCount, 0)
        XCTAssertEqual(primary.saveCount, 0)
    }

    func testLegacyIdentityOnlyIsNotFallbackAndCreatesOnlyPrimaryIdentity() throws {
        let primaryIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let legacyIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let primary = PairingNamespaceStoreSpy(
            snapshot: .empty,
            identityToCreate: primaryIdentity
        )
        let legacySnapshot = try pairingNamespaceSnapshot(
            identity: legacyIdentity,
            record: nil
        )
        let legacy = PairingNamespaceStoreSpy(snapshot: legacySnapshot)

        let state = ViewerPairingState(
            store: ViewerPairingNamespaceSelectorStore(
                primaryStore: primary,
                legacyStore: legacy
            )
        )

        XCTAssertEqual(state.viewerIdentity, primaryIdentity)
        XCTAssertNotEqual(state.viewerIdentity, legacyIdentity)
        XCTAssertNil(state.pairingRecord)
        XCTAssertEqual(primary.createIdentityCount, 1)
        XCTAssertEqual(primary.snapshotLoadCount, 2)
        XCTAssertEqual(legacy.snapshotLoadCount, 1)
        XCTAssertEqual(legacy.snapshot, legacySnapshot)
        XCTAssertEqual(legacy.createIdentityCount, 0)
        XCTAssertEqual(legacy.preserveIdentityCount, 0)
        XCTAssertEqual(legacy.saveCount, 0)
        XCTAssertEqual(legacy.deleteCount, 0)
    }

    func testBothEmptyNamespacesCreateIdentityOnlyInPrimary() throws {
        let createdIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let primary = PairingNamespaceStoreSpy(
            snapshot: .empty,
            identityToCreate: createdIdentity
        )
        let legacy = PairingNamespaceStoreSpy(snapshot: .empty)

        let state = ViewerPairingState(
            store: ViewerPairingNamespaceSelectorStore(
                primaryStore: primary,
                legacyStore: legacy
            )
        )

        XCTAssertEqual(state.viewerIdentity, createdIdentity)
        XCTAssertNil(state.pairingRecord)
        XCTAssertEqual(primary.createIdentityCount, 1)
        XCTAssertEqual(primary.saveCount, 0)
        XCTAssertEqual(legacy.createIdentityCount, 0)
        XCTAssertEqual(legacy.preserveIdentityCount, 0)
        XCTAssertEqual(legacy.saveCount, 0)
        XCTAssertEqual(legacy.deleteCount, 0)
    }

    func testPairOnlyPrimaryFailsClosedWithoutProbingLegacyOrWriting() throws {
        let legacyIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let legacyRecord = try makePairedMacRecord(localIdentity: legacyIdentity)
        let primary = PairingNamespaceStoreSpy(snapshot: .empty)
        primary.snapshotError = ViewerPairingStoreError.invalidPairedMacRecord
        let legacySnapshot = try pairingNamespaceSnapshot(
            identity: legacyIdentity,
            record: legacyRecord
        )
        let legacy = PairingNamespaceStoreSpy(snapshot: legacySnapshot)
        let selector = ViewerPairingNamespaceSelectorStore(
            primaryStore: primary,
            legacyStore: legacy
        )

        XCTAssertThrowsError(try selector.loadOrCreateViewerIdentity()) { error in
            XCTAssertEqual(error as? ViewerPairingStoreError, .invalidPairedMacRecord)
        }
        XCTAssertEqual(primary.snapshotLoadCount, 1)
        XCTAssertEqual(primary.createIdentityCount, 0)
        XCTAssertEqual(legacy.snapshotLoadCount, 0)
        XCTAssertEqual(legacy.snapshot, legacySnapshot)
        XCTAssertEqual(legacy.saveCount, 0)
    }

    func testPairOnlyKeychainNamespaceFailsClosedWithoutCreatingIdentity() throws {
        let items = makeKeychainItems(testName: #function)
        defer { deleteKeychainItems(items) }
        let orphanIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let orphanRecord = try makePairedMacRecord(localIdentity: orphanIdentity)
        let orphanRecordData = try JSONEncoder().encode(orphanRecord)
        try KeychainStore(item: items.pairedMac).saveData(orphanRecordData)
        let store = ViewerPairingKeychainStore(
            identityItem: items.identity,
            pairedMacItem: items.pairedMac
        )

        XCTAssertThrowsError(try store.loadNamespaceSnapshot()) { error in
            XCTAssertEqual(error as? ViewerPairingStoreError, .invalidPairedMacRecord)
        }
        XCTAssertNil(try KeychainStore(item: items.identity).loadData())
        XCTAssertEqual(
            try KeychainStore(item: items.pairedMac).loadData(),
            orphanRecordData
        )
    }

    func testCorruptPrimaryRecordFailsClosedWithoutLegacyFallback() throws {
        let primaryItems = makeKeychainItems(testName: "\(#function)-primary")
        let legacyItems = makeKeychainItems(testName: "\(#function)-legacy")
        defer {
            deleteKeychainItems(primaryItems)
            deleteKeychainItems(legacyItems)
        }
        let primaryIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let legacyIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let legacyRecord = try makePairedMacRecord(localIdentity: legacyIdentity)
        let primaryIdentityData = try JSONEncoder().encode(primaryIdentity)
        let malformedRecordData = Data("{not-json".utf8)
        let legacyIdentityData = try JSONEncoder().encode(legacyIdentity)
        let legacyRecordData = try JSONEncoder().encode(legacyRecord)
        try KeychainStore(item: primaryItems.identity).saveData(primaryIdentityData)
        try KeychainStore(item: primaryItems.pairedMac).saveData(malformedRecordData)
        try KeychainStore(item: legacyItems.identity).saveData(legacyIdentityData)
        try KeychainStore(item: legacyItems.pairedMac).saveData(legacyRecordData)

        let selector = makeNamespaceSelector(
            primaryItems: primaryItems,
            legacyItems: legacyItems
        )

        XCTAssertThrowsError(try selector.loadOrCreateViewerIdentity()) { error in
            XCTAssertEqual(error as? ViewerPairingStoreError, .invalidPairedMacRecord)
        }
        XCTAssertEqual(
            try KeychainStore(item: primaryItems.identity).loadData(),
            primaryIdentityData
        )
        XCTAssertEqual(
            try KeychainStore(item: primaryItems.pairedMac).loadData(),
            malformedRecordData
        )
        XCTAssertEqual(
            try KeychainStore(item: legacyItems.identity).loadData(),
            legacyIdentityData
        )
        XCTAssertEqual(
            try KeychainStore(item: legacyItems.pairedMac).loadData(),
            legacyRecordData
        )
    }

    func testPrimaryRecordBoundToAnotherIdentityFailsClosedWithoutMixing() throws {
        let primaryItems = makeKeychainItems(testName: "\(#function)-primary")
        let legacyItems = makeKeychainItems(testName: "\(#function)-legacy")
        defer {
            deleteKeychainItems(primaryItems)
            deleteKeychainItems(legacyItems)
        }
        let primaryIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let otherIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let mismatchedRecord = try makePairedMacRecord(localIdentity: otherIdentity)
        let legacyIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let legacyRecord = try makePairedMacRecord(localIdentity: legacyIdentity)
        try seedPairingNamespace(
            items: primaryItems,
            identity: primaryIdentity,
            record: mismatchedRecord
        )
        try seedPairingNamespace(
            items: legacyItems,
            identity: legacyIdentity,
            record: legacyRecord
        )

        let selector = makeNamespaceSelector(
            primaryItems: primaryItems,
            legacyItems: legacyItems
        )

        XCTAssertThrowsError(try selector.loadOrCreateViewerIdentity()) { error in
            XCTAssertEqual(error as? ViewerPairingStoreError, .invalidPairedMacRecord)
        }
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemotePairedDeviceRecord.self,
                from: XCTUnwrap(KeychainStore(item: primaryItems.pairedMac).loadData())
            ),
            mismatchedRecord
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemotePairedDeviceRecord.self,
                from: XCTUnwrap(KeychainStore(item: legacyItems.pairedMac).loadData())
            ),
            legacyRecord
        )
    }

    func testNamespaceSelectorPropagatesKeychainReadFailureWithoutFallback() throws {
        let primary = PairingNamespaceStoreSpy(snapshot: .empty)
        primary.snapshotError = KeychainStoreError.operationFailed(errSecInteractionNotAllowed)
        let legacy = PairingNamespaceStoreSpy(snapshot: .empty)
        let selector = ViewerPairingNamespaceSelectorStore(
            primaryStore: primary,
            legacyStore: legacy
        )

        XCTAssertThrowsError(try selector.loadOrCreateViewerIdentity()) { error in
            XCTAssertEqual(
                error as? KeychainStoreError,
                .operationFailed(errSecInteractionNotAllowed)
            )
        }
        XCTAssertEqual(primary.snapshotLoadCount, 1)
        XCTAssertEqual(legacy.snapshotLoadCount, 0)
        XCTAssertEqual(primary.createIdentityCount, 0)
    }

    func testLegacyReadFailureDoesNotCreatePrimaryIdentity() throws {
        let primary = PairingNamespaceStoreSpy(
            snapshot: .empty,
            identityToCreate: try RemoteDeviceIdentity.generate(role: .viewer)
        )
        let legacy = PairingNamespaceStoreSpy(snapshot: .empty)
        legacy.snapshotError = KeychainStoreError.operationFailed(errSecInteractionNotAllowed)
        let selector = ViewerPairingNamespaceSelectorStore(
            primaryStore: primary,
            legacyStore: legacy
        )

        XCTAssertThrowsError(try selector.loadOrCreateViewerIdentity()) { error in
            XCTAssertEqual(
                error as? KeychainStoreError,
                .operationFailed(errSecInteractionNotAllowed)
            )
        }
        XCTAssertEqual(primary.snapshotLoadCount, 1)
        XCTAssertEqual(legacy.snapshotLoadCount, 1)
        XCTAssertEqual(primary.createIdentityCount, 0)
        XCTAssertEqual(primary.saveCount, 0)
    }

    func testSavingAfterLegacySelectionWritesOnlyLegacyNamespace() throws {
        let primaryItems = makeKeychainItems(testName: "\(#function)-primary")
        let legacyItems = makeKeychainItems(testName: "\(#function)-legacy")
        defer {
            deleteKeychainItems(primaryItems)
            deleteKeychainItems(legacyItems)
        }
        let legacyIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let originalRecord = try makePairedMacRecord(localIdentity: legacyIdentity)
        try seedPairingNamespace(
            items: legacyItems,
            identity: legacyIdentity,
            record: originalRecord
        )
        let selector = makeNamespaceSelector(
            primaryItems: primaryItems,
            legacyItems: legacyItems
        )
        let state = ViewerPairingState(store: selector)
        let replacement = try makePairedMacRecord(localIdentity: legacyIdentity)

        try state.saveAuthenticatedPairing(replacement)

        XCTAssertEqual(state.pairedMac, replacement)
        XCTAssertNil(try KeychainStore(item: primaryItems.identity).loadData())
        XCTAssertNil(try KeychainStore(item: primaryItems.pairedMac).loadData())
        XCTAssertEqual(
            try ViewerPairingKeychainStore(
                identityItem: legacyItems.identity,
                pairedMacItem: legacyItems.pairedMac
            ).loadPairedMac(for: legacyIdentity),
            replacement
        )
    }

    func testPrimaryForgetDeletesUnselectedLegacyPairBeforeSelectedPrimaryPair() throws {
        let recorder = PairingNamespaceOperationRecorder()
        let primaryIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let legacyIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let primary = PairingNamespaceStoreSpy(
            snapshot: try pairingNamespaceSnapshot(
                identity: primaryIdentity,
                record: makePairedMacRecord(localIdentity: primaryIdentity)
            ),
            label: "primary",
            operationRecorder: recorder
        )
        let legacy = PairingNamespaceStoreSpy(
            snapshot: try pairingNamespaceSnapshot(
                identity: legacyIdentity,
                record: makePairedMacRecord(localIdentity: legacyIdentity)
            ),
            label: "legacy",
            operationRecorder: recorder
        )
        let state = ViewerPairingState(
            store: ViewerPairingNamespaceSelectorStore(
                primaryStore: primary,
                legacyStore: legacy
            )
        )
        recorder.operations.removeAll()

        try state.forgetPairedMac()

        XCTAssertEqual(
            recorder.operations,
            ["legacy.delete-pair", "primary.delete-pair"]
        )
        XCTAssertNil(primary.snapshot.pairedMac)
        XCTAssertNil(legacy.snapshot.pairedMac)
    }

    func testLegacyForgetPromotesIdentityAndDeletesSelectedLegacyPairLast() throws {
        let recorder = PairingNamespaceOperationRecorder()
        let legacyIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let primary = PairingNamespaceStoreSpy(
            snapshot: .empty,
            label: "primary",
            operationRecorder: recorder
        )
        let legacy = PairingNamespaceStoreSpy(
            snapshot: try pairingNamespaceSnapshot(
                identity: legacyIdentity,
                record: makePairedMacRecord(localIdentity: legacyIdentity)
            ),
            label: "legacy",
            operationRecorder: recorder
        )
        let state = ViewerPairingState(
            store: ViewerPairingNamespaceSelectorStore(
                primaryStore: primary,
                legacyStore: legacy
            )
        )
        recorder.operations.removeAll()

        try state.forgetPairedMac()

        XCTAssertEqual(
            recorder.operations,
            [
                "primary.snapshot",
                "primary.preserve-identity",
                "primary.delete-pair",
                "legacy.delete-pair"
            ]
        )
        XCTAssertEqual(primary.snapshot.identity, legacyIdentity)
        XCTAssertNil(primary.snapshot.pairedMac)
        XCTAssertNil(legacy.snapshot.pairedMac)
    }

    func testPrimarySelectedForgetDeletesBothPairsAndPreservesBothIdentities() throws {
        let primaryItems = makeKeychainItems(testName: "\(#function)-primary")
        let legacyItems = makeKeychainItems(testName: "\(#function)-legacy")
        defer {
            deleteKeychainItems(primaryItems)
            deleteKeychainItems(legacyItems)
        }
        let primaryIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let primaryRecord = try makePairedMacRecord(localIdentity: primaryIdentity)
        let legacyIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let legacyRecord = try makePairedMacRecord(localIdentity: legacyIdentity)
        try seedPairingNamespace(
            items: primaryItems,
            identity: primaryIdentity,
            record: primaryRecord
        )
        try seedPairingNamespace(
            items: legacyItems,
            identity: legacyIdentity,
            record: legacyRecord
        )
        let primaryIdentityData = try XCTUnwrap(
            KeychainStore(item: primaryItems.identity).loadData()
        )
        let legacyIdentityData = try XCTUnwrap(
            KeychainStore(item: legacyItems.identity).loadData()
        )
        let state = ViewerPairingState(
            store: makeNamespaceSelector(
                primaryItems: primaryItems,
                legacyItems: legacyItems
            )
        )

        try state.forgetPairedMac()

        XCTAssertEqual(state.viewerIdentity, primaryIdentity)
        XCTAssertNil(state.pairingRecord)
        XCTAssertEqual(
            try KeychainStore(item: primaryItems.identity).loadData(),
            primaryIdentityData
        )
        XCTAssertEqual(
            try KeychainStore(item: legacyItems.identity).loadData(),
            legacyIdentityData
        )
        XCTAssertNil(try KeychainStore(item: primaryItems.pairedMac).loadData())
        XCTAssertNil(try KeychainStore(item: legacyItems.pairedMac).loadData())
    }

    func testLegacySelectedForgetPromotesExactIdentityThenDeletesBothPairs() throws {
        let primaryItems = makeKeychainItems(testName: "\(#function)-primary")
        let legacyItems = makeKeychainItems(testName: "\(#function)-legacy")
        defer {
            deleteKeychainItems(primaryItems)
            deleteKeychainItems(legacyItems)
        }
        let legacyIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let legacyRecord = try makePairedMacRecord(localIdentity: legacyIdentity)
        var identityObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(legacyIdentity)
            ) as? [String: Any]
        )
        identityObject["migrationMetadata"] = ["preserveExactBytes": true]
        let exactLegacyIdentityData = try JSONSerialization.data(
            withJSONObject: identityObject,
            options: [.sortedKeys]
        )
        try KeychainStore(item: legacyItems.identity).saveData(exactLegacyIdentityData)
        try KeychainStore(item: legacyItems.pairedMac).saveData(
            try JSONEncoder().encode(legacyRecord)
        )
        let selector = makeNamespaceSelector(
            primaryItems: primaryItems,
            legacyItems: legacyItems
        )
        let state = ViewerPairingState(store: selector)
        XCTAssertEqual(state.viewerIdentity, legacyIdentity)
        XCTAssertEqual(state.pairedMac, legacyRecord)

        try state.forgetPairedMac()

        XCTAssertEqual(
            try KeychainStore(item: primaryItems.identity).loadData(),
            exactLegacyIdentityData
        )
        XCTAssertEqual(
            try KeychainStore(item: legacyItems.identity).loadData(),
            exactLegacyIdentityData
        )
        XCTAssertNil(try KeychainStore(item: primaryItems.pairedMac).loadData())
        XCTAssertNil(try KeychainStore(item: legacyItems.pairedMac).loadData())

        let replacement = try makePairedMacRecord(localIdentity: legacyIdentity)
        try state.saveAuthenticatedPairing(replacement)
        XCTAssertEqual(
            try ViewerPairingKeychainStore(
                identityItem: primaryItems.identity,
                pairedMacItem: primaryItems.pairedMac
            ).loadPairedMac(for: legacyIdentity),
            replacement
        )
        XCTAssertNil(try KeychainStore(item: legacyItems.pairedMac).loadData())
    }

    func testLegacySelectedForgetRejectsConflictingPrimaryIdentityBeforeDeleting() throws {
        let primaryItems = makeKeychainItems(testName: "\(#function)-primary")
        let legacyItems = makeKeychainItems(testName: "\(#function)-legacy")
        defer {
            deleteKeychainItems(primaryItems)
            deleteKeychainItems(legacyItems)
        }
        let legacyIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let legacyRecord = try makePairedMacRecord(localIdentity: legacyIdentity)
        try seedPairingNamespace(
            items: legacyItems,
            identity: legacyIdentity,
            record: legacyRecord
        )
        let state = ViewerPairingState(
            store: makeNamespaceSelector(
                primaryItems: primaryItems,
                legacyItems: legacyItems
            )
        )
        let conflictingIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        try KeychainStore(item: primaryItems.identity).saveData(
            try JSONEncoder().encode(conflictingIdentity)
        )

        XCTAssertThrowsError(try state.forgetPairedMac()) { error in
            XCTAssertEqual(error as? ViewerPairingStoreError, .viewerIdentityConflict)
        }

        XCTAssertEqual(state.viewerIdentity, legacyIdentity)
        XCTAssertEqual(state.pairedMac, legacyRecord)
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteDeviceIdentity.self,
                from: XCTUnwrap(KeychainStore(item: primaryItems.identity).loadData())
            ),
            conflictingIdentity
        )
        XCTAssertEqual(
            try ViewerPairingKeychainStore(
                identityItem: legacyItems.identity,
                pairedMacItem: legacyItems.pairedMac
            ).loadPairedMac(for: legacyIdentity),
            legacyRecord
        )
    }

    func testLegacySelectedForgetAcceptsEqualPrimaryIdentityWithoutRewritingIt() throws {
        let primaryItems = makeKeychainItems(testName: "\(#function)-primary")
        let legacyItems = makeKeychainItems(testName: "\(#function)-legacy")
        defer {
            deleteKeychainItems(primaryItems)
            deleteKeychainItems(legacyItems)
        }
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let legacyRecord = try makePairedMacRecord(localIdentity: identity)
        try seedPairingNamespace(
            items: legacyItems,
            identity: identity,
            record: legacyRecord
        )
        let state = ViewerPairingState(
            store: makeNamespaceSelector(
                primaryItems: primaryItems,
                legacyItems: legacyItems
            )
        )
        var primaryIdentityObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(identity)
            ) as? [String: Any]
        )
        primaryIdentityObject["primaryMetadata"] = ["keepExistingEncoding": true]
        let exactPrimaryIdentityData = try JSONSerialization.data(
            withJSONObject: primaryIdentityObject,
            options: [.sortedKeys]
        )
        try KeychainStore(item: primaryItems.identity).saveData(exactPrimaryIdentityData)

        try state.forgetPairedMac()

        XCTAssertEqual(state.viewerIdentity, identity)
        XCTAssertNil(state.pairingRecord)
        XCTAssertEqual(
            try KeychainStore(item: primaryItems.identity).loadData(),
            exactPrimaryIdentityData
        )
        XCTAssertNotNil(try KeychainStore(item: legacyItems.identity).loadData())
        XCTAssertNil(try KeychainStore(item: primaryItems.pairedMac).loadData())
        XCTAssertNil(try KeychainStore(item: legacyItems.pairedMac).loadData())
    }

    func testAuthenticatedCompletionPersistsBeforeInvitationDeletionExactlyOnce() throws {
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let records = try makePairingRecords(viewerIdentity: identity)
        var events: [String] = []
        var saveCount = 0
        let store = ViewerPairingStoreStub(identity: identity) {
            saveCount += 1
            events.append(saveCount == 1 ? "persist-recoverable-pair" : "persist-active-pair")
        }
        let state = ViewerPairingState(store: store)
        var invitationDeleteCount = 0
        var acceptance = InvitationAcceptanceAction()
        let generation = UUID()
        acceptance.arm(
            generation: generation,
            onAdmitted: {
                events.append("persist-admission-marker")
            }
        ) { record in
            try state.saveAuthenticatedPairing(record)
            events.append("delete-invitation")
            events.append("delete-admission-marker")
            invitationDeleteCount += 1
        }

        // Sequence 1: the recoverable viewer acknowledgement is durable first.
        try state.savePairingRecord(records.viewerAcceptedIssued)
        // Sequence 2 boundary: persist admission immediately before the ACK is sent.
        try acceptance.persistAdmissionAfterRecoverablePairing(
            records.viewerAcceptedIssued,
            generation: generation
        )
        try acceptance.persistAdmissionAfterRecoverablePairing(
            records.viewerAcceptedIssued,
            generation: generation
        )
        XCTAssertEqual(
            events,
            ["persist-recoverable-pair", "persist-admission-marker"]
        )
        XCTAssertEqual(invitationDeleteCount, 0)

        XCTAssertTrue(
            try acceptance.completeAuthenticatedPairing(
                records.viewerActive,
                generation: generation
            )
        )
        XCTAssertFalse(
            try acceptance.completeAuthenticatedPairing(
                records.viewerActive,
                generation: generation
            )
        )

        XCTAssertEqual(
            events,
            [
                "persist-recoverable-pair",
                "persist-admission-marker",
                "persist-active-pair",
                "delete-invitation",
                "delete-admission-marker"
            ]
        )
        XCTAssertEqual(invitationDeleteCount, 1)
        XCTAssertEqual(state.pairedMac, records.viewerActive)
    }

    func testFailureBeforeRecoverableBoundaryLeavesInvitationRetryable() throws {
        let invitation = try RemoteInvitationCode.generate()
        let store = WorldwideInvitationAdmissionStoreStub()
        let admissionState = WorldwideInvitationAdmissionState(store: store)
        var acceptance = InvitationAcceptanceAction()
        let generation = UUID()
        acceptance.arm(
            generation: generation,
            onAdmitted: {
                try admissionState.markAdmitted(invitation.exportedCode)
            },
            action: { _ in }
        )

        acceptance.cancel(generation: generation)

        XCTAssertFalse(admissionState.blocksPairing(invitation.exportedCode))
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertNil(store.digest)
    }

    func testPendingRecordCannotPersistAdmissionBoundary() throws {
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let pendingRecord = try makePairedMacRecord(
            localIdentity: identity,
            pairingState: .pending
        )
        var admissionCount = 0
        var acceptance = InvitationAcceptanceAction()
        let generation = UUID()
        acceptance.arm(
            generation: generation,
            onAdmitted: { admissionCount += 1 },
            action: { _ in }
        )

        XCTAssertThrowsError(
            try acceptance.persistAdmissionAfterRecoverablePairing(
                pendingRecord,
                generation: generation
            )
        ) { error in
            XCTAssertEqual(
                error as? InvitationAcceptanceError,
                .pairingIsNotRecoverable
            )
        }
        XCTAssertEqual(admissionCount, 0)
    }

    func testReadyThenProcessDeathWithoutPairLeavesSavedInvitationRetryable() throws {
        let items = makeKeychainItems(testName: #function)
        defer { deleteKeychainItems(items) }
        let invitation = try RemoteInvitationCode.generate()
        let invitationStore = KeychainStore(item: items.invitationCode)
        try invitationStore.saveRemoteToken(invitation.exportedCode)

        // Simulate rendezvous readiness followed by process death before an authenticated,
        // recoverable record exists. Readiness no longer persists an admission marker.
        let relaunchedCode = RemoteTokenState(
            store: KeychainStore(item: items.invitationCode),
            codeDisplayName: "invitation code"
        )
        let relaunchedAdmission = WorldwideInvitationAdmissionState(
            store: WorldwideInvitationAdmissionKeychainStore(
                item: items.admissionMarker
            )
        )
        let relaunchedPair = ViewerPairingState(
            store: ViewerPairingKeychainStore(
                identityItem: items.identity,
                pairedMacItem: items.pairedMac
            )
        )

        XCTAssertEqual(relaunchedCode.token, invitation.exportedCode)
        XCTAssertTrue(relaunchedCode.isStored)
        XCTAssertFalse(relaunchedAdmission.isAdmitted(relaunchedCode.token))
        XCTAssertFalse(relaunchedAdmission.blocksPairing(relaunchedCode.token))
        XCTAssertNil(relaunchedPair.pairingRecord)
        XCTAssertNil(try KeychainStore(item: items.admissionMarker).loadData())
    }

    func testAdmissionBoundaryRelaunchesThroughRecoverablePairingRecord() throws {
        let items = makeKeychainItems(testName: #function)
        defer { deleteKeychainItems(items) }
        let invitation = try RemoteInvitationCode.generate()
        try KeychainStore(item: items.invitationCode).saveRemoteToken(
            invitation.exportedCode
        )
        let pairingStore = ViewerPairingKeychainStore(
            identityItem: items.identity,
            pairedMacItem: items.pairedMac
        )
        let identity = try pairingStore.loadOrCreateViewerIdentity()
        let recoverableRecord = try makePairedMacRecord(
            localIdentity: identity,
            pairingState: .acceptedIssued
        )
        let pairingState = ViewerPairingState(store: pairingStore)
        let admissionState = WorldwideInvitationAdmissionState(
            store: WorldwideInvitationAdmissionKeychainStore(
                item: items.admissionMarker
            )
        )
        var acceptance = InvitationAcceptanceAction()
        let generation = UUID()
        acceptance.arm(
            generation: generation,
            onAdmitted: {
                try admissionState.markAdmitted(invitation.exportedCode)
            },
            action: { _ in }
        )

        // Match the coordinator's sequence: durable recovery first, then admission marker,
        // immediately before the viewer acknowledgement would be transmitted.
        try pairingState.savePairingRecord(recoverableRecord)
        try acceptance.persistAdmissionAfterRecoverablePairing(
            recoverableRecord,
            generation: generation
        )

        let relaunchedCode = RemoteTokenState(
            store: KeychainStore(item: items.invitationCode),
            codeDisplayName: "invitation code"
        )
        let relaunchedAdmission = WorldwideInvitationAdmissionState(
            store: WorldwideInvitationAdmissionKeychainStore(
                item: items.admissionMarker
            )
        )
        let relaunchedPair = ViewerPairingState(
            store: ViewerPairingKeychainStore(
                identityItem: items.identity,
                pairedMacItem: items.pairedMac
            )
        )

        XCTAssertEqual(relaunchedCode.token, invitation.exportedCode)
        XCTAssertTrue(relaunchedAdmission.blocksPairing(relaunchedCode.token))
        XCTAssertEqual(relaunchedPair.pairingRecord, recoverableRecord)
        guard case .resend(let acknowledgement) = relaunchedPair.recoveryAction else {
            return XCTFail("Expected relaunch to route through the durable viewer ACK")
        }
        XCTAssertEqual(acknowledgement.phase, .acknowledgement)
    }

    func testDifferentInvitationBypassesPriorAdmissionMarker() throws {
        let admittedInvitation = try RemoteInvitationCode.generate()
        let replacementInvitation = try RemoteInvitationCode.generate()
        let store = WorldwideInvitationAdmissionStoreStub()
        let state = WorldwideInvitationAdmissionState(store: store)

        try state.markAdmitted(admittedInvitation.exportedCode.lowercased())

        XCTAssertTrue(state.blocksPairing(admittedInvitation.exportedCode))
        XCTAssertFalse(state.blocksPairing(replacementInvitation.exportedCode))
    }

    func testPairPersistenceFailureNeverDeletesInvitation() throws {
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let record = try makePairedMacRecord(localIdentity: identity)
        let store = ViewerPairingStoreStub(identity: identity)
        store.saveError = PairingTestFailure.save
        let state = ViewerPairingState(store: store)
        var invitationDeleteCount = 0
        var acceptance = InvitationAcceptanceAction()
        let generation = UUID()
        acceptance.arm(generation: generation) { record in
            try state.saveAuthenticatedPairing(record)
            invitationDeleteCount += 1
        }

        XCTAssertThrowsError(
            try acceptance.completeAuthenticatedPairing(record, generation: generation)
        )
        XCTAssertEqual(invitationDeleteCount, 0)
        XCTAssertNil(state.pairedMac)
        XCTAssertNotNil(state.storageError)

        store.saveError = nil
        XCTAssertTrue(
            try acceptance.completeAuthenticatedPairing(record, generation: generation)
        )
        XCTAssertEqual(invitationDeleteCount, 1)
    }

    func testPendingPairingCompletionCannotDeleteInvitation() throws {
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let pendingRecord = try makePairedMacRecord(
            localIdentity: identity,
            pairingState: .pending
        )
        var invitationDeleteCount = 0
        var acceptance = InvitationAcceptanceAction()
        let generation = UUID()
        acceptance.arm(generation: generation) { _ in
            invitationDeleteCount += 1
        }

        XCTAssertThrowsError(
            try acceptance.completeAuthenticatedPairing(
                pendingRecord,
                generation: generation
            )
        ) { error in
            XCTAssertEqual(error as? InvitationAcceptanceError, .pairingIsNotActive)
        }
        XCTAssertEqual(invitationDeleteCount, 0)
    }

    func testViewerPersistsPendingRecordBeforeSendingItsConfirmation() async throws {
        let client = PairingBootstrapTransportStub()
        let invitation = try RemoteInvitationCode.generate()
        let viewerIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let hostIdentity = try RemoteDeviceIdentity.generate(role: .host)
        let hostParticipant = try RemotePairingParticipant(
            identity: hostIdentity,
            invitation: invitation
        )
        let store = ViewerPairingStoreStub(identity: viewerIdentity)
        let pairingState = ViewerPairingState(store: store)
        let coordinator = WorldwideViewerConnectionCoordinator(
            bootstrapClientFactory: { _, _ in client }
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test/rendezvous"))

        let task = Task { @MainActor in
            try await coordinator.pairAndPrepareMediaSession(
                invitationCode: invitation.exportedCode,
                endpoint: endpoint,
                pairingState: pairingState,
                onRecoverableInvitationAdmitted: {},
                onAuthenticatedPairingCompleted: {}
            )
        }
        try await waitForConnect(client)
        await client.yield(
            .ready(role: .viewer, invitationExpiresAt: Date().addingTimeInterval(60))
        )
        try await waitForSentPayloadCount(1, client: client)

        let initialPayloads = await client.sentPayloadsSnapshot()
        guard case .hello(let viewerHello) = initialPayloads[0] else {
            coordinator.cancel()
            _ = await task.result
            return XCTFail("Expected the viewer hello first")
        }
        let hostAgreement = try hostParticipant.accept(viewerHello)

        // Receiving the host hello establishes an in-memory agreement only. Sending a viewer
        // confirmation here would let the Mac persist first and strand a relaunched iPhone.
        await client.yield(.signal(.hello(hostParticipant.hello)))
        for _ in 0..<10 { await Task.yield() }
        let preConfirmationPayloadCount = await client.sentPayloadsSnapshot().count
        XCTAssertEqual(preConfirmationPayloadCount, 1)
        XCTAssertNil(store.record)

        await client.yield(
            .signal(.confirmation(try hostAgreement.makeConfirmation()))
        )
        try await waitForSentPayloadCount(2, client: client)
        XCTAssertEqual(store.record?.pairingState, .pending)
        let finalPayloads = await client.sentPayloadsSnapshot()
        guard case .confirmation(let viewerConfirmation) = finalPayloads[1] else {
            coordinator.cancel()
            _ = await task.result
            return XCTFail("Expected the durable viewer confirmation second")
        }
        XCTAssertNoThrow(
            try hostAgreement.makePendingRecord(peerConfirmation: viewerConfirmation)
        )

        coordinator.cancel()
        _ = await task.result
    }

    func testCancellationDuringViewerConfirmationSendCannotPublishCommittingState() async throws {
        let client = PairingBootstrapTransportStub(
            suspendViewerConfirmationSend: true
        )
        let invitation = try RemoteInvitationCode.generate()
        let viewerIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let hostIdentity = try RemoteDeviceIdentity.generate(role: .host)
        let hostParticipant = try RemotePairingParticipant(
            identity: hostIdentity,
            invitation: invitation
        )
        let pairingState = ViewerPairingState(
            store: ViewerPairingStoreStub(identity: viewerIdentity)
        )
        let coordinator = WorldwideViewerConnectionCoordinator(
            bootstrapClientFactory: { _, _ in client }
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test/rendezvous"))

        let task = Task { @MainActor in
            try await coordinator.pairAndPrepareMediaSession(
                invitationCode: invitation.exportedCode,
                endpoint: endpoint,
                pairingState: pairingState,
                onRecoverableInvitationAdmitted: {},
                onAuthenticatedPairingCompleted: {}
            )
        }
        try await waitForConnect(client)
        await client.yield(
            .ready(role: .viewer, invitationExpiresAt: Date().addingTimeInterval(60))
        )
        try await waitForSentPayloadCount(1, client: client)

        let helloPayloads = await client.sentPayloadsSnapshot()
        guard case .hello(let viewerHello) = helloPayloads[0] else {
            coordinator.cancel()
            task.cancel()
            _ = await task.result
            return XCTFail("Expected the viewer hello first")
        }
        let hostAgreement = try hostParticipant.accept(viewerHello)
        await client.yield(.signal(.hello(hostParticipant.hello)))
        await client.yield(
            .signal(.confirmation(try hostAgreement.makeConfirmation()))
        )
        try await waitForViewerConfirmationSendSuspension(client)

        coordinator.cancel()
        task.cancel()
        XCTAssertEqual(coordinator.stateText, "Not connected")
        XCTAssertFalse(coordinator.isConnecting)

        await client.resumeViewerConfirmationSend()
        _ = await task.result

        XCTAssertEqual(coordinator.stateText, "Not connected")
        XCTAssertFalse(coordinator.isConnecting)
    }

    func testViewerPersistenceFailurePreventsConfirmationTransmission() async throws {
        let client = PairingBootstrapTransportStub()
        let invitation = try RemoteInvitationCode.generate()
        let viewerIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let hostIdentity = try RemoteDeviceIdentity.generate(role: .host)
        let hostParticipant = try RemotePairingParticipant(
            identity: hostIdentity,
            invitation: invitation
        )
        let store = ViewerPairingStoreStub(identity: viewerIdentity)
        store.saveError = PairingTestFailure.save
        let pairingState = ViewerPairingState(store: store)
        let coordinator = WorldwideViewerConnectionCoordinator(
            bootstrapClientFactory: { _, _ in client }
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test/rendezvous"))

        let task = Task { @MainActor in
            try await coordinator.pairAndPrepareMediaSession(
                invitationCode: invitation.exportedCode,
                endpoint: endpoint,
                pairingState: pairingState,
                onRecoverableInvitationAdmitted: {},
                onAuthenticatedPairingCompleted: {}
            )
        }
        try await waitForConnect(client)
        await client.yield(
            .ready(role: .viewer, invitationExpiresAt: Date().addingTimeInterval(60))
        )
        try await waitForSentPayloadCount(1, client: client)
        let payloads = await client.sentPayloadsSnapshot()
        guard case .hello(let viewerHello) = payloads[0] else {
            return XCTFail("Expected the viewer hello first")
        }
        let hostAgreement = try hostParticipant.accept(viewerHello)
        await client.yield(.signal(.hello(hostParticipant.hello)))
        await client.yield(
            .signal(.confirmation(try hostAgreement.makeConfirmation()))
        )

        let result = await task.result
        guard case .failure = result else {
            return XCTFail("Expected Keychain persistence to fail the bootstrap")
        }
        let finalPayloadCount = await client.sentPayloadsSnapshot().count
        XCTAssertEqual(finalPayloadCount, 1)
        XCTAssertNil(store.record)
        XCTAssertNotNil(pairingState.storageError)
    }

    func testInterruptedPairingRetriesSavedInvitationThenFallsBackToDurablePair() async throws {
        let invitation = try RemoteInvitationCode.generate()
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let acceptedIssued = try makePairedMacRecord(
            localIdentity: identity,
            pairingState: .acceptedIssued
        )
        let store = ViewerPairingStoreStub(identity: identity)
        store.record = acceptedIssued
        let pairingState = ViewerPairingState(store: store)
        let bootstrap = PairingBootstrapTransportStub()
        let availability = PairedAvailabilityTransportStub()
        var availabilityFactoryCallCount = 0
        let coordinator = WorldwideViewerConnectionCoordinator(
            bootstrapClientFactory: { _, _ in bootstrap },
            availabilityClientFactory: { _, _ in
                availabilityFactoryCallCount += 1
                return availability
            }
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test/rendezvous"))

        let task = Task { @MainActor in
            try await coordinator.recoverInterruptedPairingAndPrepareMediaSession(
                invitationCode: invitation.exportedCode,
                endpoint: endpoint,
                pairingState: pairingState,
                onRecoverableInvitationAdmitted: {},
                onAuthenticatedPairingCompleted: {}
            )
        }
        try await waitForConnect(bootstrap)
        await bootstrap.yield(.serverError(.peerUnavailable))
        try await waitForConnect(availability)

        let bootstrapCloseCount = await bootstrap.closeCallCount()
        XCTAssertEqual(bootstrapCloseCount, 1)
        XCTAssertEqual(availabilityFactoryCallCount, 1)
        XCTAssertEqual(pairingState.pairingRecord, acceptedIssued)
        XCTAssertTrue(coordinator.isConnecting)
        XCTAssertEqual(coordinator.stateText, "Recovering saved secure pairing")

        let exchangeID = try RemoteAvailabilityExchangeID(
            wireValue: "AAAAAAAAAAAAAAAAAAAAAA"
        )
        await availability.yield(.ready(role: .viewer, exchangeID: exchangeID))
        try await waitForSentPayloadCount(1, client: availability)
        let recoveryPayloads = await availability.sentPayloadsSnapshot()
        guard case .pairingCommit(let acknowledgement) = recoveryPayloads[0] else {
            coordinator.cancel()
            _ = await task.result
            return XCTFail("Expected the durable acknowledgement fallback")
        }
        XCTAssertEqual(acknowledgement.phase, .acknowledgement)

        coordinator.cancel()
        _ = await task.result
    }

    func testSuccessfulRecoveryBootstrapAvailabilityDeadlineDoesNotFallbackOrRestartBudget() async throws {
        let invitation = try RemoteInvitationCode.generate()
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let oldRecoverableRecord = try makePairedMacRecord(
            localIdentity: identity,
            pairingState: .acceptedIssued
        )
        let store = ViewerPairingStoreStub(identity: identity)
        store.record = oldRecoverableRecord
        let pairingState = ViewerPairingState(store: store)
        let bootstrap = PairingBootstrapTransportStub()
        let availability = PairedAvailabilityTransportStub(connectError: .connectionFailed)
        let clock = AvailabilityRetryClockStub()
        var availabilityFactoryCallCount = 0
        var authenticatedCompletionCount = 0
        let coordinator = WorldwideViewerConnectionCoordinator(
            bootstrapClientFactory: { _, _ in bootstrap },
            availabilityClientFactory: { _, _ in
                availabilityFactoryCallCount += 1
                return availability
            },
            availabilityRetryDeadlineNanoseconds: 1,
            availabilityMonotonicNow: clock.now,
            availabilityRetrySleep: clock.sleep
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test/rendezvous"))

        let task = Task { @MainActor in
            try await coordinator.recoverInterruptedPairingAndPrepareMediaSession(
                invitationCode: invitation.exportedCode,
                endpoint: endpoint,
                pairingState: pairingState,
                onRecoverableInvitationAdmitted: {},
                onAuthenticatedPairingCompleted: { authenticatedCompletionCount += 1 }
            )
        }
        try await driveBootstrapPairingToCompletion(
            client: bootstrap,
            invitation: invitation
        )

        do {
            _ = try await task.value
            XCTFail("The exhausted availability attempt must fail")
        } catch {
            XCTAssertEqual(error as? RendezvousSignalingError, .connectionFailed)
        }

        XCTAssertEqual(authenticatedCompletionCount, 1)
        XCTAssertEqual(
            availabilityFactoryCallCount,
            1,
            "A successful bootstrap must not let an availability failure enter fallback"
        )
        XCTAssertEqual(clock.now(), 1, "Recovery gets exactly one monotonic availability budget")
        XCTAssertEqual(pairingState.pairingRecord?.pairingState, .active)
    }

    func testSuccessfulRecoveryBootstrapNontransientAvailabilityErrorDoesNotFallback() async throws {
        let invitation = try RemoteInvitationCode.generate()
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let oldRecoverableRecord = try makePairedMacRecord(
            localIdentity: identity,
            pairingState: .acceptedIssued
        )
        let store = ViewerPairingStoreStub(identity: identity)
        store.record = oldRecoverableRecord
        let pairingState = ViewerPairingState(store: store)
        let bootstrap = PairingBootstrapTransportStub()
        let availability = PairedAvailabilityTransportStub(connectError: .invalidServerMessage)
        let clock = AvailabilityRetryClockStub()
        var availabilityFactoryCallCount = 0
        var authenticatedCompletionCount = 0
        let coordinator = WorldwideViewerConnectionCoordinator(
            bootstrapClientFactory: { _, _ in bootstrap },
            availabilityClientFactory: { _, _ in
                availabilityFactoryCallCount += 1
                return availability
            },
            availabilityMonotonicNow: clock.now,
            availabilityRetrySleep: clock.sleep
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test/rendezvous"))

        let task = Task { @MainActor in
            try await coordinator.recoverInterruptedPairingAndPrepareMediaSession(
                invitationCode: invitation.exportedCode,
                endpoint: endpoint,
                pairingState: pairingState,
                onRecoverableInvitationAdmitted: {},
                onAuthenticatedPairingCompleted: { authenticatedCompletionCount += 1 }
            )
        }
        try await driveBootstrapPairingToCompletion(
            client: bootstrap,
            invitation: invitation
        )

        do {
            _ = try await task.value
            XCTFail("A malformed availability response must fail")
        } catch {
            XCTAssertEqual(error as? RendezvousSignalingError, .invalidServerMessage)
        }

        XCTAssertEqual(authenticatedCompletionCount, 1)
        XCTAssertEqual(availabilityFactoryCallCount, 1)
        XCTAssertEqual(clock.sleepCallCount(), 0)
        XCTAssertEqual(pairingState.pairingRecord?.pairingState, .active)
    }

    func testInterruptedPairingRetriesTransientReplacementConflict() async throws {
        let invitation = try RemoteInvitationCode.generate()
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let acceptedIssued = try makePairedMacRecord(
            localIdentity: identity,
            pairingState: .acceptedIssued
        )
        let store = ViewerPairingStoreStub(identity: identity)
        store.record = acceptedIssued
        let pairingState = ViewerPairingState(store: store)
        let staleSocketAttempt = PairingBootstrapTransportStub()
        let replacementAttempt = PairingBootstrapTransportStub()
        var bootstrapClients = [staleSocketAttempt, replacementAttempt]
        let availability = PairedAvailabilityTransportStub()
        let coordinator = WorldwideViewerConnectionCoordinator(
            bootstrapClientFactory: { _, _ in bootstrapClients.removeFirst() },
            availabilityClientFactory: { _, _ in availability }
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test/rendezvous"))

        let task = Task { @MainActor in
            try await coordinator.recoverInterruptedPairingAndPrepareMediaSession(
                invitationCode: invitation.exportedCode,
                endpoint: endpoint,
                pairingState: pairingState,
                onRecoverableInvitationAdmitted: {},
                onAuthenticatedPairingCompleted: {}
            )
        }
        try await waitForConnect(staleSocketAttempt)
        await staleSocketAttempt.yield(.serverError(.roleConflict))
        try await waitForConnect(replacementAttempt)
        XCTAssertEqual(bootstrapClients.count, 0)

        // Once the old socket was reconciled, an unavailable bootstrap means the Mac already
        // advanced to pair-scoped recovery rather than that the saved code was lost.
        await replacementAttempt.yield(.serverError(.peerUnavailable))
        try await waitForConnect(availability)
        XCTAssertTrue(coordinator.isConnecting)

        coordinator.cancel()
        _ = await task.result
    }

    func testCancelledOperationCannotCloseOrResetReplacementOperation() async throws {
        let firstClient = PairingBootstrapTransportStub(suspendClose: true)
        let replacementClient = PairingBootstrapTransportStub()
        var clients: [PairingBootstrapTransportStub] = [firstClient, replacementClient]
        let coordinator = WorldwideViewerConnectionCoordinator(
            bootstrapClientFactory: { _, _ in clients.removeFirst() }
        )
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let pairingState = ViewerPairingState(
            store: ViewerPairingStoreStub(identity: identity)
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test/rendezvous"))
        let firstInvitation = try RemoteInvitationCode.generate()
        let replacementInvitation = try RemoteInvitationCode.generate()

        let firstTask = Task { @MainActor in
            try await coordinator.pairAndPrepareMediaSession(
                invitationCode: firstInvitation.exportedCode,
                endpoint: endpoint,
                pairingState: pairingState,
                onRecoverableInvitationAdmitted: {},
                onAuthenticatedPairingCompleted: {}
            )
        }
        try await waitForConnect(firstClient)

        coordinator.cancel()
        let replacementTask = Task { @MainActor in
            try await coordinator.pairAndPrepareMediaSession(
                invitationCode: replacementInvitation.exportedCode,
                endpoint: endpoint,
                pairingState: pairingState,
                onRecoverableInvitationAdmitted: {},
                onAuthenticatedPairingCompleted: {}
            )
        }
        try await waitForConnect(replacementClient)

        await firstClient.resumeClose()
        _ = await firstTask.result
        for _ in 0..<10 { await Task.yield() }

        XCTAssertTrue(coordinator.isConnecting)
        XCTAssertEqual(coordinator.stateText, "Pairing securely")
        let replacementCloseCount = await replacementClient.closeCallCount()
        XCTAssertEqual(replacementCloseCount, 0)

        coordinator.cancel()
        _ = await replacementTask.result
    }

    func testPairingPreparationKeepsBackgroundLeaseUntilExplicitCancellation() async throws {
        let client = PairingBootstrapTransportStub()
        let backgroundTask = PairingBackgroundTaskStub()
        var admissionCount = 0
        let coordinator = WorldwideViewerConnectionCoordinator(
            bootstrapClientFactory: { _, _ in client },
            pairingBackgroundTask: backgroundTask
        )
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let pairingState = ViewerPairingState(
            store: ViewerPairingStoreStub(identity: identity)
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test/rendezvous"))
        let invitation = try RemoteInvitationCode.generate()

        let task = Task { @MainActor in
            try await coordinator.pairAndPrepareMediaSession(
                invitationCode: invitation.exportedCode,
                endpoint: endpoint,
                pairingState: pairingState,
                onRecoverableInvitationAdmitted: { admissionCount += 1 },
                onAuthenticatedPairingCompleted: {}
            )
        }
        try await waitForConnect(client)
        await client.yield(
            .ready(
                role: .viewer,
                invitationExpiresAt: Date().addingTimeInterval(60)
            )
        )
        try await waitForSentPayloadCount(1, client: client)

        XCTAssertTrue(coordinator.isConnecting)
        XCTAssertEqual(backgroundTask.beginCount, 1)
        XCTAssertEqual(backgroundTask.endCount, 0)
        XCTAssertEqual(admissionCount, 0, "Rendezvous readiness alone must not block the saved code")

        // App scene backgrounding no longer calls coordinator.cancel(). The lease remains
        // active so the short authenticated commit can reach durable paired-device storage.
        coordinator.cancel()
        _ = await task.result

        XCTAssertFalse(coordinator.isConnecting)
        XCTAssertEqual(backgroundTask.beginCount, 1)
        XCTAssertEqual(backgroundTask.endCount, 1)
    }

    func testAvailabilityRetriesWhenHostRegistrationIsNotReady() async throws {
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let activeRecord = try makePairedMacRecord(localIdentity: identity)
        let store = ViewerPairingStoreStub(identity: identity)
        store.record = activeRecord
        let pairingState = ViewerPairingState(store: store)
        let firstClient = PairedAvailabilityTransportStub()
        let retryClient = PairedAvailabilityTransportStub()
        let clock = AvailabilityRetryClockStub()
        var clients: [PairedAvailabilityTransportStub] = [firstClient, retryClient]
        let coordinator = WorldwideViewerConnectionCoordinator(
            availabilityClientFactory: { _, _ in clients.removeFirst() },
            availabilityMonotonicNow: clock.now,
            availabilityRetrySleep: clock.sleep
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test/rendezvous"))

        let task = Task { @MainActor in
            try await coordinator.preparePairedMediaSession(
                endpoint: endpoint,
                pairingState: pairingState,
                onAuthenticatedPairingCompleted: {}
            )
        }
        try await waitForConnect(firstClient)
        await firstClient.yield(.serverError(.peerUnavailable))
        try await waitForConnect(retryClient)

        XCTAssertTrue(coordinator.isConnecting)
        XCTAssertEqual(coordinator.stateText, "Waiting for paired Mac")
        guard case .waitingForAvailability(let attempt) = coordinator.savedPairConnectionState else {
            coordinator.cancel()
            _ = await task.result
            return XCTFail("A transient host-registration race must remain recoverable")
        }
        XCTAssertEqual(attempt.pairID, activeRecord.pairID)
        XCTAssertTrue(clients.isEmpty)
        let firstCloseCount = await firstClient.closeCallCount()
        let retryCloseCount = await retryClient.closeCallCount()
        XCTAssertEqual(firstCloseCount, 1)
        XCTAssertEqual(retryCloseCount, 0)
        XCTAssertEqual(clock.recordedBaseDelays(), [250_000_000])

        coordinator.cancel()
        _ = await task.result
        XCTAssertEqual(coordinator.savedPairConnectionState, .idle)
    }

    func testActiveViewerResendsActivationProofBeforeReconnectRequest() async throws {
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let activeRecord = try makePairedMacRecord(localIdentity: identity)
        let store = ViewerPairingStoreStub(identity: identity)
        store.record = activeRecord
        let pairingState = ViewerPairingState(store: store)
        let client = PairedAvailabilityTransportStub()
        let coordinator = WorldwideViewerConnectionCoordinator(
            availabilityClientFactory: { _, _ in client }
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test/rendezvous"))
        let exchangeID = try RemoteAvailabilityExchangeID(
            wireValue: "AAAAAAAAAAAAAAAAAAAAAA"
        )

        let task = Task { @MainActor in
            try await coordinator.preparePairedMediaSession(
                endpoint: endpoint,
                pairingState: pairingState,
                onAuthenticatedPairingCompleted: {}
            )
        }
        try await waitForConnect(client)
        await client.yield(.ready(role: .viewer, exchangeID: exchangeID))
        try await waitForSentPayloadCount(2, client: client)

        let sent = await client.sentPayloadsSnapshot()
        guard case .pairingCommit(let activation) = sent[0] else {
            coordinator.cancel()
            _ = await task.result
            return XCTFail("Expected activation proof before reconnect")
        }
        XCTAssertEqual(activation.phase, .activationAcknowledgement)
        guard case .reconnectRequest = sent[1] else {
            coordinator.cancel()
            _ = await task.result
            return XCTFail("Expected reconnect request after activation proof")
        }

        coordinator.cancel()
        _ = await task.result
    }

    func testCancelledSuspendedActivationCannotResavePairAfterForget() async throws {
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let activeRecord = try makePairedMacRecord(localIdentity: identity)
        let store = ViewerPairingStoreStub(identity: identity)
        store.record = activeRecord
        let pairingState = ViewerPairingState(store: store)
        let client = PairedAvailabilityTransportStub(suspendActivationSend: true)
        var authenticatedCompletionCount = 0
        let coordinator = WorldwideViewerConnectionCoordinator(
            availabilityClientFactory: { _, _ in client }
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test/rendezvous"))
        let exchangeID = try RemoteAvailabilityExchangeID(
            wireValue: "AAAAAAAAAAAAAAAAAAAAAA"
        )
        let attemptFinished = expectation(
            description: "Cancelled activation attempt terminates promptly"
        )

        let task = Task { @MainActor in
            defer { attemptFinished.fulfill() }
            return try await coordinator.preparePairedMediaSession(
                endpoint: endpoint,
                pairingState: pairingState,
                onAuthenticatedPairingCompleted: { authenticatedCompletionCount += 1 }
            )
        }
        try await waitForConnect(client)
        await client.yield(.ready(role: .viewer, exchangeID: exchangeID))
        try await waitForActivationSendSuspension(client)

        task.cancel()
        try pairingState.forgetPairedMac()
        await client.resumeActivationSend()
        await fulfillment(of: [attemptFinished], timeout: 1)
        // If a mutation removes the post-await guard, the expectation above turns red. Closing
        // the stub then ensures the intentionally broken run still terminates promptly.
        await client.close()

        do {
            _ = try await task.value
            XCTFail("The cancelled availability attempt must not resume")
        } catch is CancellationError {
            // Expected.
        }

        let payloads = await client.sentPayloadsSnapshot()
        XCTAssertEqual(payloads.count, 1, "The cancelled task must not create a reconnect request")
        XCTAssertNil(store.record, "A resumed old send must not resurrect the forgotten pair")
        XCTAssertNil(pairingState.pairingRecord)
        XCTAssertEqual(store.saveCount, 0, "No reconnect counter may become durable after Forget")
        XCTAssertEqual(authenticatedCompletionCount, 0)
        XCTAssertEqual(store.deleteCount, 1)
    }

    func testCancelledSuspendedActivationCannotOverwriteReplacementPair() async throws {
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let oldRecord = try makePairedMacRecord(localIdentity: identity)
        let replacementRecord = try makePairedMacRecord(localIdentity: identity)
        XCTAssertNotEqual(oldRecord.pairID, replacementRecord.pairID)
        let replacementSequence = replacementRecord.nextOutboundReconnectSequence
        let store = ViewerPairingStoreStub(identity: identity)
        store.record = oldRecord
        let pairingState = ViewerPairingState(store: store)
        let client = PairedAvailabilityTransportStub(suspendActivationSend: true)
        var authenticatedCompletionCount = 0
        let coordinator = WorldwideViewerConnectionCoordinator(
            availabilityClientFactory: { _, _ in client }
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test/rendezvous"))
        let exchangeID = try RemoteAvailabilityExchangeID(
            wireValue: "AAAAAAAAAAAAAAAAAAAAAA"
        )
        let attemptFinished = expectation(
            description: "Replaced-pair activation attempt terminates promptly"
        )

        let task = Task { @MainActor in
            defer { attemptFinished.fulfill() }
            return try await coordinator.preparePairedMediaSession(
                endpoint: endpoint,
                pairingState: pairingState,
                onAuthenticatedPairingCompleted: { authenticatedCompletionCount += 1 }
            )
        }
        try await waitForConnect(client)
        await client.yield(.ready(role: .viewer, exchangeID: exchangeID))
        try await waitForActivationSendSuspension(client)

        task.cancel()
        try pairingState.saveAuthenticatedPairing(replacementRecord)
        await client.resumeActivationSend()
        await fulfillment(of: [attemptFinished], timeout: 1)
        await client.close()

        do {
            _ = try await task.value
            XCTFail("The old pair attempt must not continue after replacement")
        } catch is CancellationError {
            // Expected.
        }

        let payloads = await client.sentPayloadsSnapshot()
        XCTAssertEqual(payloads.count, 1, "The old pair must not advance its reconnect counter")
        XCTAssertEqual(store.record, replacementRecord)
        XCTAssertEqual(pairingState.pairedMac, replacementRecord)
        XCTAssertEqual(store.saveCount, 1, "Only the explicit replacement save is permitted")
        XCTAssertEqual(store.savedRecords, [replacementRecord])
        XCTAssertEqual(
            store.record?.nextOutboundReconnectSequence,
            replacementSequence,
            "The old attempt must not advance the replacement pair's counter"
        )
        XCTAssertEqual(authenticatedCompletionCount, 0)
    }

    func testThreeColdReconnectPayloadSequencesAreAcceptedByTheRealHostRecord() async throws {
        let viewerIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let records = try makePairingRecords(viewerIdentity: viewerIdentity)
        let store = ViewerPairingStoreStub(identity: viewerIdentity)
        store.record = records.viewerActive
        var hostRecord = records.hostAcceptedReceived
        guard case .resend(let durableActivation) = records.viewerActive.recoveryAction else {
            return XCTFail("Active viewer fixture must carry its durable activation proof")
        }
        try hostRecord.acceptActivationAcknowledgement(durableActivation)
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test"))
        let exchangeIDs = try [
            "AAAAAAAAAAAAAAAAAAAAAA",
            "AQEBAQEBAQEBAQEBAQEBAQ",
            "AgICAgICAgICAgICAgICAg",
        ].map(RemoteAvailabilityExchangeID.init(wireValue:))
        var reconnectSequences: [UInt64] = []
        let originalPairID = records.viewerActive.pairID

        for cycle in 0..<3 {
            // Rebuild all process-local coordinator and observable state while retaining only
            // the store-backed identity and record, matching a force-terminated cold launch.
            let pairingState = ViewerPairingState(store: store)
            let transport = PairedAvailabilityTransportStub()
            let coordinator = WorldwideViewerConnectionCoordinator(
                availabilityClientFactory: { _, _ in transport }
            )
            let task = Task { @MainActor in
                try await coordinator.preparePairedMediaSession(
                    endpoint: endpoint,
                    pairingState: pairingState,
                    onAuthenticatedPairingCompleted: {}
                )
            }

            try await waitForConnect(transport)
            await transport.yield(
                .ready(role: .viewer, exchangeID: exchangeIDs[cycle])
            )
            try await waitForSentPayloadCount(2, client: transport)
            let payloads = await transport.sentPayloadsSnapshot()
            XCTAssertEqual(payloads.count, 2)

            guard case .pairingCommit(let activation) = payloads[0] else {
                coordinator.cancel()
                _ = await task.result
                return XCTFail("Every cold reconnect must send activation proof first")
            }
            // Exercise the production host record's verifier. This exact call rejects the
            // malformed/proposal/completion payloads that surface in host logs as
            // `unexpectedAvailabilityPayload`.
            try hostRecord.acceptActivationAcknowledgement(activation)

            guard case .reconnectRequest(let request) = payloads[1] else {
                coordinator.cancel()
                _ = await task.result
                return XCTFail("Activation proof must be followed by a reconnect request")
            }
            reconnectSequences.append(request.sequence)
            let responder = try hostRecord.respond(
                to: request,
                using: records.hostIdentity
            )
            await transport.yield(.signal(.reconnectResponse(responder.response)))

            let mediaClient = try await task.value
            await mediaClient.close()
            XCTAssertEqual(store.record?.pairID, originalPairID)
            XCTAssertEqual(pairingState.pairedMac?.pairID, originalPairID)
            XCTAssertEqual(coordinator.savedPairConnectionState, .idle)
            XCTAssertNil(coordinator.lastError)
        }

        XCTAssertEqual(reconnectSequences.count, 3)
        XCTAssertEqual(reconnectSequences[1], reconnectSequences[0] + 1)
        XCTAssertEqual(reconnectSequences[2], reconnectSequences[1] + 1)
        XCTAssertEqual(
            hostRecord.highestAcceptedReconnectSequence,
            reconnectSequences.last
        )
        XCTAssertEqual(store.record?.nextOutboundReconnectSequence, reconnectSequences[2] + 1)
        XCTAssertEqual(store.record?.pairingState, .active)
        XCTAssertEqual(hostRecord.pairingState, .active)
    }

    func testSilentReconnectResponseClosesAttemptAndRetriesWithNextSequence() async throws {
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let activeRecord = try makePairedMacRecord(localIdentity: identity)
        let store = ViewerPairingStoreStub(identity: identity)
        store.record = activeRecord
        let pairingState = ViewerPairingState(store: store)
        let silentClient = PairedAvailabilityTransportStub()
        let retryClient = PairedAvailabilityTransportStub()
        var clients = [silentClient, retryClient]
        let clock = AvailabilityRetryClockStub()
        let responseTimeout = ReconnectResponseTimeoutStub(
            timeoutsBeforeBlocking: 1,
            timeoutDelayNanoseconds: 1_000_000
        )
        let coordinator = WorldwideViewerConnectionCoordinator(
            availabilityClientFactory: { _, _ in clients.removeFirst() },
            availabilityMonotonicNow: clock.now,
            availabilityRetrySleep: clock.sleep,
            reconnectResponseTimeoutNanoseconds: 1,
            reconnectResponseTimeoutSleep: responseTimeout.sleep
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test/rendezvous"))
        let exchangeID = try RemoteAvailabilityExchangeID(
            wireValue: "AAAAAAAAAAAAAAAAAAAAAA"
        )

        let task = Task { @MainActor in
            try await coordinator.preparePairedMediaSession(
                endpoint: endpoint,
                pairingState: pairingState,
                onAuthenticatedPairingCompleted: {}
            )
        }
        try await waitForConnect(silentClient)
        await silentClient.yield(.ready(role: .viewer, exchangeID: exchangeID))
        try await waitForConnect(retryClient)

        let firstPayloads = await silentClient.sentPayloadsSnapshot()
        let firstRequest = try XCTUnwrap(reconnectRequest(in: firstPayloads))
        let silentClientCloseCount = await silentClient.closeCallCount()
        XCTAssertGreaterThanOrEqual(silentClientCloseCount, 1)
        XCTAssertEqual(clock.recordedBaseDelays(), [250_000_000])

        await retryClient.yield(.ready(role: .viewer, exchangeID: exchangeID))
        try await waitForSentPayloadCount(2, client: retryClient)
        let retryPayloads = await retryClient.sentPayloadsSnapshot()
        let retryRequest = try XCTUnwrap(reconnectRequest(in: retryPayloads))

        XCTAssertEqual(retryRequest.sequence, firstRequest.sequence + 1)
        XCTAssertEqual(coordinator.stateText, "Authorizing fresh session")
        XCTAssertTrue(coordinator.isConnecting)
        XCTAssertTrue(clients.isEmpty)

        coordinator.cancel()
        _ = await task.result
    }

    func testReconnectDeadlineAlsoBoundsASuspendedRequestSend() async throws {
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let activeRecord = try makePairedMacRecord(localIdentity: identity)
        let store = ViewerPairingStoreStub(identity: identity)
        store.record = activeRecord
        let pairingState = ViewerPairingState(store: store)
        let suspendedClient = PairedAvailabilityTransportStub(suspendReconnectSend: true)
        let retryClient = PairedAvailabilityTransportStub()
        var clients = [suspendedClient, retryClient]
        let clock = AvailabilityRetryClockStub()
        let responseTimeout = ReconnectResponseTimeoutStub(
            timeoutsBeforeBlocking: 1,
            timeoutDelayNanoseconds: 1_000_000
        )
        let coordinator = WorldwideViewerConnectionCoordinator(
            availabilityClientFactory: { _, _ in clients.removeFirst() },
            availabilityMonotonicNow: clock.now,
            availabilityRetrySleep: clock.sleep,
            reconnectResponseTimeoutNanoseconds: 1,
            reconnectResponseTimeoutSleep: responseTimeout.sleep
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test/rendezvous"))
        let exchangeID = try RemoteAvailabilityExchangeID(
            wireValue: "AAAAAAAAAAAAAAAAAAAAAA"
        )

        let task = Task { @MainActor in
            try await coordinator.preparePairedMediaSession(
                endpoint: endpoint,
                pairingState: pairingState,
                onAuthenticatedPairingCompleted: {}
            )
        }
        try await waitForConnect(suspendedClient)
        await suspendedClient.yield(.ready(role: .viewer, exchangeID: exchangeID))
        try await waitForConnect(retryClient)

        let suspendedCloseCount = await suspendedClient.closeCallCount()
        XCTAssertGreaterThanOrEqual(suspendedCloseCount, 1)
        XCTAssertEqual(clock.recordedBaseDelays(), [250_000_000])
        XCTAssertTrue(coordinator.isConnecting)

        coordinator.cancel()
        _ = await task.result
    }

    func testFreshExchangeImmediatelyResendsWithANewerReconnectSequence() async throws {
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let activeRecord = try makePairedMacRecord(localIdentity: identity)
        let store = ViewerPairingStoreStub(identity: identity)
        store.record = activeRecord
        let pairingState = ViewerPairingState(store: store)
        let client = PairedAvailabilityTransportStub()
        let responseTimeout = ReconnectResponseTimeoutStub(timeoutsBeforeBlocking: 0)
        let coordinator = WorldwideViewerConnectionCoordinator(
            availabilityClientFactory: { _, _ in client },
            reconnectResponseTimeoutNanoseconds: 60_000_000_000,
            reconnectResponseTimeoutSleep: responseTimeout.sleep
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test/rendezvous"))
        let firstExchange = try RemoteAvailabilityExchangeID(
            wireValue: "AAAAAAAAAAAAAAAAAAAAAA"
        )
        let replacementExchange = try RemoteAvailabilityExchangeID(
            wireValue: "AQEBAQEBAQEBAQEBAQEBAQ"
        )

        let task = Task { @MainActor in
            try await coordinator.preparePairedMediaSession(
                endpoint: endpoint,
                pairingState: pairingState,
                onAuthenticatedPairingCompleted: {}
            )
        }
        try await waitForConnect(client)
        await client.yield(.ready(role: .viewer, exchangeID: firstExchange))
        try await waitForSentPayloadCount(2, client: client)
        await client.yield(.ready(role: .viewer, exchangeID: replacementExchange))
        try await waitForSentPayloadCount(4, client: client)

        let requests = reconnectRequests(in: await client.sentPayloadsSnapshot())
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].sequence, requests[0].sequence + 1)
        let closeCount = await client.closeCallCount()
        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(coordinator.stateText, "Authorizing fresh session")

        coordinator.cancel()
        _ = await task.result
    }

    func testPairedIdlePreservesCurrentTerminalMediaError() {
        let pairID = UUID()
        let previousDisconnect =
            "The Mac disconnected. Reconnect to the saved paired Mac when it is available."

        XCTAssertEqual(
            BrowserView.worldwideStatusPresentation(
                hasActiveSession: false,
                isPreparingFreshSession: false,
                pairedMacID: pairID,
                savedPairState: .idle,
                preparationError: nil,
                mediaError: previousDisconnect
            ),
            .mediaError(previousDisconnect),
            "A durable pair must keep the current terminal media outcome until a fresh attempt."
        )
        XCTAssertEqual(
            BrowserView.pairedMacPresentation(
                pairID: pairID,
                isPairingActive: true,
                savedPairState: .idle
            ),
            BrowserView.PairedMacPresentation(
                primaryActionTitle: "Connect to Paired Mac",
                recovery: nil
            )
        )
    }

    func testPreparationErrorIsTheOnlyErrorDuringFreshSessionPreparation() {
        let pairID = UUID()
        XCTAssertEqual(
            BrowserView.worldwideStatusPresentation(
                hasActiveSession: false,
                isPreparingFreshSession: true,
                pairedMacID: pairID,
                savedPairState: .waitingForAvailability(
                    .init(attemptID: UUID(), pairID: pairID)
                ),
                preparationError: "The current attempt failed.",
                mediaError: "Old media failure"
            ),
            .preparationError("The current attempt failed.")
        )
    }

    func testMatchingAvailabilityDeadlineShowsRetainedPairRecoveryOnly() {
        let pairID = UUID()
        let context = SavedPairAttemptContext(attemptID: UUID(), pairID: pairID)
        let paired = BrowserView.pairedMacPresentation(
            pairID: pairID,
            isPairingActive: true,
            savedPairState: .unavailableAfterDeadline(context)
        )

        XCTAssertEqual(paired.primaryActionTitle, "Retry Saved Pairing")
        XCTAssertEqual(paired.recovery?.title, "Paired Mac Unavailable")
        XCTAssertEqual(paired.recovery?.message, BrowserView.savedPairUnavailableMessage)
        XCTAssertEqual(
            BrowserView.worldwideStatusPresentation(
                hasActiveSession: false,
                isPreparingFreshSession: false,
                pairedMacID: pairID,
                savedPairState: .unavailableAfterDeadline(context),
                preparationError: nil,
                mediaError: "Old media failure"
            ),
            .savedPairUnavailable(
                title: "Paired Mac Unavailable",
                message: BrowserView.savedPairUnavailableMessage
            )
        )

        let lowercased = BrowserView.savedPairUnavailableMessage.lowercased()
        for forbiddenClaim in ["expired", "deleted", "lost", "reset", "pair again"] {
            XCTAssertFalse(
                lowercased.contains(forbiddenClaim),
                "Reachability alone must not claim that pairing was \(forbiddenClaim)"
            )
        }
    }

    func testUnavailableStateFromSupersededPairCannotAffectCurrentPair() {
        let currentPairID = UUID()
        let oldContext = SavedPairAttemptContext(
            attemptID: UUID(),
            pairID: UUID()
        )
        XCTAssertEqual(
            BrowserView.pairedMacPresentation(
                pairID: currentPairID,
                isPairingActive: true,
                savedPairState: .unavailableAfterDeadline(oldContext)
            ),
            BrowserView.PairedMacPresentation(
                primaryActionTitle: "Connect to Paired Mac",
                recovery: nil
            )
        )
        XCTAssertEqual(
            BrowserView.worldwideStatusPresentation(
                hasActiveSession: false,
                isPreparingFreshSession: false,
                pairedMacID: currentPairID,
                savedPairState: .unavailableAfterDeadline(oldContext),
                preparationError: nil,
                mediaError: "Current media failure"
            ),
            .mediaError("Current media failure")
        )
    }

    func testMediaErrorBelongsToCurrentMediaUnpairedOrPairedIdlePresentation() {
        XCTAssertEqual(
            BrowserView.worldwideStatusPresentation(
                hasActiveSession: true,
                isPreparingFreshSession: false,
                pairedMacID: UUID(),
                savedPairState: .idle,
                preparationError: nil,
                mediaError: "Current media failed"
            ),
            .mediaError("Current media failed")
        )
        XCTAssertEqual(
            BrowserView.worldwideStatusPresentation(
                hasActiveSession: false,
                isPreparingFreshSession: false,
                pairedMacID: nil,
                savedPairState: .idle,
                preparationError: nil,
                mediaError: "Unpaired media failed"
            ),
            .mediaError("Unpaired media failed")
        )
        XCTAssertEqual(
            BrowserView.worldwideStatusPresentation(
                hasActiveSession: false,
                isPreparingFreshSession: false,
                pairedMacID: UUID(),
                savedPairState: .idle,
                preparationError: nil,
                mediaError: "Paired media failed"
            ),
            .mediaError("Paired media failed")
        )
        XCTAssertNil(
            BrowserView.worldwideStatusPresentation(
                hasActiveSession: false,
                isPreparingFreshSession: true,
                pairedMacID: nil,
                savedPairState: .idle,
                preparationError: nil,
                mediaError: "Old media failed"
            )
        )
    }

    func testAbsoluteDeadlineClosesAHealthySocketThatWaitsForeverForTheMac() async throws {
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let activeRecord = try makePairedMacRecord(localIdentity: identity)
        let store = ViewerPairingStoreStub(identity: identity)
        store.record = activeRecord
        let pairingState = ViewerPairingState(store: store)
        let transport = PairedAvailabilityTransportStub()
        let clock = AvailabilityRetryClockStub()
        let deadline = AvailabilityAttemptDeadlineStub()
        let telemetry = ViewerConnectionTelemetryRecorderStub()
        let coordinator = WorldwideViewerConnectionCoordinator(
            availabilityClientFactory: { _, _ in transport },
            availabilityRetryDeadlineNanoseconds: 100,
            availabilityMonotonicNow: clock.now,
            availabilityRetrySleep: clock.sleep,
            availabilityAttemptDeadlineSleep: deadline.sleep,
            connectionTelemetry: telemetry
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test/rendezvous"))

        let task = Task { @MainActor in
            try await coordinator.preparePairedMediaSession(
                endpoint: endpoint,
                pairingState: pairingState,
                onAuthenticatedPairingCompleted: {}
            )
        }
        try await waitForConnect(transport)
        await transport.yield(.waiting)
        try await waitForTelemetryStage(.viewerWorkerWaitingForHost, recorder: telemetry)
        try await waitForAvailabilityDeadline(deadline)

        clock.advance(by: 100)
        await deadline.fire()
        let outcome = await boundedPairedMediaAttemptOutcome(task)
        XCTAssertEqual(
            outcome,
            .failure(.pairedMacUnavailable),
            "A hostless waiting socket must fail promptly at the absolute deadline"
        )

        let closeCount = await transport.closeCallCount()
        // Production close is idempotent. The deadline must effectively close the socket; the
        // attempt's ordinary catch cleanup is intentionally also allowed to request closure.
        XCTAssertGreaterThanOrEqual(closeCount, 1)
        XCTAssertFalse(coordinator.isConnecting)
        XCTAssertEqual(pairingState.pairedMac, activeRecord)
        guard case .unavailableAfterDeadline(let attempt) = coordinator.savedPairConnectionState else {
            return XCTFail("Silent waiting must end in retained-pair recovery")
        }
        XCTAssertEqual(attempt.pairID, activeRecord.pairID)
        XCTAssertNil(coordinator.lastError)
        XCTAssertEqual(coordinator.stateText, "Paired Mac unavailable")
        let armedTimeout = await deadline.armedTimeout()
        let connectCount = await transport.connectCallCount()
        XCTAssertEqual(armedTimeout, 100)
        XCTAssertEqual(connectCount, 1)
        XCTAssertEqual(
            telemetry.snapshot().events.map(\.stage),
            [
                .attemptStarted,
                .availabilitySocketOpening,
                .availabilitySocketOpened,
                .viewerWorkerWaitingForHost,
                .availabilityDeadlineExpired,
                .attemptFailed,
            ]
        )
        XCTAssertEqual(
            telemetry.snapshot().events.filter { $0.terminal != nil }.count,
            1
        )
        XCTAssertEqual(
            telemetry.snapshot().events.last?.failure,
            .availabilityDeadlineExpired
        )
        XCTAssertEqual(
            coordinator.connectionTelemetrySnapshot,
            telemetry.snapshot()
        )
    }

    func testDeadlineCloseBeforeReadySendStillPublishesRetainedPairRecovery() async throws {
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let activeRecord = try makePairedMacRecord(localIdentity: identity)
        let store = ViewerPairingStoreStub(identity: identity)
        store.record = activeRecord
        let pairingState = ViewerPairingState(store: store)
        let transport = PairedAvailabilityTransportStub(suspendFirstSendUntilClose: true)
        let clock = AvailabilityRetryClockStub()
        let deadline = AvailabilityAttemptDeadlineStub()
        let coordinator = WorldwideViewerConnectionCoordinator(
            availabilityClientFactory: { _, _ in transport },
            availabilityRetryDeadlineNanoseconds: 100,
            availabilityMonotonicNow: clock.now,
            availabilityRetrySleep: clock.sleep,
            availabilityAttemptDeadlineSleep: deadline.sleep
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test/rendezvous"))
        let exchangeID = try RemoteAvailabilityExchangeID(
            wireValue: "AAAAAAAAAAAAAAAAAAAAAA"
        )

        let task = Task { @MainActor in
            try await coordinator.preparePairedMediaSession(
                endpoint: endpoint,
                pairingState: pairingState,
                onAuthenticatedPairingCompleted: {}
            )
        }
        try await waitForConnect(transport)
        await transport.yield(.ready(role: .viewer, exchangeID: exchangeID))
        try await waitForFirstSendSuspension(transport)

        // Force close to win after `.ready` was dequeued but before its first payload can send.
        // The production transport reports `.notConnected` at this boundary; it is a transient
        // consequence of the authoritative deadline, not a reason to discard or indict the pair.
        clock.advance(by: 100)
        await deadline.fire()

        let outcome = await boundedPairedMediaAttemptOutcome(task)
        XCTAssertEqual(
            outcome,
            .failure(nil),
            "The low-level close race remains a signaling error while UI state is normalized below"
        )
        XCTAssertEqual(pairingState.pairedMac, activeRecord)
        guard case .unavailableAfterDeadline(let attempt) = coordinator.savedPairConnectionState else {
            return XCTFail("Deadline-close send races must retain the pair as unavailable")
        }
        XCTAssertEqual(attempt.pairID, activeRecord.pairID)
        XCTAssertNil(coordinator.lastError)
        XCTAssertEqual(coordinator.stateText, "Paired Mac unavailable")
        let closeCount = await transport.closeCallCount()
        XCTAssertGreaterThanOrEqual(closeCount, 1)
    }

    func testReconnectResponseAtAbsoluteDeadlineCannotStartMedia() async throws {
        let viewerIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let records = try makePairingRecords(viewerIdentity: viewerIdentity)
        let store = ViewerPairingStoreStub(identity: viewerIdentity)
        store.record = records.viewerActive
        let pairingState = ViewerPairingState(store: store)
        var hostRecord = records.hostAcceptedReceived
        guard case .resend(let durableActivation) = records.viewerActive.recoveryAction else {
            return XCTFail("Active viewer fixture must carry its durable activation proof")
        }
        try hostRecord.acceptActivationAcknowledgement(durableActivation)

        let transport = PairedAvailabilityTransportStub()
        let clock = AvailabilityRetryClockStub()
        let coordinator = WorldwideViewerConnectionCoordinator(
            availabilityClientFactory: { _, _ in transport },
            availabilityRetryDeadlineNanoseconds: 100,
            availabilityMonotonicNow: clock.now,
            availabilityRetrySleep: clock.sleep,
            availabilityAttemptDeadlineSleep: { _ in
                try await Task<Never, Never>.sleep(nanoseconds: 10_000_000_000)
            },
            reconnectResponseTimeoutSleep: { _ in
                try await Task<Never, Never>.sleep(nanoseconds: 10_000_000_000)
            }
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test"))
        let exchangeID = try RemoteAvailabilityExchangeID(
            wireValue: "AAAAAAAAAAAAAAAAAAAAAA"
        )

        let task = Task { @MainActor in
            try await coordinator.preparePairedMediaSession(
                endpoint: endpoint,
                pairingState: pairingState,
                onAuthenticatedPairingCompleted: {}
            )
        }
        try await waitForConnect(transport)
        await transport.yield(.ready(role: .viewer, exchangeID: exchangeID))
        try await waitForSentPayloadCount(2, client: transport)
        let payloads = await transport.sentPayloadsSnapshot()
        guard case .pairingCommit(let activation) = payloads[0],
              case .reconnectRequest(let request) = payloads[1] else {
            coordinator.cancel()
            _ = await task.result
            return XCTFail("Expected activation proof followed by reconnect request")
        }
        try hostRecord.acceptActivationAcknowledgement(activation)
        let responder = try hostRecord.respond(to: request, using: records.hostIdentity)

        // The response is cryptographically valid, but it arrives on the exact monotonic
        // boundary. It must not resurrect an availability attempt whose budget is exhausted.
        clock.advance(by: 100)
        await transport.yield(.signal(.reconnectResponse(responder.response)))

        let outcome = await boundedPairedMediaAttemptOutcome(task)
        XCTAssertEqual(
            outcome,
            .failure(.pairedMacUnavailable),
            "A reconnect response at the absolute deadline must not start media"
        )
        XCTAssertEqual(pairingState.pairedMac?.pairID, records.viewerActive.pairID)
        guard case .unavailableAfterDeadline(let attempt) = coordinator.savedPairConnectionState else {
            return XCTFail("Boundary exhaustion must publish retained-pair recovery")
        }
        XCTAssertEqual(attempt.pairID, records.viewerActive.pairID)
        XCTAssertNil(coordinator.lastError)
    }

    func testFreshAttemptRetiresTerminalMediaHistoryButPassiveLifecycleDoesNot() {
        let viewModel = WorldwideSessionViewModel()
        viewModel.debugFailSessionForTests("Previous terminal media error")
        XCTAssertEqual(viewModel.lastError, "Previous terminal media error")

        viewModel.handleAppBecameInactive()
        viewModel.handleAppEnteredBackground()
        viewModel.handleAppBecameActive()
        XCTAssertEqual(
            viewModel.lastError,
            "Previous terminal media error",
            "Passive lifecycle events must not silently rewrite a real outcome"
        )

        viewModel.beginFreshConnectionAttempt()
        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(viewModel.stateText, "Not connected")
    }

    func testAvailabilityRetryUsesThirtySecondDeadlineAndFourSecondCap() async throws {
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let activeRecord = try makePairedMacRecord(localIdentity: identity)
        let store = ViewerPairingStoreStub(identity: identity)
        store.record = activeRecord
        let pairingState = ViewerPairingState(store: store)
        let clock = AvailabilityRetryClockStub()
        var clients: [PairedAvailabilityTransportStub] = []
        let coordinator = WorldwideViewerConnectionCoordinator(
            availabilityClientFactory: { _, _ in
                let client = PairedAvailabilityTransportStub(
                    connectError: .connectionFailed
                )
                clients.append(client)
                return client
            },
            availabilityRetryDeadlineNanoseconds: 30_000_000_000,
            availabilityMonotonicNow: clock.now,
            availabilityRetrySleep: clock.sleep
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test/rendezvous"))

        do {
            _ = try await coordinator.preparePairedMediaSession(
                endpoint: endpoint,
                pairingState: pairingState,
                onAuthenticatedPairingCompleted: {}
            )
            XCTFail("Expected the availability deadline to be exhausted")
        } catch {
            XCTAssertEqual(error as? RendezvousSignalingError, .connectionFailed)
        }

        XCTAssertEqual(clock.now(), 30_000_000_000)
        XCTAssertEqual(clients.count, 11)
        XCTAssertEqual(
            clock.recordedBaseDelays(),
            [
                250_000_000,
                500_000_000,
                1_000_000_000,
                2_000_000_000,
                4_000_000_000,
                4_000_000_000,
                4_000_000_000,
                4_000_000_000,
                4_000_000_000,
                4_000_000_000,
                4_000_000_000
            ]
        )
        XCTAssertFalse(coordinator.isConnecting)
        XCTAssertEqual(pairingState.pairedMac, activeRecord)
        guard case .unavailableAfterDeadline(let attempt) = coordinator.savedPairConnectionState else {
            return XCTFail("Deadline exhaustion must publish retained-pair recovery")
        }
        XCTAssertEqual(attempt.pairID, activeRecord.pairID)
        XCTAssertNil(coordinator.lastError)
        XCTAssertEqual(coordinator.stateText, "Paired Mac unavailable")
        for client in clients {
            let closeCount = await client.closeCallCount()
            XCTAssertEqual(closeCount, 1)
        }
    }

    func testAvailabilityRetrySleepIsCancellableWithoutLosingPairing() async throws {
        let identity = try RemoteDeviceIdentity.generate(role: .viewer)
        let activeRecord = try makePairedMacRecord(localIdentity: identity)
        let store = ViewerPairingStoreStub(identity: identity)
        store.record = activeRecord
        let pairingState = ViewerPairingState(store: store)
        let clock = AvailabilityRetryClockStub(blocksUntilCancelled: true)
        let telemetry = ViewerConnectionTelemetryRecorderStub()
        var factoryCallCount = 0
        let coordinator = WorldwideViewerConnectionCoordinator(
            availabilityClientFactory: { _, _ in
                factoryCallCount += 1
                return PairedAvailabilityTransportStub(
                    connectError: .connectionFailed
                )
            },
            availabilityMonotonicNow: clock.now,
            availabilityRetrySleep: clock.sleep,
            connectionTelemetry: telemetry
        )
        let endpoint = try XCTUnwrap(URL(string: "wss://example.test/rendezvous"))

        let task = Task { @MainActor in
            try await coordinator.preparePairedMediaSession(
                endpoint: endpoint,
                pairingState: pairingState,
                onAuthenticatedPairingCompleted: {}
            )
        }
        try await waitForRetrySleep(clock)

        task.cancel()
        coordinator.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation during retry backoff")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(factoryCallCount, 1)
        XCTAssertFalse(coordinator.isConnecting)
        XCTAssertEqual(pairingState.pairedMac, activeRecord)
        XCTAssertEqual(
            telemetry.snapshot().events.map(\.stage),
            [
                .attemptStarted,
                .availabilitySocketOpening,
                .retryScheduled,
                .attemptCancelled,
            ]
        )
        XCTAssertEqual(
            telemetry.snapshot().events.filter { $0.terminal != nil }.count,
            1,
            "Cancel and the resumed task catch must share one terminal oracle"
        )
        XCTAssertEqual(coordinator.savedPairConnectionState, .idle)
    }
}

func makePairedMacRecord() throws -> RemotePairedDeviceRecord {
    try makePairedMacRecord(
        localIdentity: RemoteDeviceIdentity.generate(role: .viewer)
    )
}

func makePairedMacRecord(
    localIdentity: RemoteDeviceIdentity,
    pairingState: RemotePairingPersistenceState = .active
) throws -> RemotePairedDeviceRecord {
    let records = try makePairingRecords(viewerIdentity: localIdentity)
    return switch pairingState {
    case .pending:
        records.viewerPending
    case .acceptedIssued:
        records.viewerAcceptedIssued
    case .active:
        records.viewerActive
    case .acceptedReceived:
        throw RemoteSessionCoreError.invalidPairedDeviceRecord
    }
}

// MARK: - Pairing fixtures and controllable transports

/// Consistent viewer/host records used to model each durable distributed-commit phase.
private struct PairingRecords {
    let hostIdentity: RemoteDeviceIdentity
    let viewerPending: RemotePairedDeviceRecord
    let viewerAcceptedIssued: RemotePairedDeviceRecord
    let viewerActive: RemotePairedDeviceRecord
    let hostAcceptedReceived: RemotePairedDeviceRecord
}

private func makePairingRecords(
    viewerIdentity: RemoteDeviceIdentity
) throws -> PairingRecords {
    let invitation = try RemoteInvitationCode.generate()
    let hostIdentity = try RemoteDeviceIdentity.generate(
        role: .host,
        displayName: "Test Mac"
    )
    let hostParticipant = try RemotePairingParticipant(
        identity: hostIdentity,
        invitation: invitation
    )
    let viewerParticipant = try RemotePairingParticipant(
        identity: viewerIdentity,
        invitation: invitation
    )
    let hostAgreement = try hostParticipant.accept(viewerParticipant.hello)
    let viewerAgreement = try viewerParticipant.accept(hostParticipant.hello)
    let hostConfirmation = try hostAgreement.makeConfirmation()
    let viewerConfirmation = try viewerAgreement.makeConfirmation()

    let viewerPending = try viewerAgreement.makePendingRecord(
        peerConfirmation: hostConfirmation
    )
    var hostRecord = try hostAgreement.makePendingRecord(
        peerConfirmation: viewerConfirmation
    )
    let proposal = try hostRecord.prepareProposal(using: hostIdentity)

    var viewerAcceptedIssued = viewerPending
    let acknowledgement = try viewerAcceptedIssued.prepareAcknowledgement(
        after: proposal,
        using: viewerIdentity
    )

    try hostRecord.acceptAcknowledgement(acknowledgement)
    let completion = try hostRecord.prepareCompletion(using: hostIdentity)
    let hostAcceptedReceived = hostRecord

    var viewerActive = viewerAcceptedIssued
    _ = try viewerActive.acceptCompletion(
        completion,
        using: viewerIdentity
    )

    return PairingRecords(
        hostIdentity: hostIdentity,
        viewerPending: viewerPending,
        viewerAcceptedIssued: viewerAcceptedIssued,
        viewerActive: viewerActive,
        hostAcceptedReceived: hostAcceptedReceived
    )
}

/// Actor-backed bootstrap transport whose suspension points make cancellation races deterministic.
private actor PairingBootstrapTransportStub: ViewerPairingBootstrapTransport {
    private let stream: PairingBootstrapSignalingClient.EventStream
    private let continuation: PairingBootstrapSignalingClient.EventStream.Continuation
    private var connectCount = 0
    private var closeCount = 0
    private var sentPayloads: [RemotePairingPayload] = []
    private var shouldSuspendClose: Bool
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private var shouldSuspendViewerConfirmationSend: Bool
    private var viewerConfirmationSendContinuation: CheckedContinuation<Void, Never>?

    init(
        suspendClose: Bool = false,
        suspendViewerConfirmationSend: Bool = false
    ) {
        let pair = PairingBootstrapSignalingClient.EventStream.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        shouldSuspendClose = suspendClose
        shouldSuspendViewerConfirmationSend = suspendViewerConfirmationSend
    }

    func connect() async throws -> PairingBootstrapSignalingClient.EventStream {
        connectCount += 1
        return stream
    }

    func send(_ payload: RemotePairingPayload) async throws {
        sentPayloads.append(payload)
        if shouldSuspendViewerConfirmationSend,
           case .confirmation = payload {
            await withCheckedContinuation { continuation in
                viewerConfirmationSendContinuation = continuation
            }
        }
    }

    func close() async {
        closeCount += 1
        if shouldSuspendClose {
            await withCheckedContinuation { continuation in
                closeContinuation = continuation
            }
        }
        continuation.finish()
    }

    func resumeClose() {
        shouldSuspendClose = false
        let pending = closeContinuation
        closeContinuation = nil
        pending?.resume()
    }

    func viewerConfirmationSendIsSuspended() -> Bool {
        viewerConfirmationSendContinuation != nil
    }

    func resumeViewerConfirmationSend() {
        shouldSuspendViewerConfirmationSend = false
        let pending = viewerConfirmationSendContinuation
        viewerConfirmationSendContinuation = nil
        pending?.resume()
    }

    func connectCallCount() -> Int { connectCount }
    func closeCallCount() -> Int { closeCount }
    func sentPayloadsSnapshot() -> [RemotePairingPayload] { sentPayloads }

    func yield(_ event: PairingBootstrapSignalingEvent) {
        continuation.yield(event)
    }
}

@MainActor
private final class PairingBackgroundTaskStub: TransitionBackgroundTaskCoordinating {
    private(set) var beginCount = 0
    private(set) var endCount = 0

    func beginTransitionTask() {
        beginCount += 1
    }

    func endTransitionTask() {
        endCount += 1
    }
}

private actor PairedAvailabilityTransportStub: ViewerPairedAvailabilityTransport {
    private let stream: PairedAvailabilitySignalingClient.EventStream
    private let continuation: PairedAvailabilitySignalingClient.EventStream.Continuation
    private let connectError: RendezvousSignalingError?
    private let suspendReconnectSend: Bool
    private let suspendActivationSend: Bool
    private let suspendFirstSendUntilClose: Bool
    private var connectCount = 0
    private var closeCount = 0
    private var isClosed = false
    private var sentPayloads: [RemoteAvailabilityPayload] = []
    private var didSuspendFirstSend = false
    private var firstSendContinuation: CheckedContinuation<Void, Never>?
    private var reconnectSendContinuation: CheckedContinuation<Void, any Error>?
    private var activationSendContinuation: CheckedContinuation<Void, any Error>?

    init(
        connectError: RendezvousSignalingError? = nil,
        suspendReconnectSend: Bool = false,
        suspendActivationSend: Bool = false,
        suspendFirstSendUntilClose: Bool = false
    ) {
        let pair = PairedAvailabilitySignalingClient.EventStream.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        self.connectError = connectError
        self.suspendReconnectSend = suspendReconnectSend
        self.suspendActivationSend = suspendActivationSend
        self.suspendFirstSendUntilClose = suspendFirstSendUntilClose
    }

    func connect() async throws -> PairedAvailabilitySignalingClient.EventStream {
        connectCount += 1
        if let connectError { throw connectError }
        return stream
    }

    func send(_ payload: RemoteAvailabilityPayload) async throws {
        if suspendFirstSendUntilClose, !didSuspendFirstSend {
            didSuspendFirstSend = true
            await withCheckedContinuation { continuation in
                firstSendContinuation = continuation
            }
        }
        guard !isClosed else { throw RendezvousSignalingError.notConnected }
        sentPayloads.append(payload)
        if suspendReconnectSend, case .reconnectRequest = payload {
            try await withCheckedThrowingContinuation { continuation in
                reconnectSendContinuation = continuation
            }
        }
        if suspendActivationSend,
           case .pairingCommit(let commit) = payload,
           commit.phase == .activationAcknowledgement {
            try await withCheckedThrowingContinuation { continuation in
                activationSendContinuation = continuation
            }
        }
    }

    func close() async {
        closeCount += 1
        isClosed = true
        let suspendedFirstSend = firstSendContinuation
        firstSendContinuation = nil
        suspendedFirstSend?.resume()
        let suspendedSend = reconnectSendContinuation
        reconnectSendContinuation = nil
        suspendedSend?.resume(throwing: RendezvousSignalingError.sendFailed)
        let suspendedActivation = activationSendContinuation
        activationSendContinuation = nil
        suspendedActivation?.resume(throwing: RendezvousSignalingError.sendFailed)
        continuation.finish()
    }

    func connectCallCount() -> Int { connectCount }
    func closeCallCount() -> Int { closeCount }
    func sentPayloadsSnapshot() -> [RemoteAvailabilityPayload] { sentPayloads }
    func activationSendIsSuspended() -> Bool { activationSendContinuation != nil }
    func firstSendIsSuspended() -> Bool { firstSendContinuation != nil }

    func resumeActivationSend() {
        let suspendedActivation = activationSendContinuation
        activationSendContinuation = nil
        suspendedActivation?.resume()
    }

    func yield(_ event: PairedAvailabilitySignalingEvent) {
        continuation.yield(event)
    }
}

private final class AvailabilityRetryClockStub: @unchecked Sendable {
    private let lock = NSLock()
    private let blocksUntilCancelled: Bool
    private var currentNanoseconds: UInt64 = 0
    private var baseDelays: [UInt64] = []

    init(blocksUntilCancelled: Bool = false) {
        self.blocksUntilCancelled = blocksUntilCancelled
    }

    func now() -> UInt64 {
        lock.withLock { currentNanoseconds }
    }

    func sleep(baseDelay: UInt64, remaining: UInt64) async throws {
        try Task.checkCancellation()
        record(baseDelay: baseDelay)
        if blocksUntilCancelled {
            try await Task<Never, Never>.sleep(nanoseconds: 10_000_000_000)
            return
        }
        advance(by: min(baseDelay, remaining))
    }

    func recordedBaseDelays() -> [UInt64] {
        lock.withLock { baseDelays }
    }

    func sleepCallCount() -> Int {
        lock.withLock { baseDelays.count }
    }

    private func record(baseDelay: UInt64) {
        lock.withLock { baseDelays.append(baseDelay) }
    }

    func advance(by delta: UInt64) {
        lock.withLock { currentNanoseconds += delta }
    }
}

private actor AvailabilityAttemptDeadlineStub {
    private var timeoutNanoseconds: UInt64?
    private var continuation: CheckedContinuation<Void, Never>?

    func sleep(_ timeoutNanoseconds: UInt64) async throws {
        self.timeoutNanoseconds = timeoutNanoseconds
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancelPendingSleep() }
        }
    }

    func armedTimeout() -> UInt64? { timeoutNanoseconds }

    func fire() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    private func cancelPendingSleep() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

private enum PairedMediaAttemptOutcome: Equatable, Sendable {
    case success
    case failure(WorldwideViewerConnectionError?)
    case timedOut
}

private func boundedPairedMediaAttemptOutcome(
    _ task: Task<RendezvousSignalingClient, any Error>,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async -> PairedMediaAttemptOutcome {
    await withTaskGroup(of: PairedMediaAttemptOutcome.self) { group in
        group.addTask {
            do {
                _ = try await task.value
                return .success
            } catch {
                return .failure(error as? WorldwideViewerConnectionError)
            }
        }
        group.addTask {
            do {
                try await Task<Never, Never>.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return .timedOut
            }
            return .timedOut
        }

        let outcome = await group.next() ?? .timedOut
        if outcome == .timedOut {
            task.cancel()
        }
        group.cancelAll()
        return outcome
    }
}

private final class ReconnectResponseTimeoutStub: @unchecked Sendable {
    private let lock = NSLock()
    private let timeoutsBeforeBlocking: Int
    private let timeoutDelayNanoseconds: UInt64
    private var callCount = 0

    init(
        timeoutsBeforeBlocking: Int,
        timeoutDelayNanoseconds: UInt64 = 0
    ) {
        self.timeoutsBeforeBlocking = timeoutsBeforeBlocking
        self.timeoutDelayNanoseconds = timeoutDelayNanoseconds
    }

    func sleep(_ timeoutNanoseconds: UInt64) async throws {
        _ = timeoutNanoseconds
        let shouldTimeout = lock.withLock { () -> Bool in
            callCount += 1
            return callCount <= timeoutsBeforeBlocking
        }
        if shouldTimeout {
            if timeoutDelayNanoseconds > 0 {
                try await Task<Never, Never>.sleep(nanoseconds: timeoutDelayNanoseconds)
            }
            return
        }
        try await Task<Never, Never>.sleep(nanoseconds: 10_000_000_000)
    }
}

private func reconnectRequest(
    in payloads: [RemoteAvailabilityPayload]
) -> RemoteReconnectRequest? {
    for payload in payloads {
        if case .reconnectRequest(let request) = payload {
            return request
        }
    }
    return nil
}

private func reconnectRequests(
    in payloads: [RemoteAvailabilityPayload]
) -> [RemoteReconnectRequest] {
    payloads.compactMap { payload in
        guard case .reconnectRequest(let request) = payload else { return nil }
        return request
    }
}

private func waitForConnect(
    _ client: PairingBootstrapTransportStub
) async throws {
    for _ in 0..<500 {
        if await client.connectCallCount() > 0 { return }
        try await Task<Never, Never>.sleep(nanoseconds: 2_000_000)
    }
    throw PairingTestFailure.timeout
}

private func waitForSentPayloadCount(
    _ expectedCount: Int,
    client: PairingBootstrapTransportStub
) async throws {
    for _ in 0..<500 {
        if await client.sentPayloadsSnapshot().count >= expectedCount { return }
        try await Task<Never, Never>.sleep(nanoseconds: 2_000_000)
    }
    throw PairingTestFailure.timeout
}

private func waitForViewerConfirmationSendSuspension(
    _ client: PairingBootstrapTransportStub
) async throws {
    for _ in 0..<500 {
        if await client.viewerConfirmationSendIsSuspended() { return }
        try await Task<Never, Never>.sleep(nanoseconds: 2_000_000)
    }
    throw PairingTestFailure.timeout
}

private func waitForActivationSendSuspension(
    _ client: PairedAvailabilityTransportStub
) async throws {
    for _ in 0..<500 {
        if await client.activationSendIsSuspended() { return }
        try await Task<Never, Never>.sleep(nanoseconds: 2_000_000)
    }
    throw PairingTestFailure.timeout
}

private func waitForFirstSendSuspension(
    _ client: PairedAvailabilityTransportStub
) async throws {
    for _ in 0..<500 {
        if await client.firstSendIsSuspended() { return }
        try await Task<Never, Never>.sleep(nanoseconds: 2_000_000)
    }
    throw PairingTestFailure.timeout
}

private func driveBootstrapPairingToCompletion(
    client: PairingBootstrapTransportStub,
    invitation: RemoteInvitationCode
) async throws {
    let hostIdentity = try RemoteDeviceIdentity.generate(role: .host)
    let hostParticipant = try RemotePairingParticipant(
        identity: hostIdentity,
        invitation: invitation
    )

    try await waitForConnect(client)
    await client.yield(
        .ready(role: .viewer, invitationExpiresAt: Date().addingTimeInterval(60))
    )
    try await waitForSentPayloadCount(1, client: client)
    let helloPayloads = await client.sentPayloadsSnapshot()
    guard case .hello(let viewerHello) = helloPayloads[0] else {
        throw PairingTestFailure.unexpectedPayload
    }
    let hostAgreement = try hostParticipant.accept(viewerHello)

    await client.yield(.signal(.hello(hostParticipant.hello)))
    await client.yield(
        .signal(.confirmation(try hostAgreement.makeConfirmation()))
    )
    try await waitForSentPayloadCount(2, client: client)
    let confirmationPayloads = await client.sentPayloadsSnapshot()
    guard case .confirmation(let viewerConfirmation) = confirmationPayloads[1] else {
        throw PairingTestFailure.unexpectedPayload
    }

    var hostRecord = try hostAgreement.makePendingRecord(
        peerConfirmation: viewerConfirmation
    )
    let proposal = try hostRecord.prepareProposal(using: hostIdentity)
    await client.yield(.signal(.commit(proposal)))
    try await waitForSentPayloadCount(3, client: client)
    let acknowledgementPayloads = await client.sentPayloadsSnapshot()
    guard case .commit(let acknowledgement) = acknowledgementPayloads[2] else {
        throw PairingTestFailure.unexpectedPayload
    }
    try hostRecord.acceptAcknowledgement(acknowledgement)

    let completion = try hostRecord.prepareCompletion(using: hostIdentity)
    await client.yield(.signal(.commit(completion)))
    try await waitForSentPayloadCount(4, client: client)
    let activationPayloads = await client.sentPayloadsSnapshot()
    guard case .commit(let activation) = activationPayloads[3] else {
        throw PairingTestFailure.unexpectedPayload
    }
    try hostRecord.acceptActivationAcknowledgement(activation)
}

private func waitForRetrySleep(
    _ clock: AvailabilityRetryClockStub
) async throws {
    for _ in 0..<500 {
        if clock.sleepCallCount() > 0 { return }
        try await Task<Never, Never>.sleep(nanoseconds: 2_000_000)
    }
    throw PairingTestFailure.timeout
}

private func waitForAvailabilityDeadline(
    _ deadline: AvailabilityAttemptDeadlineStub
) async throws {
    for _ in 0..<500 {
        if await deadline.armedTimeout() != nil { return }
        try await Task<Never, Never>.sleep(nanoseconds: 2_000_000)
    }
    throw PairingTestFailure.timeout
}

private func waitForTelemetryStage(
    _ stage: ConnectionTelemetryStage,
    recorder: ViewerConnectionTelemetryRecorderStub
) async throws {
    for _ in 0..<500 {
        if recorder.snapshot().events.contains(where: { $0.stage == stage }) { return }
        try await Task<Never, Never>.sleep(nanoseconds: 2_000_000)
    }
    throw PairingTestFailure.timeout
}

private func waitForConnect(
    _ client: PairedAvailabilityTransportStub
) async throws {
    for _ in 0..<500 {
        if await client.connectCallCount() > 0 { return }
        try await Task<Never, Never>.sleep(nanoseconds: 2_000_000)
    }
    throw PairingTestFailure.timeout
}

private func waitForSentPayloadCount(
    _ expectedCount: Int,
    client: PairedAvailabilityTransportStub
) async throws {
    for _ in 0..<500 {
        if await client.sentPayloadsSnapshot().count >= expectedCount { return }
        try await Task<Never, Never>.sleep(nanoseconds: 2_000_000)
    }
    throw PairingTestFailure.timeout
}

private final class ViewerPairingStoreStub: ViewerPairingStoring {
    let identity: RemoteDeviceIdentity
    var record: RemotePairedDeviceRecord?
    var saveError: (any Error)?
    var loadIdentityError: (any Error)?
    var onSave: () -> Void
    private(set) var identityLoadCount = 0
    private(set) var deleteCount = 0
    private(set) var saveCount = 0
    private(set) var savedRecords: [RemotePairedDeviceRecord] = []

    init(identity: RemoteDeviceIdentity, onSave: @escaping () -> Void = {}) {
        self.identity = identity
        self.onSave = onSave
    }

    func loadOrCreateViewerIdentity() throws -> RemoteDeviceIdentity {
        identityLoadCount += 1
        if let loadIdentityError { throw loadIdentityError }
        return identity
    }

    func loadPairedMac(for identity: RemoteDeviceIdentity) throws -> RemotePairedDeviceRecord? {
        record
    }

    func savePairedMac(
        _ record: RemotePairedDeviceRecord,
        for identity: RemoteDeviceIdentity
    ) throws {
        if let saveError { throw saveError }
        onSave()
        saveCount += 1
        savedRecords.append(record)
        self.record = record
    }

    func deletePairedMac() throws {
        deleteCount += 1
        record = nil
    }
}

private final class PairingNamespaceStoreSpy: ViewerPairingNamespaceStoring {
    private(set) var snapshot: ViewerPairingNamespaceSnapshot
    var snapshotError: (any Error)?
    let identityToCreate: RemoteDeviceIdentity?
    let label: String?
    let operationRecorder: PairingNamespaceOperationRecorder?
    private(set) var snapshotLoadCount = 0
    private(set) var createIdentityCount = 0
    private(set) var preserveIdentityCount = 0
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    init(
        snapshot: ViewerPairingNamespaceSnapshot,
        identityToCreate: RemoteDeviceIdentity? = nil,
        label: String? = nil,
        operationRecorder: PairingNamespaceOperationRecorder? = nil
    ) {
        self.snapshot = snapshot
        self.identityToCreate = identityToCreate
        self.label = label
        self.operationRecorder = operationRecorder
    }

    func loadNamespaceSnapshot() throws -> ViewerPairingNamespaceSnapshot {
        record("snapshot")
        snapshotLoadCount += 1
        if let snapshotError { throw snapshotError }
        return snapshot
    }

    func loadOrCreateViewerIdentity() throws -> RemoteDeviceIdentity {
        record("create-identity")
        createIdentityCount += 1
        if let identity = snapshot.identity {
            return identity
        }
        guard let identityToCreate else {
            throw PairingTestFailure.load
        }
        snapshot = try pairingNamespaceSnapshot(
            identity: identityToCreate,
            record: nil
        )
        return identityToCreate
    }

    func preserveViewerIdentity(
        _ identity: RemoteDeviceIdentity,
        encodedIdentity: Data
    ) throws {
        record("preserve-identity")
        preserveIdentityCount += 1
        if let existingIdentity = snapshot.identity {
            guard existingIdentity == identity else {
                throw ViewerPairingStoreError.viewerIdentityConflict
            }
            return
        }
        snapshot = ViewerPairingNamespaceSnapshot(
            identity: identity,
            encodedIdentity: encodedIdentity,
            pairedMac: nil
        )
    }

    func savePairedMac(
        _ record: RemotePairedDeviceRecord,
        for identity: RemoteDeviceIdentity
    ) throws {
        self.record("save-pair")
        saveCount += 1
        guard snapshot.identity == identity,
              let encodedIdentity = snapshot.encodedIdentity else {
            throw ViewerPairingStoreError.invalidViewerIdentity
        }
        snapshot = ViewerPairingNamespaceSnapshot(
            identity: identity,
            encodedIdentity: encodedIdentity,
            pairedMac: record
        )
    }

    func deletePairedMac() throws {
        record("delete-pair")
        deleteCount += 1
        snapshot = ViewerPairingNamespaceSnapshot(
            identity: snapshot.identity,
            encodedIdentity: snapshot.encodedIdentity,
            pairedMac: nil
        )
    }

    private func record(_ operation: String) {
        guard let label else { return }
        operationRecorder?.operations.append("\(label).\(operation)")
    }
}

private final class PairingNamespaceOperationRecorder {
    var operations: [String] = []
}

private func pairingNamespaceSnapshot(
    identity: RemoteDeviceIdentity,
    record: RemotePairedDeviceRecord?
) throws -> ViewerPairingNamespaceSnapshot {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return ViewerPairingNamespaceSnapshot(
        identity: identity,
        encodedIdentity: try encoder.encode(identity),
        pairedMac: record
    )
}

private func makeNamespaceSelector(
    primaryItems: PairingKeychainItems,
    legacyItems: PairingKeychainItems
) -> ViewerPairingNamespaceSelectorStore {
    ViewerPairingNamespaceSelectorStore(
        primaryStore: ViewerPairingKeychainStore(
            identityItem: primaryItems.identity,
            pairedMacItem: primaryItems.pairedMac
        ),
        legacyStore: ViewerPairingKeychainStore(
            identityItem: legacyItems.identity,
            pairedMacItem: legacyItems.pairedMac
        )
    )
}

private func seedPairingNamespace(
    items: PairingKeychainItems,
    identity: RemoteDeviceIdentity,
    record: RemotePairedDeviceRecord?
) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try KeychainStore(item: items.identity).saveData(try encoder.encode(identity))
    if let record {
        try KeychainStore(item: items.pairedMac).saveData(try encoder.encode(record))
    }
}

private final class WorldwideInvitationAdmissionStoreStub:
    WorldwideInvitationAdmissionStoring {
    var digest: Data?
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    func loadAdmittedInvitationDigest() throws -> Data? { digest }

    func saveAdmittedInvitationDigest(_ digest: Data) throws {
        saveCount += 1
        self.digest = digest
    }

    func deleteAdmittedInvitationDigest() throws {
        deleteCount += 1
        digest = nil
    }
}

private struct PairingKeychainItems {
    let identity: KeychainStore.Item
    let pairedMac: KeychainStore.Item
    let invitationCode: KeychainStore.Item
    let admissionMarker: KeychainStore.Item
}

private func makeKeychainItems(testName: String) -> PairingKeychainItems {
    let suffix = "\(testName)-\(UUID().uuidString)"
    return PairingKeychainItems(
        identity: KeychainStore.Item(
            service: "org.example.opensteamer.viewer-pairing-tests",
            account: "identity-\(suffix)"
        ),
        pairedMac: KeychainStore.Item(
            service: "org.example.opensteamer.viewer-pairing-tests",
            account: "paired-mac-\(suffix)"
        ),
        invitationCode: KeychainStore.Item(
            service: "org.example.opensteamer.viewer-pairing-tests",
            account: "invitation-code-\(suffix)"
        ),
        admissionMarker: KeychainStore.Item(
            service: "org.example.opensteamer.viewer-pairing-tests",
            account: "admission-marker-\(suffix)"
        )
    )
}

private func deleteKeychainItems(_ items: PairingKeychainItems) {
    try? KeychainStore(item: items.identity).deleteData()
    try? KeychainStore(item: items.pairedMac).deleteData()
    try? KeychainStore(item: items.invitationCode).deleteData()
    try? KeychainStore(item: items.admissionMarker).deleteData()
}

private func assertThisDeviceOnly(
    item: KeychainStore.Item,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: item.service,
        kSecAttrAccount as String: item.account,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    XCTAssertEqual(status, errSecSuccess, file: file, line: line)
    let attributes = try XCTUnwrap(result as? [String: Any], file: file, line: line)
    XCTAssertEqual(
        attributes[kSecAttrAccessible as String] as? String,
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
        file: file,
        line: line
    )
}

private final class ViewerConnectionTelemetryRecorderStub:
    ConnectionTelemetryRecording,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var events: [ConnectionTelemetryEvent] = []

    func record(_ draft: ConnectionTelemetryDraft) -> ConnectionTelemetrySnapshot {
        lock.withLock {
            events.append(
                ConnectionTelemetryEvent(
                    id: UInt64(events.count + 1),
                    timestamp: Date(timeIntervalSince1970: 0),
                    monotonicNanoseconds: UInt64(events.count),
                    role: draft.role,
                    stage: draft.stage,
                    attemptReference: draft.attemptReference,
                    pairReference: draft.pairReference,
                    exchangeReference: draft.exchangeReference,
                    retryOrdinal: draft.retryOrdinal,
                    delayMilliseconds: draft.delayMilliseconds,
                    failure: draft.failure,
                    terminal: draft.terminal
                )
            )
            return snapshotLocked()
        }
    }

    func snapshot() -> ConnectionTelemetrySnapshot {
        lock.withLock { snapshotLocked() }
    }

    private func snapshotLocked() -> ConnectionTelemetrySnapshot {
        ConnectionTelemetrySnapshot(
            events: events,
            droppedEventCount: 0,
            persistenceHealthy: true
        )
    }
}

private enum PairingTestFailure: Error {
    case save
    case load
    case timeout
    case unexpectedPayload
}
