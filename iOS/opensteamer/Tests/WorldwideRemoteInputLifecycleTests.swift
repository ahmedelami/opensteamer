import RemoteSessionCore
import SwiftUI
import WebRTCTransport
import XCTest
@testable import opensteamer

/// Concurrency regression suite for screen leases, visibility acknowledgements, and remote input.
/// Exact peer/generation/lease ownership is the oracle at every suspension point: delayed control
/// feedback, timeout, or input completion must be unable to mutate a replacement session.
final class WorldwideRemoteInputLifecycleTests: XCTestCase {
    @MainActor
    func testReplacementSessionStaleTeardownAndRawRequestIDCannotTouchCurrentLease() async throws {
        let viewModel = WorldwideSessionViewModel()
        let peerA = try makeScreenPeer()
        let peerB = try makeScreenPeer()
        let generationA = UUID()
        let generationB = UUID()
        let reusedRequestID: UInt64 = 88
        let fixtureA = viewModel.debugInstallActiveScreenPresentationForTests(
            peer: peerA,
            generation: generationA,
            screenRequestID: reusedRequestID
        )
        let transport = ScreenVisibilityTransportProbe()
        let stalePostSendGate = NonCooperativeAsyncGate()
        let stalePostSendReached = MainActorCountGate()
        let staleCompletion = MainActorCountGate()
        var staleOperationID: UUID?
        viewModel.debugInstallScreenVisibilityRequestSender(transport.send)
        viewModel.debugInstallScreenVisibilityPostSendHook { event in
            guard event.request.lease == fixtureA.lease else { return }
            staleOperationID = event.request.operationID
            XCTAssertEqual(event.requestID, reusedRequestID)
            stalePostSendReached.increment()
            await stalePostSendGate.wait()
        }

        let staleClaimed = viewModel.beginPassiveScreenTeardown(for: fixtureA.lease) {
            staleCompletion.increment()
        }
        XCTAssertTrue(staleClaimed)
        guard staleClaimed else {
            viewModel.disconnect()
            await peerA.close()
            await peerB.close()
            return
        }

        await transport.waitForRequestCount(1)
        XCTAssertEqual(transport.requests[0].lease, fixtureA.lease)
        XCTAssertFalse(transport.requests[0].isVisible)
        await transport.resolveRequest(at: 0, with: .success(reusedRequestID))
        await stalePostSendReached.waitForCount(1)
        guard let staleOperationID else {
            XCTFail("The stale operation did not reach the post-send seam.")
            await stalePostSendGate.open()
            viewModel.disconnect()
            await staleCompletion.waitForCount(1)
            await peerA.close()
            await peerB.close()
            return
        }

        viewModel.debugInstallScreenSessionForTests(
            peer: peerB,
            generation: generationB,
            visible: false
        )
        let leaseB: WorldwideScreenPresentationLease
        do {
            leaseB = try XCTUnwrap(viewModel.issueScreenPresentationLease())
        } catch {
            await stalePostSendGate.open()
            viewModel.disconnect()
            await staleCompletion.waitForCount(1)
            await peerA.close()
            await peerB.close()
            return
        }
        let showB = Task { @MainActor in
            await viewModel.setScreenVisible(true, for: leaseB)
        }

        await transport.waitForRequestCount(2)
        XCTAssertEqual(transport.requests[1].lease, leaseB)
        XCTAssertTrue(transport.requests[1].isVisible)
        let keyB = WorldwideScreenVisibilityRequestKey(
            sessionGeneration: generationB,
            requestID: reusedRequestID
        )
        await transport.resolveRequest(at: 1, with: .success(reusedRequestID))
        await viewModel.debugWaitForPendingScreenVisibilityRequest(keyB)
        XCTAssertEqual(viewModel.debugScreenPresentationState.pendingRequestKey, keyB)

        await stalePostSendGate.open()
        await viewModel.debugWaitForScreenVisibilityPostSendProcessing(
            operationID: staleOperationID
        )

        let afterStalePostSend = viewModel.debugScreenPresentationState
        let staleCouldNotReplaceB = afterStalePostSend.pendingRequestKey == keyB
            && afterStalePostSend.displacedPendingRequestCount == 0
            && staleCompletion.count == 1
        XCTAssertEqual(afterStalePostSend.pendingRequestKey, keyB)
        XCTAssertEqual(afterStalePostSend.displacedPendingRequestCount, 0)
        XCTAssertEqual(staleCompletion.count, 1)
        guard staleCouldNotReplaceB else {
            viewModel.disconnect()
            _ = await showB.value
            await staleCompletion.waitForCount(1)
            await peerA.close()
            await peerB.close()
            return
        }

        _ = await viewModel.debugDeliverControlAcknowledgement(
            key: WorldwideScreenVisibilityRequestKey(
                sessionGeneration: generationA,
                requestID: reusedRequestID
            ),
            state: .inactive,
            sourcePeer: peerA
        )
        XCTAssertEqual(viewModel.debugScreenPresentationState.pendingRequestKey, keyB)
        XCTAssertFalse(viewModel.screenPresentationIsVisible(leaseB))
        XCTAssertFalse(viewModel.remoteInputIsAvailable(for: leaseB))
        XCTAssertTrue(viewModel.debugScreenPeerIs(peerB))

        let capabilityB = WebRTCInputCapability(
            inputSessionID: UUID(),
            screenRequestID: reusedRequestID,
            supportsPrimaryDrag: true
        )
        let authorizationB = await viewModel.debugDeliverControlAcknowledgement(
            key: keyB,
            state: .active,
            inputCapability: capabilityB,
            sourcePeer: peerB
        )
        let afterBAcknowledgement = viewModel.debugScreenPresentationState
        let bAcknowledgedImmediately = authorizationB?.isValid == true
            && afterBAcknowledgement.pendingRequestKey == nil
            && afterBAcknowledgement.currentLease == leaseB
            && afterBAcknowledgement.activeLease == leaseB
            && afterBAcknowledgement.isScreenVisible
            && afterBAcknowledgement.inputAvailable
        XCTAssertTrue(authorizationB?.isValid == true)
        XCTAssertNil(afterBAcknowledgement.pendingRequestKey)
        XCTAssertEqual(afterBAcknowledgement.currentLease, leaseB)
        XCTAssertEqual(afterBAcknowledgement.activeLease, leaseB)
        XCTAssertTrue(afterBAcknowledgement.isScreenVisible)
        XCTAssertTrue(afterBAcknowledgement.inputAvailable)
        guard bAcknowledgedImmediately else {
            viewModel.disconnect()
            _ = await showB.value
            await peerA.close()
            await peerB.close()
            return
        }

        let didShowB = await showB.value
        XCTAssertTrue(didShowB)
        XCTAssertTrue(viewModel.screenPresentationIsVisible(leaseB))
        XCTAssertTrue(viewModel.remoteInputIsAvailable(for: leaseB))
        XCTAssertEqual(staleCompletion.count, 1)

        viewModel.disconnect()
        await peerA.close()
        await peerB.close()
    }

