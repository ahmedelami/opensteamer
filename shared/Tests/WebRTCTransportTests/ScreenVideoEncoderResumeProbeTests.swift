import CoreVideo
import Foundation
@preconcurrency import LiveKitWebRTC
@testable import WebRTCTransport
import XCTest

private final class ResumeProbeCodecInfo: NSObject, LKRTCCodecSpecificInfo {}

private final class ResumeProbeFakeEncoder: NSObject, LKRTCVideoEncoder {
    enum CallbackMode {
        case synchronous
        case manual
    }

    private let lock = NSLock()
    private var callback:
        ((LKRTCEncodedImage, any LKRTCCodecSpecificInfo) -> Bool)?
    var callbackMode: CallbackMode = .synchronous
    var startResults: [Int] = [0]
    var encodeResult = 0
    private(set) var encodeCount = 0
    private(set) var lastFrameTypes: [NSNumber] = []
    private(set) var lastCallbackReturnValue: Bool?

    var hasCallback: Bool { lock.withLock { callback != nil } }

    func setCallback(
        _ callback: ((LKRTCEncodedImage, any LKRTCCodecSpecificInfo) -> Bool)?
    ) {
        lock.withLock { self.callback = callback }
    }

    func startEncode(
        with _: LKRTCVideoEncoderSettings,
        numberOfCores _: Int32
    ) -> Int {
        if startResults.isEmpty { return 0 }
        return startResults.removeFirst()
    }

    func release() -> Int { 0 }

    func encode(
        _ frame: LKRTCVideoFrame,
        codecSpecificInfo _: (any LKRTCCodecSpecificInfo)?,
        frameTypes: [NSNumber]
    ) -> Int {
        encodeCount += 1
        lastFrameTypes = frameTypes
        if callbackMode == .synchronous {
            emit(
                timestamp: UInt32(bitPattern: frame.timeStamp),
                frameType: requestedFrameType(frameTypes)
            )
        }
        return encodeResult
    }

    func emit(timestamp: UInt32, frameType: LKRTCFrameType) {
        let image = LKRTCEncodedImage()
        image.timeStamp = timestamp
        image.frameType = frameType
        image.buffer = Data([0x00, 0x00, 0x01])
        let callback = lock.withLock { self.callback }
        lastCallbackReturnValue = callback?(image, ResumeProbeCodecInfo())
    }

    func setBitrate(_: UInt32, framerate _: UInt32) -> Int32 { 0 }
    func implementationName() -> String { "resume-probe-fake" }
    func scalingSettings() -> LKRTCVideoEncoderQpThresholds? { nil }
    var resolutionAlignment: Int { 1 }
    var applyAlignmentToAllSimulcastLayers: Bool { false }
    var supportsNativeHandle: Bool { true }

    private func requestedFrameType(_ frameTypes: [NSNumber]) -> LKRTCFrameType {
        if frameTypes.contains(where: {
            $0.uintValue == LKRTCFrameType.videoFrameKey.rawValue
        }) {
            return .videoFrameKey
        }
        return .videoFrameDelta
    }
}

private final class ResumeProbeLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}

private final class ResumeProbeRenderedRTPProbe:
    NSObject,
    LKRTCVideoRenderer,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var timestamps: [UInt32] = []
    private var expectedAfter: UInt32?
    private var expectation: XCTestExpectation?

    func clear() {
        lock.withLock {
            timestamps.removeAll(keepingCapacity: true)
            expectedAfter = nil
            expectation = nil
        }
    }

    func expectNext(after reference: UInt32? = nil) -> XCTestExpectation {
        let expectation = XCTestExpectation(
            description: reference.map {
                "rendered RTP strictly newer than \($0)"
            } ?? "rendered first exact RTP timestamp"
        )
        let alreadyRendered = lock.withLock { () -> Bool in
            expectedAfter = reference
            self.expectation = expectation
            let matched = timestamps.contains { timestamp in
                guard let reference else { return true }
                return resumeProbeForwardDelta(timestamp, from: reference) != nil
            }
            if matched { self.expectation = nil }
            return matched
        }
        if alreadyRendered { expectation.fulfill() }
        return expectation
    }

    func firstTimestamp(after reference: UInt32? = nil) -> UInt32? {
        lock.withLock {
            timestamps.first { timestamp in
                guard let reference else { return true }
                return resumeProbeForwardDelta(timestamp, from: reference) != nil
            }
        }
    }

    func setSize(_: CGSize) {}

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        let timestamp = UInt32(bitPattern: frame.timeStamp)
        let fulfillment = lock.withLock { () -> XCTestExpectation? in
            timestamps.append(timestamp)
            guard let expectation else { return nil }
            if let expectedAfter,
               resumeProbeForwardDelta(timestamp, from: expectedAfter) == nil {
                return nil
            }
            self.expectation = nil
            return expectation
        }
        fulfillment?.fulfill()
    }
}

private actor ResumeProbeLoopbackState {
    private(set) var remoteVideoTrack: WebRTCRemoteVideoTrack?
    private(set) var controlRequests: [WebRTCControlRequest] = []
    private(set) var controlAcknowledgements: [WebRTCControlAcknowledgement] = []
    private(set) var suspensionNotices: [WebRTCScreenMediaSuspensionNotice] = []
    private(set) var coveredAcknowledgements:
        [WebRTCScreenMediaCoveredAcknowledgement] = []
    private(set) var errors: [String] = []

    func observe(_ event: WebRTCTransportEvent, viewerSide: Bool) {
        if viewerSide, case .remoteVideoTrack(let track) = event {
            remoteVideoTrack = track
        }
        if !viewerSide, case .controlRequestReceived(let request) = event {
            controlRequests.append(request)
        }
        if viewerSide,
           case .controlAcknowledgementReceived(let acknowledgement, _) = event {
            controlAcknowledgements.append(acknowledgement)
        }
        if viewerSide,
           case .screenMediaSuspensionReceived(let notice) = event {
            suspensionNotices.append(notice)
        }
        if !viewerSide,
           case .screenMediaCoveredAcknowledgementReceived(let acknowledgement) = event {
            coveredAcknowledgements.append(acknowledgement)
        }
    }

    func record(_ error: Error) {
        errors.append(String(describing: error))
    }
}

private final class ResumeProbeLoopbackExpectations: @unchecked Sendable {
    let hostConnected = XCTestExpectation(description: "floor host connected")
    let viewerConnected = XCTestExpectation(description: "floor viewer connected")
    let remoteVideoTrack = XCTestExpectation(
        description: "floor viewer received video track"
    )

    func observe(_ event: WebRTCTransportEvent, viewerSide: Bool) {
        switch event {
        case .peerStateChanged(.connected):
            (viewerSide ? viewerConnected : hostConnected).fulfill()
        case .remoteVideoTrack where viewerSide:
            remoteVideoTrack.fulfill()
        default:
            break
        }
    }
}

