import Foundation
import RemoteSessionCore
import Security
import XCTest
@testable import AudioStreamer

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
        let coordinator = WorldwideViewerConnectionCoordinator(
            bootstrapClientFactory: { _, _ in bootstrap },
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
        try await waitForConnect(bootstrap)
        await bootstrap.yield(.serverError(.peerUnavailable))
        try await waitForConnect(availability)

        let bootstrapCloseCount = await bootstrap.closeCallCount()
        XCTAssertEqual(bootstrapCloseCount, 1)
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
        XCTAssertTrue(clients.isEmpty)
        let firstCloseCount = await firstClient.closeCallCount()
        let retryCloseCount = await retryClient.closeCallCount()
        XCTAssertEqual(firstCloseCount, 1)
        XCTAssertEqual(retryCloseCount, 0)
        XCTAssertEqual(clock.recordedBaseDelays(), [250_000_000])

        coordinator.cancel()
        _ = await task.result
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
        var factoryCallCount = 0
        let coordinator = WorldwideViewerConnectionCoordinator(
            availabilityClientFactory: { _, _ in
                factoryCallCount += 1
                return PairedAvailabilityTransportStub(
                    connectError: .connectionFailed
                )
            },
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

private struct PairingRecords {
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
        viewerPending: viewerPending,
        viewerAcceptedIssued: viewerAcceptedIssued,
        viewerActive: viewerActive,
        hostAcceptedReceived: hostAcceptedReceived
    )
}

private actor PairingBootstrapTransportStub: ViewerPairingBootstrapTransport {
    private let stream: PairingBootstrapSignalingClient.EventStream
    private let continuation: PairingBootstrapSignalingClient.EventStream.Continuation
    private var connectCount = 0
    private var closeCount = 0
    private var sentPayloads: [RemotePairingPayload] = []
    private var shouldSuspendClose: Bool
    private var closeContinuation: CheckedContinuation<Void, Never>?

    init(suspendClose: Bool = false) {
        let pair = PairingBootstrapSignalingClient.EventStream.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        shouldSuspendClose = suspendClose
    }

    func connect() async throws -> PairingBootstrapSignalingClient.EventStream {
        connectCount += 1
        return stream
    }

    func send(_ payload: RemotePairingPayload) async throws {
        sentPayloads.append(payload)
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
    private var connectCount = 0
    private var closeCount = 0
    private var sentPayloads: [RemoteAvailabilityPayload] = []

    init(connectError: RendezvousSignalingError? = nil) {
        let pair = PairedAvailabilitySignalingClient.EventStream.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        self.connectError = connectError
    }

    func connect() async throws -> PairedAvailabilitySignalingClient.EventStream {
        connectCount += 1
        if let connectError { throw connectError }
        return stream
    }

    func send(_ payload: RemoteAvailabilityPayload) async throws {
        sentPayloads.append(payload)
    }

    func close() async {
        closeCount += 1
        continuation.finish()
    }

    func connectCallCount() -> Int { connectCount }
    func closeCallCount() -> Int { closeCount }
    func sentPayloadsSnapshot() -> [RemoteAvailabilityPayload] { sentPayloads }

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

    private func advance(by delta: UInt64) {
        lock.withLock { currentNanoseconds += delta }
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

private func waitForRetrySleep(
    _ clock: AvailabilityRetryClockStub
) async throws {
    for _ in 0..<500 {
        if clock.sleepCallCount() > 0 { return }
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
        self.record = record
    }

    func deletePairedMac() throws {
        deleteCount += 1
        record = nil
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
            service: "org.example.AudioStreamer.viewer-pairing-tests",
            account: "identity-\(suffix)"
        ),
        pairedMac: KeychainStore.Item(
            service: "org.example.AudioStreamer.viewer-pairing-tests",
            account: "paired-mac-\(suffix)"
        ),
        invitationCode: KeychainStore.Item(
            service: "org.example.AudioStreamer.viewer-pairing-tests",
            account: "invitation-code-\(suffix)"
        ),
        admissionMarker: KeychainStore.Item(
            service: "org.example.AudioStreamer.viewer-pairing-tests",
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

private enum PairingTestFailure: Error {
    case save
    case load
    case timeout
}
