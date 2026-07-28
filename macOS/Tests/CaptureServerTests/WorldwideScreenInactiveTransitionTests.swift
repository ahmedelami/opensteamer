import Foundation
import XCTest
@testable import CaptureServer

/// Defines the ordering and failure boundary for acknowledging that remote screen video is hidden.
///
/// The host may report `.inactive` only after native capture has stopped. A native-stop failure
/// closes the session because continued capture would contradict the acknowledgement; an ACK
/// transport failure is reported but does not retroactively invalidate the completed local stop.
@MainActor
final class WorldwideScreenInactiveTransitionTests: XCTestCase {
    func testSuccessfulTransitionStopsNativeCaptureBeforeInactiveAcknowledgement() async {
        let probe = InactiveTransitionProbe()

        let failure = await WorldwideScreenInactiveTransition.perform(
            stopNativeCapture: {
                probe.events.append("native-stop")
            },
            acknowledgeInactive: {
                probe.events.append("inactive-ack")
                probe.inactiveAcknowledgementCount += 1
            },
            failClosed: { error in
                probe.events.append("close-session")
                probe.closeSessionCount += 1
                probe.closeError = error
            }
        )

        XCTAssertNil(failure)
        XCTAssertEqual(probe.events, ["native-stop", "inactive-ack"])
        XCTAssertEqual(probe.inactiveAcknowledgementCount, 1)
        XCTAssertEqual(probe.closeSessionCount, 0)
        XCTAssertNil(probe.closeError)
    }

    func testThrowingNativeStopRejectsInactiveAcknowledgementAndClosesSession() async {
        let source = ThrowingScreenStopSource()
        let probe = InactiveTransitionProbe()

        let failure = await WorldwideScreenInactiveTransition.perform(
            stopNativeCapture: {
                probe.events.append("native-stop")
                try await source.stop()
            },
            acknowledgeInactive: {
                probe.events.append("inactive-ack")
                probe.inactiveAcknowledgementCount += 1
            },
            failClosed: { error in
                probe.events.append("close-session")
                probe.closeSessionCount += 1
                probe.closeError = error
            }
        )

        XCTAssertEqual(source.stopAttemptCount, 1)
        XCTAssertEqual(probe.inactiveAcknowledgementCount, 0)
        XCTAssertEqual(probe.closeSessionCount, 1)
        XCTAssertEqual(probe.events, ["native-stop", "close-session"])
        XCTAssertEqual(probe.closeError as? ThrowingScreenStopSource.StopError, .injected)

        guard case .nativeStop(let error) = failure else {
            return XCTFail("A throwing native stop must remain a visible native-stop failure.")
        }
        XCTAssertEqual(error as? ThrowingScreenStopSource.StopError, .injected)
    }

    func testAcknowledgementFailureOccursAfterNativeStopWithoutClosingSession() async {
        let probe = InactiveTransitionProbe()

        let failure = await WorldwideScreenInactiveTransition.perform(
            stopNativeCapture: {
                probe.events.append("native-stop")
            },
            acknowledgeInactive: {
                probe.events.append("inactive-ack")
                probe.inactiveAcknowledgementCount += 1
                throw InactiveAcknowledgementError.injected
            },
            failClosed: { error in
                probe.events.append("close-session")
                probe.closeSessionCount += 1
                probe.closeError = error
            }
        )

        XCTAssertEqual(probe.events, ["native-stop", "inactive-ack"])
        XCTAssertEqual(probe.inactiveAcknowledgementCount, 1)
        XCTAssertEqual(probe.closeSessionCount, 0)
        XCTAssertNil(probe.closeError)
        guard case .acknowledgement(let error) = failure else {
            return XCTFail("A throwing acknowledgement must remain a visible ACK failure.")
        }
        XCTAssertEqual(error as? InactiveAcknowledgementError, .injected)
    }