final class ScreenVideoEncoderResumeProbeTests: XCTestCase {
    func testSynchronousCallbackCannotMintProofBeforeEncodeReturnsSuccess() throws {
        let harness = try makeHarness()
        var eventsObservedInsideCallback: [ScreenVideoEncoderResumeProbeEvent] = []
        harness.wrapper.setCallback { _, _ in
            eventsObservedInsideCallback = harness.probe.drainEventsForTesting()
            return true
        }
        XCTAssertEqual(start(harness), 0)
        XCTAssertTrue(
            harness.probe.armMarker(
                attemptID: harness.attemptID,
                marker: harness.marker,
                boundaryRevision: 101,
                markerInputGateIsClosed: true
            )
        )

        let markerTimestamp: UInt32 = 0x1020_3040
        let status = harness.wrapper.encode(
            try makeMarkerFrame(marker: harness.marker, timestamp: markerTimestamp),
            codecSpecificInfo: nil,
            frameTypes: [NSNumber(value: LKRTCFrameType.videoFrameDelta.rawValue)]
        )

        XCTAssertEqual(status, 0)
        XCTAssertTrue(eventsObservedInsideCallback.isEmpty)
        XCTAssertEqual(harness.downstream.lastCallbackReturnValue, true)
        XCTAssertEqual(
            harness.downstream.lastFrameTypes,
            [NSNumber(value: LKRTCFrameType.videoFrameKey.rawValue)]
        )
        let proof = try markerProof(in: harness.probe.drainEventsForTesting())
        XCTAssertEqual(proof.rtpTimestamp, markerTimestamp)
    }

    func testRejectedEncodeWithSynchronousCallbackFailsClosed() throws {
        let harness = try makeHarness()
        harness.downstream.encodeResult = -7
        var eventsObservedInsideCallback: [ScreenVideoEncoderResumeProbeEvent] = []
        harness.wrapper.setCallback { _, _ in
            eventsObservedInsideCallback = harness.probe.drainEventsForTesting()
            return false
        }
        XCTAssertEqual(start(harness), 0)
        XCTAssertTrue(
            harness.probe.armMarker(
                attemptID: harness.attemptID,
                marker: harness.marker,
                boundaryRevision: 102,
                markerInputGateIsClosed: true
            )
        )

        XCTAssertEqual(
            harness.wrapper.encode(
                try makeMarkerFrame(marker: harness.marker, timestamp: 71),
                codecSpecificInfo: nil,
                frameTypes: []
            ),
            -7
        )

        XCTAssertTrue(eventsObservedInsideCallback.isEmpty)
        let events = harness.probe.drainEventsForTesting()
        XCTAssertFalse(events.contains { if case .markerEncoded = $0 { true } else { false } })
        XCTAssertTrue(events.contains {
            if case .cancelled(let attemptID, let reason) = $0 {
                attemptID == harness.attemptID && reason.contains("rejected")
            } else {
                false
            }
        })
    }

    func testCallbackNilIsForwardedExactlyAndStartsOwnEncoderGeneration() throws {
        let harness = try makeHarness()
        harness.wrapper.setCallback { _, _ in true }
        XCTAssertTrue(harness.downstream.hasCallback)
        harness.wrapper.setCallback(nil)
        XCTAssertFalse(harness.downstream.hasCallback)
        XCTAssertFalse(
            harness.probe.armMarker(
                attemptID: harness.attemptID,
                marker: harness.marker,
                boundaryRevision: 103,
                markerInputGateIsClosed: true
            )
        )

        harness.downstream.startResults = [0, 0, -11]
        XCTAssertEqual(start(harness), 0)
        XCTAssertTrue(
            harness.probe.armMarker(
                attemptID: harness.attemptID,
                marker: harness.marker,
                boundaryRevision: 104,
                markerInputGateIsClosed: true
            )
        )
        XCTAssertEqual(start(harness), 0)
        XCTAssertTrue(harness.probe.drainEventsForTesting().contains {
            if case .cancelled(let attemptID, let reason) = $0 {
                attemptID == harness.attemptID && reason.contains("restarted")
            } else {
                false
            }
        })

        let secondAttemptID = UUID()
        XCTAssertTrue(
            harness.probe.armMarker(
                attemptID: secondAttemptID,
                marker: harness.marker,
                boundaryRevision: 105,
                markerInputGateIsClosed: true
            )
        )
        XCTAssertEqual(start(harness), -11)
        XCTAssertTrue(harness.probe.drainEventsForTesting().contains {
            if case .cancelled(let attemptID, let reason) = $0 {
                attemptID == secondAttemptID && reason.contains("failed to start")
            } else {
                false
            }
        })
        XCTAssertFalse(
            harness.probe.armMarker(
                attemptID: UUID(),
                marker: harness.marker,
                boundaryRevision: 106,
                markerInputGateIsClosed: true
            )
        )
    }

    func testExplicitActivationRolloverRebindsExactlyOnceBeforeMarkerSubmission() throws {
        let harness = try makeHarness()
        harness.wrapper.setCallback { _, _ in true }
        XCTAssertEqual(start(harness), 0)
        let boundaryRevision: UInt64 = 0xA11C
        XCTAssertTrue(
            harness.probe.armMarker(
                attemptID: harness.attemptID,
                marker: harness.marker,
                boundaryRevision: boundaryRevision,
                permitsNextActivationEncoderRestart: true,
                markerInputGateIsClosed: true
            )
        )

        XCTAssertEqual(harness.wrapper.release(), 0)
        XCTAssertTrue(harness.probe.drainEventsForTesting().isEmpty)
        XCTAssertEqual(start(harness), 0)
        XCTAssertTrue(harness.probe.drainEventsForTesting().isEmpty)

        _ = harness.wrapper.encode(
            try makeMarkerFrame(marker: harness.marker, timestamp: 0xA000),
            codecSpecificInfo: nil,
            frameTypes: []
        )
        let proof = try markerProof(
            in: harness.probe.drainEventsForTesting()
        )
        XCTAssertEqual(proof.boundaryRevision, boundaryRevision)

        // The one explicit activation allowance was consumed by the first rebind.
        XCTAssertEqual(harness.wrapper.release(), 0)
        XCTAssertTrue(harness.probe.drainEventsForTesting().contains {
            if case .cancelled(let attemptID, let reason) = $0 {
                attemptID == harness.attemptID && reason.contains("reset")
            } else {
                false
            }
        })
    }

