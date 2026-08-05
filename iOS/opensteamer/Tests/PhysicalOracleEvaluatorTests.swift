import CoreVideo
import XCTest
@testable import opensteamer
@testable import WebRTCTransport

private final class RawMicrophoneOracleIdentity {}

/// Locks down the machine-readable physical audio/video oracle semantics.
/// Tests exercise malformed payload rejection, monotonic counter requirements, waveform-quality
/// thresholds, and stable-duration windows so one late callback or static frame cannot pass.
final class PhysicalOracleEvaluatorTests: XCTestCase {
    private let session = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let renderer = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let hostedPolicy = UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!
    private let ordinaryAudioPolicy = UUID(uuidString: "cccccccc-dddd-eeee-ffff-000000000002")!
    private let hostedAudioPolicy = UUID(uuidString: "cccccccc-dddd-eeee-ffff-000000000001")!
    private let rawWindow = UUID(uuidString: "dddddddd-eeee-ffff-0000-000000000001")!
    private let rawTransport = UUID(uuidString: "dddddddd-eeee-ffff-0000-000000000002")!
    private let rawAudioPolicy = UUID(uuidString: "dddddddd-eeee-ffff-0000-000000000003")!
    private let rawPeerEpoch = UUID(uuidString: "dddddddd-eeee-ffff-0000-000000000004")!
    private let rawPeerIdentity = RawMicrophoneOracleIdentity()
    private let rawAuthorizationIdentity =
        RawMicrophoneOracleIdentity()
    private let rawReplacementIdentity =
        RawMicrophoneOracleIdentity()

    @MainActor
    func testRawMicrophoneProductionOracleRequiresTwoExactSamplesAndRoundTrips() throws {
        var tracker = WorldwideRawMicrophoneContinuityTracker()
        XCTAssertEqual(
            tracker.observe(rawMicrophoneSample(time: 1)),
            .waiting
        )
        let result = tracker.observe(rawMicrophoneSample(time: 2))
        guard case .satisfied(let production) = result else {
            return XCTFail("Two coherent advancing exact samples must publish.")
        }
        let value = try XCTUnwrap(
            BrowserView.rawMicrophoneOracleAccessibilityValue(
                production
            )
        )
        XCTAssertLessThanOrEqual(
            value.utf8.count,
            WorldwideRawMicrophoneOracleSnapshot
                .maximumAccessibilityValueBytes
        )
        let parsed = try XCTUnwrap(
            PhysicalRawMicrophoneSnapshot(
                accessibilityValue: value
            )
        )
        XCTAssertGreaterThan(parsed.applicationProcessIdentifier, 0)
        XCTAssertEqual(parsed.applicationProcessIdentifier, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(parsed.sessionGeneration, session)
        XCTAssertEqual(parsed.transportAuthorizationGeneration, rawTransport)
        XCTAssertEqual(parsed.audioPolicyGeneration, rawAudioPolicy)
        XCTAssertEqual(parsed.negotiationEpoch, 5)
        XCTAssertEqual(parsed.bindingGeneration, 3)
        XCTAssertEqual(parsed.trackGeneration, 7)
        XCTAssertEqual(parsed.microphonePolicyGeneration, 11)
        XCTAssertEqual(parsed.recordingGeneration, 13)
        XCTAssertEqual(parsed.approvedRecordingGeneration, 13)
        XCTAssertEqual(parsed.realtimeAdmissionCount, 200)
        XCTAssertEqual(parsed.deliveryCallbackCount, 200)
        XCTAssertEqual(parsed.deliveredFrameCount, 96_000)
        XCTAssertEqual(parsed.packetsSent, 100)
        XCTAssertEqual(parsed.bytesSent, 16_000)
        XCTAssertEqual(parsed.coherentSampleCount, 2)
    }

    func testRawMicrophoneDensityRequiresRealtimeMovementAndAllowsSilence() {
        let silentPrevious = rawMicrophoneSample(
            time: 1,
            audioTotals: (0, 1)
        )
        let silentCurrent = rawMicrophoneSample(
            time: 2,
            audioTotals: (0, 2)
        )
        XCTAssertEqual(
            WorldwideRawMicrophoneOracleEvaluator.evaluate(
                previous: silentPrevious,
                current: silentCurrent
            ),
            .advancing,
            "Zero energy magnitude is legitimate when sample duration and every delivery counter advance."
        )

        let absentPrevious = rawMicrophoneSample(
            time: 1,
            audioTotals: (nil, nil)
        )
        let sparseProduction = rawMicrophoneSample(
            time: 2,
            sender: rawMicrophoneSender(
                time: 2,
                realtimeAdmissionCount: 101,
                deliveryCallbackCount: 101,
                deliveredFrameCount: 48_001
            ),
            packetsSent: 51,
            bytesSent: 8_001,
            audioTotals: (nil, nil)
        )
        XCTAssertEqual(
            WorldwideRawMicrophoneOracleEvaluator.evaluate(
                previous: absentPrevious,
                current: sparseProduction
            ),
            .insufficientDensity
        )

        let baseValue = rawOracleAccessibilityValue()
        let physicalPrevious = physicalRawSnapshot(
            basedOn: baseValue
        )
        let silentPhysical = physicalRawSnapshot(
            basedOn: baseValue,
            overrides: rawPhysicalOverrides(
                step: 1,
                energy: 0.5
            )
        )
        XCTAssertEqual(
            PhysicalRawMicrophoneEvaluator.evaluate(
                previous: physicalPrevious,
                current: silentPhysical,
                elapsed: 1.3
            ),
            .advancing
        )
        XCTAssertTrue(
            PhysicalRawMicrophoneEvaluator.coversElapsedInterval(
                previous: physicalPrevious,
                current: silentPhysical,
                elapsed: 1.3
            )
        )

        var sparseOverrides = rawPhysicalOverrides(
            step: 1,
            energy: 0.5
        )
        sparseOverrides["admissions"] = "201"
        sparseOverrides["callbacks"] = "201"
        sparseOverrides["frames"] = "96001"
        sparseOverrides["packets"] = "101"
        sparseOverrides["bytes"] = "16001"
        let sparsePhysical = physicalRawSnapshot(
            basedOn: baseValue,
            overrides: sparseOverrides
        )
        XCTAssertEqual(
            PhysicalRawMicrophoneEvaluator.evaluate(
                previous: physicalPrevious,
                current: sparsePhysical,
                elapsed: 1.3
            ),
            .insufficientDensity
        )
        XCTAssertFalse(
            PhysicalRawMicrophoneEvaluator.coversElapsedInterval(
                previous: physicalPrevious,
                current: sparsePhysical,
                elapsed: 1.3
            )
        )
    }

    func testRawMicrophoneRejectsStructurallyAllZeroPayloads() {
        let allZeroProduction = rawMicrophoneSample(
            time: 0,
            sender: rawMicrophoneSender(
                time: 0,
                realtimeAdmissionCount: 0,
                deliveryCallbackCount: 0,
                deliveredFrameCount: 0
            ),
            packetsSent: 0,
            bytesSent: 0,
            audioTotals: (nil, nil)
        )
        XCTAssertFalse(
            WorldwideRawMicrophoneOracleEvaluator
                .hasValidState(allZeroProduction)
        )

        let allZeroValue = replacingOracleFields(
            in: rawOracleAccessibilityValue(),
            overrides: [
                "admissions": "0",
                "callbacks": "0",
                "frames": "0",
                "packets": "0",
                "bytes": "0",
            ]
        )
        XCTAssertNil(
            PhysicalRawMicrophoneSnapshot(
                accessibilityValue: allZeroValue
            )
        )
    }

    func testRawMicrophoneRejectsEveryOwnershipPolicyTopologyAndAuthorizationGateMutation() {
        let invalidSenders: [(String, WebRTCIPhoneMicrophoneSenderDiagnostics)] = [
            ("wrong sender MID", rawMicrophoneSender(time: 2, senderOwnsMID: false)),
            ("replaced local track", rawMicrophoneSender(time: 2, senderOwnsLocalTrack: false)),
            ("stopped transceiver", rawMicrophoneSender(time: 2, transceiverIsStopped: true)),
            ("preferred direction not sending", rawMicrophoneSender(time: 2, preferredDirectionIncludesSending: false)),
            ("current direction not sending", rawMicrophoneSender(time: 2, currentDirectionIncludesSending: false)),
            ("track disabled", rawMicrophoneSender(time: 2, trackIsEnabled: false)),
            ("raw processing false", rawMicrophoneSender(time: 2, rawProcessingIsLive: false)),
            ("peer transport unhealthy", rawMicrophoneSender(time: 2, transportIsHealthy: false)),
            ("authorization not current", rawMicrophoneSender(time: 2, authorizationIsCurrent: false)),
            ("authorization closed", rawMicrophoneSender(time: 2, authorizationIsValid: false)),
            ("sender not admitted", rawMicrophoneSender(time: 2, senderIsAdmitted: false)),
            ("device closed", rawMicrophoneSender(time: 2, nativeDeviceIsOpen: false)),
            ("device gate closed", rawMicrophoneSender(time: 2, nativeDeviceGateIsOpen: false)),
            ("authorization gate closed", rawMicrophoneSender(time: 2, nativeAuthorizationGateIsOpen: false)),
            ("wrong category", rawMicrophoneSender(time: 2, categoryIsPlayAndRecord: false)),
            ("wrong mode", rawMicrophoneSender(time: 2, modeIsDefault: false)),
            ("wrong audio unit", rawMicrophoneSender(time: 2, usesRemoteIO: false)),
            ("input bus disabled", rawMicrophoneSender(time: 2, inputBusEnabled: false)),
            ("capture route is not built-in microphone", rawMicrophoneSender(time: 2, captureRouteIsBuiltInMicrophone: false)),
            ("capture route proof generation is zero", rawMicrophoneSender(time: 2, captureRouteProofGeneration: 0)),
            ("output bus disabled", rawMicrophoneSender(time: 2, outputBusEnabled: false)),
            ("category options empty", rawMicrophoneSender(time: 2, categoryOptionsAreEmpty: true)),
            ("wrong category options", rawMicrophoneSender(time: 2, categoryOptionsAreIPhoneMicrophoneRouting: false)),
            ("wrong route policy", rawMicrophoneSender(time: 2, routeSharingPolicyIsDefault: false)),
            ("output route absent", rawMicrophoneSender(time: 2, hasOutputRoute: false)),
            ("wrong sample rate", rawMicrophoneSender(time: 2, sampleRateIs48k: false)),
            ("unbounded IO buffer", rawMicrophoneSender(time: 2, ioBufferDurationIsBounded: false)),
            ("wrong channel topology", rawMicrophoneSender(time: 2, outputChannelCountIsStereo: false)),
            ("recovery required", rawMicrophoneSender(time: 2, recoveryRequired: true)),
            ("explicit resume required", rawMicrophoneSender(time: 2, explicitResumeRequired: true)),
            ("hosted call topology", rawMicrophoneSender(time: 2, hostedCallMode: true)),
            ("native failure", rawMicrophoneSender(time: 2, failureCode: 1)),
            ("native status", rawMicrophoneSender(time: 2, lastLifecycleStatus: -1)),
            ("zero generation", rawMicrophoneSender(time: 2, recordingGeneration: 0, approvedRecordingGeneration: 0)),
            ("mismatched generation", rawMicrophoneSender(time: 2, recordingGeneration: 13, approvedRecordingGeneration: 14)),
        ]
        for (name, sender) in invalidSenders {
            XCTAssertFalse(
                WorldwideRawMicrophoneOracleEvaluator.hasValidState(
                    rawMicrophoneSample(time: 2, sender: sender)
                ),
                name
            )
        }

        let invalidContexts: [(String, WorldwideRawMicrophoneProofSample)] = [
            ("not paired", rawMicrophoneSample(time: 2, authenticatedPairedSession: false)),
            ("mic intent off", rawMicrophoneSample(time: 2, microphoneIntentIsCurrent: false)),
            ("permission denied", rawMicrophoneSample(time: 2, microphonePermissionGranted: false)),
            ("call active", rawMicrophoneSample(time: 2, callIsActive: true)),
            ("transport unhealthy", rawMicrophoneSample(time: 2, transportIsHealthy: false)),
            ("source report unlinked", rawMicrophoneSample(time: 2, sourceReportWasLinked: false)),
        ]
        for (name, sample) in invalidContexts {
            XCTAssertFalse(
                WorldwideRawMicrophoneOracleEvaluator
                    .hasValidState(sample),
                name
            )
        }

        XCTAssertTrue(
            WorldwideRawMicrophoneOracleEvaluator.hasValidState(
                rawMicrophoneSample(
                    time: 2,
                    callIsActive: true,
                    macHostedCallEvidenceAdmitted: true
                )
            )
        )
        XCTAssertFalse(
            WorldwideRawMicrophoneOracleEvaluator.hasValidState(
                rawMicrophoneSample(
                    time: 2,
                    macHostedCallEvidenceAdmitted: true
                )
            )
        )
    }

    func testRawMicrophoneRejectsEveryStaleIdentityAndGenerationReplacement() {
        let previous = rawMicrophoneSample(time: 1)
        let replacementIdentity =
            ObjectIdentifier(rawReplacementIdentity)
        let cases: [(String, WorldwideRawMicrophoneProofSample)] = [
            (
                "session",
                rawMicrophoneSample(time: 2, sessionGeneration: UUID())
            ),
            (
                "peer object",
                rawMicrophoneSample(time: 2, peerIdentity: replacementIdentity)
            ),
            (
                "authorization object",
                rawMicrophoneSample(time: 2, authorizationIdentity: replacementIdentity)
            ),
            (
                "transport generation",
                rawMicrophoneSample(time: 2, transportAuthorizationGeneration: UUID())
            ),
            (
                "audio policy generation",
                rawMicrophoneSample(time: 2, audioPolicyGeneration: UUID())
            ),
            (
                "peer epoch",
                rawMicrophoneSample(
                    time: 2,
                    sender: rawMicrophoneSender(time: 2, peerEpoch: UUID())
                )
            ),
            (
                "sender binding",
                rawMicrophoneSample(
                    time: 2,
                    sender: rawMicrophoneSender(time: 2, bindingGeneration: 4)
                )
            ),
            (
                "negotiation epoch",
                rawMicrophoneSample(
                    time: 2,
                    sender: rawMicrophoneSender(time: 2, negotiationEpoch: 6)
                )
            ),
            (
                "track generation",
                rawMicrophoneSample(
                    time: 2,
                    sender: rawMicrophoneSender(time: 2, trackGeneration: 8)
                )
            ),
            (
                "microphone policy generation",
                rawMicrophoneSample(
                    time: 2,
                    sender: rawMicrophoneSender(time: 2, microphonePolicyGeneration: 12)
                )
            ),
            (
                "capture route proof generation",
                rawMicrophoneSample(
                    time: 2,
                    sender: rawMicrophoneSender(
                        time: 2,
                        captureRouteProofGeneration: 14
                    )
                )
            ),
            (
                "native generation",
                rawMicrophoneSample(
                    time: 2,
                    sender: rawMicrophoneSender(
                        time: 2,
                        recordingGeneration: 14,
                        approvedRecordingGeneration: 14
                    )
                )
            ),
        ]
        for (name, current) in cases {
            XCTAssertNotEqual(
                WorldwideRawMicrophoneOracleEvaluator.evaluate(
                    previous: previous,
                    current: current
                ),
                .advancing,
                name
            )
        }
    }

    func testRawMicrophoneRejectsFrozenRegressingMalformedAndUnboundedCounters() {
        let previous = rawMicrophoneSample(time: 1)
        let frozen: [(String, WorldwideRawMicrophoneProofSample)] = [
            (
                "native admission",
                rawMicrophoneSample(
                    time: 2,
                    sender: rawMicrophoneSender(
                        time: 2,
                        realtimeAdmissionCount: 100,
                        deliveryCallbackCount: 100
                    )
                )
            ),
            (
                "native callback",
                rawMicrophoneSample(
                    time: 2,
                    sender: rawMicrophoneSender(time: 2, deliveryCallbackCount: 100)
                )
            ),
            (
                "native frame",
                rawMicrophoneSample(
                    time: 2,
                    sender: rawMicrophoneSender(time: 2, deliveredFrameCount: 48_000)
                )
            ),
            ("sender packets", rawMicrophoneSample(time: 2, packetsSent: 50)),
            ("sender bytes", rawMicrophoneSample(time: 2, bytesSent: 8_000)),
            ("audio duration", rawMicrophoneSample(time: 2, audioTotals: (0.50, 1))),
        ]
        for (name, current) in frozen {
            XCTAssertEqual(
                WorldwideRawMicrophoneOracleEvaluator.evaluate(
                    previous: previous,
                    current: current
                ),
                .counterStalled,
                name
            )
        }

        let regressing: [(String, WorldwideRawMicrophoneProofSample)] = [
            (
                "native admission",
                rawMicrophoneSample(
                    time: 2,
                    sender: rawMicrophoneSender(
                        time: 2,
                        realtimeAdmissionCount: 99,
                        deliveryCallbackCount: 99
                    )
                )
            ),
            (
                "native callback",
                rawMicrophoneSample(
                    time: 2,
                    sender: rawMicrophoneSender(time: 2, deliveryCallbackCount: 99)
                )
            ),
            (
                "native frame",
                rawMicrophoneSample(
                    time: 2,
                    sender: rawMicrophoneSender(time: 2, deliveredFrameCount: 47_999)
                )
            ),
            ("sender packets", rawMicrophoneSample(time: 2, packetsSent: 49)),
            ("sender bytes", rawMicrophoneSample(time: 2, bytesSent: 7_999)),
            ("audio totals", rawMicrophoneSample(time: 2, audioTotals: (0.24, 0.99))),
        ]
        for (name, current) in regressing {
            XCTAssertEqual(
                WorldwideRawMicrophoneOracleEvaluator.evaluate(
                    previous: previous,
                    current: current
                ),
                .counterRegressed,
                name
            )
        }

        XCTAssertFalse(
            WorldwideRawMicrophoneOracleEvaluator.hasValidState(
                rawMicrophoneSample(time: 2, audioTotals: (0.5, nil))
            )
        )
        let leap = rawMicrophoneSample(
            time: 1.1,
            sender: rawMicrophoneSender(
                time: 1.1,
                realtimeAdmissionCount: 10_000,
                deliveryCallbackCount: 10_000,
                deliveredFrameCount: 10_000_000
            ),
            packetsSent: 10_000,
            bytesSent: 100_000_000,
            audioTotals: (1, 1.1)
        )
        XCTAssertEqual(
            WorldwideRawMicrophoneOracleEvaluator.evaluate(
                previous: previous,
                current: leap
            ),
            .counterLeap
        )
    }

    func testRawMicrophoneContinuityResetsAfterTeardownCallDenialAndMicrophoneOff() {
        var teardown = WorldwideRawMicrophoneContinuityTracker()
        _ = teardown.observe(rawMicrophoneSample(time: 1))
        guard case .satisfied =
            teardown.observe(rawMicrophoneSample(time: 2)) else {
            return XCTFail("Precondition proof did not publish.")
        }
        teardown.reset()
        XCTAssertEqual(
            teardown.observe(rawMicrophoneSample(time: 3)),
            .waiting
        )

        let invalidTransitions = [
            rawMicrophoneSample(time: 3, callIsActive: true),
            rawMicrophoneSample(time: 3, microphonePermissionGranted: false),
            rawMicrophoneSample(time: 3, microphoneIntentIsCurrent: false),
            rawMicrophoneSample(time: 3, transportIsHealthy: false),
        ]
        for invalid in invalidTransitions {
            var tracker = WorldwideRawMicrophoneContinuityTracker()
            _ = tracker.observe(rawMicrophoneSample(time: 1))
            guard case .satisfied =
                tracker.observe(rawMicrophoneSample(time: 2)) else {
                return XCTFail("Precondition proof did not publish.")
            }
            XCTAssertEqual(tracker.observe(invalid), .rejected)
            XCTAssertEqual(
                tracker.observe(rawMicrophoneSample(time: 4)),
                .waiting,
                "A retired window must require a new baseline."
            )
        }
    }

    @MainActor
    func testRawMicrophoneAccessibilityParserAndPhysicalContinuityFailClosed() throws {
        let baseValue = rawOracleAccessibilityValue()
        let snapshots = (0...2).map {
            physicalRawSnapshot(
                basedOn: baseValue,
                overrides: rawPhysicalOverrides(step: UInt64($0))
            )
        }

        var physical = PhysicalRawMicrophoneContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 1.5,
            expectedSessionGeneration: session,
            expectedWindowGeneration:
                snapshots[0].windowGeneration,
            minimumAdvancementObservations: 2
        )
        XCTAssertEqual(physical.observe(snapshots[0], at: 0), .waiting)
        XCTAssertEqual(physical.observe(snapshots[1], at: 1.3), .waiting)
        XCTAssertEqual(physical.observe(snapshots[2], at: 2.6), .satisfied)
        XCTAssertEqual(physical.advancementObservationCount, 2)
        XCTAssertEqual(physical.accumulatedValidDuration, 2.6, accuracy: 0.000_001)

        let validValue = rawOracleAccessibilityValue()
        let processIdentifierField =
            "pid=\(ProcessInfo.processInfo.processIdentifier)"
        let valueWithoutProcessIdentifier = validValue
            .split(separator: "|")
            .filter { !$0.hasPrefix("pid=") }
            .joined(separator: "|")
        let malformed = [
            validValue + "|\(processIdentifierField)",
            valueWithoutProcessIdentifier,
            validValue + "|packets=999",
            validValue.replacingOccurrences(of: "v=3", with: "v=2"),
            validValue.replacingOccurrences(of: "energy=0.5", with: "energy=nan"),
            validValue.replacingOccurrences(of: "recording=13", with: "recording=0"),
            validValue.replacingOccurrences(of: "approved=13", with: "approved=14"),
            validValue.replacingOccurrences(of: "raw=1", with: "raw=0"),
            validValue.replacingOccurrences(
                of: "captureBuiltInMic=1",
                with: "captureBuiltInMic=0"
            ),
            validValue
                .split(separator: "|")
                .filter { !$0.hasPrefix("captureBuiltInMic=") }
                .joined(separator: "|"),
            validValue.replacingOccurrences(
                of: processIdentifierField,
                with: "pid=0"
            ),
            validValue.replacingOccurrences(
                of: processIdentifierField,
                with: "pid=not-a-number"
            ),
            validValue.replacingOccurrences(
                of: processIdentifierField,
                with: "pid=\(Int64(Int32.max) + 1)"
            ),
            replacingOracleFields(
                in: validValue,
                overrides: [
                    "admissions": "0",
                    "callbacks": "0",
                    "frames": "0",
                    "packets": "0",
                    "bytes": "0",
                ]
            ),
            String(repeating: "x", count: 1_025),
        ]
        for value in malformed {
            XCTAssertNil(
                PhysicalRawMicrophoneSnapshot(
                    accessibilityValue: value
                )
            )
        }
        XCTAssertNil(
            BrowserView.rawMicrophoneOracleAccessibilityValue(nil)
        )
    }