    func testHideCommandUsesVerifiedNativeStopBoundaryBeforeInactiveAcknowledgement() throws {
        // Behavioral tests cover the transition helper. This source-level integration oracle makes
        // sure the production Hide branch still calls that helper instead of acknowledging the peer
        // directly. The mutation check below proves the oracle detects the bypass it guards against.
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serviceSourceURL = repositoryRoot.appendingPathComponent(
            "macOS/Sources/CaptureServer/WorldwideScreenService.swift"
        )
        let serviceSource = try String(contentsOf: serviceSourceURL, encoding: .utf8)
        let handler = try sourceSlice(
            in: serviceSource,
            after: "    private func handleControlRequest(_ request: WebRTCControlRequest) async {",
            before: "    @discardableResult\n    private func acknowledgeInactiveAfterVerifiedScreenStop("
        )
        let hideBranch = try sourceSlice(
            in: handler,
            after: "        case .hideScreen:",
            before: "        case .requestKeyFrame:"
        )

        XCTAssertEqual(hideContractViolations(in: hideBranch), [])

        let directAcknowledgementMutant = hideBranch.replacingOccurrences(
            of: "acknowledgeInactiveAfterVerifiedScreenStop(",
            with: "peer.acknowledgeControlRequest("
        )
        XCTAssertNotEqual(directAcknowledgementMutant, hideBranch)
        XCTAssertEqual(
            Set(hideContractViolations(in: directAcknowledgementMutant)),
            Set([
                "verified-boundary-call-count",
                "direct-peer-acknowledgement",
            ]),
            "The source oracle itself must reject a regression that bypasses the boundary."
        )

        let verifiedBoundary = try sourceSlice(
            in: serviceSource,
            after: "    private func acknowledgeInactiveAfterVerifiedScreenStop(",
            before: "    @discardableResult\n    private func stopScreenCaptureOrCloseSession("
        )
        XCTAssertTrue(
            verifiedBoundary.contains("WorldwideScreenInactiveTransition.perform("),
            "The production helper must use the behavior-tested transition boundary."
        )
        let nativeStop = try XCTUnwrap(
            verifiedBoundary.range(of: "try await self.stopScreenCapture()")
        )
        let inactiveAcknowledgement = try XCTUnwrap(
            verifiedBoundary.range(
                of: "try await peer.acknowledgeControlRequest(\n                    id: requestID,\n                    state: .inactive"
            )
        )
        XCTAssertLessThan(
            nativeStop.lowerBound,
            inactiveAcknowledgement.lowerBound,
            "The production boundary must attempt native stop before sending Inactive."
        )
    }

    func testIPhoneMicrophoneInstallationDelegatesClassifiedTrackToGenerationDriver() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serviceSourceURL = repositoryRoot.appendingPathComponent(
            "macOS/Sources/CaptureServer/WorldwideScreenService.swift"
        )
        let serviceSource = try String(
            contentsOf: serviceSourceURL,
            encoding: .utf8
        )

        let installation = try sourceSlice(
            in: serviceSource,
            after: "    private func installIPhoneMicrophoneTrack(",
            before: "    /// Converts unexplained audio-start failure on a healthy route into ICE recovery."
        )
        let laneCheck = try XCTUnwrap(
            installation.range(
                of: "track.logicalLane == .iPhoneMicrophone"
            )
        )
        let driverInstallation = try XCTUnwrap(
            installation.range(
                of: "await iPhoneMicrophoneForwarding.installTrack(track)"
            )
        )
        XCTAssertLessThan(
            laneCheck.lowerBound,
            driverInstallation.lowerBound
        )
        XCTAssertFalse(installation.contains(".trackID"))
        XCTAssertFalse(
            installation.contains(
                "WebRTCAudioTrackIdentifiers.iPhoneMicrophone"
            )
        )