    func testPendingRealReplacementIgnoresLateAbandonedCallbackAndUsesNewestProof()
        throws
    {
        let harness = try makeHarness()
        harness.wrapper.setCallback { _, _ in true }
        XCTAssertEqual(start(harness), 0)
        XCTAssertTrue(
            harness.probe.armMarker(
                attemptID: harness.attemptID,
                marker: harness.marker,
                boundaryRevision: 0xB001,
                markerInputGateIsClosed: true
            )
        )
        let markerTimestamp: UInt32 = 100_000
        _ = harness.wrapper.encode(
            try makeMarkerFrame(
                marker: harness.marker,
                timestamp: markerTimestamp
            ),
            codecSpecificInfo: nil,
            frameTypes: []
        )
        let markerProof = try markerProof(
            in: harness.probe.drainEventsForTesting()
        )
        XCTAssertTrue(
            harness.probe.beginRealFrameAdmission(
                attemptID: harness.attemptID,
                markerRTPTimestamp: markerProof.rtpTimestamp,
                boundaryRevision: markerProof.boundaryRevision,
                receiverMarkerRTPTimestamp: 500_000
            )
        )

        harness.downstream.callbackMode = .manual
        let abandonedTimestamp: UInt32 = markerTimestamp + 90_000
        let replacementTimestamp: UInt32 = abandonedTimestamp + 90_000
        _ = harness.wrapper.encode(
            try makeRealFrame(timestamp: abandonedTimestamp),
            codecSpecificInfo: nil,
            frameTypes: []
        )
        _ = harness.wrapper.encode(
            try makeRealFrame(timestamp: replacementTimestamp),
            codecSpecificInfo: nil,
            frameTypes: []
        )
        XCTAssertEqual(
            harness.downstream.lastFrameTypes,
            [NSNumber(value: LKRTCFrameType.videoFrameKey.rawValue)]
        )

        harness.downstream.emit(
            timestamp: abandonedTimestamp,
            frameType: .videoFrameKey
        )
        XCTAssertTrue(harness.probe.drainEventsForTesting().isEmpty)
        harness.downstream.emit(
            timestamp: replacementTimestamp,
            frameType: .videoFrameKey
        )
        let events = harness.probe.drainEventsForTesting()
        let proof = try XCTUnwrap(events.compactMap { event in
            if case .realFrameEncoded(let proof) = event { return proof }
            return nil
        }.first)
        XCTAssertEqual(proof.rtpTimestamp, replacementTimestamp)
        let snapshot = harness.probe.debugSnapshot()
        XCTAssertEqual(snapshot.realPendingReplacementCount, 1)
        XCTAssertEqual(snapshot.abandonedCallbackTimestampCount, 1)
    }

    func testPendingMarkerIsNeverReplacedAndRealReplacementBudgetIsBounded()
        throws
    {
        let harness = try makeHarness()
        harness.wrapper.setCallback { _, _ in true }
        XCTAssertEqual(start(harness), 0)
        harness.downstream.callbackMode = .manual
        XCTAssertTrue(
            harness.probe.armMarker(
                attemptID: harness.attemptID,
                marker: harness.marker,
                boundaryRevision: 0xB002,
                markerInputGateIsClosed: true
            )
        )
        let markerTimestamp: UInt32 = 100_000
        _ = harness.wrapper.encode(
            try makeMarkerFrame(
                marker: harness.marker,
                timestamp: markerTimestamp
            ),
            codecSpecificInfo: nil,
            frameTypes: []
        )
        let markerEncodeCount = harness.downstream.encodeCount
        _ = harness.wrapper.encode(
            try makeMarkerFrame(
                marker: harness.marker,
                timestamp: markerTimestamp + 90_000
            ),
            codecSpecificInfo: nil,
            frameTypes: []
        )
        _ = harness.wrapper.encode(
            try makeRealFrame(timestamp: markerTimestamp + 180_000),
            codecSpecificInfo: nil,
            frameTypes: []
        )
        XCTAssertEqual(harness.downstream.encodeCount, markerEncodeCount)

        harness.downstream.emit(
            timestamp: markerTimestamp,
            frameType: .videoFrameKey
        )
        let markerProof = try markerProof(
            in: harness.probe.drainEventsForTesting()
        )
        XCTAssertTrue(
            harness.probe.beginRealFrameAdmission(
                attemptID: harness.attemptID,
                markerRTPTimestamp: markerProof.rtpTimestamp,
                boundaryRevision: markerProof.boundaryRevision,
                receiverMarkerRTPTimestamp: 500_000
            )
        )

        var timestamp = markerTimestamp + 270_000
        for _ in 0..<12 {
            _ = harness.wrapper.encode(
                try makeRealFrame(timestamp: timestamp),
                codecSpecificInfo: nil,
                frameTypes: []
            )
            timestamp += 90_000
        }
        let encodeCountAtBudget = harness.downstream.encodeCount
        _ = harness.wrapper.encode(
            try makeRealFrame(timestamp: timestamp),
            codecSpecificInfo: nil,
            frameTypes: []
        )
        XCTAssertEqual(harness.downstream.encodeCount, encodeCountAtBudget)
        XCTAssertTrue(harness.probe.drainEventsForTesting().contains {
            if case .cancelled(let attemptID, let reason) = $0 {
                return attemptID == harness.attemptID
                    && reason.contains("replacement budget")
            }
            return false
        })
    }

    func testExactMarkerAndRealPairMintsOneRevocableAuthorization() throws {
        let harness = try makeHarness()
        harness.wrapper.setCallback { _, _ in true }
        XCTAssertEqual(start(harness), 0)
        let markerTimestamp: UInt32 = 0xFFFF_0000
        let realTimestamp: UInt32 = 0x0000_1000
        let receiverMarkerTimestamp: UInt32 = 0xFFFF_FFF0
        let receiverRealTimestamp: UInt32 = 0x0001_0FF0

        let firstAuthorization = try completeFence(
            harness,
            markerTimestamp: markerTimestamp,
            realTimestamp: realTimestamp,
            receiverMarkerTimestamp: receiverMarkerTimestamp,
            receiverRealTimestamp: receiverRealTimestamp
        )
        XCTAssertTrue(firstAuthorization.isValid)
        XCTAssertNil(
            harness.probe.issueResumeAuthorization(
                attemptID: harness.attemptID,
                encoderGeneration: firstAuthorization.encoderGeneration,
                realEncoderRTPTimestamp: realTimestamp,
                receiverRealRTPTimestamp: receiverRealTimestamp
            )
        )
        harness.probe.cancelForMutation(.trackChanged)
        XCTAssertFalse(firstAuthorization.isValid)
        XCTAssertFalse(harness.probe.consumeResumeAuthorization(firstAuthorization))

        let secondAttemptID = UUID()
        let secondHarness = ResumeProbeHarness(
            probe: harness.probe,
            downstream: harness.downstream,
            wrapper: harness.wrapper,
            marker: harness.marker,
            attemptID: secondAttemptID
        )
        let secondAuthorization = try completeFence(
            secondHarness,
            markerTimestamp: 0x0001_0000,
            realTimestamp: 0x0002_0000,
            receiverMarkerTimestamp: 400,
            receiverRealTimestamp: 400 &+ 0x0001_0000 &+ 500
        )
        XCTAssertTrue(harness.probe.consumeResumeAuthorization(secondAuthorization))
        XCTAssertFalse(secondAuthorization.isValid)
        XCTAssertFalse(harness.probe.consumeResumeAuthorization(secondAuthorization))

        let realCountBeforeRelease = harness.downstream.encodeCount
        _ = harness.wrapper.encode(
            try makeRealFrame(timestamp: 0x0003_0000),
            codecSpecificInfo: nil,
            frameTypes: []
        )
        XCTAssertEqual(harness.downstream.encodeCount, realCountBeforeRelease + 1)
    }

