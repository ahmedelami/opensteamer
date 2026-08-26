import Foundation
import XCTest

/// Locks the remote-input authorization boundary to the exact live screen-format generation.
final class WorldwideRemoteInputScaleTransitionTests: XCTestCase {
    func testIrreversibleInputPostHoldsForwardingTokenAcrossFinalSinkCheck() throws {
        let method = try serviceSlice(
            after: "    private func injectRemoteInputIfAuthorized(",
            before: "    /// Maps validated wire actions onto the narrow macOS input controller surface."
        )
        let inputAuthorization = try XCTUnwrap(
            method.range(
                of: "let result: WorldwideRemoteInputInjectionOutcome? ="
            )
        )
        let captureAuthorization = try XCTUnwrap(
            method.range(
                of: "try expectedCaptureAuthorization.withValidAuthorization {",
                range: inputAuthorization.upperBound..<method.endIndex
            )
        )
        let forwardingAuthorization = try XCTUnwrap(
            method.range(
                of: "try expectedForwardingAuthorization.withValidAuthorization {",
                range: captureAuthorization.upperBound..<method.endIndex
            )
        )
        let sinkCheck = try XCTUnwrap(
            method.range(
                of: "captureSink?.allowsActiveUseWhileAuthorizationHeld(",
                range: forwardingAuthorization.upperBound..<method.endIndex
            )
        )
        let injection = try XCTUnwrap(
            method.range(
                of: "return injectRemoteInput(request)",
                range: sinkCheck.upperBound..<method.endIndex
            )
        )
        let unlockedClassification = try XCTUnwrap(
            method.range(
                of: "return result ?? remoteInputCaptureUnavailableResult()",
                range: injection.upperBound..<method.endIndex
            )
        )

        XCTAssertLessThan(inputAuthorization.lowerBound, captureAuthorization.lowerBound)
        XCTAssertLessThan(captureAuthorization.lowerBound, forwardingAuthorization.lowerBound)
        XCTAssertLessThan(forwardingAuthorization.lowerBound, sinkCheck.lowerBound)
        XCTAssertLessThan(sinkCheck.lowerBound, injection.lowerBound)
        XCTAssertLessThan(injection.lowerBound, unlockedClassification.lowerBound)
        XCTAssertFalse(
            String(method[forwardingAuthorization.lowerBound..<injection.upperBound])
                .contains("captureSink?.allowsActiveUse(\n")
        )
        XCTAssertFalse(
            String(method[forwardingAuthorization.lowerBound..<injection.upperBound])
                .contains("remoteInputCaptureUnavailableResult()")
        )
    }

    func testDisplayModeCallbackClearsOldCoordinateMapBeforeTokenRevocationAndRebuild() throws {
        let sink = try serviceSlice(
            after: "    func displayModeDidChange() {",
            before: "    func screenVideoCaptureSource(\n        _ source: ScreenVideoCaptureSource,"
        )
        let stateTransition = try XCTUnwrap(
            sink.range(of: "let transition = lock.withLock")
        )
        let clearGeometry = try XCTUnwrap(
            sink.range(of: "remoteInputController.updateScreenVideoFrameGeometry(nil)")
        )
        let revokeToken = try XCTUnwrap(
            sink.range(
                of: "transition.retiredAuthorization?.revoke()",
                range: clearGeometry.upperBound..<sink.endIndex
            )
        )
        let scheduleRebuild = try XCTUnwrap(
            sink.range(
                of: "didRequireCaptureFormatRenegotiation(self)",
                range: revokeToken.upperBound..<sink.endIndex
            )
        )

        XCTAssertLessThan(stateTransition.lowerBound, clearGeometry.lowerBound)
        XCTAssertLessThan(clearGeometry.lowerBound, revokeToken.lowerBound)
        XCTAssertLessThan(revokeToken.lowerBound, scheduleRebuild.lowerBound)
    }

