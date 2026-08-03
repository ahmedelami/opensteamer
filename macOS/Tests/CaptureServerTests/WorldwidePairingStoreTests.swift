import Foundation
import RemoteSessionCore
import XCTest
@testable import CaptureServer

/// Verifies durable host identity, paired-viewer recovery, and fail-closed persistence behavior.
///
/// A one-time invitation is only bootstrap material; reconnect authority comes from an
/// authenticated durable record. Corrupt data must never cause silent identity rotation, and a
/// host relaunched mid-commit must resend completion without accepting media until the viewer's
/// activation acknowledgement has been authenticated.
final class WorldwidePairingStoreTests: XCTestCase {
    func testOpensteamerHostUsesPairingServiceIsolatedFromProtectedLegacyHost() {
        XCTAssertEqual(
            WorldwideKeychainDataStore.opensteamerPairingService,
            "com.elamin.opensteamer.CaptureServer.WorldwidePairing.v1"
        )
        XCTAssertNotEqual(
            WorldwideKeychainDataStore.opensteamerPairingService,
            "com.elamin.AudioStreamer.CaptureServer.WorldwidePairing.v1"
        )
    }

    func testPeerDepartureRestartsOnlyBeforeDurablePairingStateExists() {
        XCTAssertEqual(
            worldwidePairingPeerDepartureAction(hasDurableRecord: false),
            .restartBootstrap
        )
        XCTAssertEqual(
            worldwidePairingPeerDepartureAction(hasDurableRecord: true),
            .recoverOnAvailability
        )
    }

    func testRealKeychainBackendRoundTripsAcrossStoreRecreation() throws {
        // A unique service isolates the real Keychain integration from production and parallel
        // test runs. The deferred removal is part of the test's privacy boundary.
        let testingServiceID = UUID()
        let account = "pairing-round-trip"
        let dataStore = WorldwideKeychainDataStore(testingServiceID: testingServiceID)
        defer { try? dataStore.removeData(for: account) }

        XCTAssertNil(try dataStore.data(for: account))
        let first = Data("first durable pairing value".utf8)
        try dataStore.set(first, for: account)
        XCTAssertEqual(try dataStore.data(for: account), first)
        XCTAssertEqual(
            try WorldwideKeychainDataStore(testingServiceID: testingServiceID).data(for: account),
            first
        )

        let replacement = Data("updated durable pairing value".utf8)
        try dataStore.set(replacement, for: account)
        XCTAssertEqual(try dataStore.data(for: account), replacement)
        try dataStore.removeData(for: account)
        XCTAssertNil(try dataStore.data(for: account))
    }

    func testHostIdentitySurvivesStoreRecreation() throws {
        let dataStore = MemoryPairingDataStore()
        let firstStore = WorldwidePairingStore(dataStore: dataStore)
        let first = try firstStore.loadOrCreateHostIdentity(displayName: "Mac mini")

        let recreatedStore = WorldwidePairingStore(dataStore: dataStore)
        let recreated = try recreatedStore.loadOrCreateHostIdentity(displayName: "Renamed Mac")

        XCTAssertEqual(recreated, first)
        XCTAssertEqual(recreated.role, .host)
    }

    func testResetDeletesOnlyPairedViewerRecord() throws {
        let dataStore = MemoryPairingDataStore()
        let store = WorldwidePairingStore(dataStore: dataStore)
        let identity = try store.loadOrCreateHostIdentity(displayName: nil)
        try dataStore.set(Data("placeholder".utf8), for: WorldwidePairingStore.pairedViewerAccount)

        try store.resetPairedViewer()

        XCTAssertNil(try dataStore.data(for: WorldwidePairingStore.pairedViewerAccount))
        XCTAssertEqual(
            try store.loadOrCreateHostIdentity(displayName: "ignored"),
            identity
        )
    }

    func testCorruptIdentityFailsClosedInsteadOfRotatingKeys() throws {
        let dataStore = MemoryPairingDataStore()
        try dataStore.set(Data("{}".utf8), for: WorldwidePairingStore.identityAccount)
        let store = WorldwidePairingStore(dataStore: dataStore)

        XCTAssertThrowsError(try store.loadOrCreateHostIdentity(displayName: nil)) { error in
            XCTAssertEqual(error as? WorldwidePairingStoreError, .invalidPersistedData)
        }
        XCTAssertEqual(try dataStore.data(for: WorldwidePairingStore.identityAccount), Data("{}".utf8))
    }