    func testDuplicateCallbackAndHalfRangeTimestampCancelTheAttempt() throws {
        let harness = try makeHarness()
        harness.downstream.callbackMode = .manual
        harness.wrapper.setCallback { _, _ in true }
        XCTAssertEqual(start(harness), 0)
        XCTAssertTrue(
            harness.probe.armMarker(
                attemptID: harness.attemptID,
                marker: harness.marker,
                boundaryRevision: 107,
                markerInputGateIsClosed: true
            )
        )
        let markerTimestamp: UInt32 = 0x1111_0000
        _ = harness.wrapper.encode(
            try makeMarkerFrame(marker: harness.marker, timestamp: markerTimestamp),
            codecSpecificInfo: nil,
            frameTypes: []
        )
        harness.downstream.emit(timestamp: markerTimestamp, frameType: .videoFrameKey)
        _ = try markerProof(in: harness.probe.drainEventsForTesting())
        harness.downstream.emit(timestamp: markerTimestamp, frameType: .videoFrameKey)
        XCTAssertTrue(harness.probe.drainEventsForTesting().contains {
            if case .cancelled(let attemptID, let reason) = $0 {
                attemptID == harness.attemptID && reason.contains("untracked")
            } else {
                false
            }
        })

        harness.downstream.callbackMode = .synchronous
        let halfRangeAttemptID = UUID()
        XCTAssertTrue(
            harness.probe.armMarker(
                attemptID: halfRangeAttemptID,
                marker: harness.marker,
                boundaryRevision: 108,
                markerInputGateIsClosed: true
            )
        )
        _ = harness.wrapper.encode(
            try makeMarkerFrame(marker: harness.marker, timestamp: markerTimestamp),
            codecSpecificInfo: nil,
            frameTypes: []
        )
        let markerProof = try markerProof(in: harness.probe.drainEventsForTesting())
        XCTAssertTrue(
            harness.probe.beginRealFrameAdmission(
                attemptID: halfRangeAttemptID,
                markerRTPTimestamp: markerProof.rtpTimestamp,
                boundaryRevision: markerProof.boundaryRevision,
                receiverMarkerRTPTimestamp: 10
            )
        )
        let encodeCount = harness.downstream.encodeCount
        _ = harness.wrapper.encode(
            try makeRealFrame(timestamp: markerTimestamp &+ 0x8000_0000),
            codecSpecificInfo: nil,
            frameTypes: []
        )
        XCTAssertEqual(harness.downstream.encodeCount, encodeCount)
        XCTAssertTrue(harness.probe.drainEventsForTesting().contains {
            if case .cancelled(let attemptID, let reason) = $0 {
                attemptID == halfRangeAttemptID && reason.contains("stale or ambiguous")
            } else {
                false
            }
        })
    }

    func testProductionEventHandlerIsSingleInstallOrderedAndReentrantSafe() throws {
        let harness = try makeHarness()
        harness.wrapper.setCallback { _, _ in true }
        XCTAssertEqual(start(harness), 0)
        let markerDelivered = expectation(description: "marker event delivered outside lock")
        let callbackEvents = ResumeProbeLockedBox<[ScreenVideoEncoderResumeProbeEvent]>([])
        let probe = harness.probe
        XCTAssertTrue(
            probe.installEventHandler { event in
                callbackEvents.withLock { $0.append(event) }
                if case .markerEncoded(let proof) = event {
                    probe.cancelAttempt(
                        attemptID: proof.attemptID,
                        reason: "reentrant test cancellation"
                    )
                    markerDelivered.fulfill()
                }
            }
        )
        XCTAssertFalse(harness.probe.installEventHandler { _ in })
        XCTAssertTrue(
            harness.probe.armMarker(
                attemptID: harness.attemptID,
                marker: harness.marker,
                boundaryRevision: 109,
                markerInputGateIsClosed: true
            )
        )
        _ = harness.wrapper.encode(
            try makeMarkerFrame(marker: harness.marker, timestamp: 0x1000),
            codecSpecificInfo: nil,
            frameTypes: []
        )
        wait(for: [markerDelivered], timeout: 2)
        for _ in 0..<200 where callbackEvents.withLock({ $0.count }) < 2 {
            Thread.sleep(forTimeInterval: 0.005)
        }
        let delivered = callbackEvents.withLock { $0 }
        XCTAssertEqual(delivered.count, 2)
        XCTAssertTrue({ if case .markerEncoded = delivered[0] { true } else { false } }())
        XCTAssertTrue({ if case .cancelled = delivered[1] { true } else { false } }())
    }

    func testLateCancelledAttemptCallbackCannotRetireCurrentRetry() throws {
        let harness = try makeHarness()
        harness.downstream.callbackMode = .manual
        harness.wrapper.setCallback { _, _ in true }
        XCTAssertEqual(start(harness), 0)

        let retiredAttemptID = UUID()
        XCTAssertTrue(
            harness.probe.armMarker(
                attemptID: retiredAttemptID,
                marker: harness.marker,
                boundaryRevision: 201,
                markerInputGateIsClosed: true
            )
        )
        XCTAssertEqual(
            harness.wrapper.encode(
                try makeMarkerFrame(marker: harness.marker, timestamp: 10_000),
                codecSpecificInfo: nil,
                frameTypes: []
            ),
            0
        )
        harness.probe.cancelAttempt(
            attemptID: retiredAttemptID,
            reason: "retire attempt A"
        )
        _ = harness.probe.drainEventsForTesting()

        let currentAttemptID = UUID()
        XCTAssertTrue(
            harness.probe.armMarker(
                attemptID: currentAttemptID,
                marker: harness.marker,
                boundaryRevision: 202,
                markerInputGateIsClosed: true
            )
        )
        XCTAssertEqual(
            harness.wrapper.encode(
                try makeMarkerFrame(marker: harness.marker, timestamp: 20_000),
                codecSpecificInfo: nil,
                frameTypes: []
            ),
            0
        )

        harness.downstream.emit(timestamp: 10_000, frameType: .videoFrameKey)
        XCTAssertTrue(harness.probe.drainEventsForTesting().isEmpty)
        XCTAssertEqual(harness.wrapper.callbackOwnershipCountForTesting, 1)

        harness.downstream.emit(timestamp: 20_000, frameType: .videoFrameKey)
        let events = harness.probe.drainEventsForTesting()
        XCTAssertEqual(try markerProof(in: events).attemptID, currentAttemptID)
        XCTAssertFalse(events.contains {
            if case .cancelled(let attemptID, _) = $0 {
                return attemptID == currentAttemptID
            }
            return false
        })
        XCTAssertEqual(harness.wrapper.callbackOwnershipCountForTesting, 0)
    }

