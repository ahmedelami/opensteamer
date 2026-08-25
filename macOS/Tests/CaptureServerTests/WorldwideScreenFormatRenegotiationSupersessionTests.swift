import Foundation
import XCTest
@testable import CaptureServer

final class WorldwideScreenFormatRenegotiationSupersessionTests: XCTestCase {
    func testNewVisibilityCommandSupersedesRetiredRebuildFailure() {
        XCTAssertTrue(
            superseded(
                visibilityCommandEpoch: 7,
                currentVisibilityCommandEpoch: 8
            )
        )
    }

    func testNewPeerRecoveryOrStoppedServiceSupersedesRetiredRebuildFailure() {
        XCTAssertTrue(superseded(peerGeneration: 2, currentPeerGeneration: 3))
        XCTAssertTrue(superseded(recoveryEpoch: 4, currentRecoveryEpoch: 5))
        XCTAssertTrue(superseded(serviceIsStopped: true))
    }

    func testUnchangedLifecycleKeepsTerminalRebuildFailureFailClosed() {
        XCTAssertFalse(superseded())
    }

    func testProductionCatchChecksSupersessionBeforeTerminalSessionStop() throws {
        let source = try serviceSource()
        let method = try sourceSlice(
            in: source,
            after: "    private func renegotiateScreenCaptureFormat(",
            before: "    /// A newer visibility command, peer, recovery epoch, or completed service owns any failure"
        )
        let visibilitySnapshot = try XCTUnwrap(
            method.range(of: "let visibilityCommandEpoch = screenVisibilityCommandEpoch")
        )
        let replacementStart = try XCTUnwrap(
            method.range(of: "_ = try await startScreenCaptureWithDisplayModeRetries(")
        )
        let supersessionCheck = try XCTUnwrap(
            method.range(of: "let wasSuperseded = Self.screenFormatRenegotiationWasSuperseded(")
        )
        let supersededReturn = try XCTUnwrap(
            method.range(
                of: "if wasSuperseded {",
                range: supersessionCheck.upperBound..<method.endIndex
            )
        )
        let terminalStop = try XCTUnwrap(
            method.range(
                of: "await stop()",
                range: supersededReturn.upperBound..<method.endIndex
            )
        )
        let protectedRegion = String(
            method[supersededReturn.lowerBound..<terminalStop.lowerBound]
        )

        XCTAssertLessThan(visibilitySnapshot.lowerBound, replacementStart.lowerBound)
        XCTAssertLessThan(replacementStart.lowerBound, supersessionCheck.lowerBound)
        XCTAssertLessThan(supersessionCheck.lowerBound, supersededReturn.lowerBound)
        XCTAssertTrue(protectedRegion.contains("return"))
        XCTAssertFalse(protectedRegion.contains("await stop()"))
    }

    private func superseded(
        visibilityCommandEpoch: UInt64 = 7,
        currentVisibilityCommandEpoch: UInt64 = 7,
        peerGeneration: UInt64 = 2,
        currentPeerGeneration: UInt64 = 2,
        recoveryEpoch: UInt64 = 4,
        currentRecoveryEpoch: UInt64 = 4,
        serviceIsStopped: Bool = false
    ) -> Bool {
        WorldwideScreenService.screenFormatRenegotiationWasSuperseded(
            visibilityCommandEpoch: visibilityCommandEpoch,
            currentVisibilityCommandEpoch: currentVisibilityCommandEpoch,
            peerGeneration: peerGeneration,
            currentPeerGeneration: currentPeerGeneration,
            recoveryEpoch: recoveryEpoch,
            currentRecoveryEpoch: currentRecoveryEpoch,
            serviceIsStopped: serviceIsStopped
        )
    }

    private func serviceSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/Sources/CaptureServer/WorldwideScreenService.swift"
            ),
            encoding: .utf8
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