    @MainActor
    func testStaleHideFailureCannotCloseReplacementSession() async throws {
        do {
            let viewModel = WorldwideSessionViewModel()
            let peerA = try makeScreenPeer()
            let peerB = try makeScreenPeer()
            let fixtureA = viewModel.debugInstallActiveScreenPresentationForTests(peer: peerA)
            let fixtureB = viewModel.debugInstallActiveScreenPresentationForTests(peer: peerB)
            let transport = ScreenVisibilityTransportProbe()
            let completion = MainActorCountGate()
            viewModel.debugInstallScreenVisibilityRequestSender(transport.send)

            let staleClaim = viewModel.beginPassiveScreenTeardown(for: fixtureA.lease) {
                completion.increment()
            }
            if staleClaim {
                await transport.waitForRequestCount(1)
                await transport.resolveRequest(at: 0, with: .failure(.sendFailed))
                await completion.waitForCount(1)
            }

            XCTAssertFalse(staleClaim)
            XCTAssertTrue(viewModel.debugScreenPeerIs(peerB))
            XCTAssertTrue(viewModel.debugScreenPresentationState.hasActiveSession)
            XCTAssertEqual(viewModel.debugScreenPresentationState.currentLease, fixtureB.lease)
            XCTAssertEqual(viewModel.debugScreenPresentationState.activeLease, fixtureB.lease)
            XCTAssertTrue(fixtureB.authorization.isValid)
            XCTAssertTrue(viewModel.remoteInputIsAvailable(for: fixtureB.lease))

            viewModel.disconnect()
            await peerA.close()
            await peerB.close()
        }

        do {
            let viewModel = WorldwideSessionViewModel()
            let peerA = try makeScreenPeer()
            let peerB = try makeScreenPeer()
            let fixtureA = viewModel.debugInstallActiveScreenPresentationForTests(peer: peerA)
            let transport = ScreenVisibilityTransportProbe()
            let completion = MainActorCountGate()
            viewModel.debugInstallScreenVisibilityRequestSender(transport.send)

            let staleClaim = viewModel.beginPassiveScreenTeardown(for: fixtureA.lease) {
                completion.increment()
            }
            XCTAssertTrue(staleClaim)
            guard staleClaim else {
                viewModel.disconnect()
                await peerA.close()
                await peerB.close()
                return
            }

            await transport.waitForRequestCount(1)
            XCTAssertEqual(transport.requests[0].lease, fixtureA.lease)
            XCTAssertFalse(transport.requests[0].isVisible)

            let fixtureB = viewModel.debugInstallActiveScreenPresentationForTests(peer: peerB)
            await transport.resolveRequest(at: 0, with: .failure(.sendFailed))
            await completion.waitForCount(1)

            XCTAssertEqual(completion.count, 1)
            XCTAssertTrue(viewModel.debugScreenPeerIs(peerB))
            XCTAssertTrue(viewModel.debugScreenPresentationState.hasActiveSession)
            XCTAssertEqual(viewModel.debugScreenPresentationState.currentLease, fixtureB.lease)
            XCTAssertEqual(viewModel.debugScreenPresentationState.activeLease, fixtureB.lease)
            XCTAssertTrue(fixtureB.authorization.isValid)
            XCTAssertTrue(viewModel.remoteInputIsAvailable(for: fixtureB.lease))

            viewModel.disconnect()
            await peerA.close()
            await peerB.close()
        }
    }