    func testLatePreReleaseCallbackCannotAliasRestartedRetry() throws {
        let harness = try makeHarness()
        harness.downstream.callbackMode = .manual
        harness.wrapper.setCallback { _, _ in true }
        XCTAssertEqual(start(harness), 0)

        let retiredAttemptID = UUID()
        XCTAssertTrue(
            harness.probe.armMarker(
                attemptID: retiredAttemptID,
                marker: harness.marker,
                boundaryRevision: 203,
                markerInputGateIsClosed: true
            )
        )
        XCTAssertEqual(
            harness.wrapper.encode(
                try makeMarkerFrame(marker: harness.marker, timestamp: 30_000),
                codecSpecificInfo: nil,
                frameTypes: []
            ),
            0
        )
        harness.probe.cancelAttempt(
            attemptID: retiredAttemptID,
            reason: "retire before encoder release"
        )
        _ = harness.wrapper.release()
        XCTAssertEqual(start(harness), 0)
        _ = harness.probe.drainEventsForTesting()

        let currentAttemptID = UUID()
        XCTAssertTrue(
            harness.probe.armMarker(
                attemptID: currentAttemptID,
                marker: harness.marker,
                boundaryRevision: 204,
                markerInputGateIsClosed: true
            )
        )
        XCTAssertEqual(
            harness.wrapper.encode(
                try makeMarkerFrame(marker: harness.marker, timestamp: 40_000),
                codecSpecificInfo: nil,
                frameTypes: []
            ),
            0
        )
        harness.downstream.emit(timestamp: 30_000, frameType: .videoFrameKey)
        XCTAssertTrue(harness.probe.drainEventsForTesting().isEmpty)
        harness.downstream.emit(timestamp: 40_000, frameType: .videoFrameKey)
        XCTAssertEqual(
            try markerProof(in: harness.probe.drainEventsForTesting()).attemptID,
            currentAttemptID
        )
    }

    func testUnresolvedOwnershipLedgerIsBoundedAndRejectsTimestampReuse() throws {
        let harness = try makeHarness()
        harness.downstream.callbackMode = .manual
        harness.wrapper.setCallback { _, _ in true }
        XCTAssertEqual(start(harness), 0)

        let reusedTimestamp: UInt32 = 50_000
        let retiredAttemptID = UUID()
        XCTAssertTrue(
            harness.probe.armMarker(
                attemptID: retiredAttemptID,
                marker: harness.marker,
                boundaryRevision: 205,
                markerInputGateIsClosed: true
            )
        )
        XCTAssertEqual(
            harness.wrapper.encode(
                try makeMarkerFrame(
                    marker: harness.marker,
                    timestamp: reusedTimestamp
                ),
                codecSpecificInfo: nil,
                frameTypes: []
            ),
            0
        )
        harness.probe.cancelAttempt(
            attemptID: retiredAttemptID,
            reason: "retain exact ownership tombstone"
        )
        _ = harness.probe.drainEventsForTesting()

        let collidingAttemptID = UUID()
        XCTAssertTrue(
            harness.probe.armMarker(
                attemptID: collidingAttemptID,
                marker: harness.marker,
                boundaryRevision: 206,
                markerInputGateIsClosed: true
            )
        )
        XCTAssertEqual(
            harness.wrapper.encode(
                try makeMarkerFrame(
                    marker: harness.marker,
                    timestamp: reusedTimestamp
                ),
                codecSpecificInfo: nil,
                frameTypes: []
            ),
            1
        )
        XCTAssertEqual(harness.downstream.encodeCount, 1)
        XCTAssertEqual(harness.wrapper.callbackOwnershipCountForTesting, 1)
        XCTAssertTrue(harness.probe.drainEventsForTesting().contains {
            if case .cancelled(let attemptID, _) = $0 {
                return attemptID == collidingAttemptID
            }
            return false
        })
        harness.downstream.emit(
            timestamp: reusedTimestamp,
            frameType: .videoFrameKey
        )
        XCTAssertEqual(harness.wrapper.callbackOwnershipCountForTesting, 0)

        for offset in 0..<64 {
            let attemptID = UUID()
            XCTAssertTrue(
                harness.probe.armMarker(
                    attemptID: attemptID,
                    marker: harness.marker,
                    boundaryRevision: UInt64(300 + offset),
                    markerInputGateIsClosed: true
                )
            )
            XCTAssertEqual(
                harness.wrapper.encode(
                    try makeMarkerFrame(
                        marker: harness.marker,
                        timestamp: UInt32(100_000 + offset)
                    ),
                    codecSpecificInfo: nil,
                    frameTypes: []
                ),
                0
            )
            harness.probe.cancelAttempt(
                attemptID: attemptID,
                reason: "fill bounded ownership ledger"
            )
            _ = harness.probe.drainEventsForTesting()
        }
        XCTAssertEqual(harness.wrapper.callbackOwnershipCountForTesting, 64)
        let overflowAttemptID = UUID()
        XCTAssertTrue(
            harness.probe.armMarker(
                attemptID: overflowAttemptID,
                marker: harness.marker,
                boundaryRevision: 400,
                markerInputGateIsClosed: true
            )
        )
        XCTAssertEqual(
            harness.wrapper.encode(
                try makeMarkerFrame(marker: harness.marker, timestamp: 200_000),
                codecSpecificInfo: nil,
                frameTypes: []
            ),
            1
        )
        XCTAssertEqual(harness.wrapper.callbackOwnershipCountForTesting, 64)
        XCTAssertEqual(harness.downstream.encodeCount, 65)
    }