    func testRawMicrophoneRollingTrackerSupportsArbitraryDurationAndRetiresInvalidSegments() {
        let baseValue = rawOracleAccessibilityValue()
        let snapshots = (0...6).map {
            physicalRawSnapshot(
                basedOn: baseValue,
                overrides: rawPhysicalOverrides(step: UInt64($0))
            )
        }

        var longWindow = PhysicalRawMicrophoneContinuityTracker(
            requiredDuration: 6.5,
            maximumProgressGap: 1.5,
            expectedSessionGeneration: session,
            expectedWindowGeneration: snapshots[0].windowGeneration,
            minimumAdvancementObservations: 5
        )
        XCTAssertEqual(longWindow.observe(snapshots[0], at: 0), .waiting)
        for index in 1..<5 {
            XCTAssertEqual(
                longWindow.observe(
                    snapshots[index],
                    at: Double(index) * 1.3
                ),
                .waiting
            )
        }
        XCTAssertEqual(
            longWindow.observe(snapshots[5], at: 6.5),
            .satisfied
        )
        XCTAssertEqual(longWindow.advancementObservationCount, 5)
        XCTAssertEqual(
            longWindow.accumulatedValidDuration,
            6.5,
            accuracy: 0.000_001
        )

        var gap = PhysicalRawMicrophoneContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 1.5,
            expectedSessionGeneration: session,
            expectedWindowGeneration: snapshots[0].windowGeneration
        )
        XCTAssertEqual(gap.observe(snapshots[0], at: 0), .waiting)
        XCTAssertEqual(
            gap.observe(snapshots[1], at: 1.6),
            .rejected,
            "An oversized adjacent gap must retire the entire rolling window."
        )
        XCTAssertEqual(gap.observe(snapshots[2], at: 2.9), .waiting)
        XCTAssertEqual(gap.observe(snapshots[3], at: 4.2), .waiting)
        XCTAssertEqual(gap.observe(snapshots[4], at: 5.5), .satisfied)