    @MainActor
    func testSameSessionReplacementHidesABeforeShowingBAndWaitsForBActive() async throws {
        let viewModel = WorldwideSessionViewModel()
        let peer = try makeScreenPeer()
        let generation = UUID()
        let fixtureA = viewModel.debugInstallActiveScreenPresentationForTests(
            peer: peer,
            generation: generation,
            screenRequestID: 401
        )
        let transport = ScreenVisibilityTransportProbe()
        viewModel.debugInstallScreenVisibilityRequestSender(transport.send)

        let leaseB = try XCTUnwrap(viewModel.issueScreenPresentationLease())
        let immediatelyAfterIssue = viewModel.debugScreenPresentationState
        XCTAssertEqual(immediatelyAfterIssue.currentLease, leaseB)
        XCTAssertFalse(immediatelyAfterIssue.isScreenVisible)
        XCTAssertFalse(immediatelyAfterIssue.inputAvailable)
        XCTAssertFalse(fixtureA.authorization.isValid)

        guard !immediatelyAfterIssue.isScreenVisible,
              !immediatelyAfterIssue.inputAvailable,
              !fixtureA.authorization.isValid else {
            viewModel.disconnect()
            await peer.close()
            return
        }

        let showB = Task { @MainActor in
            await viewModel.setScreenVisible(true, for: leaseB)
        }

        await transport.waitForRequestCount(1)
        XCTAssertEqual(transport.requests[0].lease, fixtureA.lease)
        XCTAssertFalse(transport.requests[0].isVisible)
        let hideAKey = WorldwideScreenVisibilityRequestKey(
            sessionGeneration: generation,
            requestID: 501
        )
        await transport.resolveRequest(at: 0, with: .success(501))
        await viewModel.debugWaitForPendingScreenVisibilityRequest(hideAKey)
        await viewModel.debugDeliverControlAcknowledgement(
            key: hideAKey,
            state: .inactive,
            sourcePeer: peer
        )

        await transport.waitForRequestCount(2)
        XCTAssertEqual(transport.requests[1].lease, leaseB)
        XCTAssertTrue(transport.requests[1].isVisible)
        XCTAssertNotEqual(transport.requests[0].operationID, transport.requests[1].operationID)
        let showBKey = WorldwideScreenVisibilityRequestKey(
            sessionGeneration: generation,
            requestID: 502
        )
        await transport.resolveRequest(at: 1, with: .success(502))
        await viewModel.debugWaitForPendingScreenVisibilityRequest(showBKey)

        let awaitingB = viewModel.debugScreenPresentationState
        XCTAssertEqual(awaitingB.pendingRequestKey, showBKey)
        XCTAssertFalse(awaitingB.isScreenVisible)
        XCTAssertFalse(awaitingB.inputAvailable)

        _ = await viewModel.debugDeliverControlAcknowledgement(
            key: showBKey,
            state: .active,
            inputCapability: WebRTCInputCapability(
                inputSessionID: UUID(),
                screenRequestID: 502,
                supportsPrimaryDrag: true
            ),
            sourcePeer: peer
        )
        let didShowReplacement = await showB.value
        XCTAssertTrue(didShowReplacement)
        XCTAssertTrue(viewModel.screenPresentationIsVisible(leaseB))
        XCTAssertTrue(viewModel.remoteInputIsAvailable(for: leaseB))

        viewModel.disconnect()
        await peer.close()
    }

    @MainActor
    func testBackDuringPendingShowRetiresLeaseAndDrainsExactlyOneHide() async throws {
        let viewModel = WorldwideSessionViewModel()
        let peer = try makeScreenPeer()
        let generation = UUID()
        let transport = ScreenVisibilityTransportProbe()
        let hideCompletion = MainActorCountGate()
        viewModel.debugInstallScreenSessionForTests(
            peer: peer,
            generation: generation,
            visible: false
        )
        viewModel.debugInstallScreenVisibilityRequestSender(transport.send)
        let lease = try XCTUnwrap(viewModel.issueScreenPresentationLease())
        let show = Task { @MainActor in
            await viewModel.setScreenVisible(true, for: lease)
        }

        await transport.waitForRequestCount(1)
        XCTAssertTrue(transport.requests[0].isVisible)
        let showKey = WorldwideScreenVisibilityRequestKey(
            sessionGeneration: generation,
            requestID: 551
        )
        await transport.resolveRequest(at: 0, with: .success(showKey.requestID))
        await viewModel.debugWaitForPendingScreenVisibilityRequest(showKey)

        XCTAssertTrue(
            viewModel.beginPassiveScreenTeardown(for: lease) {
                hideCompletion.increment()
            }
        )
        viewModel.retireScreenPresentationLease(lease)
        XCTAssertFalse(viewModel.beginPassiveScreenTeardown(for: lease))
        let didShow = await show.value
        XCTAssertFalse(didShow)

        await transport.waitForRequestCount(2)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests.map(\.isVisible), [true, false])
        XCTAssertEqual(transport.requests[1].lease, lease)

