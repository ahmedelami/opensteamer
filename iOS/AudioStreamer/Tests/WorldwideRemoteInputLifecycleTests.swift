import XCTest
import SwiftUI
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
