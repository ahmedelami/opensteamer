import Foundation
import WebRTCTransport
import XCTest
@testable import CaptureServer

/// Locks the additive scroll action to its acknowledged capability and existing input gates.
final class WorldwideRemoteScrollDispatchTests: XCTestCase {
    private let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    func testArmedHostCapabilityAdvertisesDragAndScroll() {
        let capability = WorldwideScreenService.remoteInputCapability(
            inputSessionID: sessionID,
            screenRequestID: 73
        )

        XCTAssertTrue(capability.supportsPrimaryDrag)
        XCTAssertTrue(capability.supportsScroll)
        XCTAssertEqual(capability.inputSessionID, sessionID)
        XCTAssertEqual(capability.screenRequestID, 73)
    }

    func testScrollAndDragRequireTheirOwnAdvertisedCapability() {
        let legacyCapability = WebRTCInputCapability(
            inputSessionID: sessionID,
            screenRequestID: 73
        )
        let scroll = WebRTCInputAction.scroll(
            anchor: .init(x: 0.25, y: 0.75),
            deltaX: -17,
            deltaY: 29
        )
        let drag = WebRTCInputAction.primaryDrag(
            start: .init(x: 0.25, y: 0.25),
            end: .init(x: 0.75, y: 0.75)
        )

        XCTAssertFalse(
            WorldwideScreenService.remoteInputActionIsSupported(
                scroll,
                capability: legacyCapability
            )
        )
        XCTAssertFalse(
            WorldwideScreenService.remoteInputActionIsSupported(
                drag,
                capability: legacyCapability
            )
        )
        XCTAssertTrue(
            WorldwideScreenService.remoteInputActionIsSupported(
                .tap(.init(x: 0.5, y: 0.5)),
                capability: legacyCapability
            )
        )

        let currentCapability = WorldwideScreenService.remoteInputCapability(
            inputSessionID: sessionID,
            screenRequestID: 73
        )
        XCTAssertTrue(
            WorldwideScreenService.remoteInputActionIsSupported(
                scroll,
                capability: currentCapability
            )
        )
        XCTAssertTrue(
            WorldwideScreenService.remoteInputActionIsSupported(
                drag,
                capability: currentCapability
            )
        )
    }

    func testScrollDiagnosticNameContainsNoAnchorOrDeltaPayload() {
        let action = WebRTCInputAction.scroll(
            anchor: .init(x: 0.123, y: 0.987),
            deltaX: -4_096,
            deltaY: 4_096
        )

        XCTAssertEqual(
            WorldwideScreenService.remoteInputDiagnosticName(for: action),
            "scroll"
        )
    }

    func testScrollDispatchRunsInsideTheExistingAuthorizationTransaction() throws {
        let admission = try serviceSlice(
            after: "    private func injectRemoteInputIfAuthorized(",
            before: "    /// A live, actor-owned display rebuild"
        )
        let capabilityCheck = try XCTUnwrap(
            admission.range(of: "Self.remoteInputActionIsSupported(request.action")
        )
        let inputAuthorization = try XCTUnwrap(
            admission.range(
                of: "try authorization.withValidAuthorization {",
                range: capabilityCheck.upperBound..<admission.endIndex
            )
        )
        let captureAuthorization = try XCTUnwrap(
            admission.range(
                of: "try expectedCaptureAuthorization.withValidAuthorization {",
                range: inputAuthorization.upperBound..<admission.endIndex
            )
        )
        let forwardingAuthorization = try XCTUnwrap(
            admission.range(
                of: "try expectedForwardingAuthorization.withValidAuthorization {",
                range: captureAuthorization.upperBound..<admission.endIndex
            )
        )
        let dispatch = try XCTUnwrap(
            admission.range(
                of: "return injectRemoteInput(request)",
                range: forwardingAuthorization.upperBound..<admission.endIndex
            )
        )

        XCTAssertLessThan(capabilityCheck.lowerBound, inputAuthorization.lowerBound)
        XCTAssertLessThan(inputAuthorization.lowerBound, captureAuthorization.lowerBound)
        XCTAssertLessThan(captureAuthorization.lowerBound, forwardingAuthorization.lowerBound)
        XCTAssertLessThan(forwardingAuthorization.lowerBound, dispatch.lowerBound)

        let routing = try serviceSlice(
            after: "    private func injectRemoteInput(\n",
            before: "    /// Verbose acceptance diagnostics"
        )
        XCTAssertTrue(routing.contains("case .scroll(let anchor, let deltaX, let deltaY):"))
        XCTAssertTrue(routing.contains("remoteInputController.handleScrollWithDiagnostics("))
        XCTAssertTrue(routing.contains("anchor: .init(x: anchor.x, y: anchor.y)"))
        XCTAssertTrue(routing.contains("deltaX: deltaX"))
        XCTAssertTrue(routing.contains("deltaY: deltaY"))
        XCTAssertTrue(routing.contains("viewerVideoSize: request.viewerVideoSize.map"))
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