        let driverSourceURL = repositoryRoot.appendingPathComponent(
            "macOS/Sources/CaptureServer/" +
                "WorldwideIPhoneMicrophoneForwardingDriver.swift"
        )
        let driverSource = try String(
            contentsOf: driverSourceURL,
            encoding: .utf8
        )
        XCTAssertTrue(
            driverSource.contains(
                "candidate.peer === attempt.peer"
            )
        )
        XCTAssertTrue(
            driverSource.contains(
                "candidate.track === attempt.track"
            )
        )
        XCTAssertTrue(
            driverSource.contains(
                "candidate.key == attempt.key"
            ),
            "Every post-await continuation must retain the complete generation key."
        )
        XCTAssertTrue(
            serviceSource.contains(
                "peer.enableRemoteIPhoneMicrophonePlaybackIfTransportHealthy("
            ),
            "The service must delegate final current-object and health admission to the peer."
        )
    }

    func testIPhoneMicrophoneForwardingRevalidatesAfterBlockingOutputStart() async {
        let eventLog = MicrophoneForwardingEventLog()
        let startEntered = MicrophoneTestExpectation(
            description: "output start entered"
        )
        let startGate = DispatchSemaphore(value: 0)
        let output = MicrophoneTestOutput(
            startEntered: startEntered,
            startGate: startGate,
            eventLog: eventLog
        )
        let factory = MicrophoneOutputFactory(outputs: [output])
        let peer = MicrophoneTestPeer(healthy: true)
        let track = MicrophoneTestTrack()
        let harness = MicrophoneForwardingHarness(
            factory: factory,
            eventLog: eventLog
        )

        let startTask = Task {
            try await harness.start(peer: peer, track: track)
        }
        defer { output.releaseStart() }

        await fulfillment(of: [startEntered.expectation], timeout: 2)
        XCTAssertEqual(
            eventLog.snapshot(),
            ["published", "start"],
            "The pending attempt must be published before synchronous output startup blocks."
        )

        await peer.setHealthy(false)
        output.releaseStart()

        do {
            _ = try await startTask.value
            XCTFail("Fresh post-start admission must reject the unhealthy peer.")
        } catch let error as MicrophoneAdmissionTestError {
            XCTAssertEqual(error, .transportNotHealthy)
        } catch {
            XCTFail("Unexpected admission error: \(error)")
        }

        let snapshot = await harness.snapshot()
        XCTAssertFalse(snapshot.hasPublishedAttempt)
        XCTAssertFalse(snapshot.isActive)
        XCTAssertEqual(snapshot.retiringAttemptCount, 0)
        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertEqual(output.startCount, 1)
        XCTAssertGreaterThanOrEqual(output.stopCount, 1)
        XCTAssertFalse(track.isEnabled)
    }

    func testReentrantIPhoneMicrophoneStartDoesNotCreateDuplicateOutput() async throws {
        let eventLog = MicrophoneForwardingEventLog()
        let startEntered = MicrophoneTestExpectation(
            description: "first output start entered"
        )
        let admissionEntered = MicrophoneTestExpectation(
            description: "first peer admission entered"
        )
        let startGate = DispatchSemaphore(value: 0)
        let admissionGate = MicrophoneAdmissionGate()
        let firstOutput = MicrophoneTestOutput(
            startEntered: startEntered,
            startGate: startGate,
            eventLog: eventLog
        )
        let duplicateOutput = MicrophoneTestOutput()
        let factory = MicrophoneOutputFactory(
            outputs: [firstOutput, duplicateOutput]
        )
        let peer = MicrophoneTestPeer(
            healthy: true,
            admissionGate: admissionGate,
            admissionEntered: admissionEntered
        )
        let track = MicrophoneTestTrack()
        let harness = MicrophoneForwardingHarness(
            factory: factory,
            eventLog: eventLog
        )

        let firstTask = Task {
            try await harness.start(peer: peer, track: track)
        }
        defer {
            firstOutput.releaseStart()
            Task { await admissionGate.release() }
        }

        await fulfillment(of: [startEntered.expectation], timeout: 2)
        let reentrantTask = Task {
            try await harness.start(peer: peer, track: track)
        }

        firstOutput.releaseStart()
        await fulfillment(of: [admissionEntered.expectation], timeout: 2)

        let reentrantResult = try await reentrantTask.value
        XCTAssertEqual(reentrantResult, .alreadyPublished)
        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertEqual(firstOutput.startCount, 1)
        XCTAssertEqual(duplicateOutput.startCount, 0)
        XCTAssertEqual(
            eventLog.snapshot().filter { $0 == "published" }.count,
            1,
            "A duplicate start for the same current object must not publish another output."
        )

        await admissionGate.release()
        let firstResult = try await firstTask.value
        XCTAssertEqual(firstResult, .started)

        let activeSnapshot = await harness.snapshot()
        XCTAssertTrue(activeSnapshot.hasPublishedAttempt)
        XCTAssertTrue(activeSnapshot.isActive)
        XCTAssertEqual(activeSnapshot.retiringAttemptCount, 0)
        XCTAssertTrue(track.isEnabled)

        await harness.stopCurrent()
        XCTAssertFalse(track.isEnabled)
    }

    func testCurrentRuntimeFailureStopsAndUnpublishesOnlyOwnedAttempt() async throws {
        let output = MicrophoneTestOutput()
        let factory = MicrophoneOutputFactory(outputs: [output])
        let peer = MicrophoneTestPeer(healthy: true)
        let track = MicrophoneTestTrack()
        let harness = MicrophoneForwardingHarness(factory: factory)

        let result = try await harness.start(
            peer: peer,
            track: track
        )
        XCTAssertEqual(result, .started)
        XCTAssertTrue(track.isEnabled)

        let handled = await harness.handleRuntimeFailure(from: output)
        XCTAssertTrue(handled)

        let snapshot = await harness.snapshot()
        XCTAssertFalse(snapshot.hasPublishedAttempt)
        XCTAssertFalse(snapshot.isActive)
        XCTAssertEqual(snapshot.retiringAttemptCount, 0)
        XCTAssertFalse(track.isEnabled)
        XCTAssertEqual(output.stopCount, 1)

        let repeated = await harness.handleRuntimeFailure(from: output)
        XCTAssertFalse(repeated)
        XCTAssertEqual(
            output.stopCount,
            1,
            "A consumed output failure must not repeat teardown."
        )
    }

    func testStaleOutputRuntimeFailureCannotAffectSamePeerSameTrackReplacement() async throws {
        let staleOutput = MicrophoneTestOutput()
        let replacementOutput = MicrophoneTestOutput()
        let factory = MicrophoneOutputFactory(
            outputs: [staleOutput, replacementOutput]
        )
        let peer = MicrophoneTestPeer(healthy: true)
        let track = MicrophoneTestTrack()
        let harness = MicrophoneForwardingHarness(factory: factory)

        let staleResult = try await harness.start(
            peer: peer,
            track: track
        )
        XCTAssertEqual(staleResult, .started)
        XCTAssertTrue(track.isEnabled)

        await harness.stopCurrent()
        XCTAssertFalse(track.isEnabled)
        XCTAssertEqual(staleOutput.stopCount, 1)

        let replacementResult = try await harness.start(
            peer: peer,
            track: track
        )
        XCTAssertEqual(replacementResult, .started)
        XCTAssertTrue(track.isEnabled)
        XCTAssertEqual(factory.creationCount, 2)
        XCTAssertEqual(replacementOutput.startCount, 1)
        XCTAssertEqual(replacementOutput.stopCount, 0)

        let staleFailureWasCurrent = await harness.handleRuntimeFailure(
            from: staleOutput
        )
        XCTAssertFalse(staleFailureWasCurrent)

        let snapshot = await harness.snapshot()
        XCTAssertTrue(snapshot.hasPublishedAttempt)
        XCTAssertTrue(snapshot.isActive)
        XCTAssertEqual(snapshot.retiringAttemptCount, 0)
        XCTAssertTrue(
            track.isEnabled,
            "A stale output must not disable the track reused by its replacement."
        )
        XCTAssertEqual(
            replacementOutput.stopCount,
            0,
            "A stale output must not stop the replacement output."
        )

        await harness.stopCurrent()
        XCTAssertFalse(track.isEnabled)
        XCTAssertEqual(replacementOutput.stopCount, 1)
    }

    func testStaleAttemptCompletionAndRuntimeFailureCannotAffectReplacement() async throws {
        let staleAdmissionEntered = MicrophoneTestExpectation(
            description: "stale admission entered"
        )
        let staleAdmissionGate = MicrophoneAdmissionGate()
        let staleOutput = MicrophoneTestOutput()
        let replacementOutput = MicrophoneTestOutput()
        let factory = MicrophoneOutputFactory(
            outputs: [staleOutput, replacementOutput]
        )
        let stalePeer = MicrophoneTestPeer(
            healthy: true,
            admissionGate: staleAdmissionGate,
            admissionEntered: staleAdmissionEntered
        )
        let replacementPeer = MicrophoneTestPeer(healthy: true)
        let staleTrack = MicrophoneTestTrack()
        let replacementTrack = MicrophoneTestTrack()
        let harness = MicrophoneForwardingHarness(factory: factory)

        let staleTask = Task {
            try await harness.start(peer: stalePeer, track: staleTrack)
        }
        defer { Task { await staleAdmissionGate.release() } }

        await fulfillment(of: [staleAdmissionEntered.expectation], timeout: 2)
        await harness.stopCurrent()

        let cancelledSnapshot = await harness.snapshot()
        XCTAssertFalse(cancelledSnapshot.hasPublishedAttempt)
        XCTAssertEqual(cancelledSnapshot.retiringAttemptCount, 1)
        XCTAssertFalse(staleTrack.isEnabled)

        let replacementResult = try await harness.start(
            peer: replacementPeer,
            track: replacementTrack
        )
        XCTAssertEqual(replacementResult, .started)
        XCTAssertTrue(replacementTrack.isEnabled)
        XCTAssertEqual(replacementOutput.startCount, 1)
        XCTAssertEqual(replacementOutput.stopCount, 0)

        let staleStopCountBeforeFailure = staleOutput.stopCount
        let staleFailureWasCurrent = await harness.handleRuntimeFailure(
            from: staleOutput
        )
        XCTAssertFalse(staleFailureWasCurrent)
        XCTAssertEqual(
            staleOutput.stopCount,
            staleStopCountBeforeFailure + 1,
            "A retiring output may repeat only its own idempotent stop."
        )
        XCTAssertFalse(staleTrack.isEnabled)
        XCTAssertTrue(replacementTrack.isEnabled)
        XCTAssertEqual(replacementOutput.stopCount, 0)

        let afterStaleFailure = await harness.snapshot()
        XCTAssertTrue(afterStaleFailure.hasPublishedAttempt)
        XCTAssertTrue(afterStaleFailure.isActive)
        XCTAssertEqual(afterStaleFailure.retiringAttemptCount, 1)

        await staleAdmissionGate.release()
        let staleResult = try await staleTask.value
        XCTAssertEqual(staleResult, .superseded)

        let finalSnapshot = await harness.snapshot()
        XCTAssertTrue(finalSnapshot.hasPublishedAttempt)
        XCTAssertTrue(finalSnapshot.isActive)
        XCTAssertEqual(finalSnapshot.retiringAttemptCount, 0)
        XCTAssertFalse(staleTrack.isEnabled)
        XCTAssertTrue(replacementTrack.isEnabled)
        XCTAssertGreaterThanOrEqual(staleOutput.stopCount, 1)
        XCTAssertEqual(
            replacementOutput.stopCount,
            0,
            "A stale cleanup must stop only its exact output."
        )

        await harness.stopCurrent()
        XCTAssertFalse(replacementTrack.isEnabled)
        XCTAssertEqual(replacementOutput.stopCount, 1)
    }

    private func sourceSlice(
        in source: String,
        after startMarker: String,
        before endMarker: String
    ) throws -> String {
        // Markers intentionally name neighboring declarations/cases so extraction fails loudly if
        // production control-flow structure changes and the integration contract needs review.
        let start = try XCTUnwrap(source.range(of: startMarker)?.upperBound)
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound
        )
        return String(source[start..<end])
    }

    private func hideContractViolations(in hideBranch: String) -> [String] {
        // Return all violations to keep mutant failures diagnostic rather than stopping at the
        // first missing argument or forbidden direct acknowledgement.
        var violations: [String] = []
        let verifiedCallCount = hideBranch.components(
            separatedBy: "acknowledgeInactiveAfterVerifiedScreenStop("
        ).count - 1
        if verifiedCallCount != 1 {
            violations.append("verified-boundary-call-count")
        }
        if !hideBranch.contains("peer: peer,") {
            violations.append("peer-argument")
        }
        if !hideBranch.contains("requestID: request.id,") {
            violations.append("request-id-argument")
        }
        if !hideBranch.contains("context: \"screen Hide\"") {
            violations.append("hide-context")
        }
        if hideBranch.contains("peer.acknowledgeControlRequest(") {
            violations.append("direct-peer-acknowledgement")
        }
        return violations
    }
}