        let lateAuthorization = await viewModel.debugDeliverControlAcknowledgement(
            key: showKey,
            state: .active,
            inputCapability: WebRTCInputCapability(
                inputSessionID: UUID(),
                screenRequestID: showKey.requestID,
                supportsPrimaryDrag: true
            ),
            sourcePeer: peer
        )
        XCTAssertFalse(lateAuthorization?.isValid ?? true)
        XCTAssertFalse(viewModel.debugScreenPresentationState.isScreenVisible)
        XCTAssertFalse(viewModel.debugScreenPresentationState.inputAvailable)

        let hideKey = WorldwideScreenVisibilityRequestKey(
            sessionGeneration: generation,
            requestID: 552
        )
        await transport.resolveRequest(at: 1, with: .success(hideKey.requestID))
        await viewModel.debugWaitForPendingScreenVisibilityRequest(hideKey)
        await viewModel.debugDeliverControlAcknowledgement(
            key: hideKey,
            state: .inactive,
            sourcePeer: peer
        )
        await hideCompletion.waitForCount(1)

        let finalState = viewModel.debugScreenPresentationState
        XCTAssertEqual(hideCompletion.count, 1)
        XCTAssertNil(finalState.currentLease)
        XCTAssertNil(finalState.activeLease)
        XCTAssertNil(finalState.pendingRequestKey)
        XCTAssertFalse(finalState.isScreenVisible)
        XCTAssertFalse(finalState.inputAvailable)
        XCTAssertFalse(finalState.remoteHideRequired)
        XCTAssertTrue(finalState.hasActiveSession)
        XCTAssertTrue(viewModel.debugScreenPeerIs(peer))

