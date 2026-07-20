import RemoteSessionCore
import SwiftUI
import WebRTCTransport
import XCTest
@testable import AudioStreamer

final class WorldwideRemoteInputLifecycleTests: XCTestCase {
    @MainActor
    func testPassiveTeardownRevokesQueuedReturnBeforeAsyncHideAndStaysRevokedOnFailure() async {
        let viewModel = WorldwideSessionViewModel()
        let oldAuthorization = viewModel.debugInstallQueuedReturnForPassiveTeardown()
        let before = viewModel.debugRemoteInputState
        let hideGate = AsyncGate()
        let hideFinished = expectation(description: "simulated failed Hide finished")
        let probe = LifecycleProbe()

        XCTAssertTrue(oldAuthorization.isValid)
        XCTAssertTrue(before.inputAvailable)
        XCTAssertEqual(before.queuedActionCount, 1)
        XCTAssertEqual(before.focusGeneration, 41)
        XCTAssertTrue(before.acceptsActiveScreenAcknowledgement)
        XCTAssertTrue(before.remoteHideRequired)
        XCTAssertFalse(before.hideRequestWouldBeNoOp)

        viewModel.beginPassiveScreenTeardown {
            probe.hideStarted = true
            await hideGate.wait()
            probe.hideFailed = true
            hideFinished.fulfill()
        }

        // No actor yield has occurred: revocation and queue clearing must precede the Hide task.
        let immediatelyAfter = viewModel.debugRemoteInputState
        XCTAssertFalse(probe.hideStarted)
        XCTAssertFalse(oldAuthorization.isValid)
        XCTAssertFalse(immediatelyAfter.capabilityInstalled)
        XCTAssertFalse(immediatelyAfter.authorizationInstalled)
        XCTAssertNil(immediatelyAfter.focusGeneration)
        XCTAssertEqual(immediatelyAfter.queuedActionCount, 0)
        XCTAssertEqual(immediatelyAfter.pendingActionCount, 0)
        XCTAssertNotEqual(immediatelyAfter.inputGeneration, before.inputGeneration)
        XCTAssertNotEqual(
            immediatelyAfter.screenVisibilityOperationGeneration,
            before.screenVisibilityOperationGeneration
        )
        XCTAssertFalse(immediatelyAfter.inputAvailable)
        XCTAssertFalse(immediatelyAfter.acceptsActiveScreenAcknowledgement)
        XCTAssertTrue(immediatelyAfter.remoteHideRequired)
        XCTAssertFalse(immediatelyAfter.hideRequestWouldBeNoOp)

        // Even when Show has not yet made local visibility true, the remembered remote Hide
        // requirement must bypass the ordinary false→false visibility fast path.
        viewModel.debugSimulateLocallyHiddenPendingShow()
        XCTAssertTrue(viewModel.debugRemoteInputState.remoteHideRequired)
        XCTAssertFalse(viewModel.debugRemoteInputState.hideRequestWouldBeNoOp)

        let lateAuthorization = await viewModel.debugDeliverLateActiveAcknowledgement()
        XCTAssertFalse(lateAuthorization.isValid)
        XCTAssertFalse(viewModel.debugRemoteInputState.capabilityInstalled)
        XCTAssertFalse(viewModel.debugRemoteInputState.inputAvailable)

        await Task.yield()
        XCTAssertTrue(probe.hideStarted)
        await hideGate.open()
        await fulfillment(of: [hideFinished], timeout: 1)

        // A failed asynchronous Hide cannot restore the old local authorization or queue.
        let afterFailure = viewModel.debugRemoteInputState
        XCTAssertTrue(probe.hideFailed)
        XCTAssertFalse(oldAuthorization.isValid)
        XCTAssertFalse(afterFailure.capabilityInstalled)
        XCTAssertFalse(afterFailure.authorizationInstalled)
        XCTAssertNil(afterFailure.focusGeneration)
        XCTAssertEqual(afterFailure.queuedActionCount, 0)
        XCTAssertFalse(afterFailure.inputAvailable)
        XCTAssertFalse(afterFailure.acceptsActiveScreenAcknowledgement)
        XCTAssertTrue(afterFailure.remoteHideRequired)
        XCTAssertFalse(afterFailure.hideRequestWouldBeNoOp)
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
    func testPassiveTeardownDispatchesProductionHideAfterSynchronousRevocation() async {
        let viewModel = WorldwideSessionViewModel()
        let oldAuthorization = viewModel.debugInstallQueuedReturnForPassiveTeardown()
        let hideDispatched = expectation(description: "production Hide dispatched")
        let probe = LifecycleProbe()
        let hideRequestID: UInt64 = 901
        viewModel.debugInstallScreenVisibilityRequestSender { visible in
            probe.visibilityRequests.append(visible)
            hideDispatched.fulfill()
            return hideRequestID
        }

        viewModel.beginPassiveScreenTeardown()

        // This is the production convenience path, not the injectable ordering-only overload.
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
}

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

@MainActor
private final class LifecycleProbe {
    var hideStarted = false
    var hideFailed = false
    var visibilityRequests: [Bool] = []
}

private actor AsyncGate {
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
        let currentWaiters = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in currentWaiters {
            waiter.resume()
        }
    }
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