    func testRelaunchRecoversCompletionButBarsMediaUntilViewerActivationAck() throws {
        let dataStore = MemoryPairingDataStore()
        let store = WorldwidePairingStore(dataStore: dataStore)
        let hostIdentity = try store.loadOrCreateHostIdentity(displayName: "Mac mini")
        let viewerIdentity = try RemoteDeviceIdentity.generate(
            role: .viewer,
            displayName: "iPhone"
        )
        let invitation = try RemoteInvitationCode.generate()
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

        // Persist at `acceptedReceived`, the exact crash window after completion is sent but before
        // the viewer's final activation acknowledgement reaches the host.
        var hostRecord = try hostAgreement.makePendingRecord(
            peerConfirmation: viewerAgreement.makeConfirmation()
        )
        var viewerRecord = try viewerAgreement.makePendingRecord(
            peerConfirmation: hostAgreement.makeConfirmation()
        )
        let proposal = try hostRecord.prepareProposal(using: hostIdentity)
        let acknowledgement = try viewerRecord.prepareAcknowledgement(
            after: proposal,
            using: viewerIdentity
        )
        try hostRecord.acceptAcknowledgement(acknowledgement)
        let completion = try hostRecord.prepareCompletion(using: hostIdentity)
        try hostRecord.markCompletionSent(commitID: completion.commitID)
        XCTAssertEqual(hostRecord.pairingState, .acceptedReceived)
        try store.savePairedViewer(hostRecord, for: hostIdentity)

        let recreatedStore = WorldwidePairingStore(dataStore: dataStore)
        var relaunchedHost = try XCTUnwrap(
            recreatedStore.loadPairedViewer(for: hostIdentity)
        )
        XCTAssertEqual(relaunchedHost.pairingState, .acceptedReceived)
        XCTAssertEqual(relaunchedHost.recoveryAction, .resend(completion))
        XCTAssertEqual(
            try relaunchedHost.availabilityLocator().channelID,
            try viewerRecord.availabilityLocator().channelID
        )

        let activation = try viewerRecord.acceptCompletion(
            completion,
            using: viewerIdentity
        )
        var activeViewer = viewerRecord
        let reconnect = try activeViewer.beginReconnect(using: viewerIdentity)
        XCTAssertThrowsError(
            try relaunchedHost.respond(to: reconnect.request, using: hostIdentity)
        )

        try relaunchedHost.acceptActivationAcknowledgement(activation)
        try recreatedStore.savePairedViewer(relaunchedHost, for: hostIdentity)
        XCTAssertEqual(relaunchedHost.pairingState, .active)
        XCTAssertNoThrow(
            try relaunchedHost.respond(to: reconnect.request, using: hostIdentity)
        )
    }

    func testAcceptedReceivedReplayIsReauthenticatedBeforeCompletionResend() throws {
        let hostIdentity = try RemoteDeviceIdentity.generate(role: .host)
        let viewerIdentity = try RemoteDeviceIdentity.generate(role: .viewer)
        let invitation = try RemoteInvitationCode.generate()
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
        var hostRecord = try hostAgreement.makePendingRecord(
            peerConfirmation: viewerAgreement.makeConfirmation()
        )
        var viewerRecord = try viewerAgreement.makePendingRecord(
            peerConfirmation: hostAgreement.makeConfirmation()
        )
        let proposal = try hostRecord.prepareProposal(using: hostIdentity)
        let acknowledgement = try viewerRecord.prepareAcknowledgement(
            after: proposal,
            using: viewerIdentity
        )
        try validateAndAcceptWorldwidePairingAcknowledgement(
            acknowledgement,
            record: &hostRecord
        )
        let completion = try hostRecord.prepareCompletion(using: hostIdentity)
        XCTAssertEqual(hostRecord.pairingState, .acceptedReceived)
        XCTAssertEqual(hostRecord.recoveryAction, .resend(completion))

        var tamperedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(acknowledgement))
                as? [String: Any]
        )
        var signature = try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(tamperedObject["signature"] as? String))
        )
        // Flip one signature bit while preserving a structurally valid encoded commit. Rejection
        // must therefore come from authentication, not JSON decoding or message shape.
        signature[0] ^= 1
        tamperedObject["signature"] = signature.base64EncodedString()
        let tampered = try JSONDecoder().decode(
            RemotePairingCommit.self,
            from: JSONSerialization.data(withJSONObject: tamperedObject)
        )

        XCTAssertThrowsError(
            try validateAndAcceptWorldwidePairingAcknowledgement(
                tampered,
                record: &hostRecord
            )
        ) { error in
            XCTAssertEqual(error as? RemoteSessionCoreError, .authenticationFailed)
        }
        XCTAssertEqual(hostRecord.pairingState, .acceptedReceived)
        XCTAssertEqual(hostRecord.recoveryAction, .resend(completion))

        XCTAssertNoThrow(
            try validateAndAcceptWorldwidePairingAcknowledgement(
                acknowledgement,
                record: &hostRecord
            )
        )
        XCTAssertEqual(hostRecord.recoveryAction, .resend(completion))
    }
}

/// Thread-safe in-memory substitute for persistence-focused tests that do not need Keychain I/O.
/// It intentionally stores the same opaque `Data` values as the production backend.
private final class MemoryPairingDataStore: WorldwidePairingDataStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(for account: String) throws -> Data? {
        lock.withLock { values[account] }
    }

    func set(_ data: Data, for account: String) throws {
        lock.withLock { values[account] = data }
    }

    func removeData(for account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: account) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
