import Foundation
@testable import CaptureCore
@testable import CaptureServer
@testable import WebRTCTransport
import XCTest

final class WorldwideSystemAudioRecoveryTests: XCTestCase {
    func testStartPolicyResumesOnlyAnExactPausedPeerGeneration() {
        XCTAssertEqual(
            startMode(
                isLive: true,
                isPaused: false,
                hasSource: true,
                hasSink: true,
                hasAuthorization: true,
                generationMatches: true
            ),
            .alreadyLive
        )
        XCTAssertEqual(
            startMode(
                isLive: false,
                isPaused: true,
                hasSource: true,
                hasSink: true,
                hasAuthorization: false,
                generationMatches: true
            ),
            .resumeExisting
        )
        XCTAssertEqual(
            startMode(
                isLive: false,
                isPaused: false,
                hasSource: false,
                hasSink: false,
                hasAuthorization: false,
                generationMatches: false
            ),
            .startNew
        )
        XCTAssertNil(
            startMode(
                isLive: false,
                isPaused: true,
                hasSource: true,
                hasSink: true,
                hasAuthorization: false,
                generationMatches: false
            )
        )
        XCTAssertNil(
            startMode(
                isLive: false,
                isPaused: true,
                hasSource: true,
                hasSink: false,
                hasAuthorization: false,
                generationMatches: true
            )
        )
    }

    func testPauseResumeRotatesTransportAndEvidenceTokensWithoutCopyingProof() {
        let gate = WorldwideSystemAudioForwardingGate()
        let firstAudioAuthorization = WebRTCAudioAuthorization()
        let bindingID = UUID()
        let challenge = nativeChallenge(sequence: 1, callEpochNonce: UUID())
        let observation = SystemAudioMacFaceTimeActivityObservation(
            challenge: challenge,
            observationSequence: 1,
            causalBindingID: bindingID
        )

        XCTAssertTrue(
            gate.beginForwarding(with: firstAudioAuthorization)
        )
        let firstEvidence = evidenceAuthorization(
            from: gate,
            observation: observation
        )
        let repeatedEvidence = evidenceAuthorization(
            from: gate,
            observation: observation
        )
        XCTAssertTrue(firstEvidence === repeatedEvidence)

        gate.stopForwarding()
        XCTAssertFalse(firstAudioAuthorization.isValid)
        XCTAssertFalse(firstEvidence.isValid)

        let secondAudioAuthorization = WebRTCAudioAuthorization()
        XCTAssertTrue(
            gate.beginForwarding(with: secondAudioAuthorization)
        )
        let resumedEvidence = evidenceAuthorization(
            from: gate,
            observation: observation
        )

        XCTAssertTrue(secondAudioAuthorization.isValid)
        XCTAssertFalse(firstEvidence === resumedEvidence)
        XCTAssertEqual(
            resumedEvidence.callEpochNonce,
            challenge.callEpochNonce
        )
    }

    func testStaleAudioAuthorizationCannotForwardAfterRollover() {
        let gate = WorldwideSystemAudioForwardingGate()
        let staleAuthorization = WebRTCAudioAuthorization()
        XCTAssertTrue(gate.beginForwarding(with: staleAuthorization))

        gate.stopForwarding()
        let currentAuthorization = WebRTCAudioAuthorization()
        XCTAssertTrue(gate.beginForwarding(with: currentAuthorization))

        var staleOperationRan = false
        XCTAssertFalse(
            gate.withCurrentAuthorization(staleAuthorization) {
                staleOperationRan = true
            }
        )
        XCTAssertFalse(staleOperationRan)

        var currentOperationRan = false
        XCTAssertTrue(
            gate.withCurrentAuthorization(currentAuthorization) {
                currentOperationRan = true
            }
        )
        XCTAssertTrue(currentOperationRan)
    }

    func testEvidenceTokenRequiresChallengeAndRotatesForEpochMismatch() {
        let gate = WorldwideSystemAudioForwardingGate()
        XCTAssertTrue(
            gate.beginForwarding(with: WebRTCAudioAuthorization())
        )
        let bindingID = UUID()
        let firstEpoch = UUID()
        let secondEpoch = UUID()
        let firstObservation = SystemAudioMacFaceTimeActivityObservation(
            challenge: nativeChallenge(
                sequence: 1,
                callEpochNonce: firstEpoch
            ),
            observationSequence: 1,
            causalBindingID: bindingID
        )
        let secondObservation = SystemAudioMacFaceTimeActivityObservation(
            challenge: nativeChallenge(
                sequence: 2,
                callEpochNonce: secondEpoch
            ),
            observationSequence: 2,
            causalBindingID: bindingID
        )

        let firstEvidence = evidenceAuthorization(
            from: gate,
            observation: firstObservation
        )
        let secondEvidence = evidenceAuthorization(
            from: gate,
            observation: secondObservation
        )

        XCTAssertFalse(firstEvidence.isValid)
        XCTAssertFalse(firstEvidence === secondEvidence)
        XCTAssertEqual(secondEvidence.callEpochNonce, secondEpoch)

        var missingChallengeWasDelivered = false
        XCTAssertFalse(
            gate.withEvidenceAuthorization(
                for: SystemAudioMacFaceTimeActivityObservation(
                    challenge: nil,
                    observationSequence: 3,
                    causalBindingID: bindingID
                )
            ) { _, _ in
                missingChallengeWasDelivered = true
            }
        )
        XCTAssertFalse(missingChallengeWasDelivered)
        XCTAssertFalse(secondEvidence.isValid)
    }