    func testPublicMarkerFactoryProducesTheExactClassifierInput() throws {
        let attemptID = UUID(uuid: (
            0, 1, 2, 3, 4, 5, 6, 7,
            8, 9, 10, 11, 12, 13, 14, 15
        ))
        let marker = ScreenVideoInBandMarkerNonce(attemptID: attemptID)
        XCTAssertEqual(
            marker.bytes,
            (0..<ScreenVideoInBandMarkerNonce.byteCount).map(UInt8.init)
        )
        XCTAssertThrowsError(
            try ScreenVideoInBandMarkerPixelBufferFactory.make(
                width: 39,
                height: 80,
                marker: marker
            )
        )
        // 40x80 is the exact decoded floor produced by 480x960 at 12x scale.
        let pixelBuffer = try ScreenVideoInBandMarkerPixelBufferFactory.make(
            width: 40,
            height: 80,
            marker: marker
        )
        let frame = makeProbeFrame(pixelBuffer: pixelBuffer, timestamp: 90_000)
        XCTAssertEqual(
            ScreenVideoInBandMarkerClassifier.classify(frame, expectedMarker: marker),
            .exactMarker
        )
        XCTAssertEqual(
            ScreenVideoInBandMarkerClassifier.classify(frame),
            .exactMarker(marker)
        )

        let staleReal = makeProbeFrame(
            pixelBuffer: try makeUniformProbePixelBuffer(
                width: 40,
                height: 80,
                value: 0x20
            ),
            timestamp: 89_000
        )
        XCTAssertNotEqual(
            ScreenVideoInBandMarkerClassifier.classify(staleReal),
            .exactMarker(marker)
        )
    }