        viewModel.disconnect()
        await peer.close()
    }

    @MainActor
    func testBackDuringPendingShowHideSendFailureClosesExactOwner() async throws {
        let viewModel = WorldwideSessionViewModel()
        let peer = try makeScreenPeer()
        let generation = UUID()
        let transport = ScreenVisibilityTransportProbe()
        let hideCompletion = MainActorCountGate()
        viewModel.debugInstallScreenSessionForTests(
            peer: peer,
            generation: generation,
            visible: false
        )
        viewModel.debugInstallScreenVisibilityRequestSender(transport.send)
        let lease = try XCTUnwrap(viewModel.issueScreenPresentationLease())
        let show = Task { @MainActor in
            await viewModel.setScreenVisible(true, for: lease)
        }

        await transport.waitForRequestCount(1)
        let showKey = WorldwideScreenVisibilityRequestKey(
            sessionGeneration: generation,
            requestID: 561
        )
        await transport.resolveRequest(at: 0, with: .success(showKey.requestID))
        await viewModel.debugWaitForPendingScreenVisibilityRequest(showKey)
        XCTAssertTrue(
            viewModel.beginPassiveScreenTeardown(for: lease) {
                hideCompletion.increment()
            }
        )
        viewModel.retireScreenPresentationLease(lease)
        let didShow = await show.value
        XCTAssertFalse(didShow)

        await transport.waitForRequestCount(2)
        XCTAssertEqual(transport.requests.map(\.isVisible), [true, false])
        await transport.resolveRequest(at: 1, with: .failure(.sendFailed))
        await hideCompletion.waitForCount(1)

        XCTAssertEqual(hideCompletion.count, 1)
        assertScreenOwnerClosed(viewModel, formerPeer: peer)
        await peer.close()
    }

    @MainActor
    func testBackDuringPendingShowHideTimeoutClosesExactOwner() async throws {
        let viewModel = WorldwideSessionViewModel()
        let peer = try makeScreenPeer()
        let generation = UUID()
        let transport = ScreenVisibilityTransportProbe()
        let hideCompletion = MainActorCountGate()
        viewModel.debugInstallScreenSessionForTests(
            peer: peer,
            generation: generation,
            visible: false
        )
        viewModel.debugInstallScreenVisibilityRequestSender(transport.send)
        let lease = try XCTUnwrap(viewModel.issueScreenPresentationLease())
        let show = Task { @MainActor in
            await viewModel.setScreenVisible(true, for: lease)
        }

        await transport.waitForRequestCount(1)
        let showKey = WorldwideScreenVisibilityRequestKey(
            sessionGeneration: generation,
            requestID: 571
        )
        await transport.resolveRequest(at: 0, with: .success(showKey.requestID))
        await viewModel.debugWaitForPendingScreenVisibilityRequest(showKey)
        XCTAssertTrue(
            viewModel.beginPassiveScreenTeardown(for: lease) {
                hideCompletion.increment()
            }
        )
        viewModel.retireScreenPresentationLease(lease)
        let didShow = await show.value
        XCTAssertFalse(didShow)

        await transport.waitForRequestCount(2)
        XCTAssertEqual(transport.requests.map(\.isVisible), [true, false])
        let hideKey = WorldwideScreenVisibilityRequestKey(
            sessionGeneration: generation,
            requestID: 572
        )
        await transport.resolveRequest(at: 1, with: .success(hideKey.requestID))
        await viewModel.debugWaitForPendingScreenVisibilityRequest(hideKey)
        viewModel.debugTriggerScreenVisibilityTimeout(key: hideKey)
        await hideCompletion.waitForCount(1)

        XCTAssertEqual(hideCompletion.count, 1)
        assertScreenOwnerClosed(viewModel, formerPeer: peer)
        await peer.close()
    }

    @MainActor
    func testDuplicateHideAndDisappearClaimSendsAndCompletesOnce() async throws {
        let viewModel = WorldwideSessionViewModel()
        let peer = try makeScreenPeer()
        let fixture = viewModel.debugInstallActiveScreenPresentationForTests(peer: peer)
        let transport = ScreenVisibilityTransportProbe()
        let completion = MainActorCountGate()
        viewModel.debugInstallScreenVisibilityRequestSender(transport.send)

        let firstClaim = viewModel.beginPassiveScreenTeardown(for: fixture.lease) {
            completion.increment()
        }
        let duplicateClaim = viewModel.beginPassiveScreenTeardown(for: fixture.lease) {
            completion.increment()
        }

        XCTAssertTrue(firstClaim)
        XCTAssertFalse(duplicateClaim)
        guard firstClaim, !duplicateClaim else {
            viewModel.disconnect()
            await peer.close()
            return
        }

        await transport.waitForRequestCount(1)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertFalse(transport.requests[0].isVisible)
        let hideKey = WorldwideScreenVisibilityRequestKey(
            sessionGeneration: fixture.lease.sessionGeneration,
            requestID: 601
        )
        await transport.resolveRequest(at: 0, with: .success(601))
        await viewModel.debugWaitForPendingScreenVisibilityRequest(hideKey)
        await viewModel.debugDeliverControlAcknowledgement(
            key: hideKey,
            state: .inactive,
            sourcePeer: peer
        )
        await completion.waitForCount(1)
        XCTAssertEqual(completion.count, 1)
        XCTAssertEqual(transport.requests.count, 1)

        viewModel.disconnect()
        await peer.close()
    }

    @MainActor
    func testCurrentOwnerRevokesRenderAndInputBeforeAsyncHide() async throws {
        let viewModel = WorldwideSessionViewModel()
        let peer = try makeScreenPeer()
        let fixture = viewModel.debugInstallActiveScreenPresentationForTests(peer: peer)
        let transport = ScreenVisibilityTransportProbe()
        let completion = MainActorCountGate()
        viewModel.debugInstallScreenVisibilityRequestSender(transport.send)

        XCTAssertTrue(
            viewModel.beginPassiveScreenTeardown(for: fixture.lease) {
                completion.increment()
            }
        )

        XCTAssertFalse(fixture.authorization.isValid)
        XCTAssertFalse(viewModel.screenPresentationIsVisible(fixture.lease))
        XCTAssertFalse(viewModel.remoteInputIsAvailable(for: fixture.lease))
        XCTAssertFalse(viewModel.debugScreenPresentationState.isScreenVisible)
        XCTAssertFalse(viewModel.debugScreenPresentationState.inputAvailable)

        await transport.waitForRequestCount(1)
        let hideKey = WorldwideScreenVisibilityRequestKey(
            sessionGeneration: fixture.lease.sessionGeneration,
            requestID: 701
        )
        await transport.resolveRequest(at: 0, with: .success(701))
        await viewModel.debugWaitForPendingScreenVisibilityRequest(hideKey)
        await viewModel.debugDeliverControlAcknowledgement(
            key: hideKey,
            state: .inactive,
            sourcePeer: peer
        )
        await completion.waitForCount(1)

        viewModel.disconnect()
        await peer.close()
    }

    @MainActor
    func testCurrentOwnerHideSendFailureClosesExactOwner() async throws {
        let viewModel = WorldwideSessionViewModel()
        let peer = try makeScreenPeer()
        let fixture = viewModel.debugInstallActiveScreenPresentationForTests(peer: peer)
        let transport = ScreenVisibilityTransportProbe()
        let completion = MainActorCountGate()
        viewModel.debugInstallScreenVisibilityRequestSender(transport.send)

        XCTAssertTrue(
            viewModel.beginPassiveScreenTeardown(for: fixture.lease) {
                completion.increment()
            }
        )
        XCTAssertFalse(viewModel.screenPresentationIsVisible(fixture.lease))
        XCTAssertFalse(viewModel.remoteInputIsAvailable(for: fixture.lease))
        await transport.waitForRequestCount(1)
        await transport.resolveRequest(at: 0, with: .failure(.sendFailed))
        await completion.waitForCount(1)

        assertScreenOwnerClosed(viewModel, formerPeer: peer)
        XCTAssertFalse(fixture.authorization.isValid)
        await peer.close()
    }

    @MainActor
    func testCurrentOwnerHideTimeoutClosesExactOwner() async throws {
        let viewModel = WorldwideSessionViewModel()
        let peer = try makeScreenPeer()
        let fixture = viewModel.debugInstallActiveScreenPresentationForTests(peer: peer)
        let transport = ScreenVisibilityTransportProbe()
        let completion = MainActorCountGate()
        viewModel.debugInstallScreenVisibilityRequestSender(transport.send)

        XCTAssertTrue(
            viewModel.beginPassiveScreenTeardown(for: fixture.lease) {
                completion.increment()
            }
        )
        XCTAssertFalse(viewModel.screenPresentationIsVisible(fixture.lease))
        XCTAssertFalse(viewModel.remoteInputIsAvailable(for: fixture.lease))
        await transport.waitForRequestCount(1)
        await transport.resolveRequest(at: 0, with: .success(801))
        let key = WorldwideScreenVisibilityRequestKey(
            sessionGeneration: fixture.lease.sessionGeneration,
            requestID: 801
        )
        await viewModel.debugWaitForPendingScreenVisibilityRequest(key)
        XCTAssertEqual(viewModel.debugScreenPresentationState.pendingRequestKey, key)
        viewModel.debugTriggerScreenVisibilityTimeout(key: key)
        await completion.waitForCount(1)

        assertScreenOwnerClosed(viewModel, formerPeer: peer)
        XCTAssertFalse(fixture.authorization.isValid)
        await peer.close()
    }

    @MainActor
    func testCurrentOwnerActiveForHideClosesExactOwner() async throws {
        let viewModel = WorldwideSessionViewModel()
        let peer = try makeScreenPeer()
        let fixture = viewModel.debugInstallActiveScreenPresentationForTests(peer: peer)
        let transport = ScreenVisibilityTransportProbe()
        let completion = MainActorCountGate()
        viewModel.debugInstallScreenVisibilityRequestSender(transport.send)

        XCTAssertTrue(
            viewModel.beginPassiveScreenTeardown(for: fixture.lease) {
                completion.increment()
            }
        )
        XCTAssertFalse(viewModel.screenPresentationIsVisible(fixture.lease))
        XCTAssertFalse(viewModel.remoteInputIsAvailable(for: fixture.lease))
        await transport.waitForRequestCount(1)
        let hideKey = WorldwideScreenVisibilityRequestKey(
            sessionGeneration: fixture.lease.sessionGeneration,
            requestID: 901
        )
        await transport.resolveRequest(at: 0, with: .success(901))
        await viewModel.debugWaitForPendingScreenVisibilityRequest(hideKey)
        let unexpectedAuthorization = await viewModel.debugDeliverControlAcknowledgement(
            key: hideKey,
            state: .active,
            inputCapability: WebRTCInputCapability(
                inputSessionID: UUID(),
                screenRequestID: 901
            ),
            sourcePeer: peer
        )
        await completion.waitForCount(1)

        assertScreenOwnerClosed(viewModel, formerPeer: peer)
        XCTAssertFalse(unexpectedAuthorization?.isValid ?? true)
        XCTAssertFalse(fixture.authorization.isValid)
        await peer.close()
    }

    @MainActor
    func testInitialShowIsAllowedOnlyWhileSceneIsActive() {
        XCTAssertTrue(WorldwideScreenViewerView.allowsScreenPresentation(in: .active))
        XCTAssertFalse(WorldwideScreenViewerView.allowsScreenPresentation(in: .inactive))
        XCTAssertFalse(WorldwideScreenViewerView.allowsScreenPresentation(in: .background))
    }

    @MainActor
    func testRemoteScreenPixelsRenderOnlyForAnActivePresentation() {
        XCTAssertTrue(
            WorldwideScreenViewerView.allowsScreenRendering(
                in: .active,
                allowsPresentation: true,
                isScreenVisible: true
            )
        )
        XCTAssertFalse(
            WorldwideScreenViewerView.allowsScreenRendering(
                in: .active,
                allowsPresentation: false,
                isScreenVisible: true
            )
        )
        XCTAssertFalse(
            WorldwideScreenViewerView.allowsScreenRendering(
                in: .active,
                allowsPresentation: true,
                isScreenVisible: false
            )
        )
        XCTAssertFalse(
            WorldwideScreenViewerView.allowsScreenRendering(
                in: .inactive,
                allowsPresentation: true,
                isScreenVisible: true
            )
        )
        XCTAssertFalse(
            WorldwideScreenViewerView.allowsScreenRendering(
                in: .background,
                allowsPresentation: true,
                isScreenVisible: true
            )
        )
    }

    @MainActor
    func testHideRequiresExplicitInactiveAcknowledgement() {
        XCTAssertTrue(
            WorldwideSessionViewModel.acknowledgementReachedVisibilityTarget(
                .inactive,
                requestedVisibility: false,
                mayAcceptActive: false,
                canViewScreen: true
            )
        )
        XCTAssertFalse(
            WorldwideSessionViewModel.acknowledgementReachedVisibilityTarget(
                .active,
                requestedVisibility: false,
                mayAcceptActive: false,
                canViewScreen: true
            )
        )
        XCTAssertFalse(
            WorldwideSessionViewModel.acknowledgementReachedVisibilityTarget(
                .active,
                requestedVisibility: false,
                mayAcceptActive: false,
                canViewScreen: false
            )
        )
    }

    @MainActor
    func testPassiveTeardownDispatchesProductionHideAfterSynchronousRevocation() async throws {
        let viewModel = WorldwideSessionViewModel()
        let oldAuthorization = viewModel.debugInstallQueuedReturnForPassiveTeardown()
        let lease = try XCTUnwrap(viewModel.debugScreenPresentationState.currentLease)
        let hideDispatched = expectation(description: "production Hide dispatched")
        let probe = LifecycleProbe()
        let hideRequestID: UInt64 = 901
        viewModel.debugInstallScreenVisibilityRequestSender { visible in
            probe.visibilityRequests.append(visible)
            hideDispatched.fulfill()
            return hideRequestID
        }

        XCTAssertTrue(viewModel.beginPassiveScreenTeardown(for: lease))

        // Revocation remains synchronous even though its real visibility send has not run yet.
        XCTAssertFalse(oldAuthorization.isValid)
        XCTAssertFalse(viewModel.debugRemoteInputState.inputAvailable)
        XCTAssertTrue(viewModel.debugRemoteInputState.remoteHideRequired)
        XCTAssertFalse(viewModel.debugRemoteInputState.hideRequestWouldBeNoOp)
        XCTAssertTrue(probe.visibilityRequests.isEmpty)

        await fulfillment(of: [hideDispatched], timeout: 1)
        XCTAssertEqual(probe.visibilityRequests, [false])

        await viewModel.debugDeliverControlAcknowledgement(
            id: hideRequestID,
            state: .inactive
        )
        for _ in 0..<4 { await Task.yield() }
        XCTAssertFalse(viewModel.debugRemoteInputState.remoteHideRequired)
        XCTAssertFalse(viewModel.debugRemoteInputState.inputAvailable)
    }

    // MARK: - Peer and ownership fixtures

    @MainActor
    private func makeScreenPeer() throws -> WebRTCPeer {
        try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .viewer, iceServers: [])
        )
    }

    @MainActor
    private func assertScreenOwnerClosed(
        _ viewModel: WorldwideSessionViewModel,
        formerPeer: WebRTCPeer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let state = viewModel.debugScreenPresentationState
        XCTAssertFalse(state.hasActiveSession, file: file, line: line)
        XCTAssertNil(state.currentLease, file: file, line: line)
        XCTAssertNil(state.activeLease, file: file, line: line)
        XCTAssertFalse(state.isScreenVisible, file: file, line: line)
        XCTAssertFalse(state.inputAvailable, file: file, line: line)
        XCTAssertFalse(viewModel.debugScreenPeerIs(formerPeer), file: file, line: line)
    }
}