private enum InactiveAcknowledgementError: Error, Equatable {
    case injected
}

/// Failure-injection source that records whether native-stop was attempted exactly once.
@MainActor
private final class ThrowingScreenStopSource {
    enum StopError: Error, Equatable {
        case injected
    }

    private(set) var stopAttemptCount = 0

    func stop() async throws {
        stopAttemptCount += 1
        throw StopError.injected
    }
}

/// Main-actor event ledger used to assert externally observable ordering across async closures.
@MainActor
private final class InactiveTransitionProbe {
    var events: [String] = []
    var inactiveAcknowledgementCount = 0
    var closeSessionCount = 0
    var closeError: (any Error)?
}

private enum MicrophoneAdmissionTestError: Error, Equatable {
    case transportNotHealthy
}

private actor MicrophoneAdmissionGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private final class MicrophoneTestExpectation: @unchecked Sendable {
    let expectation: XCTestExpectation

    init(description: String) {
        expectation = XCTestExpectation(description: description)
    }

    func fulfill() {
        expectation.fulfill()
    }
}

private final class MicrophoneForwardingEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class MicrophoneTestTrack: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        self.enabled = enabled
        lock.unlock()
    }
}

private final class MicrophoneTestOutput:
    WorldwideIPhoneMicrophoneOutput,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let startEntered: MicrophoneTestExpectation?
    private let startGate: DispatchSemaphore?
    private let eventLog: MicrophoneForwardingEventLog?
    private var startCountStorage = 0
    private var stopCountStorage = 0

    init(
        startEntered: MicrophoneTestExpectation? = nil,
        startGate: DispatchSemaphore? = nil,
        eventLog: MicrophoneForwardingEventLog? = nil
    ) {
        self.startEntered = startEntered
        self.startGate = startGate
        self.eventLog = eventLog
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return startCountStorage
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stopCountStorage
    }

    func start() throws {
        lock.lock()
        startCountStorage += 1
        lock.unlock()
        eventLog?.append("start")
        startEntered?.fulfill()
        startGate?.wait()
    }

    func stop() {
        lock.lock()
        stopCountStorage += 1
        lock.unlock()
    }

    func releaseStart() {
        startGate?.signal()
    }
}