    func testFreshLoopbackPreservesConstantSenderOffsetAtThirtyTwoKilobits()
        async throws
    {
        let host = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .host, iceServers: [])
        )
        let viewer = try WebRTCPeer.makeHeadlessViewerForTesting(
            configuration: WebRTCTransportConfiguration(role: .viewer, iceServers: [])
        )
        let state = ResumeProbeLoopbackState()
        let expectations = ResumeProbeLoopbackExpectations()
        let hostForwarder = Task {
            do {
                for await event in host.events {
                    await state.observe(event, viewerSide: false)
                    expectations.observe(event, viewerSide: false)
                    if case .outboundSignal(let payload) = event {
                        try await viewer.handle(payload)
                    }
                }
            } catch {
                await state.record(error)
            }
        }
        let viewerForwarder = Task {
            do {
                for await event in viewer.events {
                    await state.observe(event, viewerSide: true)
                    expectations.observe(event, viewerSide: true)
                    if case .outboundSignal(let payload) = event {
                        try await host.handle(payload)
                    }
                }
            } catch {
                await state.record(error)
            }
        }
        let headlessPlayout = Task {
            while !Task.isCancelled {
                _ = await viewer.pullHeadlessMacViewerAudioForTesting()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer {
            headlessPlayout.cancel()
            hostForwarder.cancel()
            viewerForwarder.cancel()
            Task {
                await host.close(reason: .normal)
                await viewer.close(reason: .normal)
            }
        }

        try await host.start()
        await fulfillment(
            of: [
                expectations.hostConnected,
                expectations.viewerConnected,
                expectations.remoteVideoTrack,
            ],
            timeout: 10
        )
        let forwardingErrors = await state.errors
        XCTAssertTrue(forwardingErrors.isEmpty, "\(forwardingErrors)")
        let remoteVideoTrackValue = await state.remoteVideoTrack
        let remoteVideoTrack = try XCTUnwrap(remoteVideoTrackValue)
        guard let capturer = host.externalVideoCapturer else {
            XCTFail("The floor loopback host did not expose its screen capturer.")
            return
        }

        // Start from a genuinely active sender. A negotiated track is born disabled and cannot
        // create the encoder generation needed by the probe until Show/Active commits.
        let showID = try await viewer.setScreenVisible(true)
        for _ in 0..<300 {
            if await state.controlRequests.contains(where: { $0.id == showID }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let activeRequests = await state.controlRequests
        XCTAssertTrue(
            activeRequests.contains(
                WebRTCControlRequest(id: showID, command: .showScreen)
            )
        )
        try await host.acknowledgeActiveControlRequestIfTransportHealthy(
            id: showID,
            authorization: WebRTCControlAuthorization()
        )
        for _ in 0..<300 {
            if await state.controlAcknowledgements.contains(where: {
                $0.id == showID && $0.state == .active
            }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let activeAcknowledgements = await state.controlAcknowledgements
        XCTAssertTrue(
            activeAcknowledgements.contains(where: {
                $0.id == showID && $0.state == .active
            })
        )

        _ = try await host.applyScreenVideoEncodingLimits(
            WebRTCScreenVideoEncodingLimits(
                maximumBitrateBps: 32_000,
                maximumFramesPerSecond: 1,
                scaleResolutionDownBy: 12
            )
        )
        let appliedLimits = await host.screenVideoEncodingLimitsForTesting()
        XCTAssertEqual(
            appliedLimits,
            WebRTCScreenVideoEncodingLimits(
                maximumBitrateBps: 32_000,
                maximumFramesPerSecond: 1,
                scaleResolutionDownBy: 12
            )
        )
        capturer.adaptOutput(width: 480, height: 960, framesPerSecond: 1)

        let renderer = ResumeProbeRenderedRTPProbe()
        await MainActor.run { remoteVideoTrack.addRenderer(renderer) }
        defer {
            Task { @MainActor in remoteVideoTrack.removeRenderer(renderer) }
        }

        // A single low-floor warm-up creates and starts the chosen H.264 encoder. It is fully
        // rendered before the covered attempt starts, so no high-bitrate queue can alias Tm.
        let realBuffer = try makeUniformProbePixelBuffer(
            width: 480,
            height: 960,
            value: 0x20
        )
        renderer.clear()
        let warmupRendered = renderer.expectNext()
        capturer.capture(
            pixelBuffer: realBuffer,
            timestampNanoseconds: Int64(
                clamping: DispatchTime.now().uptimeNanoseconds
            )
        )
        await fulfillment(of: [warmupRendered], timeout: 8)
        try await Task.sleep(for: .milliseconds(1_200))

        let attemptID = try XCTUnwrap(
            UUID(uuidString: "A6D359C7-E18B-42F0-9A1C-73B50D24E608")
        )
        let marker = ScreenVideoInBandMarkerNonce(attemptID: attemptID)
        let markerBuffer = try makeMarkerPixelBuffer(
            width: 480,
            height: 960,
            marker: marker
        )

        // Match production's covered inactive -> probe-active transition. The activation is the
        // single permitted encoder-generation rollover and resets WebRTC's screen cadence before
        // the exact marker is admitted.
        let suspension = WebRTCScreenMediaSuspensionNotice(
            screenRequestID: showID,
            suspensionGeneration: 1
        )
        try await host.sendScreenMediaSuspensionNotice(suspension)
        for _ in 0..<300 {
            if await state.suspensionNotices.contains(suspension) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let receivedSuspensionNotices = await state.suspensionNotices
        XCTAssertEqual(receivedSuspensionNotices, [suspension])

        let covered = WebRTCScreenMediaCoveredAcknowledgement(
            suspension: suspension
        )
        try await viewer.sendScreenMediaCoveredAcknowledgement(covered)
        for _ in 0..<300 {
            if await state.coveredAcknowledgements.contains(covered) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let receivedCoveredAcknowledgements = await state.coveredAcknowledgements
        XCTAssertEqual(receivedCoveredAcknowledgements, [covered])

        let hideID = try await viewer.setScreenVisible(false)
        for _ in 0..<300 {
            if await state.controlRequests.contains(where: { $0.id == hideID }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await host.acknowledgeControlRequest(id: hideID, state: .inactive)
        for _ in 0..<300 {
            if await state.controlAcknowledgements.contains(where: {
                $0.id == hideID && $0.state == .inactive
            }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let inactiveEncoding = await host.screenVideoEncodingActivityForTesting()
        XCTAssertEqual(inactiveEncoding, [false])

        _ = try await host.applyScreenVideoEncodingLimits(
            WebRTCScreenVideoEncodingLimits(
                maximumBitrateBps: 32_000,
                maximumFramesPerSecond: 10,
                scaleResolutionDownBy: 12
            )
        )
        capturer.adaptOutput(width: 480, height: 960, framesPerSecond: 10)

        renderer.clear()
        let markerRendered = renderer.expectNext()
        let probeAuthorization = WebRTCControlAuthorization()
        try await host.beginScreenMediaResumeProbeIfTransportHealthy(
            attemptID: attemptID,
            marker: marker,
            boundaryRevision: 103,
            markerInputGateIsClosed: true,
            authorization: probeAuthorization
        )
        let activeProbeEncoding = await host.screenVideoEncodingActivityForTesting()
        XCTAssertEqual(activeProbeEncoding, [true])
        let armedProbeSnapshot = await host
            .screenVideoEncoderResumeProbeSnapshotForTesting()
        XCTAssertEqual(armedProbeSnapshot.attemptID, attemptID)
        capturer.capture(
            pixelBuffer: markerBuffer,
            timestampNanoseconds: Int64(
                clamping: DispatchTime.now().uptimeNanoseconds
            )
        )
        let markerEvents = await drainProbeEvents(
            from: host,
            until: { if case .markerEncoded = $0 { true } else { false } }
        )
        let markerProof = try markerProof(in: markerEvents)
        await fulfillment(of: [markerRendered], timeout: 8)
        let receiverMarkerTimestamp = try XCTUnwrap(renderer.firstTimestamp())
        let markerSources = try await singleSourceSnapshot(of: remoteVideoTrack)
        let markerStatistics = await host.statisticsSnapshot()

        let realAdmissionBegan = await host.beginScreenVideoEncoderRealFrameForTesting(
            attemptID: attemptID,
            markerRTPTimestamp: markerProof.rtpTimestamp,
            boundaryRevision: markerProof.boundaryRevision
        )
        XCTAssertTrue(realAdmissionBegan)
        // The covered production sink switches directly from its one marker injection to bounded
        // real samples; retired-marker suppression is exercised separately at the wrapper level.
        try await Task.sleep(for: .milliseconds(1_050))
        let realRendered = renderer.expectNext(after: receiverMarkerTimestamp)
        var realEvents: [ScreenVideoEncoderResumeProbeEvent] = []
        for _ in 0..<12 where !realEvents.contains(where: {
            if case .realFrameEncoded = $0 { return true }
            return false
        }) {
            let retryRealBuffer = try makeUniformProbePixelBuffer(
                width: 480,
                height: 960,
                value: 0x20
            )
            capturer.capture(
                pixelBuffer: retryRealBuffer,
                timestampNanoseconds: Int64(
                    clamping: DispatchTime.now().uptimeNanoseconds
                )
            )
            try await Task.sleep(for: .milliseconds(1_050))
            realEvents += await host
                .screenVideoEncoderResumeProbeEventsForTesting()
        }
        let realProbeDebugSnapshot = await host
            .screenVideoEncoderResumeProbeSnapshotForTesting()
        let realStatistics = await host.statisticsSnapshot()
        let realProof = try XCTUnwrap(realEvents.compactMap { event in
            if case .realFrameEncoded(let proof) = event { return proof }
            return nil
        }.first, "probe=\(realProbeDebugSnapshot) events=\(realEvents) "
            + "markerStats=\(markerStatistics) realStats=\(realStatistics)")
        await fulfillment(of: [realRendered], timeout: 8)
        let receiverRealTimestamp = try XCTUnwrap(
            renderer.firstTimestamp(after: receiverMarkerTimestamp)
        )
        let realSources = try await singleSourceSnapshot(of: remoteVideoTrack)

        let receiverDelta = try XCTUnwrap(
            resumeProbeForwardDelta(
                receiverRealTimestamp,
                from: receiverMarkerTimestamp
            )
        )
        XCTAssertEqual(realProof.encoderGeneration, markerProof.encoderGeneration)
        XCTAssertEqual(receiverDelta, realProof.forwardDeltaFromMarker)
        XCTAssertEqual(
            receiverMarkerTimestamp &- markerProof.rtpTimestamp,
            receiverRealTimestamp &- realProof.rtpTimestamp,
            "The sender's random RTP offset must stay affine across Tm and Rr."
        )
        XCTAssertEqual(markerSources.receiverID, realSources.receiverID)
        XCTAssertEqual(markerSources.sourceIDs, realSources.sourceIDs)

        await host.cancelScreenMediaResumeProbe(
            attemptID: attemptID,
            reason: "The native probe verification completed."
        )
        _ = try await host.applyScreenVideoEncodingLimits(
            WebRTCScreenVideoEncodingLimits(
                maximumBitrateBps: 32_000,
                maximumFramesPerSecond: 1,
                scaleResolutionDownBy: 12
            )
        )
        capturer.adaptOutput(width: 480, height: 960, framesPerSecond: 1)
        let restoredLimits = await host.screenVideoEncodingLimitsForTesting()
        XCTAssertEqual(
            restoredLimits,
            WebRTCScreenVideoEncodingLimits(
                maximumBitrateBps: 32_000,
                maximumFramesPerSecond: 1,
                scaleResolutionDownBy: 12
            )
        )
    }

    private struct ResumeProbeHarness {
        let probe: ScreenVideoEncoderResumeProbe
        let downstream: ResumeProbeFakeEncoder
        let wrapper: ScreenVideoObservingEncoder
        let marker: ScreenVideoInBandMarkerNonce
        let attemptID: UUID
    }

    private func makeHarness() throws -> ResumeProbeHarness {
        let probe = ScreenVideoEncoderResumeProbe()
        let downstream = ResumeProbeFakeEncoder()
        let wrapper = ScreenVideoObservingEncoder(
            downstream: downstream,
            probe: probe
        )
        return ResumeProbeHarness(
            probe: probe,
            downstream: downstream,
            wrapper: wrapper,
            marker: try XCTUnwrap(
                ScreenVideoInBandMarkerNonce(
                    bytes: (0..<ScreenVideoInBandMarkerNonce.byteCount).map(UInt8.init)
                )
            ),
            attemptID: UUID()
        )
    }

    private func start(_ harness: ResumeProbeHarness) -> Int {
        harness.wrapper.startEncode(
            with: LKRTCVideoEncoderSettings(),
            numberOfCores: 4
        )
    }

    private func completeFence(
        _ harness: ResumeProbeHarness,
        markerTimestamp: UInt32,
        realTimestamp: UInt32,
        receiverMarkerTimestamp: UInt32,
        receiverRealTimestamp: UInt32
    ) throws -> ScreenVideoEncoderResumeAuthorization {
        XCTAssertTrue(
            harness.probe.armMarker(
                attemptID: harness.attemptID,
                marker: harness.marker,
                boundaryRevision: 110,
                markerInputGateIsClosed: true
            )
        )
        _ = harness.wrapper.encode(
            try makeMarkerFrame(marker: harness.marker, timestamp: markerTimestamp),
            codecSpecificInfo: nil,
            frameTypes: []
        )
        let markerProof = try markerProof(
            in: harness.probe.drainEventsForTesting()
        )
        XCTAssertTrue(
            harness.probe.beginRealFrameAdmission(
                attemptID: harness.attemptID,
                markerRTPTimestamp: markerProof.rtpTimestamp,
                boundaryRevision: markerProof.boundaryRevision,
                receiverMarkerRTPTimestamp: receiverMarkerTimestamp
            )
        )
        _ = harness.wrapper.encode(
            try makeRealFrame(timestamp: realTimestamp),
            codecSpecificInfo: nil,
            frameTypes: []
        )
        XCTAssertEqual(
            harness.downstream.lastFrameTypes,
            [NSNumber(value: LKRTCFrameType.videoFrameKey.rawValue)],
            "The first real frame must be an independent visual boundary after the marker freeze."
        )
        let realProof = try XCTUnwrap(
            harness.probe.drainEventsForTesting().compactMap { event in
                if case .realFrameEncoded(let proof) = event { return proof }
                return nil
            }.first
        )
        return try XCTUnwrap(
            harness.probe.issueResumeAuthorization(
                attemptID: harness.attemptID,
                encoderGeneration: realProof.encoderGeneration,
                realEncoderRTPTimestamp: realProof.rtpTimestamp,
                receiverRealRTPTimestamp: receiverRealTimestamp
            )
        )
    }

    private func markerProof(
        in events: [ScreenVideoEncoderResumeProbeEvent]
    ) throws -> ScreenVideoEncoderMarkerProof {
        try XCTUnwrap(events.compactMap { event in
            if case .markerEncoded(let proof) = event { return proof }
            return nil
        }.first)
    }

    private func drainProbeEvents(
        from peer: WebRTCPeer,
        until predicate: (ScreenVideoEncoderResumeProbeEvent) -> Bool
    ) async -> [ScreenVideoEncoderResumeProbeEvent] {
        var events: [ScreenVideoEncoderResumeProbeEvent] = []
        for _ in 0..<800 {
            events += await peer.screenVideoEncoderResumeProbeEventsForTesting()
            if events.contains(where: predicate) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return events
    }

    private func singleSourceSnapshot(
        of track: WebRTCRemoteVideoTrack
    ) async throws -> WebRTCRemoteVideoSourceSnapshot {
        var snapshot = track.sourceSnapshot()
        for _ in 0..<300 where snapshot.sourceIDs.count != 1 {
            try await Task.sleep(for: .milliseconds(10))
            snapshot = track.sourceSnapshot()
        }
        XCTAssertEqual(snapshot.sourceIDs.count, 1)
        return snapshot
    }
}

private func makeMarkerFrame(
    marker: ScreenVideoInBandMarkerNonce,
    timestamp: UInt32
) throws -> LKRTCVideoFrame {
    let width = 160
    let height = 100
    let pixelBuffer = try makeMarkerPixelBuffer(
        width: width,
        height: height,
        marker: marker
    )
    return makeProbeFrame(pixelBuffer: pixelBuffer, timestamp: timestamp)
}

private func makeMarkerPixelBuffer(
    width: Int,
    height: Int,
    marker: ScreenVideoInBandMarkerNonce
) throws -> CVPixelBuffer {
    try ScreenVideoInBandMarkerPixelBufferFactory.make(
        width: width,
        height: height,
        marker: marker
    )
}

private func makeRealFrame(timestamp: UInt32) throws -> LKRTCVideoFrame {
    let pixelBuffer = try makeUniformProbePixelBuffer(
        width: 160,
        height: 100,
        value: 0x20
    )
    return makeProbeFrame(pixelBuffer: pixelBuffer, timestamp: timestamp)
}

private func makeUniformProbePixelBuffer(
    width: Int,
    height: Int,
    value: UInt8
) throws -> CVPixelBuffer {
    let pixelBuffer = try makeProbePixelBuffer(width: width, height: height)
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
        memset(
            baseAddress,
            Int32(value),
            CVPixelBufferGetBytesPerRow(pixelBuffer)
                * CVPixelBufferGetHeight(pixelBuffer)
        )
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    return pixelBuffer
}

private func makeProbeFrame(
    pixelBuffer: CVPixelBuffer,
    timestamp: UInt32
) -> LKRTCVideoFrame {
    let frame = LKRTCVideoFrame(
        buffer: LKRTCCVPixelBuffer(pixelBuffer: pixelBuffer),
        rotation: ._0,
        timeStampNs: Int64(timestamp) * 1_000
    )
    frame.timeStamp = Int32(bitPattern: timestamp)
    return frame
}

private func makeProbePixelBuffer(
    width: Int,
    height: Int
) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw ResumeProbePixelBufferError.creationFailed(status)
    }
    return pixelBuffer
}

private enum ResumeProbePixelBufferError: Error {
    case creationFailed(CVReturn)
    case missingBaseAddress
}

private func resumeProbeForwardDelta(
    _ candidate: UInt32,
    from reference: UInt32
) -> UInt32? {
    let delta = candidate &- reference
    guard delta != 0,
          delta != 0x8000_0000,
          delta < 0x8000_0000 else {
        return nil
    }
    return delta
}
