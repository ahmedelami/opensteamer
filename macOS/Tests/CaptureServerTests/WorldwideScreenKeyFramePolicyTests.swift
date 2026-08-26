import Foundation
import WebRTCTransport
import XCTest
@testable import CaptureServer

/// Locks the key-frame acknowledgement policy to errors that are safe to ignore or retry.
@MainActor
final class WorldwideScreenKeyFramePolicyTests: XCTestCase {
    func testUnknownAndStaleControlRequestsAreSuperseded() {
        for error in [
            WebRTCTransportError.unknownControlRequest(41),
            WebRTCTransportError.staleControlRequest(42),
        ] {
            XCTAssertTrue(
                WorldwideScreenService.isSupersededScreenControlRequest(error),
                "\(error) must yield to the newer ordered request without stopping capture."
            )
            XCTAssertFalse(
                WorldwideScreenService.isRevokedScreenControlAuthorization(error)
            )
        }
    }

    func testControlAuthorizationRevocationIsRetryableButNotSuperseded() {
        let error = WebRTCTransportError.controlAuthorizationRevoked

        XCTAssertTrue(
            WorldwideScreenService.isRevokedScreenControlAuthorization(error)
        )
        XCTAssertFalse(
            WorldwideScreenService.isSupersededScreenControlRequest(error)
        )
    }

    func testConflictingAndTransportFailuresAreNotMisclassified() {
        let failures: [WebRTCTransportError] = [
            .conflictingControlAcknowledgement(43),
            .transportNotHealthy,
            .transportClosed,
            .dataChannelSendFailed,
        ]

        for error in failures {
            XCTAssertFalse(
                WorldwideScreenService.isSupersededScreenControlRequest(error),
                "\(error) must remain on the fail-closed acknowledgement path."
            )
            XCTAssertFalse(
                WorldwideScreenService.isRevokedScreenControlAuthorization(error),
                "\(error) must not consume the bounded authorization-retry budget."
            )
        }
    }

    func testUnrelatedErrorsAreNotTransportPolicyMatches() {
        let error = InjectedKeyFramePolicyError()

        XCTAssertFalse(
            WorldwideScreenService.isSupersededScreenControlRequest(error)
        )
        XCTAssertFalse(
            WorldwideScreenService.isRevokedScreenControlAuthorization(error)
        )
    }

    func testKeyFrameBranchSchedulesIndependentTaskWithoutInlineRetry() throws {
        let branch = try keyFrameSchedulingBranch()
        let peerGenerationSnapshot = try XCTUnwrap(
            branch.range(of: "let requestPeerGeneration = peerGeneration")
        )
        let recoveryEpochSnapshot = try XCTUnwrap(
            branch.range(of: "let requestRecoveryEpoch = recoveryProofEpoch")
        )
        let priorCancellation = try XCTUnwrap(
            branch.range(of: "keyFrameControlTask?.cancel()")
        )
        let taskScheduling = try XCTUnwrap(
            branch.range(of: "keyFrameControlTask = Task { [weak self] in")
        )
        let handlerCall = try XCTUnwrap(
            branch.range(of: "await self?.handleKeyFrameRequest(")
        )

        XCTAssertLessThan(peerGenerationSnapshot.lowerBound, taskScheduling.lowerBound)
        XCTAssertLessThan(recoveryEpochSnapshot.lowerBound, taskScheduling.lowerBound)
        XCTAssertLessThan(priorCancellation.lowerBound, taskScheduling.lowerBound)
        XCTAssertLessThan(taskScheduling.lowerBound, handlerCall.lowerBound)
        XCTAssertTrue(branch.contains("peer: peer,"))
        XCTAssertTrue(
            branch.contains("peerGeneration: requestPeerGeneration,")
        )
        XCTAssertTrue(branch.contains("recoveryEpoch: requestRecoveryEpoch"))

        for forbiddenInlineWork in [
            "for attempt in",
            "Task.sleep",
            "acknowledgeControlRequest",
            "acknowledgeInactiveAfterVerifiedScreenStop(",
        ] {
            XCTAssertFalse(
                branch.contains(forbiddenInlineWork),
                "The serial peer-event branch must only schedule deferred work."
            )
        }
    }