private final class MicrophoneOutputFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let outputs: [MicrophoneTestOutput]
    private var nextIndex = 0

    init(outputs: [MicrophoneTestOutput]) {
        self.outputs = outputs
    }

    var creationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextIndex
    }

    func makeOutput() -> (any WorldwideIPhoneMicrophoneOutput)? {
        lock.lock()
        defer { lock.unlock() }
        guard nextIndex < outputs.count else { return nil }
        let output = outputs[nextIndex]
        nextIndex += 1
        return output
    }
}

private actor MicrophoneTestPeer {
    private var healthy: Bool
    private let admissionGate: MicrophoneAdmissionGate?
    private let admissionEntered: MicrophoneTestExpectation?

    init(
        healthy: Bool,
        admissionGate: MicrophoneAdmissionGate? = nil,
        admissionEntered: MicrophoneTestExpectation? = nil
    ) {
        self.healthy = healthy
        self.admissionGate = admissionGate
        self.admissionEntered = admissionEntered
    }

    func setHealthy(_ healthy: Bool) {
        self.healthy = healthy
    }

    func admit(_ track: MicrophoneTestTrack) async throws {
        admissionEntered?.fulfill()
        if let admissionGate {
            await admissionGate.waitUntilReleased()
        }
        guard healthy else {
            track.setEnabled(false)
            throw MicrophoneAdmissionTestError.transportNotHealthy
        }
        track.setEnabled(true)
    }
}