    func testOwnedFormatRebuildIsNonTerminalForTheInputCapability() throws {
        let admission = try serviceSlice(
            after: "    private func injectRemoteInputIfAuthorized(",
            before: "    /// Maps validated wire actions onto the narrow macOS input controller surface."
        )
        XCTAssertTrue(admission.contains("return remoteInputCaptureUnavailableResult()"))

        let unavailable = try serviceSlice(
            after: "    private func remoteInputCaptureUnavailableResult()",
            before: "    /// Maps validated wire actions onto the narrow macOS input controller surface."
        )
        XCTAssertTrue(unavailable.contains("screenCaptureTransitionIsOwned"))
        XCTAssertTrue(unavailable.contains(".rejected(.screenFormatChanging)"))
        XCTAssertTrue(unavailable.contains("formatOrigin: .captureGateUnavailable"))

        let feedback = try serviceSlice(
            after: "    private func transportFeedback(",
            before: "    /// Revokes the transport token and controller state synchronously."
        )
        let transitionCase = try XCTUnwrap(
            feedback.range(of: "case .screenFormatChanging:")
        )
        let rateLimited = try XCTUnwrap(
            feedback.range(
                of: "reason = .rateLimited",
                range: transitionCase.upperBound..<feedback.endIndex
            )
        )
        let nonRevoking = try XCTUnwrap(
            feedback.range(
                of: "revokesSession = false",
                range: rateLimited.upperBound..<feedback.endIndex
            )
        )
        XCTAssertLessThan(rateLimited.lowerBound, nonRevoking.lowerBound)
    }

    func testPreConfigurationFenceRemainsOwnedAndNonTerminalForInputCapability() throws {
        let ownership = try serviceSlice(
            after: "    private var screenCaptureTransitionIsOwned: Bool {",
            before: "    /// A newer ordered request owns the screen state"
        )
        XCTAssertTrue(
            ownership.contains("currentSink.isDisplayConfigurationInProgress")
        )

        let sinkState = try serviceSlice(
            after: "    var isDisplayConfigurationInProgress: Bool {",
            before: "    /// Privacy-safe capture state sampled"
        )
        XCTAssertTrue(sinkState.contains("displayConfigurationInProgress"))
        XCTAssertTrue(sinkState.contains("forwardingPhase == .starting"))
        XCTAssertTrue(sinkState.contains("forwardingPhase == .active"))
        XCTAssertTrue(sinkState.contains("callbackGateAllowsEntry"))

        let request = try serviceSlice(
            after: "    private func handleRemoteInputRequest(",
            before: "    /// Holds input, capture, then the exact forwarding authorization"
        )
        XCTAssertTrue(request.contains("if feedback.revokesSession"))

        let unavailable = try serviceSlice(
            after: "    private func remoteInputCaptureUnavailableResult()",
            before: "    /// Maps validated wire actions onto the narrow macOS input controller surface."
        )
        XCTAssertTrue(unavailable.contains(".rejected(.screenFormatChanging)"))

        let feedback = try serviceSlice(
            after: "    private func transportFeedback(",
            before: "    /// Revokes the transport token and controller state synchronously."
        )
        let transitionCase = try XCTUnwrap(
            feedback.range(of: "case .screenFormatChanging:")
        )
        let nonRevoking = try XCTUnwrap(
            feedback.range(
                of: "revokesSession = false",
                range: transitionCase.upperBound..<feedback.endIndex
            )
        )
        XCTAssertLessThan(transitionCase.lowerBound, nonRevoking.lowerBound)
    }

    func testNativeRestartRetryPreservesInputOnlyForAnOwnedFormatTransition() throws {
        let startup = try serviceSlice(
            after: "    private func startScreenCapture(\n",
            before: "    /// Revokes visibility before awaiting native ScreenCaptureKit shutdown."
        )
        XCTAssertTrue(
            startup.contains(
                "revokeCaptureAuthorization(\n                    preservingRemoteInput: screenCaptureTransitionIsOwned"
            )
        )

        let revocation = try serviceSlice(
            after: "    private func revokeCaptureAuthorization(\n",
            before: "}\n\n/// Actor-owned handoff for sequential live capture-format rebuilds."
        )
        XCTAssertTrue(revocation.contains("preservingRemoteInput: Bool = false"))
        XCTAssertTrue(revocation.contains("if !preservingRemoteInput"))
        XCTAssertTrue(revocation.contains("revokeRemoteInputAuthorization()"))
    }

    private func serviceSlice(after startMarker: String, before endMarker: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/Sources/CaptureServer/WorldwideScreenService.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: startMarker)?.upperBound)
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound
        )
        return String(source[start..<end])
    }
}