    func testVisibilityCommandsCancelDeferredKeyFrameTaskBeforeDispatch() throws {
        let preamble = try controlRequestPreamble()
        let visibilityCommandCheck = try XCTUnwrap(
            preamble.range(of: "if request.command != .requestKeyFrame {")
        )
        let cancellation = try XCTUnwrap(
            preamble.range(of: "keyFrameControlTask?.cancel()")
        )
        let release = try XCTUnwrap(
            preamble.range(of: "keyFrameControlTask = nil")
        )

        XCTAssertLessThan(visibilityCommandCheck.lowerBound, cancellation.lowerBound)
        XCTAssertLessThan(cancellation.lowerBound, release.lowerBound)
    }

    func testKeyFrameHandlerUsesBoundedRetryAndExactActorFences() throws {
        let handler = try keyFrameHandler()
        let retryLoop = try XCTUnwrap(handler.range(of: "for attempt in 0..<600"))
        let cancellationFence = try XCTUnwrap(
            handler.range(of: "guard !Task.isCancelled,")
        )
        let peerIdentityFence = try XCTUnwrap(
            handler.range(of: "self.peer === peer,")
        )
        let peerGenerationFence = try XCTUnwrap(
            handler.range(of: "requestPeerGeneration == peerGeneration,")
        )
        let recoveryEpochFence = try XCTUnwrap(
            handler.range(of: "requestRecoveryEpoch == recoveryProofEpoch")
        )
        let activeAcknowledgement = try XCTUnwrap(
            handler.range(of: "peer.acknowledgeControlRequestIfTransportHealthy(")
        )
        let revocationCheck = try XCTUnwrap(
            handler.range(of: "if Self.isRevokedScreenControlAuthorization(error),")
        )
        let failureStop = try XCTUnwrap(
            handler.range(
                of: "acknowledgeInactiveAfterVerifiedScreenStop(",
                range: revocationCheck.upperBound..<handler.endIndex
            )
        )
        let revocationRetry = String(
            handler[revocationCheck.lowerBound..<failureStop.lowerBound]
        )

        XCTAssertLessThan(retryLoop.lowerBound, cancellationFence.lowerBound)
        XCTAssertLessThan(cancellationFence.lowerBound, activeAcknowledgement.lowerBound)
        XCTAssertLessThan(peerIdentityFence.lowerBound, activeAcknowledgement.lowerBound)
        XCTAssertLessThan(peerGenerationFence.lowerBound, activeAcknowledgement.lowerBound)
        XCTAssertLessThan(recoveryEpochFence.lowerBound, activeAcknowledgement.lowerBound)
        XCTAssertEqual(
            handler.components(separatedBy: "attempt < 599").count - 1,
            2,
            "Both token-revocation and in-progress-transition retries must remain bounded."
        )
        XCTAssertEqual(
            handler.components(
                separatedBy: "try? await Task.sleep(for: .milliseconds(25))"
            ).count - 1,
            2
        )
        XCTAssertTrue(revocationRetry.contains("screenCaptureTransitionIsOwned"))
        XCTAssertTrue(revocationRetry.contains("attempt < 599"))
        XCTAssertTrue(
            revocationRetry.contains(
                "try? await Task.sleep(for: .milliseconds(25))"
            )
        )
        XCTAssertTrue(revocationRetry.contains("continue"))
        XCTAssertFalse(
            revocationRetry.contains("acknowledgeInactiveAfterVerifiedScreenStop(")
        )
    }

    func testSupersededKeyFrameErrorReturnsBeforeVerifiedStopHelper() throws {
        let handler = try keyFrameHandler()
        let supersededCheck = try XCTUnwrap(
            handler.range(of: "if Self.isSupersededScreenControlRequest(error) {")
        )
        let revocationCheck = try XCTUnwrap(
            handler.range(
                of: "if Self.isRevokedScreenControlAuthorization(error),",
                range: supersededCheck.upperBound..<handler.endIndex
            )
        )
        let supersededBlock = String(
            handler[supersededCheck.lowerBound..<revocationCheck.lowerBound]
        )
        let verifiedStop = try XCTUnwrap(
            handler.range(
                of: "acknowledgeInactiveAfterVerifiedScreenStop(",
                range: revocationCheck.upperBound..<handler.endIndex
            )
        )

        XCTAssertTrue(supersededBlock.contains("return"))
        XCTAssertFalse(
            supersededBlock.contains("acknowledgeInactiveAfterVerifiedScreenStop(")
        )
        XCTAssertLessThan(supersededCheck.lowerBound, verifiedStop.lowerBound)

        let missingReturnMutant = supersededBlock.replacingOccurrences(
            of: "return",
            with: "_ = ()"
        )
        XCTAssertNotEqual(missingReturnMutant, supersededBlock)
        XCTAssertFalse(
            missingReturnMutant.contains("return"),
            "The source oracle must detect removal of the superseded fast return."
        )
    }