        var timestampRegression = PhysicalRawMicrophoneContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 1.5
        )
        XCTAssertEqual(
            timestampRegression.observe(snapshots[0], at: 1),
            .waiting
        )
        XCTAssertEqual(
            timestampRegression.observe(snapshots[1], at: 1),
            .rejected
        )

        func mutant(
            _ additional: [String: String]
        ) -> PhysicalRawMicrophoneSnapshot {
            var overrides = rawPhysicalOverrides(step: 1)
            for (key, value) in additional {
                overrides[key] = value
            }
            return physicalRawSnapshot(
                basedOn: baseValue,
                overrides: overrides
            )
        }

        let replacementCases: [(String, PhysicalRawMicrophoneSnapshot)] = [
            (
                "session",
                mutant(["session": UUID().uuidString.lowercased()])
            ),
            (
                "window",
                mutant(["window": UUID().uuidString.lowercased()])
            ),
            (
                "transport",
                mutant(["transport": UUID().uuidString.lowercased()])
            ),
            (
                "audio policy",
                mutant(["audioPolicy": UUID().uuidString.lowercased()])
            ),
            (
                "sender generation",
                mutant(["recording": "14", "approved": "14"])
            ),
            (
                "counter regression",
                mutant([
                    "admissions": "199",
                    "callbacks": "199",
                    "frames": "95999",
                    "packets": "99",
                    "bytes": "15999",
                ])
            ),
        ]

        for (name, replacement) in replacementCases {
            var tracker = PhysicalRawMicrophoneContinuityTracker(
                requiredDuration: 2,
                maximumProgressGap: 1.5,
                expectedSessionGeneration: session,
                expectedWindowGeneration:
                    snapshots[0].windowGeneration
            )
            XCTAssertEqual(tracker.observe(snapshots[0], at: 0), .waiting)
            XCTAssertEqual(
                tracker.observe(replacement, at: 1.3),
                .rejected,
                name
            )
            XCTAssertEqual(
                tracker.observe(snapshots[2], at: 2.6),
                .waiting,
                "\(name) did not require a new baseline."
            )
        }

        var leapOverrides = rawPhysicalOverrides(step: 1)
        leapOverrides["admissions"] = "10000"
        leapOverrides["callbacks"] = "10000"
        leapOverrides["frames"] = "10000000"
        leapOverrides["packets"] = "10000"
        leapOverrides["bytes"] = "100000000"
        let leap = physicalRawSnapshot(
            basedOn: baseValue,
            overrides: leapOverrides
        )
        XCTAssertEqual(
            PhysicalRawMicrophoneEvaluator.evaluate(
                previous: snapshots[0],
                current: leap,
                elapsed: 0.1
            ),
            .counterLeap
        )
        var leapTracker = PhysicalRawMicrophoneContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 1.5
        )
        XCTAssertEqual(leapTracker.observe(snapshots[0], at: 0), .waiting)
        XCTAssertEqual(leapTracker.observe(leap, at: 0.1), .rejected)
    }

    func testProductionAudioAccessibilityV2ContractRoundTripsWithExactPolicy() throws {
        let productionValue = ordinaryAudioAccessibilityValue()
        let production = try XCTUnwrap(
            PhysicalAudioPlayoutSnapshot(
                accessibilityValue: productionValue
            )
        )

        XCTAssertEqual(
            productionValue.split(separator: "|").prefix(3).map(String.init),
            [
                "v=2",
                "session=\(session.uuidString.lowercased())",
                "audioPolicy=\(ordinaryAudioPolicy.uuidString.lowercased())",
            ]
        )
        XCTAssertEqual(production.sessionGeneration, session)
        XCTAssertEqual(
            production.audioPolicyGeneration,
            ordinaryAudioPolicy
        )
        XCTAssertEqual(production.callbackCount, 41)
        XCTAssertEqual(production.frameCount, 19_680)
        XCTAssertEqual(production.failureCount, 0)
        XCTAssertEqual(production.pcmSampleCount, 39_360)
        XCTAssertEqual(production.pcmNonzeroSampleCount, 38_000)
        XCTAssertEqual(production.pcmAbsoluteSampleSum, 38_000_000)
        XCTAssertEqual(production.pcmLeftAbsoluteSampleSum, 19_000_000)
        XCTAssertEqual(production.pcmRightAbsoluteSampleSum, 19_000_000)
        XCTAssertEqual(
            production.pcmStereoDifferenceAbsoluteSampleSum,
            9_000_000
        )
        XCTAssertEqual(production.pcmEnvelopeTransitionCount, 3)
        XCTAssertEqual(production.pcmShapeAnomalyCallbackCount, 1)
        XCTAssertEqual(production.pcmBoundaryDiscontinuityCallbackCount, 1)
        XCTAssertEqual(production.lastCallbackMeanMagnitude, 1_250)
        XCTAssertEqual(production.lastPeakMagnitude, 8_000)
        XCTAssertEqual(production.inboundAudioEnergy, 2.5)
        XCTAssertEqual(production.inboundSamplesDuration, 0.41)
        XCTAssertTrue(production.fullQualityInvariantsHold)
    }

    func testOrdinaryAudioParserRejectsV1AndEveryMalformedAudioPolicyForm() {
        let valid = ordinaryAudioAccessibilityValue()
        let components = valid.split(
            separator: "|",
            omittingEmptySubsequences: false
        )

        XCTAssertNil(
            PhysicalAudioPlayoutSnapshot(
                accessibilityValue:
                    valid.replacingOccurrences(
                        of: "v=2",
                        with: "v=1"
                    )
            )
        )
        XCTAssertNil(
            PhysicalAudioPlayoutSnapshot(
                accessibilityValue: components
                    .filter { !$0.hasPrefix("audioPolicy=") }
                    .joined(separator: "|")
            )
        )
        XCTAssertNil(
            PhysicalAudioPlayoutSnapshot(
                accessibilityValue:
                    valid
                        + "|audioPolicy="
                        + ordinaryAudioPolicy.uuidString.lowercased()
            )
        )
        XCTAssertNil(
            PhysicalAudioPlayoutSnapshot(
                accessibilityValue: valid + "|unknown=1"
            )
        )

        let invalidPolicies = [
            "not-a-uuid",
            "00000000-0000-0000-0000-000000000000",
            ordinaryAudioPolicy.uuidString.uppercased(),
            "",
        ]
        for invalid in invalidPolicies {
            XCTAssertNil(
                PhysicalAudioPlayoutSnapshot(
                    accessibilityValue: replacingOracleFields(
                        in: valid,
                        overrides: ["audioPolicy": invalid]
                    )
                ),
                invalid
            )
        }
    }

    func testOrdinaryAudioEvaluatorAndTrackerRejectCrossPolicyEvidence() {
        let previous = audio(
            callbacks: 10,
            frames: 4_800,
            failures: 0
        )
        let replacementPolicy = UUID()
        let replacement = audio(
            audioPolicy: replacementPolicy,
            callbacks: 20,
            frames: 9_600,
            failures: 0
        )

        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: replacement
            ),
            .audioPolicyChanged
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: replacement,
                elapsed: 1
            )
        )

        var expectedMismatch = PhysicalAudioContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 1.5,
            expectedSessionGeneration: session,
            expectedAudioPolicyGeneration: replacementPolicy
        )
        XCTAssertEqual(
            expectedMismatch.observe(previous, at: 0),
            .rejected
        )
    }

    func testPreCallSeededAudioTrackerCannotSatisfyPostCallPolicyAndFreshTrackerNeedsLaterAdvancement() {
        let preCallBaseline = audio(
            callbacks: 10,
            frames: 4_800,
            failures: 0
        )
        let preCallAdvancing = audio(
            callbacks: 110,
            frames: 52_800,
            failures: 0
        )
        var preCallTracker = PhysicalAudioContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 1.5,
            expectedSessionGeneration: session
        )
        XCTAssertEqual(
            preCallTracker.observe(preCallBaseline, at: 0),
            .waiting
        )
        XCTAssertEqual(
            preCallTracker.observe(preCallAdvancing, at: 1),
            .waiting
        )

        let postCallPolicy = UUID()
        let postCallBaseline = audio(
            audioPolicy: postCallPolicy,
            callbacks: 10,
            frames: 4_800,
            failures: 0
        )
        XCTAssertEqual(
            preCallTracker.observe(postCallBaseline, at: 2),
            .rejected,
            "A pre-call-seeded window must retire instead of comparing counters across policies."
        )

        var postCallTracker = PhysicalAudioContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 1.5,
            expectedSessionGeneration: session,
            expectedAudioPolicyGeneration: postCallPolicy
        )
        XCTAssertEqual(
            postCallTracker.observe(postCallBaseline, at: 0),
            .waiting,
            "The first post-call publication is only the new policy baseline."
        )
        XCTAssertEqual(
            postCallTracker.observe(
                audio(
                    audioPolicy: postCallPolicy,
                    callbacks: 110,
                    frames: 52_800,
                    failures: 0
                ),
                at: 1
            ),
            .waiting
        )
        XCTAssertEqual(
            postCallTracker.observe(
                audio(
                    audioPolicy: postCallPolicy,
                    callbacks: 210,
                    frames: 100_800,
                    failures: 0
                ),
                at: 2
            ),
            .waiting
        )
        XCTAssertEqual(
            postCallTracker.observe(
                audio(
                    audioPolicy: postCallPolicy,
                    callbacks: 310,
                    frames: 148_800,
                    failures: 0
                ),
                at: 3
            ),
            .satisfied
        )
    }

    func testProductionAudioAccessibilityContractRoundTrips() throws {
        let production = WorldwideAudioPlayoutOracleSnapshot(
            sessionGeneration: session,
            audioPolicyGeneration: ordinaryAudioPolicy,
            callbackCount: 41,
            frameCount: 19_680,
            failureCount: 0,
            pcmSampleCount: 39_360,
            pcmNonzeroSampleCount: 38_000,
            pcmAbsoluteSampleSum: 38_000_000,
            pcmLeftAbsoluteSampleSum: 19_000_000,
            pcmRightAbsoluteSampleSum: 19_000_000,
            pcmStereoDifferenceAbsoluteSampleSum: 9_000_000,
            pcmEnvelopeTransitionCount: 3,
            pcmShapeAnomalyCallbackCount: 1,
            pcmBoundaryDiscontinuityCallbackCount: 1,
            lastCallbackMeanMagnitude: 1_250,
            lastPeakMagnitude: 8_000,
            inboundAudioEnergy: 2.5,
            inboundSamplesDuration: 0.41,
            fullQualityInvariantsHold: true
        )

        let parsed = try XCTUnwrap(
            PhysicalAudioPlayoutSnapshot(
                accessibilityValue: production.accessibilityValue
            )
        )
        XCTAssertEqual(parsed.sessionGeneration, session)
        XCTAssertEqual(
            parsed.audioPolicyGeneration,
            ordinaryAudioPolicy
        )
        XCTAssertEqual(parsed.callbackCount, 41)
        XCTAssertEqual(parsed.frameCount, 19_680)
        XCTAssertEqual(parsed.failureCount, 0)
        XCTAssertEqual(parsed.pcmSampleCount, 39_360)
        XCTAssertEqual(parsed.pcmNonzeroSampleCount, 38_000)
        XCTAssertEqual(parsed.pcmAbsoluteSampleSum, 38_000_000)
        XCTAssertEqual(parsed.pcmLeftAbsoluteSampleSum, 19_000_000)
        XCTAssertEqual(parsed.pcmRightAbsoluteSampleSum, 19_000_000)
        XCTAssertEqual(parsed.pcmStereoDifferenceAbsoluteSampleSum, 9_000_000)
        XCTAssertEqual(parsed.pcmEnvelopeTransitionCount, 3)
        XCTAssertEqual(parsed.pcmShapeAnomalyCallbackCount, 1)
        XCTAssertEqual(parsed.pcmBoundaryDiscontinuityCallbackCount, 1)
        XCTAssertEqual(parsed.lastCallbackMeanMagnitude, 1_250)
        XCTAssertEqual(parsed.lastPeakMagnitude, 8_000)
        XCTAssertEqual(parsed.inboundAudioEnergy, 2.5)
        XCTAssertEqual(parsed.inboundSamplesDuration, 0.41)
        XCTAssertTrue(parsed.fullQualityInvariantsHold)
    }

    func testAudioEvaluatorAcceptsOnlyFreshFailureFreeFullQualityProgress() {
        let previous = audio(callbacks: 10, frames: 4_800, failures: 0)
        let current = audio(callbacks: 20, frames: 9_600, failures: 0)

        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(previous: previous, current: current),
            .advancing
        )
    }

    func testAudioEvaluatorRejectsOneShotOrStalledEvidence() {
        let oneShot = audio(callbacks: 1, frames: 480, failures: 0)
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(previous: oneShot, current: oneShot),
            .callbackCounterStalled
        )

        let callbackOnly = audio(callbacks: 2, frames: 480, failures: 0)
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: oneShot,
                current: callbackOnly
            ),
            .frameCounterStalled
        )
    }

    func testAudioEvaluatorRejectsFailureIncrementAndLostQuality() {
        let previous = audio(callbacks: 10, frames: 4_800, failures: 0)
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(callbacks: 20, frames: 9_600, failures: 1)
            ),
            .failureCounterChanged
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    fullQuality: false
                )
            ),
            .fullQualityMissing
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: audio(callbacks: 10, frames: 4_800, failures: 3),
                current: audio(callbacks: 20, frames: 9_600, failures: 3)
            ),
            .renderFailurePresent,
            "A failure before the observation window must not become an accepted baseline."
        )
    }

    func testAudioEvaluatorRejectsStructurallyImpossibleCounterSnapshots() {
        let previous = audio(callbacks: 10, frames: 4_800, failures: 0)
        let impossible: [(String, PhysicalAudioPlayoutSnapshot, PhysicalAudioPlayoutDelta)] = [
            (
                "nonzero exceeds samples",
                audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    pcmNonzero: 19_201
                ),
                .invalidPCMStructure
            ),
            (
                "channel sums disagree with total",
                audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    pcmLeftAbsolute: 15_000_000,
                    pcmRightAbsolute: 15_000_000
                ),
                .invalidPCMStructure
            ),
            (
                "stereo difference exceeds total magnitude",
                audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    pcmStereoDifferenceAbsolute: 30_000_000
                ),
                .invalidPCMStructure
            ),
            (
                "peak exceeds signed-16-bit magnitude",
                audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    peak: 32_769
                ),
                .invalidPCMStructure
            ),
            (
                "maximum callback gap is not reflected in its violation counter",
                audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    gapViolations: 0,
                    maximumGapNanoseconds: 300_000_000
                ),
                .invalidPCMStructure
            ),
            (
                "callback gap violation has no corresponding over-threshold gap",
                audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    gapViolations: 1,
                    maximumGapNanoseconds: 25_000_000
                ),
                .invalidPCMStructure
            ),
            (
                "inbound normalized energy exceeds duration",
                audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    inboundEnergy: 10,
                    inboundDuration: 0.2
                ),
                .invalidInboundStructure
            ),
        ]
        for (name, mutant, expected) in impossible {
            XCTAssertEqual(
                PhysicalAudioPlayoutEvaluator.evaluate(
                    previous: previous,
                    current: mutant
                ),
                expected,
                name
            )
        }
    }

    func testAudioEvaluatorRejectsSilentMonoClippedAndMissingInboundContent() {
        let previous = audio(callbacks: 10, frames: 4_800, failures: 0)
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    pcmNonzero: previous.pcmNonzeroSampleCount,
                    pcmAbsolute: previous.pcmAbsoluteSampleSum,
                    pcmLeftAbsolute: previous.pcmLeftAbsoluteSampleSum,
                    pcmRightAbsolute: previous.pcmRightAbsoluteSampleSum,
                    pcmStereoDifferenceAbsolute:
                        previous.pcmStereoDifferenceAbsoluteSampleSum,
                    peak: 0
                )
            ),
            .pcmContentStalled
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    pcmStereoDifferenceAbsolute:
                        previous.pcmStereoDifferenceAbsoluteSampleSum
                )
            ),
            .pcmContentStalled
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    clipped: 1
                )
            ),
            .clippedSamplesPresent
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    inboundEnergy: previous.inboundAudioEnergy,
                    inboundDuration: previous.inboundSamplesDuration
                )
            ),
            .inboundContentStalled
        )

        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    silenceCallbacks: 1
                )
            ),
            .explicitSilencePresent
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    gapViolations: 1,
                    maximumGapNanoseconds: 300_000_000
                )
            ),
            .callbackGapDetected
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    nearSilenceCallbacks: 1,
                    currentNearSilenceFrames: 480,
                    maximumNearSilenceFrames: 480
                )
            ),
            .nearSilenceDetected
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    recoveryRebuilds: 1
                )
            ),
            .audioUnitRebuilt
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    peak: 0
                )
            ),
            .peakMissing
        )
    }

    func testAudioEvaluatorRejectsPCMAndInboundCounterRegressionDirectly() {
        let previous = audio(callbacks: 10, frames: 4_800, failures: 0)
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    pcmAbsolute: previous.pcmAbsoluteSampleSum - 1
                )
            ),
            .pcmCounterRegressed
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    inboundEnergy: previous.inboundAudioEnergy - 0.001,
                    inboundDuration: previous.inboundSamplesDuration - 0.001
                )
            ),
            .inboundCounterRegressed
        )
    }

    func testAudioContinuityWindowRejectsLateSingleIncrementAndLowRealtimeCoverage() {
        let start: TimeInterval = 10_000
        var late = PhysicalAudioContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 2.5
        )
        XCTAssertEqual(
            late.observe(audio(callbacks: 10, frames: 4_800, failures: 0), at: start),
            .waiting
        )
        XCTAssertEqual(
            late.observe(
                audio(callbacks: 11, frames: 5_280, failures: 0),
                at: start + 2.1
            ),
            .waiting,
            "The first late increment starts the window; it must not complete it."
        )

        var burst = PhysicalAudioContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 2.5
        )
        _ = burst.observe(audio(callbacks: 10, frames: 4_800, failures: 0), at: start)
        _ = burst.observe(
            audio(callbacks: 20, frames: 9_600, failures: 0),
            at: start + 0.1
        )
        _ = burst.observe(
            audio(callbacks: 21, frames: 10_080, failures: 0),
            at: start + 1.1
        )
        XCTAssertEqual(
            burst.observe(
                audio(callbacks: 22, frames: 10_560, failures: 0),
                at: start + 2.2
            ),
            .waiting,
            "Sparse counter bumps cannot cover a real two-second 48 kHz interval."
        )
    }

    func testElapsedAudioOracleRejectsMostlySilentHalfStereoLowLevelAndOvercountedMutants() {
        let previous = audio(callbacks: 10, frames: 48_000, failures: 0)
        let healthy = audio(callbacks: 110, frames: 144_000, failures: 0)
        XCTAssertTrue(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: healthy,
                elapsed: 2
            )
        )

        let frameDelta: UInt64 = 96_000
        let sampleDelta = frameDelta * 2
        let previousSamples = previous.pcmSampleCount
        let previousNonzero = previous.pcmNonzeroSampleCount
        let previousAbsolute = previous.pcmAbsoluteSampleSum
        let previousLeft = previous.pcmLeftAbsoluteSampleSum
        let previousRight = previous.pcmRightAbsoluteSampleSum
        let previousStereoDifference = previous.pcmStereoDifferenceAbsoluteSampleSum
        let inboundEnergy = previous.inboundAudioEnergy + 0.5
        let inboundDuration = previous.inboundSamplesDuration + 2

        let mostlySilent = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            pcmSamples: previousSamples + sampleDelta,
            pcmNonzero: previousNonzero + sampleDelta / 10,
            pcmAbsolute: previousAbsolute + sampleDelta * 1_000,
            pcmLeftAbsolute: previousLeft + sampleDelta * 500,
            pcmRightAbsolute: previousRight + sampleDelta * 500,
            pcmStereoDifferenceAbsolute: previousStereoDifference + sampleDelta * 300,
            inboundEnergy: inboundEnergy,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: mostlySilent,
                elapsed: 2
            ),
            "Ten percent nonzero PCM must not prove continuous audible output."
        )

        let halfStereo = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            pcmSamples: previousSamples + sampleDelta,
            pcmNonzero: previousNonzero + sampleDelta,
            pcmAbsolute: previousAbsolute + sampleDelta * 1_000,
            pcmLeftAbsolute: previousLeft + sampleDelta * 990,
            pcmRightAbsolute: previousRight + sampleDelta * 10,
            pcmStereoDifferenceAbsolute: previousStereoDifference + sampleDelta * 400,
            inboundEnergy: inboundEnergy,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: halfStereo,
                elapsed: 2
            ),
            "A nearly missing channel must not satisfy the deterministic stereo-tone oracle."
        )

        let epsilonInboundEnergy = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            inboundEnergy: previous.inboundAudioEnergy + 0.000_001,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: epsilonInboundEnergy,
                elapsed: 2
            ),
            "A numerically positive but inaudible inbound-energy delta must not pass."
        )

        let swappedToneChannels = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            leftCrossings: previous.pcmLeftZeroCrossingCount + 2 * 12_502,
            rightCrossings: previous.pcmRightZeroCrossingCount + 2 * 9_000,
            inboundEnergy: inboundEnergy,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: swappedToneChannels,
                elapsed: 2
            ),
            "Per-channel tone frequencies must bind evidence to the generated source."
        )

        let frozenChallenge = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            envelopeTransitions: previous.pcmEnvelopeTransitionCount,
            inboundEnergy: inboundEnergy,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: frozenChallenge,
                elapsed: 2
            ),
            "Repeating one stationary callback must not satisfy the coded source challenge."
        )

        let rapidGainFlicker = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            envelopeTransitions: previous.pcmEnvelopeTransitionCount + 100,
            inboundEnergy: inboundEnergy,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: rapidGainFlicker,
                elapsed: 2
            ),
            "Alternating callback gain must fail the bounded envelope-transition rate."
        )

        let nearMono = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            pcmSamples: previousSamples + sampleDelta,
            pcmNonzero: previousNonzero + sampleDelta,
            pcmAbsolute: previousAbsolute + sampleDelta * 1_000,
            pcmLeftAbsolute: previousLeft + sampleDelta * 500,
            pcmRightAbsolute: previousRight + sampleDelta * 500,
            pcmStereoDifferenceAbsolute: previousStereoDifference + sampleDelta * 5,
            inboundEnergy: inboundEnergy,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: nearMono,
                elapsed: 2
            ),
            "Merely nonzero channel differences must not let near-mono output pass."
        )

        let lowLevelNoise = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            pcmSamples: previousSamples + sampleDelta,
            pcmNonzero: previousNonzero + sampleDelta,
            pcmAbsolute: previousAbsolute + sampleDelta * 2,
            pcmLeftAbsolute: previousLeft + sampleDelta,
            pcmRightAbsolute: previousRight + sampleDelta,
            pcmStereoDifferenceAbsolute: previousStereoDifference + sampleDelta,
            inboundEnergy: inboundEnergy,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: lowLevelNoise,
                elapsed: 2
            ),
            "Tiny nonzero noise must not stand in for the deterministic audible source."
        )

        let overcountedPCM = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            pcmSamples: previousSamples + sampleDelta * 2,
            pcmNonzero: previousNonzero + sampleDelta * 2,
            pcmAbsolute: previousAbsolute + sampleDelta * 2_000,
            pcmLeftAbsolute: previousLeft + sampleDelta * 1_000,
            pcmRightAbsolute: previousRight + sampleDelta * 1_000,
            pcmStereoDifferenceAbsolute: previousStereoDifference + sampleDelta * 600,
            inboundEnergy: inboundEnergy,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: overcountedPCM,
                elapsed: 2
            ),
            "Duplicated PCM accounting must not prove one rendered sample per stereo frame."
        )

        let flattenedIntervalWithHealthyEndpoint = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            shapeAnomalies: previous.pcmShapeAnomalyCallbackCount + 20,
            callbackMean: 5_100,
            peak: 8_000,
            inboundEnergy: inboundEnergy,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: flattenedIntervalWithHealthyEndpoint,
                elapsed: 2
            ),
            "One healthy final callback cannot erase flattened PCM earlier in the interval."
        )

        let phaseResetIntervalWithHealthyEndpoint = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            boundaryDiscontinuities:
                previous.pcmBoundaryDiscontinuityCallbackCount + 20,
            callbackMean: 5_100,
            peak: 8_000,
            inboundEnergy: inboundEnergy,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: phaseResetIntervalWithHealthyEndpoint,
                elapsed: 2
            ),
            "Repeated 10 ms phase resets cannot be hidden by a healthy final callback."
        )
    }

    func testAudioContinuityRejectsOneCorruptPublicationWithoutLaterDilution() {
        let start: TimeInterval = 50_000
        var tracker = PhysicalAudioContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 1.5
        )
        let baseline = audio(callbacks: 10, frames: 4_800, failures: 0)
        XCTAssertEqual(tracker.observe(baseline, at: start), .waiting)
        XCTAssertEqual(
            tracker.observe(
                audio(
                    callbacks: 110,
                    frames: 52_800,
                    failures: 0,
                    shapeAnomalies: 20,
                    boundaryDiscontinuities: 20
                ),
                at: start + 1
            ),
            .rejected,
            "A corrupt second cannot be diluted by later healthy callbacks in the proof window."
        )
    }

    func testCumulativeWaveformAnomalyRateHasAnExactThreePercentBoundary() {
        let previous = audio(callbacks: 10, frames: 48_000, failures: 0)
        XCTAssertTrue(
            PhysicalAudioPlayoutEvaluator.waveformAnomalyRatesAreAcceptable(
                previous: previous,
                current: audio(
                    callbacks: 110,
                    frames: 96_000,
                    failures: 0,
                    shapeAnomalies: 3,
                    boundaryDiscontinuities: 3
                )
            ),
            "The coded challenge's bounded transition callbacks must remain admissible."
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.waveformAnomalyRatesAreAcceptable(
                previous: previous,
                current: audio(
                    callbacks: 110,
                    frames: 96_000,
                    failures: 0,
                    shapeAnomalies: 4,
                    boundaryDiscontinuities: 3
                )
            )
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.waveformAnomalyRatesAreAcceptable(
                previous: previous,
                current: audio(
                    callbacks: 110,
                    frames: 96_000,
                    failures: 0,
                    shapeAnomalies: 3,
                    boundaryDiscontinuities: 4
                )
            )
        )
    }

    func testCallbackGapStructureBindsThe25MillisecondThreshold() {
        XCTAssertTrue(
            PhysicalAudioPlayoutEvaluator.hasValidStructure(
                audio(
                    callbacks: 10,
                    frames: 4_800,
                    failures: 0,
                    maximumGapNanoseconds: 25_000_000
                )
            ),
            "The exact permitted boundary is not a violation."
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.hasValidStructure(
                audio(
                    callbacks: 10,
                    frames: 4_800,
                    failures: 0,
                    maximumGapNanoseconds: 25_000_001
                )
            ),
            "An over-threshold native gap cannot claim zero violations."
        )
        XCTAssertTrue(
            PhysicalAudioPlayoutEvaluator.hasValidStructure(
                audio(
                    callbacks: 10,
                    frames: 4_800,
                    failures: 0,
                    gapViolations: 1,
                    maximumGapNanoseconds: 25_000_001
                )
            )
        )
    }

    func testElapsedAudioOracleRejectsImpossibleFrameAndInboundRates() {
        let previous = audio(callbacks: 10, frames: 48_000, failures: 0)
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: audio(callbacks: 210, frames: 248_000, failures: 0),
                elapsed: 2
            ),
            "A huge batched counter leap is not real-time continuity."
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: audio(
                    callbacks: 110,
                    frames: 144_000,
                    failures: 0,
                    inboundDuration: previous.inboundSamplesDuration + 8
                ),
                elapsed: 2
            ),
            "Inbound duration cannot advance four times faster than wall clock."
        )
    }

    func testElapsedAudioOracleRejectsBackgroundStopResumeAndShortFlicker() {
        let previous = audio(callbacks: 1_000, frames: 480_000, failures: 0)
        let elapsed: TimeInterval = 43
        let finalFrames = previous.frameCount + UInt64(elapsed * 48_000)
        let resumedAfterStall = audio(
            callbacks: 5_300,
            frames: finalFrames,
            failures: 0,
            gapViolations: previous.callbackGapViolationCount + 1,
            maximumGapNanoseconds: 15_000_000_000,
            inboundEnergy: previous.inboundAudioEnergy + elapsed * 0.25,
            inboundDuration: previous.inboundSamplesDuration + elapsed
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: resumedAfterStall,
                elapsed: elapsed,
                minimumRealtimeCoverage: 0.90
            ),
            "Catching counters up after a background stall must not erase the native gap."
        )

        let oneFlickeringCallback = audio(
            callbacks: 5_300,
            frames: finalFrames,
            failures: 0,
            nearSilenceCallbacks: previous.nearSilenceCallbackCount + 1,
            maximumNearSilenceFrames: 480,
            inboundEnergy: previous.inboundAudioEnergy + elapsed * 0.25,
            inboundDuration: previous.inboundSamplesDuration + elapsed
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: oneFlickeringCallback,
                elapsed: elapsed,
                minimumRealtimeCoverage: 0.90
            ),
            "A short near-silent callback must not disappear inside healthy aggregate ratios."
        )
    }

    func testElapsedAudioOracleRejectsMalformedDeltaHiddenByLargeHealthyHistory() {
        let previous = audio(
            callbacks: 1_000_000,
            frames: 480_000_000,
            failures: 0,
            pcmNonzero: 950_400_000
        )
        let frameDelta: UInt64 = 96_000
        let sampleDelta = frameDelta * 2
        let malformed = audio(
            callbacks: 1_000_200,
            frames: previous.frameCount + frameDelta,
            failures: 0,
            pcmSamples: previous.pcmSampleCount + sampleDelta,
            pcmNonzero: previous.pcmNonzeroSampleCount + sampleDelta + 1,
            pcmAbsolute: previous.pcmAbsoluteSampleSum + sampleDelta * 1_000,
            pcmLeftAbsolute: previous.pcmLeftAbsoluteSampleSum + sampleDelta * 900,
            pcmRightAbsolute: previous.pcmRightAbsoluteSampleSum + sampleDelta * 900,
            pcmStereoDifferenceAbsolute:
                previous.pcmStereoDifferenceAbsoluteSampleSum + sampleDelta * 600,
            inboundEnergy: previous.inboundAudioEnergy + 3,
            inboundDuration: previous.inboundSamplesDuration + 2
        )
        XCTAssertTrue(
            PhysicalAudioPlayoutEvaluator.hasValidStructure(malformed),
            "The large lifetime baseline intentionally masks the malformed interval."
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: malformed,
                elapsed: 2
            ),
            "Interval-local accounting must fail even when lifetime ratios look healthy."
        )
    }

    func testAudioContinuityWindowRequiresMultipleRealtimeContentAdvances() {
        let start: TimeInterval = 20_000
        var tracker = PhysicalAudioContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 1.5
        )
        XCTAssertEqual(
            tracker.observe(audio(callbacks: 10, frames: 4_800, failures: 0), at: start),
            .waiting
        )
        XCTAssertEqual(
            tracker.observe(
                audio(callbacks: 110, frames: 52_800, failures: 0),
                at: start + 1
            ),
            .waiting
        )
        XCTAssertEqual(
            tracker.observe(
                audio(callbacks: 210, frames: 100_800, failures: 0),
                at: start + 2
            ),
            .waiting
        )
        XCTAssertEqual(
            tracker.observe(
                audio(callbacks: 310, frames: 148_800, failures: 0),
                at: start + 3
            ),
            .satisfied,
            "The gate must accept the production one-second statistics publication cadence."
        )
    }

    func testAudioContinuityTrackerRejectsExpectedSessionAndResetsAfterProgressGap() {
        let start: TimeInterval = 40_000
        var wrongSession = PhysicalAudioContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 2.5,
            expectedSessionGeneration: UUID()
        )
        XCTAssertEqual(
            wrongSession.observe(
                audio(callbacks: 10, frames: 4_800, failures: 0),
                at: start
            ),
            .rejected
        )

        var gap = PhysicalAudioContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 1.5
        )
        XCTAssertEqual(
            gap.observe(audio(callbacks: 10, frames: 4_800, failures: 0), at: start),
            .waiting
        )
        XCTAssertEqual(
            gap.observe(
                audio(callbacks: 110, frames: 52_800, failures: 0),
                at: start + 1
            ),
            .waiting
        )
        XCTAssertEqual(
            gap.observe(
                audio(callbacks: 310, frames: 148_800, failures: 0),
                at: start + 3
            ),
            .waiting,
            "A gap beyond the monotonic progress budget must restart the evidence window."
        )
        XCTAssertEqual(
            gap.observe(
                audio(callbacks: 410, frames: 196_800, failures: 0),
                at: start + 4
            ),
            .waiting
        )
    }

    func testAudioEvaluatorRejectsCounterRegressionAndSessionReplacement() {
        let previous = audio(callbacks: 10, frames: 4_800, failures: 0)
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(callbacks: 9, frames: 5_280, failures: 0)
            ),
            .callbackCounterRegressed
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(callbacks: 11, frames: 4_700, failures: 0)
            ),
            .frameCounterRegressed
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    session: UUID(),
                    callbacks: 11,
                    frames: 5_280,
                    failures: 0
                )
            ),
            .sessionChanged
        )

        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    audioPolicy: UUID(),
                    callbacks: 11,
                    frames: 5_280,
                    failures: 0
                )
            ),
            .audioPolicyChanged
        )
    }

    func testHostedCallAccessibilityContractParsesStrictSerializationEquivalentInput() throws {
        let parsed = try XCTUnwrap(
            PhysicalHostedCallPlayoutSnapshot(
                accessibilityValue: hostedAccessibilityValue(seconds: 2)
            )
        )

        XCTAssertEqual(parsed.sessionGeneration, session)
        XCTAssertEqual(parsed.policyID, hostedPolicy)
        XCTAssertEqual(parsed.origin, .startupConnectedCall)
        XCTAssertEqual(parsed.audioPolicyGeneration, hostedAudioPolicy)
        XCTAssertEqual(parsed.systemAudioGeneration, 7)
        XCTAssertEqual(parsed.authorizationGeneration, 7)
        XCTAssertEqual(parsed.nativeAuthorizationGeneration, 7)
        XCTAssertEqual(parsed.callbackCount, 200)
        XCTAssertEqual(parsed.frameCount, 96_000)
        XCTAssertEqual(parsed.failureCount, 0)
        XCTAssertEqual(parsed.pcmNonzeroSampleCount, 182_400)
        XCTAssertEqual(parsed.pcmAbsoluteSampleSum, 182_400_000)
        XCTAssertEqual(parsed.unexpectedRecordingRequestCount, 0)
        XCTAssertEqual(parsed.inboundBytes, 192_000)
        XCTAssertEqual(parsed.inboundPackets, 100)
        XCTAssertEqual(parsed.inboundJitterBufferEmittedCount, 96_000)
        XCTAssertEqual(parsed.inboundTotalSamplesReceived, 96_000)
        XCTAssertEqual(parsed.inboundAudioEnergy, 0.5)
        XCTAssertEqual(parsed.inboundSamplesDuration, 2)
        XCTAssertTrue(parsed.outputBusEnabled)
        XCTAssertFalse(parsed.inputBusEnabled)
        XCTAssertTrue(parsed.categoryIsMediaPlayback)
        XCTAssertTrue(parsed.modeIsDefault)
        XCTAssertTrue(parsed.categoryOptionsAreMixWithOthers)
        XCTAssertTrue(parsed.remoteIOCreated)
        XCTAssertTrue(parsed.audioUnitIsRemoteIO)
        XCTAssertTrue(parsed.activeSessionOwnership)
        XCTAssertTrue(parsed.hostedCallMode)
        XCTAssertTrue(parsed.authorizationIsValid)
        XCTAssertTrue(parsed.authorizationIsConsumed)
        XCTAssertTrue(parsed.nativeAuthorizationIsValid)
        XCTAssertTrue(parsed.nativeAuthorizationIsConsumed)
        XCTAssertTrue(parsed.authorizationPolicyMatches)
        XCTAssertTrue(parsed.authorizationGenerationMatches)
        XCTAssertTrue(parsed.connectedCallKitSnapshot)
        XCTAssertTrue(PhysicalHostedCallPlayoutEvaluator.hasValidStructure(parsed))
    }

    func testHostedCallParserRejectsExactKeySetAndMalformedScalarValues() {
        let valid = hostedAccessibilityValue(seconds: 2)
        let components = valid.split(separator: "|", omittingEmptySubsequences: false)
        XCTAssertEqual(
            components.map { String($0.split(separator: "=", maxSplits: 1)[0]) },
            hostedKeyOrder
        )

        for key in hostedKeyOrder {
            let missing = components
                .filter { !$0.hasPrefix("\(key)=") }
                .joined(separator: "|")
            XCTAssertNil(
                PhysicalHostedCallPlayoutSnapshot(accessibilityValue: missing),
                "Missing \(key) must be rejected."
            )
        }
        for component in components {
            XCTAssertNil(
                PhysicalHostedCallPlayoutSnapshot(
                    accessibilityValue: valid + "|\(component)"
                ),
                "Duplicate \(component) must be rejected."
            )
        }
        XCTAssertNil(
            PhysicalHostedCallPlayoutSnapshot(accessibilityValue: valid + "|extra=1")
        )
        XCTAssertNil(
            PhysicalHostedCallPlayoutSnapshot(accessibilityValue: valid + "|broken")
        )
        for invalidVersion in ["1", "3"] {
            XCTAssertNil(
                PhysicalHostedCallPlayoutSnapshot(
                    accessibilityValue: hostedAccessibilityValue(
                        seconds: 2,
                        overrides: ["v": invalidVersion]
                    )
                )
            )
        }
        for invalidOrigin in ["", "unspecified", "startup", "unknown"] {
            XCTAssertNil(
                PhysicalHostedCallPlayoutSnapshot(
                    accessibilityValue: hostedAccessibilityValue(
                        seconds: 2,
                        overrides: ["origin": invalidOrigin]
                    )
                ),
                "Invalid hosted origin \(invalidOrigin) must be rejected."
            )
        }

        for key in ["session", "policy", "audioPolicy"] {
            XCTAssertNil(
                PhysicalHostedCallPlayoutSnapshot(
                    accessibilityValue: hostedAccessibilityValue(
                        seconds: 2,
                        overrides: [key: "not-a-uuid"]
                    )
                ),
                key
            )
        }
        XCTAssertNil(
            PhysicalHostedCallPlayoutSnapshot(
                accessibilityValue: hostedAccessibilityValue(
                    seconds: 2,
                    overrides: ["session": session.uuidString.uppercased()]
                )
            )
        )

        for key in hostedNumericKeys {
            XCTAssertNil(
                PhysicalHostedCallPlayoutSnapshot(
                    accessibilityValue: hostedAccessibilityValue(
                        seconds: 2,
                        overrides: [key: "-1"]
                    )
                ),
                "Negative \(key) must be rejected."
            )
        }
        for key in [
            "systemAudioGeneration", "authorizationGeneration",
            "nativeAuthorizationGeneration",
        ] {
            XCTAssertNil(
                PhysicalHostedCallPlayoutSnapshot(
                    accessibilityValue: hostedAccessibilityValue(
                        seconds: 2,
                        overrides: [key: "0"]
                    )
                ),
                "Zero \(key) must be rejected."
            )
        }
        for key in hostedInboundMetricKeys {
            XCTAssertNil(
                PhysicalHostedCallPlayoutSnapshot(
                    accessibilityValue: hostedAccessibilityValue(
                        seconds: 2,
                        overrides: [key: "missing"]
                    )
                ),
                "Missing inbound field \(key) is not physical proof."
            )
        }
        for key in ["inboundEnergy", "inboundDuration"] {
            for value in ["nan", "inf", "-inf"] {
                XCTAssertNil(
                    PhysicalHostedCallPlayoutSnapshot(
                        accessibilityValue: hostedAccessibilityValue(
                            seconds: 2,
                            overrides: [key: value]
                        )
                    ),
                    "\(key)=\(value)"
                )
            }
        }
        for key in hostedBooleanKeys {
            XCTAssertNil(
                PhysicalHostedCallPlayoutSnapshot(
                    accessibilityValue: hostedAccessibilityValue(
                        seconds: 2,
                        overrides: [key: "2"]
                    )
                ),
                "Invalid Boolean \(key) must be rejected."
            )
        }
        XCTAssertNil(
            PhysicalHostedCallPlayoutSnapshot(
                accessibilityValue: hostedAccessibilityValue(
                    seconds: 2,
                    overrides: ["callbacks": "0200"]
                )
            )
        )
        XCTAssertNil(
            PhysicalHostedCallPlayoutSnapshot(
                accessibilityValue: hostedAccessibilityValue(
                    seconds: 2,
                    overrides: ["inboundEnergy": "0.500"]
                )
            )
        )
    }

    func testHostedCallEvaluatorAcceptsStableAdvancingEvidence() {
        let previous = hosted(seconds: 2)
        let current = hosted(seconds: 3)

        XCTAssertEqual(
            PhysicalHostedCallPlayoutEvaluator.evaluate(
                previous: previous,
                current: current
            ),
            .advancing
        )
        XCTAssertTrue(
            PhysicalHostedCallPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: current,
                elapsed: 1
            )
        )
    }

    func testHostedCallEvaluatorRejectsEveryFalseHostedInvariant() {
        let previous = hosted(seconds: 2)
        for key in hostedTrueInvariantKeys {
            let mutant = hosted(seconds: 3, overrides: [key: "0"])
            XCTAssertFalse(
                PhysicalHostedCallPlayoutEvaluator.hasValidStructure(mutant),
                key
            )
            XCTAssertEqual(
                PhysicalHostedCallPlayoutEvaluator.evaluate(
                    previous: previous,
                    current: mutant
                ),
                .hostedInvariantMissing,
                key
            )
        }

        let inputEnabled = hosted(seconds: 3, overrides: ["input": "1"])
        XCTAssertFalse(PhysicalHostedCallPlayoutEvaluator.hasValidStructure(inputEnabled))
        XCTAssertEqual(
            PhysicalHostedCallPlayoutEvaluator.evaluate(
                previous: previous,
                current: inputEnabled
            ),
            .hostedInvariantMissing
        )
    }

    func testHostedCallEvaluatorRejectsIdentityAndGenerationOwnershipChanges() {
        let previous = hosted(seconds: 2)
        let identityMutants: [
            (String, [String: String], PhysicalHostedCallPlayoutDelta)
        ] = [
            ("session", ["session": UUID().uuidString.lowercased()], .sessionChanged),
            ("policy", ["policy": UUID().uuidString.lowercased()], .policyChanged),
            ("origin", ["origin": "interruption"], .originChanged),
            (
                "audio policy",
                ["audioPolicy": UUID().uuidString.lowercased()],
                .audioPolicyChanged
            ),
            (
                "generation",
                [
                    "systemAudioGeneration": "8",
                    "authorizationGeneration": "8",
                    "nativeAuthorizationGeneration": "8",
                ],
                .generationChanged
            ),
        ]
        for (name, overrides, expected) in identityMutants {
            XCTAssertEqual(
                PhysicalHostedCallPlayoutEvaluator.evaluate(
                    previous: previous,
                    current: hosted(seconds: 3, overrides: overrides)
                ),
                expected,
                name
            )
        }

        let splitOwnership = hosted(
            seconds: 3,
            overrides: ["nativeAuthorizationGeneration": "8"]
        )
        XCTAssertFalse(
            PhysicalHostedCallPlayoutEvaluator.hasValidStructure(splitOwnership)
        )
        XCTAssertEqual(
            PhysicalHostedCallPlayoutEvaluator.evaluate(
                previous: previous,
                current: splitOwnership
            ),
            .invalidStructure
        )

        let structurallyImpossible: [[String: String]] = [
            ["pcmNonzero": "288001"],
            ["pcmAbs": "1"],
            ["inboundEnergy": "4.0", "inboundDuration": "1.0"],
        ]
        for overrides in structurallyImpossible {
            let mutant = hosted(seconds: 3, overrides: overrides)
            XCTAssertFalse(
                PhysicalHostedCallPlayoutEvaluator.hasValidStructure(mutant)
            )
            XCTAssertEqual(
                PhysicalHostedCallPlayoutEvaluator.evaluate(
                    previous: previous,
                    current: mutant
                ),
                .invalidStructure
            )
        }
    }

    func testHostedCallEvaluatorRejectsFailureAndRecordingRequestEvidence() {
        let cleanPrevious = hosted(seconds: 2)
        XCTAssertEqual(
            PhysicalHostedCallPlayoutEvaluator.evaluate(
                previous: cleanPrevious,
                current: hosted(seconds: 3, overrides: ["failures": "1"])
            ),
            .failureCounterChanged
        )
        XCTAssertEqual(
            PhysicalHostedCallPlayoutEvaluator.evaluate(
                previous: hosted(seconds: 2, overrides: ["failures": "1"]),
                current: hosted(seconds: 3, overrides: ["failures": "1"])
            ),
            .renderFailurePresent
        )
        XCTAssertEqual(
            PhysicalHostedCallPlayoutEvaluator.evaluate(
                previous: hosted(seconds: 2, overrides: ["failures": "1"]),
                current: hosted(seconds: 3)
            ),
            .failureCounterRegressed
        )
        XCTAssertEqual(
            PhysicalHostedCallPlayoutEvaluator.evaluate(
                previous: cleanPrevious,
                current: hosted(seconds: 3, overrides: ["recordRequests": "1"])
            ),
            .recordingRequestCounterChanged
        )
        XCTAssertEqual(
            PhysicalHostedCallPlayoutEvaluator.evaluate(
                previous: hosted(seconds: 2, overrides: ["recordRequests": "1"]),
                current: hosted(seconds: 3, overrides: ["recordRequests": "1"])
            ),
            .recordingRequestPresent
        )
        XCTAssertEqual(
            PhysicalHostedCallPlayoutEvaluator.evaluate(
                previous: hosted(seconds: 2, overrides: ["recordRequests": "1"]),
                current: hosted(seconds: 3)
            ),
            .recordingRequestCounterRegressed
        )
    }

    func testHostedCallEvaluatorRejectsEveryRegressionAndStall() {
        let previous = hosted(seconds: 2)
        let frameRegressionOverrides = [
            "frames": String(previous.frameCount - 1),
            "pcmNonzero": String(previous.pcmNonzeroSampleCount + 1),
            "pcmAbs": String(previous.pcmAbsoluteSampleSum + 1_000),
        ]
        let regressions: [
            (String, [String: String], PhysicalHostedCallPlayoutDelta)
        ] = [
            (
                "callbacks",
                ["callbacks": String(previous.callbackCount - 1)],
                .callbackCounterRegressed
            ),
            ("frames", frameRegressionOverrides, .frameCounterRegressed),
            (
                "pcm nonzero",
                ["pcmNonzero": String(previous.pcmNonzeroSampleCount - 1)],
                .pcmCounterRegressed
            ),
            (
                "pcm absolute",
                ["pcmAbs": String(previous.pcmAbsoluteSampleSum - 1)],
                .pcmCounterRegressed
            ),
            (
                "inbound bytes",
                ["inboundBytes": String(previous.inboundBytes - 1)],
                .inboundCounterRegressed
            ),
            (
                "inbound packets",
                ["inboundPackets": String(previous.inboundPackets - 1)],
                .inboundCounterRegressed
            ),
            (
                "jitter emitted",
                [
                    "inboundJitterEmitted":
                        String(previous.inboundJitterBufferEmittedCount - 1),
                ],
                .inboundCounterRegressed
            ),
            (
                "inbound samples",
                [
                    "inboundSamples":
                        String(previous.inboundTotalSamplesReceived - 1),
                ],
                .inboundCounterRegressed
            ),
            (
                "inbound energy",
                ["inboundEnergy": String(previous.inboundAudioEnergy - 0.01)],
                .inboundCounterRegressed
            ),
            (
                "inbound duration",
                ["inboundDuration": String(previous.inboundSamplesDuration - 0.01)],
                .inboundCounterRegressed
            ),
        ]
        for (name, overrides, expected) in regressions {
            XCTAssertEqual(
                PhysicalHostedCallPlayoutEvaluator.evaluate(
                    previous: previous,
                    current: hosted(seconds: 3, overrides: overrides)
                ),
                expected,
                name
            )
        }

        let frameStallOverrides = [
            "frames": String(previous.frameCount),
            "pcmNonzero": String(previous.pcmNonzeroSampleCount + 1),
            "pcmAbs": String(previous.pcmAbsoluteSampleSum + 1_000),
        ]
        let stalls: [
            (String, [String: String], PhysicalHostedCallPlayoutDelta)
        ] = [
            (
                "callbacks",
                ["callbacks": String(previous.callbackCount)],
                .callbackCounterStalled
            ),
            ("frames", frameStallOverrides, .frameCounterStalled),
            (
                "pcm nonzero",
                ["pcmNonzero": String(previous.pcmNonzeroSampleCount)],
                .pcmContentStalled
            ),
            (
                "pcm absolute",
                ["pcmAbs": String(previous.pcmAbsoluteSampleSum)],
                .pcmContentStalled
            ),
            (
                "inbound bytes",
                ["inboundBytes": String(previous.inboundBytes)],
                .inboundContentStalled
            ),
            (
                "inbound packets",
                ["inboundPackets": String(previous.inboundPackets)],
                .inboundContentStalled
            ),
            (
                "jitter emitted",
                [
                    "inboundJitterEmitted":
                        String(previous.inboundJitterBufferEmittedCount),
                ],
                .inboundContentStalled
            ),
            (
                "inbound samples",
                [
                    "inboundSamples": String(previous.inboundTotalSamplesReceived),
                ],
                .inboundContentStalled
            ),
            (
                "inbound energy",
                ["inboundEnergy": String(previous.inboundAudioEnergy)],
                .inboundContentStalled
            ),
            (
                "inbound duration",
                ["inboundDuration": String(previous.inboundSamplesDuration)],
                .inboundContentStalled
            ),
        ]
        for (name, overrides, expected) in stalls {
            XCTAssertEqual(
                PhysicalHostedCallPlayoutEvaluator.evaluate(
                    previous: previous,
                    current: hosted(seconds: 3, overrides: overrides)
                ),
                expected,
                name
            )
        }
    }

    func testHostedCallElapsedCoverageRejectsInvalidAndImplausibleIntervals() {
        let previous = hosted(seconds: 2)
        let current = hosted(seconds: 3)
        XCTAssertTrue(
            PhysicalHostedCallPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: current,
                elapsed: 1
            )
        )
        for elapsed in [0, -1, Double.nan, Double.infinity] {
            XCTAssertFalse(
                PhysicalHostedCallPlayoutEvaluator.coversElapsedInterval(
                    previous: previous,
                    current: current,
                    elapsed: elapsed
                )
            )
        }

        let sparse = hosted(
            seconds: 3,
            overrides: [
                "callbacks": String(previous.callbackCount + 1),
                "frames": String(previous.frameCount + 10),
                "pcmNonzero": String(previous.pcmNonzeroSampleCount + 20),
                "pcmAbs": String(previous.pcmAbsoluteSampleSum + 20_000),
                "inboundBytes": String(previous.inboundBytes + 100),
                "inboundPackets": String(previous.inboundPackets + 1),
                "inboundJitterEmitted":
                    String(previous.inboundJitterBufferEmittedCount + 10),
                "inboundSamples":
                    String(previous.inboundTotalSamplesReceived + 10),
                "inboundEnergy": String(previous.inboundAudioEnergy + 0.001),
                "inboundDuration": String(previous.inboundSamplesDuration + 0.01),
            ]
        )
        XCTAssertEqual(
            PhysicalHostedCallPlayoutEvaluator.evaluate(
                previous: previous,
                current: sparse
            ),
            .advancing
        )
        XCTAssertFalse(
            PhysicalHostedCallPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: sparse,
                elapsed: 1
            )
        )
        XCTAssertFalse(
            PhysicalHostedCallPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: current,
                elapsed: 0.1
            )
        )

        let lowPCM = hosted(
            seconds: 3,
            overrides: [
                "pcmNonzero": String(previous.pcmNonzeroSampleCount + 100),
                "pcmAbs": String(previous.pcmAbsoluteSampleSum + 100_000),
            ]
        )
        XCTAssertFalse(
            PhysicalHostedCallPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: lowPCM,
                elapsed: 1
            )
        )
        XCTAssertFalse(
            PhysicalHostedCallPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: hosted(
                    seconds: 3,
                    overrides: [
                        "inboundSamples":
                            String(previous.inboundTotalSamplesReceived + 1),
                    ]
                ),
                elapsed: 1
            )
        )
        XCTAssertFalse(
            PhysicalHostedCallPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: hosted(
                    seconds: 3,
                    overrides: [
                        "inboundEnergy":
                            String(previous.inboundAudioEnergy + 0.001),
                        "inboundDuration":
                            String(previous.inboundSamplesDuration + 0.01),
                    ]
                ),
                elapsed: 1
            )
        )
    }

    func testHostedCallContinuityTrackerWaitsSatisfiesRejectsAndResets() {
        let start: TimeInterval = 60_000
        var healthy = PhysicalHostedCallPlayoutContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 1.5,
            expectedOrigin: .startupConnectedCall
        )
        XCTAssertEqual(healthy.observe(hosted(seconds: 1), at: start), .waiting)
        XCTAssertEqual(
            healthy.observe(hosted(seconds: 2), at: start + 1),
            .waiting
        )
        XCTAssertEqual(
            healthy.observe(hosted(seconds: 3), at: start + 2),
            .waiting
        )
        XCTAssertEqual(
            healthy.observe(hosted(seconds: 4), at: start + 3),
            .satisfied
        )

        var rejected = PhysicalHostedCallPlayoutContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 1.5,
            expectedPolicyID: UUID(),
            expectedOrigin: .startupConnectedCall
        )
        XCTAssertEqual(
            rejected.observe(hosted(seconds: 1), at: start),
            .rejected
        )

        var wrongOrigin = PhysicalHostedCallPlayoutContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 1.5,
            expectedOrigin: .interruption
        )
        XCTAssertEqual(
            wrongOrigin.observe(hosted(seconds: 1), at: start),
            .rejected
        )

        var reset = PhysicalHostedCallPlayoutContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 1.5
        )
        XCTAssertEqual(reset.observe(hosted(seconds: 1), at: start), .waiting)
        XCTAssertEqual(
            reset.observe(hosted(seconds: 2), at: start + 1),
            .waiting
        )
        XCTAssertEqual(
            reset.observe(hosted(seconds: 2), at: start + 2.6),
            .waiting,
            "A publication gap must clear the in-progress continuity window."
        )
        XCTAssertEqual(
            reset.observe(hosted(seconds: 3), at: start + 3.6),
            .waiting
        )
        XCTAssertEqual(
            reset.observe(hosted(seconds: 4), at: start + 4.6),
            .waiting
        )
        XCTAssertEqual(
            reset.observe(hosted(seconds: 5), at: start + 5.6),
            .satisfied
        )
    }

    func testHostedCallContinuityTrackerRejectsBadPublicationAndLowCoverage() {
        let start: TimeInterval = 70_000
        var invalid = PhysicalHostedCallPlayoutContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 1.5
        )
        XCTAssertEqual(invalid.observe(hosted(seconds: 1), at: start), .waiting)
        XCTAssertEqual(
            invalid.observe(
                hosted(seconds: 2, overrides: ["output": "0"]),
                at: start + 1
            ),
            .rejected
        )

        let baseline = hosted(seconds: 2)
        func sparse(_ step: UInt64) -> PhysicalHostedCallPlayoutSnapshot {
            hosted(
                seconds: 3,
                overrides: [
                    "callbacks": String(baseline.callbackCount + step),
                    "frames": String(baseline.frameCount + step * 10),
                    "pcmNonzero":
                        String(baseline.pcmNonzeroSampleCount + step * 20),
                    "pcmAbs":
                        String(baseline.pcmAbsoluteSampleSum + step * 20_000),
                    "inboundBytes": String(baseline.inboundBytes + step * 100),
                    "inboundPackets": String(baseline.inboundPackets + step),
                    "inboundJitterEmitted":
                        String(baseline.inboundJitterBufferEmittedCount + step * 10),
                    "inboundSamples":
                        String(baseline.inboundTotalSamplesReceived + step * 10),
                    "inboundEnergy":
                        String(baseline.inboundAudioEnergy + Double(step) * 0.001),
                    "inboundDuration":
                        String(baseline.inboundSamplesDuration + Double(step) * 0.01),
                ]
            )
        }

        var lowCoverage = PhysicalHostedCallPlayoutContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 1.5
        )
        XCTAssertEqual(lowCoverage.observe(baseline, at: start), .waiting)
        XCTAssertEqual(lowCoverage.observe(sparse(1), at: start + 1), .waiting)
        XCTAssertEqual(lowCoverage.observe(sparse(2), at: start + 2), .waiting)
        XCTAssertEqual(
            lowCoverage.observe(sparse(3), at: start + 3),
            .waiting,
            "Strict advancement without real-time 48 kHz coverage is not continuity."
        )
    }

    func testProductionVideoAccessibilityContractRoundTrips() throws {
        let production = WorldwideVideoRenderOracleSnapshot(
            rendererID: renderer,
            frameCount: 12,
            timestampNanoseconds: 900_000_000,
            width: 1_920,
            height: 1_080,
            contentDigest: 0x1234,
            contentSampleCount: 4,
            contentChangeCount: 3
        )

        let parsed = try XCTUnwrap(
            PhysicalVideoRenderSnapshot(
                accessibilityValue: production.accessibilityValue
            )
        )
        XCTAssertEqual(parsed.rendererID, renderer)
        XCTAssertEqual(parsed.frameCount, 12)
        XCTAssertEqual(parsed.timestampNanoseconds, 900_000_000)
        XCTAssertEqual(parsed.width, 1_920)
        XCTAssertEqual(parsed.height, 1_080)
        XCTAssertEqual(parsed.contentDigest, 0x1234)
        XCTAssertEqual(parsed.contentSampleCount, 4)
        XCTAssertEqual(parsed.contentChangeCount, 3)
    }

    func testVideoEvaluatorRequiresNewDecodedFramesAndTimestamps() {
        let previous = video(frames: 10, timestamp: 1_000)
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(frames: 11, timestamp: 2_000)
            ),
            .advancing
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(previous: previous, current: previous),
            .frameCounterStalled
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(frames: 11, timestamp: 1_000)
            ),
            .timestampStalled
        )
    }

    func testVideoEvaluatorDistinguishesChangingPixelsFromFreshFrozenFrames() {
        let previous = video(
            frames: 10,
            timestamp: 1_000,
            contentDigest: 111,
            contentSamples: 10,
            contentChanges: 9
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(
                    frames: 11,
                    timestamp: 2_000,
                    contentDigest: 222,
                    contentSamples: 11,
                    contentChanges: 10
                )
            ),
            .advancing,
            "A genuinely distinct decoded frame must advance the pixel oracle."
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(
                    frames: 11,
                    timestamp: 2_000,
                    contentDigest: 111,
                    contentSamples: 11,
                    contentChanges: 9
                )
            ),
            .contentUnchanged,
            "Fresh RTP timestamps over identical decoded pixels must not count as fresh content."
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(
                    frames: 11,
                    timestamp: 2_000,
                    contentDigest: 222,
                    contentSamples: 11,
                    contentChanges: 9
                )
            ),
            .contentDigestChangeUnaccounted
        )
    }

    func testDecodedPixelDigestIsStableForIdenticalPixelsAndChangesWithContent() throws {
        func pixelBuffer(filledWith byte: UInt8) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(
                CVPixelBufferCreate(
                    kCFAllocatorDefault,
                    64,
                    64,
                    kCVPixelFormatType_32BGRA,
                    nil,
                    &buffer
                ),
                kCVReturnSuccess
            )
            let unwrapped = try XCTUnwrap(buffer)
            XCTAssertEqual(CVPixelBufferLockBaseAddress(unwrapped, []), kCVReturnSuccess)
            defer { CVPixelBufferUnlockBaseAddress(unwrapped, []) }
            memset(
                CVPixelBufferGetBaseAddress(unwrapped),
                Int32(byte),
                CVPixelBufferGetDataSize(unwrapped)
            )
            return unwrapped
        }

        let blackA = try pixelBuffer(filledWith: 0)
        let blackB = try pixelBuffer(filledWith: 0)
        let white = try pixelBuffer(filledWith: 255)
        let salt: UInt64 = 0x55aa
        let blackDigest = WebRTCDecodedPixelDigest.digest(pixelBuffer: blackA, salt: salt)
        XCTAssertEqual(
            blackDigest,
            WebRTCDecodedPixelDigest.digest(pixelBuffer: blackB, salt: salt)
        )
        XCTAssertNotEqual(
            blackDigest,
            WebRTCDecodedPixelDigest.digest(pixelBuffer: white, salt: salt)
        )
        XCTAssertNotEqual(
            blackDigest,
            WebRTCDecodedPixelDigest.digest(pixelBuffer: blackA, salt: salt + 1),
            "Renderer-local salt must prevent a stable cross-session screen fingerprint."
        )
    }

    func testVideoContinuityNeverAcceptsFrozenPixelsWithAdvancingFrameMetadata() {
        let start: TimeInterval = 50_000
        var frozen = PhysicalVideoContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 2.5
        )
        for second in 0...4 {
            let result = frozen.observe(
                video(
                    frames: UInt64(10 + second * 15),
                    timestamp: Int64(second) * 1_000_000_000 + 1,
                    contentDigest: 777,
                    contentSamples: UInt64(10 + second * 15),
                    contentChanges: 9
                ),
                at: start + Double(second)
            )
            XCTAssertNotEqual(result, .satisfied)
        }
    }

    func testVideoEvaluatorRejectsImpossiblePixelEvidenceCounters() {
        let previous = video(
            frames: 20,
            timestamp: 1_000,
            contentDigest: 1,
            contentSamples: 10,
            contentChanges: 8
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(
                    frames: 21,
                    timestamp: 2_000,
                    contentDigest: 2,
                    contentSamples: 9,
                    contentChanges: 8
                )
            ),
            .contentSampleCounterRegressed
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(
                    frames: 21,
                    timestamp: 2_000,
                    contentDigest: 1,
                    contentSamples: 10,
                    contentChanges: 8
                )
            ),
            .contentSampleCounterStalled
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(
                    frames: 21,
                    timestamp: 2_000,
                    contentDigest: 2,
                    contentSamples: 11,
                    contentChanges: 7
                )
            ),
            .contentChangeCounterRegressed
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(
                    frames: 21,
                    timestamp: 2_000,
                    contentDigest: 1,
                    contentSamples: 11,
                    contentChanges: 9
                )
            ),
            .contentChangeCounterImpossible,
            "Equal endpoint digests cannot be explained by exactly one sampled change."
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(
                    frames: 21,
                    timestamp: 2_000,
                    contentDigest: 2,
                    contentSamples: 22,
                    contentChanges: 9
                )
            ),
            .invalidContentEvidence
        )
    }

    func testVideoEvaluatorRejectsRegressionsInvalidFramesAndRendererReplacement() {
        let previous = video(frames: 10, timestamp: 1_000)
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(frames: 9, timestamp: 2_000)
            ),
            .frameCounterRegressed
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(frames: 11, timestamp: 999)
            ),
            .timestampRegressed
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(frames: 11, timestamp: 2_000, width: 1)
            ),
            .invalidDimensions
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(frames: 11, timestamp: 2_000, width: 1_280)
            ),
            .dimensionsChanged
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(
                    renderer: UUID(),
                    frames: 11,
                    timestamp: 2_000
                )
            ),
            .rendererChanged
        )
    }

    func testVideoContinuityWindowRejectsLateSingleFrameAndRequiresCadence() {
        let start: TimeInterval = 30_000
        var late = PhysicalVideoContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 2.5
        )
        XCTAssertEqual(late.observe(video(frames: 10, timestamp: 1_000), at: start), .waiting)
        XCTAssertEqual(
            late.observe(
                video(frames: 11, timestamp: 2_100_000_000),
                at: start + 2.1
            ),
            .waiting
        )

        var healthy = PhysicalVideoContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 2.5
        )
        _ = healthy.observe(video(frames: 10, timestamp: 1_000), at: start)
        _ = healthy.observe(
            video(frames: 25, timestamp: 1_000_001_000),
            at: start + 1
        )
        _ = healthy.observe(
            video(frames: 40, timestamp: 2_000_001_000),
            at: start + 2
        )
        XCTAssertEqual(
            healthy.observe(
                video(frames: 55, timestamp: 3_000_001_000),
                at: start + 3
            ),
            .satisfied
        )

        XCTAssertFalse(
            PhysicalVideoRenderEvaluator.coversElapsedInterval(
                previous: video(frames: 10, timestamp: 1_000),
                current: video(frames: 1_010, timestamp: 2_000_001_000),
                elapsed: 2
            ),
            "An impossible frame-count leap must not stand in for continuous rendering."
        )
        XCTAssertFalse(
            PhysicalVideoRenderEvaluator.coversElapsedInterval(
                previous: video(frames: 10, timestamp: 1_000),
                current: video(frames: 40, timestamp: 20_000_001_000),
                elapsed: 2
            ),
            "A corrupt RTP timestamp leap must not stand in for elapsed continuity."
        )
        XCTAssertFalse(
            PhysicalVideoRenderEvaluator.coversElapsedInterval(
                previous: video(frames: 10, timestamp: 1_000),
                current: video(
                    frames: 18,
                    timestamp: 2_000_001_000,
                    contentSamples: 18,
                    contentChanges: 7
                ),
                elapsed: 2
            ),
            "A four-frame-per-second slideshow is not acceptable screen streaming."
        )
        XCTAssertFalse(
            PhysicalVideoRenderEvaluator.coversElapsedInterval(
                previous: video(
                    frames: 10,
                    timestamp: 1_000,
                    contentSamples: 10,
                    contentChanges: 9
                ),
                current: video(
                    frames: 130,
                    timestamp: 2_000_001_000,
                    contentSamples: 14,
                    contentChanges: 12
                ),
                elapsed: 2
            ),
            "Sixty decoded frames per second cannot hide pixels changing like a slideshow."
        )
    }

    func testProductionScreenAcknowledgementAccessibilityContractRoundTrips() throws {
        let production = WorldwideScreenAcknowledgementOracleSnapshot(
            sessionGeneration: session,
            requestID: 91,
            command: .hide,
            state: .inactive
        )

        let parsed = try XCTUnwrap(
            PhysicalScreenAcknowledgementSnapshot(
                accessibilityValue: production.accessibilityValue
            )
        )
        XCTAssertEqual(parsed.sessionGeneration, session)
        XCTAssertEqual(parsed.requestID, 91)
        XCTAssertEqual(parsed.command, .hide)
        XCTAssertEqual(parsed.state, .inactive)
    }

    func testAccessibilityParsersRejectMissingDuplicateAndUnknownFields() {
        XCTAssertNil(PhysicalAudioPlayoutSnapshot(accessibilityValue: "v=2"))
        XCTAssertNil(
            PhysicalAudioPlayoutSnapshot(
                accessibilityValue: "v=2|session=\(session)|audioPolicy=\(ordinaryAudioPolicy)|callbacks=1|callbacks=2|frames=480|failures=0|fullQuality=1"
            )
        )
        XCTAssertNil(
            PhysicalVideoRenderSnapshot(
                accessibilityValue: "v=1|renderer=\(renderer)|frames=1|timestampNs=1|width=10|height=10|pixels=secret"
            )
        )
        XCTAssertNil(
            PhysicalScreenAcknowledgementSnapshot(
                accessibilityValue: "v=1|session=\(session)|request=1|command=show|state=unknown"
            )
        )
    }

    // MARK: - Valid snapshot fixtures

    private var hostedKeyOrder: [String] {
        [
            "v", "origin", "session", "policy", "audioPolicy",
            "systemAudioGeneration", "authorizationGeneration",
            "nativeAuthorizationGeneration", "callbacks", "frames", "failures",
            "pcmNonzero", "pcmAbs", "recordRequests", "inboundBytes",
            "inboundPackets", "inboundJitterEmitted", "inboundSamples",
            "inboundEnergy", "inboundDuration", "output", "input", "playback",
            "defaultMode", "mixWithOthers", "remoteIOCreated", "remoteIOSubtype",
            "activeOwnership", "hostedMode", "authorizationValid",
            "authorizationConsumed", "nativeAuthorizationValid",
            "nativeAuthorizationConsumed", "authorizationPolicyMatches",
            "authorizationGenerationMatches", "callKitConnected",
        ]
    }

    private var hostedNumericKeys: [String] {
        [
            "systemAudioGeneration", "authorizationGeneration",
            "nativeAuthorizationGeneration", "callbacks", "frames", "failures",
            "pcmNonzero", "pcmAbs", "recordRequests", "inboundBytes",
            "inboundPackets", "inboundJitterEmitted", "inboundSamples",
            "inboundEnergy", "inboundDuration",
        ]
    }

    private var hostedInboundMetricKeys: [String] {
        [
            "inboundBytes", "inboundPackets", "inboundJitterEmitted",
            "inboundSamples", "inboundEnergy", "inboundDuration",
        ]
    }

    private var hostedTrueInvariantKeys: [String] {
        [
            "output", "playback", "defaultMode", "mixWithOthers",
            "remoteIOCreated", "remoteIOSubtype", "activeOwnership", "hostedMode",
            "authorizationValid", "authorizationConsumed",
            "nativeAuthorizationValid", "nativeAuthorizationConsumed",
            "authorizationPolicyMatches", "authorizationGenerationMatches",
            "callKitConnected",
        ]
    }

    private var hostedBooleanKeys: [String] {
        hostedTrueInvariantKeys + ["input"]
    }

    private func rawMicrophoneSender(
        time: TimeInterval,
        peerEpoch: UUID? = nil,
        bindingGeneration: UInt64 = 3,
        negotiationEpoch: UInt64 = 5,
        trackGeneration: UInt64 = 7,
        microphonePolicyGeneration: UInt64 = 11,
        senderOwnsMID: Bool = true,
        senderOwnsLocalTrack: Bool = true,
        transceiverIsStopped: Bool = false,
        preferredDirectionIncludesSending: Bool = true,
        currentDirectionIncludesSending: Bool = true,
        trackIsEnabled: Bool = true,
        rawProcessingIsLive: Bool = true,
        transportIsHealthy: Bool = true,
        authorizationIsCurrent: Bool = true,
        authorizationIsValid: Bool = true,
        senderIsAdmitted: Bool = true,
        nativeDeviceIsOpen: Bool = true,
        nativeDeviceGateIsOpen: Bool = true,
        nativeAuthorizationGateIsOpen: Bool = true,
        categoryIsPlayAndRecord: Bool = true,
        modeIsDefault: Bool = true,
        usesRemoteIO: Bool = true,
        inputBusEnabled: Bool = true,
        captureRouteIsBuiltInMicrophone: Bool = true,
        captureRouteProofGeneration: UInt64 = 13,
        outputBusEnabled: Bool = true,
        categoryOptionsAreEmpty: Bool = false,
        categoryOptionsAreIPhoneMicrophoneRouting: Bool = true,
        routeSharingPolicyIsDefault: Bool = true,
        hasOutputRoute: Bool = true,
        sampleRateIs48k: Bool = true,
        ioBufferDurationIsBounded: Bool = true,
        outputChannelCountIsStereo: Bool = true,
        recoveryRequired: Bool = false,
        explicitResumeRequired: Bool = false,
        hostedCallMode: Bool = false,
        failureCode: Int = 0,
        lastLifecycleStatus: Int32 = 0,
        recordingGeneration: UInt64 = 13,
        approvedRecordingGeneration: UInt64? = nil,
        realtimeAdmissionCount: UInt64? = nil,
        deliveryCallbackCount: UInt64? = nil,
        deliveredFrameCount: UInt64? = nil
    ) -> WebRTCIPhoneMicrophoneSenderDiagnostics {
        WebRTCIPhoneMicrophoneSenderDiagnostics(
            peerEpoch: peerEpoch ?? rawPeerEpoch,
            bindingGeneration: bindingGeneration,
            negotiationEpoch: negotiationEpoch,
            trackGeneration: trackGeneration,
            microphonePolicyGeneration:
                microphonePolicyGeneration,
            senderOwnsMID: senderOwnsMID,
            senderOwnsLocalTrack: senderOwnsLocalTrack,
            transceiverIsStopped: transceiverIsStopped,
            preferredDirectionIncludesSending:
                preferredDirectionIncludesSending,
            currentDirectionIncludesSending:
                currentDirectionIncludesSending,
            trackIsEnabled: trackIsEnabled,
            rawProcessingIsLive: rawProcessingIsLive,
            transportIsHealthy: transportIsHealthy,
            authorizationIsCurrent: authorizationIsCurrent,
            authorizationIsValid: authorizationIsValid,
            senderIsAdmitted: senderIsAdmitted,
            nativeDeviceIsOpen: nativeDeviceIsOpen,
            nativeDeviceGateIsOpen: nativeDeviceGateIsOpen,
            nativeAuthorizationGateIsOpen:
                nativeAuthorizationGateIsOpen,
            categoryIsPlayAndRecord: categoryIsPlayAndRecord,
            modeIsDefault: modeIsDefault,
            usesRemoteIO: usesRemoteIO,
            inputBusEnabled: inputBusEnabled,
            captureRouteIsBuiltInMicrophone:
                captureRouteIsBuiltInMicrophone,
            captureRouteProofGeneration:
                captureRouteProofGeneration,
            outputBusEnabled: outputBusEnabled,
            categoryOptionsAreEmpty: categoryOptionsAreEmpty,
            categoryOptionsAreIPhoneMicrophoneRouting:
                categoryOptionsAreIPhoneMicrophoneRouting,
            routeSharingPolicyIsDefault:
                routeSharingPolicyIsDefault,
            hasOutputRoute: hasOutputRoute,
            sampleRateIs48k: sampleRateIs48k,
            ioBufferDurationIsBounded:
                ioBufferDurationIsBounded,
            outputChannelCountIsStereo:
                outputChannelCountIsStereo,
            recoveryRequired: recoveryRequired,
            explicitResumeRequired: explicitResumeRequired,
            hostedCallMode: hostedCallMode,
            failureCode: failureCode,
            lastLifecycleStatus: lastLifecycleStatus,
            recordingGeneration: recordingGeneration,
            approvedRecordingGeneration:
                approvedRecordingGeneration
                    ?? recordingGeneration,
            realtimeAdmissionCount:
                realtimeAdmissionCount
                    ?? UInt64(time * 100),
            deliveryCallbackCount:
                deliveryCallbackCount
                    ?? UInt64(time * 100),
            deliveredFrameCount:
                deliveredFrameCount
                    ?? UInt64(time * 48_000)
        )
    }

    private func rawMicrophoneSample(
        time: TimeInterval,
        sessionGeneration: UUID? = nil,
        peerIdentity: ObjectIdentifier? = nil,
        transportAuthorizationGeneration: UUID? = nil,
        audioPolicyGeneration: UUID? = nil,
        authorizationIdentity: ObjectIdentifier? = nil,
        authenticatedPairedSession: Bool = true,
        microphoneIntentIsCurrent: Bool = true,
        microphonePermissionGranted: Bool = true,
        callIsActive: Bool = false,
        macHostedCallEvidenceAdmitted: Bool = false,
        transportIsHealthy: Bool = true,
        sender: WebRTCIPhoneMicrophoneSenderDiagnostics? = nil,
        packetsSent: UInt64? = nil,
        bytesSent: UInt64? = nil,
        sourceReportWasLinked: Bool = true,
        audioTotals: (Double?, Double?)? = nil
    ) -> WorldwideRawMicrophoneProofSample {
        let sender = sender ?? rawMicrophoneSender(time: time)
        let totals = audioTotals
            ?? (time * 0.25, time)
        return WorldwideRawMicrophoneProofSample(
            sessionGeneration: sessionGeneration ?? session,
            peerIdentity:
                peerIdentity
                    ?? ObjectIdentifier(rawPeerIdentity),
            transportAuthorizationGeneration:
                transportAuthorizationGeneration ?? rawTransport,
            audioPolicyGeneration:
                audioPolicyGeneration ?? rawAudioPolicy,
            authorizationIdentity:
                authorizationIdentity
                    ?? ObjectIdentifier(rawAuthorizationIdentity),
            authenticatedPairedSession:
                authenticatedPairedSession,
            microphoneIntentIsCurrent:
                microphoneIntentIsCurrent,
            microphonePermissionGranted:
                microphonePermissionGranted,
            callIsActive: callIsActive,
            macHostedCallEvidenceAdmitted:
                macHostedCallEvidenceAdmitted,
            transportIsHealthy: transportIsHealthy,
            statistics:
                WebRTCIPhoneMicrophoneSenderStatistics(
                    collectedAt:
                        Date(timeIntervalSince1970: time),
                    sender: sender,
                    packetsSent:
                        packetsSent ?? UInt64(time * 50),
                    bytesSent:
                        bytesSent ?? UInt64(time * 8_000),
                    totalAudioEnergy: totals.0,
                    totalSamplesDuration: totals.1,
                    sourceReportWasLinked: sourceReportWasLinked
                )
        )
    }

    private func rawOracleAccessibilityValue() -> String {
        var tracker = WorldwideRawMicrophoneContinuityTracker()
        _ = tracker.observe(rawMicrophoneSample(time: 1))
        guard case .satisfied(let oracle) =
            tracker.observe(rawMicrophoneSample(time: 2)) else {
            fatalError("The deterministic raw microphone fixture is invalid.")
        }
        return oracle.accessibilityValue
    }

    private func replacingOracleFields(
        in accessibilityValue: String,
        overrides: [String: String]
    ) -> String {
        accessibilityValue
            .split(
                separator: "|",
                omittingEmptySubsequences: false
            )
            .map { component -> String in
                let pair = component.split(
                    separator: "=",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                guard pair.count == 2 else {
                    return String(component)
                }
                let key = String(pair[0])
                guard let replacement = overrides[key] else {
                    return String(component)
                }
                return "\(key)=\(replacement)"
            }
            .joined(separator: "|")
    }

    private func rawPhysicalOverrides(
        step: UInt64,
        energy: Double = 0.5
    ) -> [String: String] {
        [
            "admissions": String(200 + step * 130),
            "callbacks": String(200 + step * 130),
            "frames": String(96_000 + step * 62_400),
            "packets": String(100 + step * 65),
            "bytes": String(16_000 + step * 10_400),
            "energy": String(energy),
            "duration": String(2 + Double(step) * 1.3),
            "samples": String(2 + step),
        ]
    }

    private func physicalRawSnapshot(
        basedOn accessibilityValue: String,
        overrides: [String: String] = [:]
    ) -> PhysicalRawMicrophoneSnapshot {
        PhysicalRawMicrophoneSnapshot(
            accessibilityValue: replacingOracleFields(
                in: accessibilityValue,
                overrides: overrides
            )
        )!
    }

    private func ordinaryAudioAccessibilityValue() -> String {
        WorldwideAudioPlayoutOracleSnapshot(
            sessionGeneration: session,
            audioPolicyGeneration: ordinaryAudioPolicy,
            callbackCount: 41,
            frameCount: 19_680,
            failureCount: 0,
            pcmSampleCount: 39_360,
            pcmNonzeroSampleCount: 38_000,
            pcmAbsoluteSampleSum: 38_000_000,
            pcmLeftAbsoluteSampleSum: 19_000_000,
            pcmRightAbsoluteSampleSum: 19_000_000,
            pcmStereoDifferenceAbsoluteSampleSum: 9_000_000,
            pcmEnvelopeTransitionCount: 3,
            pcmShapeAnomalyCallbackCount: 1,
            pcmBoundaryDiscontinuityCallbackCount: 1,
            lastCallbackMeanMagnitude: 1_250,
            lastPeakMagnitude: 8_000,
            inboundAudioEnergy: 2.5,
            inboundSamplesDuration: 0.41,
            fullQualityInvariantsHold: true
        ).accessibilityValue
    }

    private func hostedAccessibilityValue(
        seconds: UInt64,
        overrides: [String: String] = [:]
    ) -> String {
        let frames = seconds * 48_000
        let callbacks = seconds * 100
        let pcmNonzero = frames * 19 / 10
        var fields: [String: String] = [
            "v": "2",
            "origin": "startup-connected-call",
            "session": session.uuidString.lowercased(),
            "policy": hostedPolicy.uuidString.lowercased(),
            "audioPolicy": hostedAudioPolicy.uuidString.lowercased(),
            "systemAudioGeneration": "7",
            "authorizationGeneration": "7",
            "nativeAuthorizationGeneration": "7",
            "callbacks": String(callbacks),
            "frames": String(frames),
            "failures": "0",
            "pcmNonzero": String(pcmNonzero),
            "pcmAbs": String(pcmNonzero * 1_000),
            "recordRequests": "0",
            "inboundBytes": String(frames * 2),
            "inboundPackets": String(frames / 960),
            "inboundJitterEmitted": String(frames),
            "inboundSamples": String(frames),
            "inboundEnergy": String(Double(frames) / 48_000 * 0.25),
            "inboundDuration": String(Double(frames) / 48_000),
            "output": "1",
            "input": "0",
            "playback": "1",
            "defaultMode": "1",
            "mixWithOthers": "1",
            "remoteIOCreated": "1",
            "remoteIOSubtype": "1",
            "activeOwnership": "1",
            "hostedMode": "1",
            "authorizationValid": "1",
            "authorizationConsumed": "1",
            "nativeAuthorizationValid": "1",
            "nativeAuthorizationConsumed": "1",
            "authorizationPolicyMatches": "1",
            "authorizationGenerationMatches": "1",
            "callKitConnected": "1",
        ]
        for (key, value) in overrides {
            fields[key] = value
        }
        return hostedKeyOrder.map { key in
            "\(key)=\(fields[key]!)"
        }.joined(separator: "|")
    }

    private func hosted(
        seconds: UInt64,
        overrides: [String: String] = [:]
    ) -> PhysicalHostedCallPlayoutSnapshot {
        PhysicalHostedCallPlayoutSnapshot(
            accessibilityValue: hostedAccessibilityValue(
                seconds: seconds,
                overrides: overrides
            )
        )!
    }

    /// Produces a structurally valid baseline; individual tests override only the invariant under test.
    private func audio(
        session: UUID? = nil,
        audioPolicy: UUID? = nil,
        callbacks: UInt64,
        frames: UInt64,
        failures: UInt64,
        pcmSamples: UInt64? = nil,
        pcmNonzero: UInt64? = nil,
        pcmAbsolute: UInt64? = nil,
        pcmLeftAbsolute: UInt64? = nil,
        pcmRightAbsolute: UInt64? = nil,
        pcmStereoDifferenceAbsolute: UInt64? = nil,
        clipped: UInt64 = 0,
        silenceCallbacks: UInt64 = 0,
        gapViolations: UInt64 = 0,
        maximumGapNanoseconds: UInt64 = 10_000_000,
        nearSilenceCallbacks: UInt64 = 0,
        currentNearSilenceFrames: UInt64 = 0,
        maximumNearSilenceFrames: UInt64 = 0,
        leftCrossings: UInt64? = nil,
        rightCrossings: UInt64? = nil,
        envelopeTransitions: UInt64? = nil,
        shapeAnomalies: UInt64 = 0,
        boundaryDiscontinuities: UInt64 = 0,
        callbackMean: UInt32? = nil,
        recoveryRebuilds: UInt64 = 0,
        peak: UInt32? = nil,
        inboundEnergy: Double? = nil,
        inboundDuration: Double? = nil,
        fullQuality: Bool = true
    ) -> PhysicalAudioPlayoutSnapshot {
        let samples = pcmSamples ?? frames * 2
        let nonzero = pcmNonzero ?? samples
        let absolute = pcmAbsolute ?? nonzero * 1_000
        let leftAbsolute = pcmLeftAbsolute ?? absolute / 2
        let rightAbsolute = pcmRightAbsolute ?? absolute - leftAbsolute
        return PhysicalAudioPlayoutSnapshot(
            accessibilityValue: WorldwideAudioPlayoutOracleSnapshot(
                sessionGeneration: session ?? self.session,
                audioPolicyGeneration:
                    audioPolicy ?? ordinaryAudioPolicy,
                callbackCount: callbacks,
                frameCount: frames,
                failureCount: failures,
                pcmSampleCount: samples,
                pcmNonzeroSampleCount: nonzero,
                pcmAbsoluteSampleSum: absolute,
                pcmLeftAbsoluteSampleSum: leftAbsolute,
                pcmRightAbsoluteSampleSum: rightAbsolute,
                pcmStereoDifferenceAbsoluteSampleSum:
                    pcmStereoDifferenceAbsolute ?? absolute * 3 / 5,
                pcmClippedSampleCount: clipped,
                explicitSilenceCallbackCount: silenceCallbacks,
                callbackGapViolationCount: gapViolations,
                maximumCallbackGapNanoseconds: maximumGapNanoseconds,
                nearSilenceCallbackCount: nearSilenceCallbacks,
                currentConsecutiveNearSilenceFrameCount: currentNearSilenceFrames,
                maximumConsecutiveNearSilenceFrameCount: maximumNearSilenceFrames,
                pcmLeftZeroCrossingCount:
                    leftCrossings ?? frames * 9_000 / 48_000,
                pcmRightZeroCrossingCount:
                    rightCrossings ?? frames * 12_502 / 48_000,
                pcmEnvelopeTransitionCount:
                    envelopeTransitions ?? frames / 24_000,
                pcmShapeAnomalyCallbackCount: shapeAnomalies,
                pcmBoundaryDiscontinuityCallbackCount: boundaryDiscontinuities,
                lastCallbackMeanMagnitude:
                    callbackMean ?? (nonzero == 0 ? 0 : 5_100),
                recoveryRebuildCount: recoveryRebuilds,
                lastPeakMagnitude: peak ?? (nonzero == 0 ? 0 : 8_000),
                inboundAudioEnergy:
                    inboundEnergy ?? Double(frames) / 48_000 * 0.25,
                inboundSamplesDuration:
                    inboundDuration ?? Double(frames) / 48_000,
                fullQualityInvariantsHold: fullQuality
            ).accessibilityValue
        )!
    }

    /// Produces internally consistent frame/content counters for video delta tests.
    private func video(
        renderer: UUID? = nil,
        frames: UInt64,
        timestamp: Int64,
        width: Int = 1_920,
        height: Int = 1_080,
        contentDigest: UInt64? = nil,
        contentSamples: UInt64? = nil,
        contentChanges: UInt64? = nil
    ) -> PhysicalVideoRenderSnapshot {
        let samples = contentSamples ?? frames
        return PhysicalVideoRenderSnapshot(
            accessibilityValue: WorldwideVideoRenderOracleSnapshot(
                rendererID: renderer ?? self.renderer,
                frameCount: frames,
                timestampNanoseconds: timestamp,
                width: width,
                height: height,
                contentDigest: contentDigest ?? frames,
                contentSampleCount: samples,
                contentChangeCount: contentChanges ?? (samples > 0 ? samples - 1 : 0)
            ).accessibilityValue
        )!
    }
}