/// Focused tests for session-generation fences shared by statistics and signaling tasks.
@MainActor
final class WorldwideSessionGenerationFenceTests: XCTestCase {
    func testCancelledStatisticsStartupCannotPublishIntoReplacementSession() async throws {
        let viewModel = WorldwideSessionViewModel()
        let statisticsStarted = expectation(description: "old statistics startup suspended")
        let staleReadyFinished = expectation(description: "old ready handler finished")
        let gate = NonCooperativeAsyncGate()
        viewModel.debugInstallStatisticsStarter { _ in
            statisticsStarted.fulfill()
            await gate.wait()
        }
        viewModel.debugInstallSessionRunner {
            try? await Task.sleep(for: .seconds(60))
        }

        let oldClient = try makeSignalingClient()
        XCTAssertTrue(viewModel.connect(signalingClient: oldClient))
        let staleReady = Task { @MainActor in
            defer { staleReadyFinished.fulfill() }
            try await viewModel.debugDeliverReadyForRaceTests()
        }

        await fulfillment(of: [statisticsStarted], timeout: 2)

        // Disconnect rotates every production ownership token and cancels actor work. The
        // injected startup deliberately ignores cancellation, matching a non-cooperative actor
        // operation that returns only after the replacement has been accepted.
        viewModel.disconnect()
        let replacementClient = try makeSignalingClient()
        XCTAssertTrue(viewModel.connect(signalingClient: replacementClient))
        XCTAssertTrue(viewModel.debugSignalingIs(replacementClient))
        staleReady.cancel()
        await gate.open()

        await fulfillment(of: [staleReadyFinished], timeout: 2)
        _ = await staleReady.result

        XCTAssertTrue(viewModel.isConnecting)
        XCTAssertEqual(viewModel.stateText, "Connecting securely")
        XCTAssertTrue(viewModel.debugSignalingIs(replacementClient))
        XCTAssertTrue(viewModel.hasActiveSession)
        viewModel.disconnect()
    }