private actor MicrophoneForwardingHarness {
    private let coordinator:
        WorldwideIPhoneMicrophoneForwardingCoordinator<
            MicrophoneTestPeer,
            MicrophoneTestTrack
        >

    init(
        factory: MicrophoneOutputFactory,
        eventLog: MicrophoneForwardingEventLog? = nil
    ) {
        let publicationObserver:
            (@Sendable (any WorldwideIPhoneMicrophoneOutput) -> Void)?
        if let eventLog {
            publicationObserver = { _ in
                eventLog.append("published")
            }
        } else {
            publicationObserver = nil
        }

        coordinator =
            WorldwideIPhoneMicrophoneForwardingCoordinator(
                makeOutput: { _ in
                    factory.makeOutput()
                },
                admit: { peer, track in
                    try await peer.admit(track)
                },
                disableTrack: { track in
                    track.setEnabled(false)
                },
                onAttemptPublished: publicationObserver
            )
    }

    func start(
        peer: MicrophoneTestPeer,
        track: MicrophoneTestTrack
    ) async throws -> WorldwideIPhoneMicrophoneForwardingStartResult {
        try await coordinator.start(peer: peer, track: track)
    }

    func stopCurrent() {
        coordinator.stopCurrent()
    }

    func handleRuntimeFailure(
        from output: MicrophoneTestOutput
    ) -> Bool {
        coordinator.handleRuntimeFailure(from: output)
    }

    func snapshot() -> WorldwideIPhoneMicrophoneForwardingSnapshot {
        coordinator.snapshot()
    }
}