    func testInactiveEvidenceIsOneShotAndEpochBound() {
        let gate = WorldwideSystemAudioForwardingGate()
        XCTAssertTrue(
            gate.beginForwarding(with: WebRTCAudioAuthorization())
        )
        let epoch = UUID()
        let first = SystemAudioMacFaceTimeActivityObservation(
            challenge: nativeChallenge(
                sequence: 1,
                callEpochNonce: epoch
            ),
            observationSequence: 1,
            causalBindingID: nil
        )
        let second = SystemAudioMacFaceTimeActivityObservation(
            challenge: first.challenge,
            observationSequence: 2,
            causalBindingID: nil
        )

        let firstEvidence = evidenceAuthorization(
            from: gate,
            observation: first
        )
        let secondEvidence = evidenceAuthorization(
            from: gate,
            observation: second
        )

        XCTAssertEqual(firstEvidence.callEpochNonce, epoch)
        XCTAssertFalse(firstEvidence.isValid)
        XCTAssertFalse(firstEvidence === secondEvidence)
        XCTAssertTrue(secondEvidence.isValid)
    }

    func testServiceRecoveryRetainsSourceAndFullStopDestroysIt() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let service = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/Sources/CaptureServer/WorldwideScreenService.swift"
            ),
            encoding: .utf8
        )
        let recoveryStop = try sourceSlice(
            in: service,
            startMarker:
                "private func stopSystemAudioForTransportUncertainty",
            endMarker: "private func stopSystemAudio() async"
        )
        XCTAssertTrue(
            recoveryStop.contains(
                "pauseSystemAudioForTransportUncertainty()"
            )
        )
        XCTAssertFalse(recoveryStop.contains("await stopSystemAudio()"))
        XCTAssertFalse(recoveryStop.contains("source.stop()"))

        let resume = try sourceSlice(
            in: service,
            startMarker: "private func resumeSystemAudio(",
            endMarker:
                "private func stopSystemAudioForTransportUncertainty"
        )
        XCTAssertTrue(resume.contains("audioSource === source"))
        XCTAssertTrue(resume.contains("audioSink === sink"))
        XCTAssertTrue(
            resume.contains("let authorization = WebRTCAudioAuthorization()")
        )
        XCTAssertTrue(
            resume.contains("sink.beginForwarding(with: authorization)")
        )
        XCTAssertTrue(
            resume.contains("installCurrentMacHostedCallChallenge(on: source)")
        )

        let fullStop = try sourceSlice(
            in: service,
            startMarker: "private func stopSystemAudio() async",
            endMarker: "private func installMacHostedCallChallenge"
        )
        XCTAssertTrue(fullStop.contains("try await source.stop()"))
    }

    private func startMode(
        isLive: Bool,
        isPaused: Bool,
        hasSource: Bool,
        hasSink: Bool,
        hasAuthorization: Bool,
        generationMatches: Bool
    ) -> WorldwideSystemAudioStartMode? {
        WorldwideSystemAudioRecoveryPolicy.startMode(
            isLive: isLive,
            isPausedForRecovery: isPaused,
            hasSource: hasSource,
            hasSink: hasSink,
            hasValidAuthorization: hasAuthorization,
            peerGenerationMatches: generationMatches
        )
    }

    private func evidenceAuthorization(
        from gate: WorldwideSystemAudioForwardingGate,
        observation: SystemAudioMacFaceTimeActivityObservation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> WebRTCMacHostedCallEvidenceAuthorization {
        var delivered: WebRTCMacHostedCallEvidenceAuthorization?
        XCTAssertTrue(
            gate.withEvidenceAuthorization(for: observation) {
                _, evidenceAuthorization in
                delivered = evidenceAuthorization
            },
            file: file,
            line: line
        )
        return try! XCTUnwrap(delivered, file: file, line: line)
    }

    private func nativeChallenge(
        sequence: UInt64,
        callEpochNonce: UUID
    ) -> SystemAudioMacFaceTimeActivityChallenge {
        SystemAudioMacFaceTimeActivityChallenge(
            sequence: sequence,
            nonce: UUID(),
            callEpochNonce: callEpochNonce
        )
    }

    private func sourceSlice(
        in source: String,
        startMarker: String,
        endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(
            source.range(of: startMarker)?.upperBound
        )
        let end = try XCTUnwrap(
            source.range(
                of: endMarker,
                range: start..<source.endIndex
            )?.lowerBound
        )
        return String(source[start..<end])
    }
}