    func testStaleInputUnavailableCannotRevokeReplacementInputSession() async throws {
        try await assertStaleInputFailureCannotMutateReplacement(.inputUnavailable)
    }

    func testStaleInvalidInputRequestCannotClearReplacementFocusOrQueue() async throws {
        try await assertStaleInputFailureCannotMutateReplacement(.invalidInputRequest)
    }

    private func assertStaleInputFailureCannotMutateReplacement(
        _ error: WebRTCTransportError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let viewModel = WorldwideSessionViewModel()
        let sendStarted = expectation(description: "old input send suspended")
        let oldDrainFinished = expectation(description: "old input drain finished")
        let gate = NonCooperativeAsyncGate()
        viewModel.debugInstallRemoteInputSender { _, _, _, _ in
            sendStarted.fulfill()
            await gate.wait()
            throw error
        }

        let oldPeer = try makeViewerPeer()
        let replacementPeer = try makeViewerPeer()
        let oldAuthorization = viewModel.debugInstallQueuedRemoteInputSessionForRaceTests(
            peer: oldPeer,
            focusGeneration: 101,
            diagnostic: "Old diagnostic"
        )
        let oldDrain = Task { @MainActor in
            await viewModel.debugDrainRemoteInputQueueForRaceTests()
            oldDrainFinished.fulfill()
        }

        await fulfillment(of: [sendStarted], timeout: 2)

        let replacementAuthorization =
            viewModel.debugInstallQueuedRemoteInputSessionForRaceTests(
                peer: replacementPeer,
                focusGeneration: 202,
                diagnostic: "Replacement diagnostic"
            )
        let replacementBeforeResume = viewModel.debugRemoteInputState
        XCTAssertFalse(oldAuthorization.isValid, file: file, line: line)
        XCTAssertTrue(replacementAuthorization.isValid, file: file, line: line)
        XCTAssertEqual(replacementBeforeResume.focusGeneration, 202, file: file, line: line)
        XCTAssertEqual(replacementBeforeResume.queuedActionCount, 1, file: file, line: line)
        XCTAssertEqual(viewModel.lastDiagnostic, "Replacement diagnostic", file: file, line: line)

        await gate.open()
        await fulfillment(of: [oldDrainFinished], timeout: 2)
        await oldDrain.value

        let replacementAfterResume = viewModel.debugRemoteInputState
        XCTAssertEqual(replacementAfterResume, replacementBeforeResume, file: file, line: line)
        XCTAssertTrue(replacementAuthorization.isValid, file: file, line: line)
        XCTAssertEqual(viewModel.lastDiagnostic, "Replacement diagnostic", file: file, line: line)

        viewModel.disconnect()
        await oldPeer.close()
        await replacementPeer.close()
    }