    func testFailClosedStopRechecksExactTaskBeforeSuspendingPeerMedia() throws {
        let handler = try keyFrameHandler()
        let stopNeedle = "_ = await acknowledgeInactiveAfterVerifiedScreenStop("
        var searchStart = handler.startIndex
        var protectedStopCount = 0

        while let stop = handler.range(
            of: stopNeedle,
            range: searchStart..<handler.endIndex
        ) {
            let suspension = try XCTUnwrap(
                handler.range(
                    of: "await peer.suspendScreenMediaForTransportUncertainty()",
                    range: stop.upperBound..<handler.endIndex
                )
            )
            let postStopFence = String(handler[stop.upperBound..<suspension.lowerBound])
            XCTAssertTrue(postStopFence.contains("guard !Task.isCancelled,"))
            XCTAssertTrue(postStopFence.contains("self.peer === peer,"))
            XCTAssertTrue(
                postStopFence.contains("requestPeerGeneration == peerGeneration,")
            )
            XCTAssertTrue(
                postStopFence.contains("requestRecoveryEpoch == recoveryProofEpoch")
            )
            protectedStopCount += 1
            searchStart = suspension.upperBound
        }

        XCTAssertEqual(
            protectedStopCount,
            2,
            "Both fail-closed key-frame paths must fence a later Show before peer suspension."
        )
    }

    func testShowAndHideRevokeHostVideoTrackBeforeApplicationEvent() throws {
        let peerSource = try source(
            at: "shared/Sources/WebRTCTransport/WebRTCPeer.swift"
        )
        let receipt = try sourceSlice(
            in: peerSource,
            after: "    private func receiveControlRequest(_ request: WebRTCControlRequest) {",
            before: "    private func receiveControlAcknowledgement("
        )
        let visibilityCheck = try XCTUnwrap(
            receipt.range(
                of: "if request.command == .showScreen || request.command == .hideScreen {"
            )
        )
        let trackRevocation = try XCTUnwrap(
            receipt.range(
                of: "localVideoTrack?.isEnabled = false",
                range: visibilityCheck.upperBound..<receipt.endIndex
            )
        )
        let inputRevocation = try XCTUnwrap(
            receipt.range(
                of: "replaceHostInputSession(capability: nil, authorization: nil)",
                range: trackRevocation.upperBound..<receipt.endIndex
            )
        )
        let applicationEvent = try XCTUnwrap(
            receipt.range(of: "emit(.controlRequestReceived(request))")
        )

        XCTAssertLessThan(visibilityCheck.lowerBound, trackRevocation.lowerBound)
        XCTAssertLessThan(trackRevocation.lowerBound, inputRevocation.lowerBound)
        XCTAssertLessThan(inputRevocation.lowerBound, applicationEvent.lowerBound)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(at relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func keyFrameSchedulingBranch() throws -> String {
        let serviceSource = try source(
            at: "macOS/Sources/CaptureServer/WorldwideScreenService.swift"
        )
        return try sourceSlice(
            in: serviceSource,
            after: "        case .requestKeyFrame:",
            before: "    /// Re-evaluates an exact forwarding token across a bounded live display transition."
        )
    }

    private func controlRequestPreamble() throws -> String {
        let serviceSource = try source(
            at: "macOS/Sources/CaptureServer/WorldwideScreenService.swift"
        )
        return try sourceSlice(
            in: serviceSource,
            after: "    private func handleControlRequest(_ request: WebRTCControlRequest) async {",
            before: "        switch request.command {"
        )
    }

    private func keyFrameHandler() throws -> String {
        let serviceSource = try source(
            at: "macOS/Sources/CaptureServer/WorldwideScreenService.swift"
        )
        return try sourceSlice(
            in: serviceSource,
            after: "    private func handleKeyFrameRequest(",
            before: "    /// Stops native screen capture before sending the matching Inactive acknowledgement."
        )
    }

    private func sourceSlice(
        in source: String,
        after startMarker: String,
        before endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.upperBound)
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound
        )
        return String(source[start..<end])
    }
}

private struct InjectedKeyFramePolicyError: Error {}