    private func makeSignalingClient() throws -> RendezvousSignalingClient {
        try RendezvousSignalingClient(
            endpoint: XCTUnwrap(URL(string: "wss://generation-fence.invalid")),
            invitation: RemoteInvitationCode.generate(),
            role: .viewer
        )
    }

    private func makeViewerPeer() throws -> WebRTCPeer {
        try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(
                role: .viewer,
                iceServers: []
            )
        )
    }
}

// MARK: - Controllable concurrency probes

/// Synchronous completion counter used where an actor hop would alter the ordering under test.
@MainActor
private final class LifecycleProbe {
    var visibilityRequests: [Bool] = []
}

/// Checked continuations intentionally do not observe task cancellation. This models the exact
/// actor-reentrancy failure mode: teardown cancels A, but A still returns after B is installed.
private actor NonCooperativeAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}

private enum ScreenVisibilityTestError: Error, Sendable {
    case sendFailed
}

private actor ScreenVisibilityResponseSlot {
    private var response: Result<UInt64, ScreenVisibilityTestError>?
    private var waiter: CheckedContinuation<Result<UInt64, ScreenVisibilityTestError>, Never>?

    func next() async throws -> UInt64 {
        let result: Result<UInt64, ScreenVisibilityTestError>
        if let response {
            self.response = nil
            result = response
        } else {
            result = await withCheckedContinuation { continuation in
                precondition(waiter == nil)
                waiter = continuation
            }
        }
        return try result.get()
    }

    func resolve(_ response: Result<UInt64, ScreenVisibilityTestError>) {
        precondition(self.response == nil)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: response)
        } else {
            self.response = response
        }
    }
}

@MainActor
private final class ScreenVisibilityTransportProbe {
    private var responseSlots: [ScreenVisibilityResponseSlot] = []
    private var requestCountWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private(set) var requests: [WorldwideScreenVisibilityDebugRequest] = []

    func send(_ request: WorldwideScreenVisibilityDebugRequest) async throws -> UInt64 {
        let responseSlot = ScreenVisibilityResponseSlot()
        requests.append(request)
        responseSlots.append(responseSlot)
        let ready = requestCountWaiters.filter { requests.count >= $0.count }
        requestCountWaiters.removeAll { requests.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
        return try await responseSlot.next()
    }

    func waitForRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestCountWaiters.append((count, continuation))
        }
    }

    func resolveRequest(
        at index: Int,
        with response: Result<UInt64, ScreenVisibilityTestError>
    ) async {
        precondition(responseSlots.indices.contains(index))
        await responseSlots[index].resolve(response)
    }
}

@MainActor
private final class MainActorCountGate {
    private var waiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private(set) var count = 0

    func increment() {
        count += 1
        let ready = waiters.filter { count >= $0.count }
        waiters.removeAll { count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func waitForCount(_ count: Int) async {
        guard self.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}
