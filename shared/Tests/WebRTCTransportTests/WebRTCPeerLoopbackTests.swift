import AudioToolbox
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import LiveKitWebRTC
import RemoteSessionCore
@testable import WebRTCTransport
import XCTest

private final class SenderStatisticsIdentity {}

private final class SemanticNativeWrapper: NSObject {
    let stableIdentity: String

    init(stableIdentity: String) {
        self.stableIdentity = stableIdentity
        super.init()
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? SemanticNativeWrapper)?.stableIdentity
            == stableIdentity
    }

    override var hash: Int { stableIdentity.hashValue }
}

private func admittedIPhoneMicrophoneSenderDiagnostics(
    peerEpoch: UUID = UUID(
        uuidString: "10000000-0000-0000-0000-000000000001"
    )!,
    bindingGeneration: UInt64 = 3,
    negotiationEpoch: UInt64 = 5,
    trackGeneration: UInt64 = 7,
    microphonePolicyGeneration: UInt64 = 11,
    recordingGeneration: UInt64 = 13,
    realtimeAdmissionCount: UInt64 = 100,
    deliveryCallbackCount: UInt64 = 100,
    deliveredFrameCount: UInt64 = 48_000,
    transportIsHealthy: Bool = true,
    trackIsEnabled: Bool = true,
    rawProcessingIsLive: Bool = true,
    transceiverIsStopped: Bool = false,
    preferredDirectionIncludesSending: Bool = true,
    currentDirectionIncludesSending: Bool = true
) -> WebRTCIPhoneMicrophoneSenderDiagnostics {
    WebRTCIPhoneMicrophoneSenderDiagnostics(
        peerEpoch: peerEpoch,
        bindingGeneration: bindingGeneration,
        negotiationEpoch: negotiationEpoch,
        trackGeneration: trackGeneration,
        microphonePolicyGeneration:
            microphonePolicyGeneration,
        senderOwnsMID: true,
        senderOwnsLocalTrack: true,
        transceiverIsStopped: transceiverIsStopped,
        preferredDirectionIncludesSending:
            preferredDirectionIncludesSending,
        currentDirectionIncludesSending:
            currentDirectionIncludesSending,
        trackIsEnabled: trackIsEnabled,
        rawProcessingIsLive: rawProcessingIsLive,
        transportIsHealthy: transportIsHealthy,
        authorizationIsCurrent: true,
        authorizationIsValid: true,
        senderIsAdmitted:
            !transceiverIsStopped
                && preferredDirectionIncludesSending
                && currentDirectionIncludesSending
                && transportIsHealthy
                && trackIsEnabled
                && rawProcessingIsLive,
        nativeDeviceIsOpen: true,
        nativeDeviceGateIsOpen: true,
        nativeAuthorizationGateIsOpen: true,
        categoryIsPlayAndRecord: true,
        modeIsDefault: true,
        usesRemoteIO: true,
        inputBusEnabled: true,
        captureRouteIsBuiltInMicrophone: true,
        captureRouteProofGeneration: 13,
        outputBusEnabled: true,
        categoryOptionsAreEmpty: false,
        categoryOptionsAreIPhoneMicrophoneRouting: true,
        routeSharingPolicyIsDefault: true,
        hasOutputRoute: true,
        sampleRateIs48k: true,
        ioBufferDurationIsBounded: true,
        outputChannelCountIsStereo: true,
        recoveryRequired: false,
        explicitResumeRequired: false,
        hostedCallMode: false,
        failureCode: 0,
        lastLifecycleStatus: 0,
        recordingGeneration: recordingGeneration,
        approvedRecordingGeneration: recordingGeneration,
        realtimeAdmissionCount: realtimeAdmissionCount,
        deliveryCallbackCount: deliveryCallbackCount,
        deliveredFrameCount: deliveredFrameCount
    )
}

private func senderStatisticsValidation(
    peerEpoch: UUID = UUID(
        uuidString: "10000000-0000-0000-0000-000000000001"
    )!,
    bindingGeneration: UInt64 = 3,
    negotiationEpoch: UInt64 = 5,
    trackGeneration: UInt64 = 7,
    microphonePolicyGeneration: UInt64 = 11,
    recordingGeneration: UInt64 = 13,
    captureRouteProofGeneration: UInt64 = 13,
    authorizationIdentity: ObjectIdentifier,
    senderID: String = "exact-microphone-sender",
    localTrackID: String = "iphone-microphone",
    mid: String = "mic-mid"
) -> WebRTCIPhoneMicrophoneSenderStatisticsValidation {
    WebRTCIPhoneMicrophoneSenderStatisticsValidation(
        peerEpoch: peerEpoch,
        bindingGeneration: bindingGeneration,
        negotiationEpoch: negotiationEpoch,
        trackGeneration: trackGeneration,
        microphonePolicyGeneration:
            microphonePolicyGeneration,
        recordingGeneration: recordingGeneration,
        approvedRecordingGeneration: recordingGeneration,
        captureRouteProofGeneration:
            captureRouteProofGeneration,
        authorizationIdentity: authorizationIdentity,
        senderID: senderID,
        localTrackID: localTrackID,
        mid: mid
    )
}

private func senderOutboundStatistics(
    reportDate: Date,
    outboundRTPRecordIDs: [String] = ["exact-outbound"],
    packetsSent: UInt64 = 50,
    bytesSent: UInt64 = 8_000,
    totalAudioEnergy: Double? = 0.25,
    totalSamplesDuration: Double? = 1,
    sourceReportWasLinked: Bool = true
) -> WebRTCIPhoneMicrophoneOutboundStatistics {
    WebRTCIPhoneMicrophoneOutboundStatistics(
        reportTimestampMicroseconds:
            reportDate.timeIntervalSince1970 * 1_000_000,
        outboundRTPRecordIDs: outboundRTPRecordIDs,
        packetsSent: packetsSent,
        bytesSent: bytesSent,
        totalAudioEnergy: totalAudioEnergy,
        totalSamplesDuration: totalSamplesDuration,
        sourceReportWasLinked: sourceReportWasLinked
    )
}

private func sampleIPhoneMicrophoneSenderStatistics(
    parsed: WebRTCIPhoneMicrophoneOutboundStatistics?,
    captured: WebRTCIPhoneMicrophoneSenderStatisticsValidation,
    current: WebRTCIPhoneMicrophoneSenderStatisticsValidation?,
    diagnostics: WebRTCIPhoneMicrophoneSenderDiagnostics?,
    callbackCompletedAt: Date,
    currentTime: Date,
    previousBaseline:
        WebRTCIPhoneMicrophoneSenderStatisticsBaseline? = nil,
    requiresAdvancingEvidence: Bool = false
) -> WebRTCIPhoneMicrophoneSenderStatisticsSamplingResult? {
    WebRTCIPhoneMicrophoneSenderStatisticsSampler.evaluate(
        parsed: parsed,
        captured: captured,
        current: current,
        diagnostics: diagnostics,
        callbackCompletedAt: callbackCompletedAt,
        currentTime: currentTime,
        previousBaseline: previousBaseline,
        requiresAdvancingEvidence: requiresAdvancingEvidence
    )
}

/// Exercises two real in-process native peers. Milestones, exact signaling counts, decoded PCM
/// waveform evidence, media frames, and authorization revocation form the end-to-end oracles.
final class WebRTCPeerLoopbackTests: XCTestCase {
    func testIPhoneMicrophoneTrackCreationPolicyMatchesPlatformAndConfiguration() {
        #if os(iOS)
        XCTAssertTrue(
            WebRTCIPhoneMicrophoneTrackCreationPolicy.shouldCreate(role: .viewer)
        )
        XCTAssertFalse(
            WebRTCIPhoneMicrophoneTrackCreationPolicy.shouldCreate(role: .host)
        )
        #elseif DEBUG && os(macOS)
        XCTAssertFalse(
            WebRTCIPhoneMicrophoneTrackCreationPolicy.shouldCreate(
                role: .viewer,
                useHeadlessMacViewerAudioForTesting: false
            )
        )
        XCTAssertTrue(
            WebRTCIPhoneMicrophoneTrackCreationPolicy.shouldCreate(
                role: .viewer,
                useHeadlessMacViewerAudioForTesting: true
            )
        )
        XCTAssertFalse(
            WebRTCIPhoneMicrophoneTrackCreationPolicy.shouldCreate(
                role: .host,
                useHeadlessMacViewerAudioForTesting: true
            )
        )
        #else
        XCTAssertFalse(
            WebRTCIPhoneMicrophoneTrackCreationPolicy.shouldCreate(
                role: .viewer,
                useHeadlessMacViewerAudioForTesting: true
            )
        )
        XCTAssertFalse(
            WebRTCIPhoneMicrophoneTrackCreationPolicy.shouldCreate(role: .host)
        )
        #endif
    }

    func testExactIPhoneMicrophoneSenderStatisticsRejectsEmptyAndDuplicateRecordIDs() {
        let authorization = SenderStatisticsIdentity()
        let captured = senderStatisticsValidation(
            authorizationIdentity: ObjectIdentifier(authorization)
        )
        let callbackCompletedAt = Date(timeIntervalSince1970: 1_000)
        let currentTime = Date(timeIntervalSince1970: 1_000.1)
        let reportDate = Date(timeIntervalSince1970: 999.75)

        for recordIDs in [[], [""], ["duplicate", "duplicate"]] {
            XCTAssertNil(
                sampleIPhoneMicrophoneSenderStatistics(
                    parsed: senderOutboundStatistics(
                        reportDate: reportDate,
                        outboundRTPRecordIDs: recordIDs
                    ),
                    captured: captured,
                    current: captured,
                    diagnostics: admittedIPhoneMicrophoneSenderDiagnostics(),
                    callbackCompletedAt: callbackCompletedAt,
                    currentTime: currentTime
                )
            )
        }
    }

#if DEBUG
    func testFailedVisibilitySendStillRevokesViewerInputSynchronously() async throws {
        let viewer = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .viewer, iceServers: [])
        )
        let capability = WebRTCInputCapability(
            inputSessionID: UUID(),
            screenRequestID: 1
        )
        let authorization = WebRTCInputAuthorization()
        try await viewer.installViewerInputSessionForTesting(
            capability: capability,
            authorization: authorization
        )
        XCTAssertTrue(authorization.isValid)

        do {
            _ = try await viewer.setScreenVisible(false)
            XCTFail("The unopened control channel must reject Hide.")
        } catch {
            // The send failure is expected; revocation must happen before it.
        }

        XCTAssertFalse(authorization.isValid)
        let currentCapability = await viewer.currentInputCapability()
        XCTAssertNil(currentCapability)
    }

    func testPublicEventBufferOverflowRevokesInputAndClosesTransport() async throws {
        let viewer = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .viewer, iceServers: [])
        )
        let capability = WebRTCInputCapability(
            inputSessionID: UUID(),
            screenRequestID: 1
        )
        let authorization = WebRTCInputAuthorization()
        try await viewer.installViewerInputSessionForTesting(
            capability: capability,
            authorization: authorization
        )

        for _ in 0...256 {
            await viewer.emitPublicEventForTesting()
        }

        XCTAssertFalse(authorization.isValid)
        let currentCapability = await viewer.currentInputCapability()
        XCTAssertNil(currentCapability)
        do {
            _ = try await viewer.sendInput(
                .tap(.init(x: 0.5, y: 0.5)),
                capability: capability,
                authorization: authorization
            )
            XCTFail("A public event loss must permanently close this transport.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .transportClosed)
        }
    }

    func testActiveAcknowledgementForHideClosesViewerTransportImmediately() async throws {
        let viewer = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .viewer, iceServers: [])
        )
        let request = WebRTCControlRequest(id: 1, command: .hideScreen)

        try await viewer.receiveControlAcknowledgementForTesting(
            request: request,
            acknowledgement: .init(id: request.id, state: .active)
        )

        let isClosed = await viewer.isClosedForTesting
        XCTAssertTrue(isClosed)
        do {
            _ = try await viewer.requestControl(.hideScreen)
            XCTFail("Active-for-Hide must close the transport without waiting for a UI timeout.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .transportClosed)
        }
    }
#endif

    func testIPhoneMicrophoneNativeOwnershipAcceptsRefreshedWrappersAndRejectsDifferentIdentity() {
        let bindingTransceiver =
            SemanticNativeWrapper(stableIdentity: "transceiver")
        let refreshedTransceiver =
            SemanticNativeWrapper(stableIdentity: "transceiver")
        let bindingSender =
            SemanticNativeWrapper(stableIdentity: "sender")
        let refreshedSender =
            SemanticNativeWrapper(stableIdentity: "sender")
        let bindingTrack =
            SemanticNativeWrapper(stableIdentity: "track")
        let refreshedTrack =
            SemanticNativeWrapper(stableIdentity: "track")

        XCTAssertFalse(bindingTransceiver === refreshedTransceiver)
        XCTAssertFalse(bindingSender === refreshedSender)
        XCTAssertFalse(bindingTrack === refreshedTrack)

        let isCurrent: (
            SemanticNativeWrapper,
            SemanticNativeWrapper,
            SemanticNativeWrapper,
            String
        ) -> Bool = {
            currentTransceiver,
            currentSender,
            currentTrack,
            senderID in
            WebRTCIPhoneMicrophoneNativeOwnership.isCurrent(
                bindingTransceiver: bindingTransceiver,
                currentTransceiver: currentTransceiver,
                bindingSender: bindingSender,
                currentSender: currentSender,
                bindingTrack: bindingTrack,
                currentTrack: currentTrack,
                bindingMID: "mic-mid",
                currentMID: "mic-mid",
                bindingSenderID: "microphone-sender",
                currentSenderID: senderID,
                bindingTrackID: "iphone-microphone",
                currentTrackID: "iphone-microphone"
            )
        }

        XCTAssertTrue(
            isCurrent(
                refreshedTransceiver,
                refreshedSender,
                refreshedTrack,
                "microphone-sender"
            )
        )
        XCTAssertFalse(
            isCurrent(
                refreshedTransceiver,
                refreshedSender,
                refreshedTrack,
                "different-sender"
            )
        )
        XCTAssertFalse(
            isCurrent(
                SemanticNativeWrapper(
                    stableIdentity: "different-transceiver"
                ),
                refreshedSender,
                refreshedTrack,
                "microphone-sender"
            )
        )
    }

    func testIPhoneMicrophoneTransceiverAdmissionRejectsStoppedInactiveAndRecvOnly() {
        XCTAssertTrue(
            WebRTCIPhoneMicrophoneTransceiverAdmission
                .permitsNegotiatedSending(
                    isStopped: false,
                    preferredDirection: .sendOnly,
                    currentDirection: .sendOnly
                )
        )
        XCTAssertTrue(
            WebRTCIPhoneMicrophoneTransceiverAdmission
                .permitsNegotiatedSending(
                    isStopped: false,
                    preferredDirection: .sendRecv,
                    currentDirection: .sendRecv
                )
        )
        XCTAssertFalse(
            WebRTCIPhoneMicrophoneTransceiverAdmission
                .permitsNegotiatedSending(
                    isStopped: true,
                    preferredDirection: .sendOnly,
                    currentDirection: .sendOnly
                )
        )
        XCTAssertFalse(
            WebRTCIPhoneMicrophoneTransceiverAdmission
                .permitsNegotiatedSending(
                    isStopped: false,
                    preferredDirection: .sendOnly,
                    currentDirection: nil
                )
        )

        let nonSendingDirections: [LKRTCRtpTransceiverDirection] = [
            .inactive,
            .recvOnly,
            .stopped,
        ]
        for direction in nonSendingDirections {
            XCTAssertFalse(
                WebRTCIPhoneMicrophoneTransceiverAdmission
                    .permitsNegotiatedSending(
                        isStopped: false,
                        preferredDirection: direction,
                        currentDirection: .sendOnly
                    )
            )
            XCTAssertFalse(
                WebRTCIPhoneMicrophoneTransceiverAdmission
                    .permitsNegotiatedSending(
                        isStopped: false,
                        preferredDirection: .sendOnly,
                        currentDirection: direction
                    )
            )
        }

        XCTAssertTrue(
            WebRTCIPhoneMicrophoneTransceiverAdmission
                .directionIncludesReceiving(.recvOnly)
        )
        XCTAssertTrue(
            WebRTCIPhoneMicrophoneTransceiverAdmission
                .directionIncludesReceiving(.sendRecv)
        )
        for direction in [
            LKRTCRtpTransceiverDirection.sendOnly,
            .inactive,
            .stopped,
        ] {
            XCTAssertFalse(
                WebRTCIPhoneMicrophoneTransceiverAdmission
                    .directionIncludesReceiving(direction)
            )
        }
    }

    func testExactIPhoneMicrophoneSenderStatisticsSelectsOnlyItsOutboundRTPAndLinkedSource() throws {
        func records(
            exactPackets: UInt64,
            exactBytes: UInt64,
            otherPackets: UInt64,
            otherBytes: UInt64
        ) -> [WebRTCStatisticsRecord] {
            [
                WebRTCStatisticsRecord(
                    id: "other-outbound",
                    type: "outbound-rtp",
                    values: [
                        "kind": "audio",
                        "senderId": "other-sender",
                        "mid": "other-mid",
                        "trackIdentifier": "other-track",
                        "mediaSourceId": "other-source",
                        "packetsSent": NSNumber(value: otherPackets),
                        "bytesSent": NSNumber(value: otherBytes),
                    ]
                ),
                WebRTCStatisticsRecord(
                    id: "exact-outbound",
                    type: "outbound-rtp",
                    values: [
                        "kind": "audio",
                        "senderId": "exact-microphone-sender",
                        "mid": "mic-mid",
                        "trackIdentifier": "iphone-microphone",
                        "mediaSourceId": "exact-source",
                        "packetsSent": NSNumber(value: exactPackets),
                        "bytesSent": NSNumber(value: exactBytes),
                    ]
                ),
                WebRTCStatisticsRecord(
                    id: "other-source",
                    type: "media-source",
                    values: [
                        "kind": "audio",
                        "trackIdentifier": "other-track",
                        "totalAudioEnergy": NSNumber(value: 500.0),
                        "totalSamplesDuration": NSNumber(value: 500.0),
                    ]
                ),
                WebRTCStatisticsRecord(
                    id: "exact-source",
                    type: "media-source",
                    values: [
                        "kind": "audio",
                        "trackIdentifier": "iphone-microphone",
                        "totalAudioEnergy": NSNumber(value: 0.25),
                        "totalSamplesDuration": NSNumber(value: 1.0),
                    ]
                ),
            ]
        }

        let first = try XCTUnwrap(
            WebRTCStatisticsParser.parseIPhoneMicrophoneSender(
                records: records(
                    exactPackets: 50,
                    exactBytes: 8_000,
                    otherPackets: 100,
                    otherBytes: 16_000
                ),
                reportTimestampMicroseconds: 1_000_000,
                expectedSenderID: "exact-microphone-sender",
                expectedTrackID: "iphone-microphone",
                expectedMID: "mic-mid"
            )
        )
        XCTAssertEqual(first.packetsSent, 50)
        XCTAssertEqual(first.bytesSent, 8_000)
        XCTAssertEqual(first.reportTimestampMicroseconds, 1_000_000)
        XCTAssertEqual(first.totalAudioEnergy, 0.25)
        XCTAssertEqual(first.totalSamplesDuration, 1.0)
        XCTAssertTrue(first.sourceReportWasLinked)

        let otherSenderOnlyAdvanced = try XCTUnwrap(
            WebRTCStatisticsParser.parseIPhoneMicrophoneSender(
                records: records(
                    exactPackets: 50,
                    exactBytes: 8_000,
                    otherPackets: 300,
                    otherBytes: 64_000
                ),
                reportTimestampMicroseconds: 2_000_000,
                expectedSenderID: "exact-microphone-sender",
                expectedTrackID: "iphone-microphone",
                expectedMID: "mic-mid"
            )
        )
        XCTAssertEqual(
            otherSenderOnlyAdvanced.packetsSent,
            first.packetsSent
        )
        XCTAssertEqual(
            otherSenderOnlyAdvanced.bytesSent,
            first.bytesSent
        )
        XCTAssertEqual(
            otherSenderOnlyAdvanced.totalAudioEnergy,
            first.totalAudioEnergy
        )
    }

    func testExactIPhoneMicrophoneSenderStatisticsAggregatesMultipleExactEncodingsSafely() throws {
        func outbound(
            id: String,
            packets: UInt64,
            bytes: UInt64,
            energy: Double?,
            duration: Double?,
            includesIdentity: Bool = true,
            mediaSourceID: String? = "exact-source"
        ) -> WebRTCStatisticsRecord {
            var values: [String: Any] = [
                "kind": "audio",
                "packetsSent": NSNumber(value: packets),
                "bytesSent": NSNumber(value: bytes),
            ]
            if includesIdentity {
                values["senderId"] = "exact-microphone-sender"
                values["mid"] = "mic-mid"
                values["trackIdentifier"] = "iphone-microphone"
                if let mediaSourceID {
                    values["mediaSourceId"] = mediaSourceID
                }
            }
            if let energy, let duration {
                values["totalAudioEnergy"] = NSNumber(value: energy)
                values["totalSamplesDuration"] =
                    NSNumber(value: duration)
            }
            return WebRTCStatisticsRecord(
                id: id,
                type: "outbound-rtp",
                values: values
            )
        }

        let source = WebRTCStatisticsRecord(
            id: "exact-source",
            type: "media-source",
            values: [
                "kind": "audio",
                "trackIdentifier": "iphone-microphone",
                "totalAudioEnergy": NSNumber(value: 0.3),
                "totalSamplesDuration": NSNumber(value: 1.0),
            ]
        )
        let exactRecords = [
            outbound(
                id: "exact-one",
                packets: 10,
                bytes: 1_000,
                energy: 0.1,
                duration: 0.4
            ),
            outbound(
                id: "exact-two",
                packets: 20,
                bytes: 2_000,
                energy: 0.2,
                duration: 0.6
            ),
            source,
        ]

        let aggregated = try XCTUnwrap(
            WebRTCStatisticsParser.parseIPhoneMicrophoneSender(
                records: exactRecords,
                reportTimestampMicroseconds: 3_000_000,
                expectedSenderID: "exact-microphone-sender",
                expectedTrackID: "iphone-microphone",
                expectedMID: "mic-mid"
            )
        )
        XCTAssertEqual(
            aggregated.outboundRTPRecordIDs,
            ["exact-one", "exact-two"]
        )
        XCTAssertEqual(aggregated.packetsSent, 30)
        XCTAssertEqual(aggregated.bytesSent, 3_000)
        XCTAssertEqual(
            try XCTUnwrap(aggregated.totalAudioEnergy),
            0.3,
            accuracy: 0.000_000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(aggregated.totalSamplesDuration),
            1,
            accuracy: 0.000_000_001
        )
        XCTAssertTrue(aggregated.sourceReportWasLinked)

        let identifierFree = try XCTUnwrap(
            WebRTCStatisticsParser.parseIPhoneMicrophoneSender(
                records: [
                    outbound(
                        id: "generic-one",
                        packets: 1,
                        bytes: 100,
                        energy: nil,
                        duration: nil,
                        includesIdentity: false,
                        mediaSourceID: nil
                    ),
                    outbound(
                        id: "generic-two",
                        packets: 2,
                        bytes: 200,
                        energy: nil,
                        duration: nil,
                        includesIdentity: false,
                        mediaSourceID: nil
                    ),
                ],
                reportTimestampMicroseconds: 4_000_000,
                expectedSenderID: "exact-microphone-sender",
                expectedTrackID: "iphone-microphone",
                expectedMID: "mic-mid"
            )
        )
        XCTAssertEqual(
            identifierFree.outboundRTPRecordIDs,
            ["generic-one", "generic-two"]
        )
        XCTAssertEqual(identifierFree.packetsSent, 3)
        XCTAssertEqual(identifierFree.bytesSent, 300)
        XCTAssertFalse(identifierFree.sourceReportWasLinked)

        let genericCollision = exactRecords + [
            outbound(
                id: "generic-collision",
                packets: 500,
                bytes: 50_000,
                energy: nil,
                duration: nil,
                includesIdentity: false,
                mediaSourceID: nil
            ),
        ]
        XCTAssertNil(
            WebRTCStatisticsParser.parseIPhoneMicrophoneSender(
                records: genericCollision,
                reportTimestampMicroseconds: 5_000_000,
                expectedSenderID: "exact-microphone-sender",
                expectedTrackID: "iphone-microphone",
                expectedMID: "mic-mid"
            )
        )

        let overflowRecords = [
            outbound(
                id: "overflow-one",
                packets: 1,
                bytes: UInt64(Int64.max),
                energy: nil,
                duration: nil,
                mediaSourceID: nil
            ),
            outbound(
                id: "overflow-two",
                packets: 1,
                bytes: 1,
                energy: nil,
                duration: nil,
                mediaSourceID: nil
            ),
        ]
        XCTAssertNil(
            WebRTCStatisticsParser.parseIPhoneMicrophoneSender(
                records: overflowRecords,
                reportTimestampMicroseconds: 6_000_000,
                expectedSenderID: "exact-microphone-sender",
                expectedTrackID: "iphone-microphone",
                expectedMID: "mic-mid"
            )
        )
    }

    func testExactIPhoneMicrophoneSenderStatisticsRejectsWrongAmbiguousAndMalformedReports() {
        let validOutbound = WebRTCStatisticsRecord(
            id: "exact-outbound",
            type: "outbound-rtp",
            values: [
                "kind": "audio",
                "senderId": "exact-microphone-sender",
                "mid": "mic-mid",
                "trackIdentifier": "iphone-microphone",
                "packetsSent": NSNumber(value: 10),
                "bytesSent": NSNumber(value: 1_000),
            ]
        )

        let malformed: [(String, [WebRTCStatisticsRecord])] = [
            (
                "wrong sender",
                [
                    WebRTCStatisticsRecord(
                        id: "wrong",
                        type: "outbound-rtp",
                        values: [
                            "kind": "audio",
                            "senderId": "other-sender",
                            "mid": "other-mid",
                            "trackIdentifier": "other-track",
                            "packetsSent": NSNumber(value: 10),
                            "bytesSent": NSNumber(value: 1_000),
                        ]
                    ),
                ]
            ),
            (
                "wrong kind",
                [
                    WebRTCStatisticsRecord(
                        id: "video",
                        type: "outbound-rtp",
                        values: [
                            "kind": "video",
                            "senderId": "exact-microphone-sender",
                            "mid": "mic-mid",
                            "trackIdentifier": "iphone-microphone",
                            "packetsSent": NSNumber(value: 10),
                            "bytesSent": NSNumber(value: 1_000),
                        ]
                    ),
                ]
            ),
            (
                "missing packets",
                [
                    WebRTCStatisticsRecord(
                        id: "missing-packets",
                        type: "outbound-rtp",
                        values: [
                            "kind": "audio",
                            "senderId": "exact-microphone-sender",
                            "mid": "mic-mid",
                            "trackIdentifier": "iphone-microphone",
                            "bytesSent": NSNumber(value: 1_000),
                        ]
                    ),
                ]
            ),
            (
                "negative packets",
                [
                    WebRTCStatisticsRecord(
                        id: "negative",
                        type: "outbound-rtp",
                        values: [
                            "kind": "audio",
                            "senderId": "exact-microphone-sender",
                            "mid": "mic-mid",
                            "trackIdentifier": "iphone-microphone",
                            "packetsSent": NSNumber(value: -1),
                            "bytesSent": NSNumber(value: 1_000),
                        ]
                    ),
                ]
            ),
            (
                "non-finite packets",
                [
                    WebRTCStatisticsRecord(
                        id: "nan",
                        type: "outbound-rtp",
                        values: [
                            "kind": "audio",
                            "senderId": "exact-microphone-sender",
                            "mid": "mic-mid",
                            "trackIdentifier": "iphone-microphone",
                            "packetsSent": NSNumber(value: Double.nan),
                            "bytesSent": NSNumber(value: 1_000),
                        ]
                    ),
                ]
            ),
            (
                "overflowing bytes",
                [
                    WebRTCStatisticsRecord(
                        id: "overflow",
                        type: "outbound-rtp",
                        values: [
                            "kind": "audio",
                            "senderId": "exact-microphone-sender",
                            "mid": "mic-mid",
                            "trackIdentifier": "iphone-microphone",
                            "packetsSent": NSNumber(value: 10),
                            "bytesSent": NSNumber(value: UInt64.max),
                        ]
                    ),
                ]
            ),
            (
                "duplicate report identifier",
                [validOutbound, validOutbound]
            ),
            (
                "generic outbound mixed with exact identity",
                [
                    validOutbound,
                    WebRTCStatisticsRecord(
                        id: "generic",
                        type: "outbound-rtp",
                        values: [
                            "kind": "audio",
                            "packetsSent": NSNumber(value: 500),
                            "bytesSent": NSNumber(value: 50_000),
                        ]
                    ),
                ]
            ),
            (
                "missing exact linked source",
                [
                    WebRTCStatisticsRecord(
                        id: "missing-source",
                        type: "outbound-rtp",
                        values: [
                            "kind": "audio",
                            "senderId": "exact-microphone-sender",
                            "mid": "mic-mid",
                            "trackIdentifier": "iphone-microphone",
                            "mediaSourceId": "absent",
                            "packetsSent": NSNumber(value: 10),
                            "bytesSent": NSNumber(value: 1_000),
                        ]
                    ),
                ]
            ),
            (
                "linked source without exact track identity",
                [
                    WebRTCStatisticsRecord(
                        id: "unbound-source-outbound",
                        type: "outbound-rtp",
                        values: [
                            "kind": "audio",
                            "senderId": "exact-microphone-sender",
                            "mid": "mic-mid",
                            "trackIdentifier": "iphone-microphone",
                            "mediaSourceId": "unbound-source",
                            "packetsSent": NSNumber(value: 10),
                            "bytesSent": NSNumber(value: 1_000),
                        ]
                    ),
                    WebRTCStatisticsRecord(
                        id: "unbound-source",
                        type: "media-source",
                        values: [
                            "kind": "audio",
                            "totalAudioEnergy": NSNumber(value: 0.25),
                            "totalSamplesDuration":
                                NSNumber(value: 1.0),
                        ]
                    ),
                ]
            ),
            (
                "partial source totals",
                [
                    WebRTCStatisticsRecord(
                        id: "partial-outbound",
                        type: "outbound-rtp",
                        values: [
                            "kind": "audio",
                            "senderId": "exact-microphone-sender",
                            "mid": "mic-mid",
                            "trackIdentifier": "iphone-microphone",
                            "mediaSourceId": "partial-source",
                            "packetsSent": NSNumber(value: 10),
                            "bytesSent": NSNumber(value: 1_000),
                        ]
                    ),
                    WebRTCStatisticsRecord(
                        id: "partial-source",
                        type: "media-source",
                        values: [
                            "kind": "audio",
                            "trackIdentifier": "iphone-microphone",
                            "totalAudioEnergy": NSNumber(value: 0.25),
                        ]
                    ),
                ]
            ),
        ]

        for (name, records) in malformed {
            XCTAssertNil(
                WebRTCStatisticsParser.parseIPhoneMicrophoneSender(
                    records: records,
                    reportTimestampMicroseconds: 7_000_000,
                    expectedSenderID: "exact-microphone-sender",
                    expectedTrackID: "iphone-microphone",
                    expectedMID: "mic-mid"
                ),
                name
            )
        }
    }

    func testExactIPhoneMicrophoneSenderStatisticsRejectsEveryStaleAsyncStableIdentityAndReplacement() throws {
        let authorization = SenderStatisticsIdentity()
        let replacementAuthorization = SenderStatisticsIdentity()
        let authorizationIdentity = ObjectIdentifier(authorization)
        let captured = senderStatisticsValidation(
            authorizationIdentity: authorizationIdentity
        )
        let diagnostics = admittedIPhoneMicrophoneSenderDiagnostics()
        let initial = try XCTUnwrap(
            sampleIPhoneMicrophoneSenderStatistics(
                parsed: senderOutboundStatistics(
                    reportDate: Date(timeIntervalSince1970: 1_000)
                ),
                captured: captured,
                current: captured,
                diagnostics: diagnostics,
                callbackCompletedAt:
                    Date(timeIntervalSince1970: 1_000.1),
                currentTime:
                    Date(timeIntervalSince1970: 1_000.2)
            )
        )
        XCTAssertNotNil(initial.statistics)

        let nextParsed = senderOutboundStatistics(
            reportDate: Date(timeIntervalSince1970: 1_001),
            packetsSent: 51,
            bytesSent: 8_100,
            totalAudioEnergy: 0.26,
            totalSamplesDuration: 1.1
        )
        let stale: [(
            String,
            WebRTCIPhoneMicrophoneSenderStatisticsValidation?
        )] = [
            ("missing current capture", nil),
            (
                "peer epoch",
                senderStatisticsValidation(
                    peerEpoch: UUID(),
                    authorizationIdentity: authorizationIdentity
                )
            ),
            (
                "binding generation",
                senderStatisticsValidation(
                    bindingGeneration: 4,
                    authorizationIdentity: authorizationIdentity
                )
            ),
            (
                "negotiation epoch",
                senderStatisticsValidation(
                    negotiationEpoch: 6,
                    authorizationIdentity: authorizationIdentity
                )
            ),
            (
                "track generation",
                senderStatisticsValidation(
                    trackGeneration: 8,
                    authorizationIdentity: authorizationIdentity
                )
            ),
            (
                "microphone policy generation",
                senderStatisticsValidation(
                    microphonePolicyGeneration: 12,
                    authorizationIdentity: authorizationIdentity
                )
            ),
            (
                "native recording generation",
                senderStatisticsValidation(
                    recordingGeneration: 14,
                    authorizationIdentity: authorizationIdentity
                )
            ),
            (
                "sender stable identity",
                senderStatisticsValidation(
                    authorizationIdentity: authorizationIdentity,
                    senderID: "replacement-sender"
                )
            ),
            (
                "local track stable identity",
                senderStatisticsValidation(
                    authorizationIdentity: authorizationIdentity,
                    localTrackID: "replacement-track"
                )
            ),
            (
                "MID stable identity",
                senderStatisticsValidation(
                    authorizationIdentity: authorizationIdentity,
                    mid: "replacement-mid"
                )
            ),
            (
                "authorization identity",
                senderStatisticsValidation(
                    authorizationIdentity:
                        ObjectIdentifier(replacementAuthorization)
                )
            ),
        ]

        for (name, current) in stale {
            XCTAssertNil(
                sampleIPhoneMicrophoneSenderStatistics(
                    parsed: nextParsed,
                    captured: captured,
                    current: current,
                    diagnostics: diagnostics,
                    callbackCompletedAt:
                        Date(timeIntervalSince1970: 1_001.1),
                    currentTime:
                        Date(timeIntervalSince1970: 1_001.2),
                    previousBaseline: initial.baseline
                ),
                name
            )
        }

        XCTAssertNil(
            sampleIPhoneMicrophoneSenderStatistics(
                parsed: nextParsed,
                captured: captured,
                current: captured,
                diagnostics:
                    admittedIPhoneMicrophoneSenderDiagnostics(
                        transportIsHealthy: false
                    ),
                callbackCompletedAt:
                    Date(timeIntervalSince1970: 1_001.1),
                currentTime:
                    Date(timeIntervalSince1970: 1_001.2),
                previousBaseline: initial.baseline
            )
        )
    }

    func testExactIPhoneMicrophoneSenderStatisticsRejectsInvalidStaleAndFutureReportTimestamps() throws {
        let authorization = SenderStatisticsIdentity()
        let captured = senderStatisticsValidation(
            authorizationIdentity: ObjectIdentifier(authorization)
        )
        let callbackCompletedAt =
            Date(timeIntervalSince1970: 1_000)
        let currentTime = Date(timeIntervalSince1970: 1_000.1)
        let reportDate = Date(timeIntervalSince1970: 999.75)
        let freshParsed = senderOutboundStatistics(
            reportDate: reportDate
        )
        let fresh = try XCTUnwrap(
            sampleIPhoneMicrophoneSenderStatistics(
                parsed: freshParsed,
                captured: captured,
                current: captured,
                diagnostics:
                    admittedIPhoneMicrophoneSenderDiagnostics(),
                callbackCompletedAt: callbackCompletedAt,
                currentTime: currentTime
            )
        )
        let freshStatistics = try XCTUnwrap(fresh.statistics)
        XCTAssertEqual(
            freshStatistics.collectedAt.timeIntervalSince1970,
            reportDate.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        XCTAssertTrue(freshStatistics.sourceReportWasLinked)

        let invalidTimestamps = [
            Double.nan,
            Double.infinity,
            0,
            -1,
        ]
        for timestamp in invalidTimestamps {
            let invalid = WebRTCIPhoneMicrophoneOutboundStatistics(
                reportTimestampMicroseconds: timestamp,
                outboundRTPRecordIDs: ["exact-outbound"],
                packetsSent: 50,
                bytesSent: 8_000,
                totalAudioEnergy: 0.25,
                totalSamplesDuration: 1,
                sourceReportWasLinked: true
            )
            XCTAssertNil(
                sampleIPhoneMicrophoneSenderStatistics(
                    parsed: invalid,
                    captured: captured,
                    current: captured,
                    diagnostics:
                        admittedIPhoneMicrophoneSenderDiagnostics(),
                    callbackCompletedAt: callbackCompletedAt,
                    currentTime: currentTime
                )
            )
        }

        XCTAssertNil(
            sampleIPhoneMicrophoneSenderStatistics(
                parsed: senderOutboundStatistics(
                    reportDate:
                        Date(timeIntervalSince1970: 994.8)
                ),
                captured: captured,
                current: captured,
                diagnostics:
                    admittedIPhoneMicrophoneSenderDiagnostics(),
                callbackCompletedAt: callbackCompletedAt,
                currentTime: currentTime
            )
        )
        XCTAssertNil(
            sampleIPhoneMicrophoneSenderStatistics(
                parsed: senderOutboundStatistics(
                    reportDate:
                        Date(timeIntervalSince1970: 1_000.5)
                ),
                captured: captured,
                current: captured,
                diagnostics:
                    admittedIPhoneMicrophoneSenderDiagnostics(),
                callbackCompletedAt: callbackCompletedAt,
                currentTime: currentTime
            )
        )
        XCTAssertNil(
            sampleIPhoneMicrophoneSenderStatistics(
                parsed: freshParsed,
                captured: captured,
                current: captured,
                diagnostics:
                    admittedIPhoneMicrophoneSenderDiagnostics(),
                callbackCompletedAt: callbackCompletedAt,
                currentTime:
                    Date(timeIntervalSince1970: 1_005.1)
            )
        )
    }

    func testExactIPhoneMicrophoneSenderStatisticsRebaselinesCounterResetBeforePublishingAdvancement() throws {
        let authorization = SenderStatisticsIdentity()
        let captured = senderStatisticsValidation(
            authorizationIdentity: ObjectIdentifier(authorization)
        )
        let diagnostics = admittedIPhoneMicrophoneSenderDiagnostics()
        let initial = try XCTUnwrap(
            sampleIPhoneMicrophoneSenderStatistics(
                parsed: senderOutboundStatistics(
                    reportDate: Date(timeIntervalSince1970: 1_000),
                    outboundRTPRecordIDs: ["old-outbound"],
                    packetsSent: 100,
                    bytesSent: 10_000,
                    totalAudioEnergy: 1,
                    totalSamplesDuration: 2
                ),
                captured: captured,
                current: captured,
                diagnostics: diagnostics,
                callbackCompletedAt:
                    Date(timeIntervalSince1970: 1_000.1),
                currentTime:
                    Date(timeIntervalSince1970: 1_000.2)
            )
        )
        XCTAssertNotNil(initial.statistics)

        let reset = try XCTUnwrap(
            sampleIPhoneMicrophoneSenderStatistics(
                parsed: senderOutboundStatistics(
                    reportDate: Date(timeIntervalSince1970: 1_001),
                    outboundRTPRecordIDs: ["replacement-outbound"],
                    packetsSent: 1,
                    bytesSent: 100,
                    totalAudioEnergy: 0.01,
                    totalSamplesDuration: 0.02
                ),
                captured: captured,
                current: captured,
                diagnostics: diagnostics,
                callbackCompletedAt:
                    Date(timeIntervalSince1970: 1_001.1),
                currentTime:
                    Date(timeIntervalSince1970: 1_001.2),
                previousBaseline: initial.baseline
            )
        )
        XCTAssertNil(reset.statistics)
        XCTAssertTrue(reset.requiresAdvancingEvidence)
        XCTAssertEqual(reset.baseline.statistics.packetsSent, 1)

        let stagnant = try XCTUnwrap(
            sampleIPhoneMicrophoneSenderStatistics(
                parsed: senderOutboundStatistics(
                    reportDate: Date(timeIntervalSince1970: 1_002),
                    outboundRTPRecordIDs: ["replacement-outbound"],
                    packetsSent: 1,
                    bytesSent: 100,
                    totalAudioEnergy: 0.01,
                    totalSamplesDuration: 0.02
                ),
                captured: captured,
                current: captured,
                diagnostics: diagnostics,
                callbackCompletedAt:
                    Date(timeIntervalSince1970: 1_002.1),
                currentTime:
                    Date(timeIntervalSince1970: 1_002.2),
                previousBaseline: reset.baseline,
                requiresAdvancingEvidence:
                    reset.requiresAdvancingEvidence
            )
        )
        XCTAssertNil(stagnant.statistics)
        XCTAssertTrue(stagnant.requiresAdvancingEvidence)

        let advanced = try XCTUnwrap(
            sampleIPhoneMicrophoneSenderStatistics(
                parsed: senderOutboundStatistics(
                    reportDate: Date(timeIntervalSince1970: 1_003),
                    outboundRTPRecordIDs: ["replacement-outbound"],
                    packetsSent: 2,
                    bytesSent: 200,
                    totalAudioEnergy: 0.02,
                    totalSamplesDuration: 0.04
                ),
                captured: captured,
                current: captured,
                diagnostics: diagnostics,
                callbackCompletedAt:
                    Date(timeIntervalSince1970: 1_003.1),
                currentTime:
                    Date(timeIntervalSince1970: 1_003.2),
                previousBaseline: stagnant.baseline,
                requiresAdvancingEvidence:
                    stagnant.requiresAdvancingEvidence
            )
        )
        let advancedStatistics = try XCTUnwrap(advanced.statistics)
        XCTAssertEqual(advancedStatistics.packetsSent, 2)
        XCTAssertEqual(advancedStatistics.bytesSent, 200)
        XCTAssertFalse(advanced.requiresAdvancingEvidence)
    }

    func testPreDescriptionCandidateQueueFailsClosedAtItsBound() async throws {
        let viewer = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .viewer, iceServers: [])
        )
        let candidate = RemoteICECandidate(
            sdp: "candidate:1 1 UDP 1 192.0.2.1 50000 typ host",
            sdpMid: "0",
            sdpMLineIndex: 0
        )

        for _ in 0..<256 {
            try await viewer.handle(.candidate(candidate))
        }
        do {
            try await viewer.handle(.candidate(candidate))
            XCTFail("The 257th pre-description candidate must fail closed.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .pendingRemoteCandidateLimitExceeded(256))
        }
        do {
            try await viewer.handle(.candidate(candidate))
            XCTFail("Candidate overflow must terminate the transport.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .transportClosed)
        }
    }

    func testRestartRejectsAnUnansweredOffer() async throws {
        let host = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .host, iceServers: [])
        )
        try await host.start()

        do {
            try await host.restartICE()
            XCTFail("A second offer must not overlap the unanswered initial offer.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .iceRestartAlreadyInProgress)
        }

        await host.close(reason: .protocolError)
    }

    func testNewViewerAnswersAnOlderMonoOfferWithoutIntroducingStereoPolicy() async throws {
        let host = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .host, iceServers: [])
        )
        let viewer = try WebRTCPeer.makeHeadlessViewerForTesting(
            configuration: WebRTCTransportConfiguration(role: .viewer, iceServers: [])
        )
        defer {
            Task {
                await host.close(reason: .normal)
                await viewer.close(reason: .normal)
            }
        }

        let offerTask = Task<String?, Never> {
            for await event in host.events {
                if case .outboundSignal(.offer(let sdp)) = event {
                    return sdp
                }
            }
            return nil
        }
        try await host.start()
        let emittedOffer = await offerTask.value
        let productOffer = try XCTUnwrap(emittedOffer)
        let offerAudioSections = mediaSections(kind: "audio", in: productOffer)
        XCTAssertEqual(offerAudioSections.count, 2)
        assertHighFidelityOpusPolicy(in: offerAudioSections[0])
        XCTAssertTrue(offerAudioSections[0].contains("a=sendonly"))
        assertIPhoneMicrophoneOpusPolicy(in: offerAudioSections[1])
        XCTAssertTrue(offerAudioSections[1].contains("a=recvonly"))

        let oldOffer = productOffer.replacingOccurrences(
            of: ";stereo=1;sprop-stereo=1;maxaveragebitrate=192000",
            with: ""
        )
        XCTAssertNotEqual(productOffer, oldOffer)

        let answerTask = Task<String?, Never> {
            for await event in viewer.events {
                if case .outboundSignal(.answer(let sdp)) = event {
                    return sdp
                }
            }
            return nil
        }
        try await viewer.handle(.offer(sdp: oldOffer))
        let emittedAnswer = await answerTask.value
        let answer = try XCTUnwrap(emittedAnswer)
        let audioSections = mediaSections(kind: "audio", in: answer)

        XCTAssertEqual(audioSections.count, 2)
        XCTAssertFalse(audioSections[0].lowercased().contains("stereo=1"))
        XCTAssertFalse(audioSections[0].lowercased().contains("sprop-stereo=1"))
        XCTAssertFalse(audioSections[0].lowercased().contains("maxaveragebitrate="))
        assertIPhoneMicrophoneOpusPolicy(in: audioSections[1])
        XCTAssertTrue(
            audioSections[1].contains("a=sendonly")
                || audioSections[1].contains("a=inactive")
        )
    }

    func testHostViewerLoopbackNegotiatesControlsVideoAndCloses() async throws {
        let host = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .host, iceServers: [])
        )
        let viewer = try WebRTCPeer.makeHeadlessViewerForTesting(
            configuration: WebRTCTransportConfiguration(role: .viewer, iceServers: [])
        )
        let constructedReceiverIDValue =
            await host.iPhoneMicrophoneReceiverIDForTesting
        let constructedReceiverID = try XCTUnwrap(constructedReceiverIDValue)
        XCTAssertFalse(constructedReceiverID.isEmpty)
        XCTAssertNotEqual(
            constructedReceiverID,
            WebRTCRemoteAudioLane.iPhoneMicrophone.rawValue,
            "The logical microphone label must not replace the host-owned native receiver ID."
        )

        let recorder = LoopbackRecorder()
        let expectations = LoopbackExpectations()
        let secondAnswerDeliveryGate = SecondAnswerDeliveryGate()
        // The custom Mac viewer is a headless test sink. Production iOS owns RemoteIO playout;
        // this explicit pull keeps the codec proof independent of Mac audio hardware/CoreAudio.
        let headlessPlayout = Task {
            while !Task.isCancelled {
                _ = await viewer.pullHeadlessMacViewerAudioForTesting()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        let hostForwarder = Task {
            do {
                for await event in host.events {
                    for milestone in await recorder.observe(event, from: .host) {
                        expectations.fulfill(milestone)
                    }
                    if case .outboundSignal(let payload) = event {
                        for milestone in await recorder.recordEmitted(payload, from: .host) {
                            expectations.fulfill(milestone)
                        }
                        try await viewer.handle(payload)
                        for milestone in await recorder.recordDelivered(payload, from: .host) {
                            expectations.fulfill(milestone)
                        }
                    }
                }
            } catch {
                await recorder.recordForwardingError(error)
            }
            expectations.hostForwarderFinished.fulfill()
        }

        let viewerForwarder = Task {
            do {
                for await event in viewer.events {
                    let milestones = await recorder.observe(event, from: .viewer)
                    for milestone in milestones {
                        expectations.fulfill(milestone)
                    }
                    if case .outboundSignal(let payload) = event {
                        let emittedMilestones = await recorder.recordEmitted(
                            payload,
                            from: .viewer
                        )
                        for milestone in emittedMilestones {
                            expectations.fulfill(milestone)
                        }
                        if emittedMilestones.contains(.secondAnswerEmitted) {
                            await secondAnswerDeliveryGate.waitUntilReleased()
                        }
                        try await host.handle(payload)
                        for milestone in await recorder.recordDelivered(payload, from: .viewer) {
                            expectations.fulfill(milestone)
                        }
                    }
                }
            } catch {
                await recorder.recordForwardingError(error)
            }
            expectations.viewerForwarderFinished.fulfill()
        }

        defer {
            Task { await secondAnswerDeliveryGate.release() }
            headlessPlayout.cancel()
            hostForwarder.cancel()
            viewerForwarder.cancel()
        }

        try await host.start()

        await fulfillment(
            of: [
                expectations.hostConnected,
                expectations.viewerConnected,
                expectations.hostDataChannelOpen,
                expectations.viewerDataChannelOpen,
                expectations.directRoute,
                expectations.hostIPhoneMicrophoneTrack,
                expectations.remoteAudioTrack,
                expectations.remoteVideoTrack
            ],
            timeout: 10
        )

        let connectedSnapshot = await recorder.snapshot()
        if ProcessInfo.processInfo.environment["OPENSTEAMER_AUDIO_TEST_DIAGNOSTICS"] == "1",
           !connectedSnapshot.hasAllConnectionMilestones {
            print(
                "OPENSTEAMER_CONNECTION_FAILURE milestones=\(connectedSnapshot.milestones) "
                    + "emitted=\(connectedSnapshot.emitted) "
                    + "delivered=\(connectedSnapshot.delivered) "
                    + "forwardingErrors=\(connectedSnapshot.forwardingErrors)"
            )
        }
        guard connectedSnapshot.hasAllConnectionMilestones else {
            await host.close(reason: .protocolError)
            await fulfillment(
                of: [
                    expectations.hostForwarderFinished,
                    expectations.viewerForwarderFinished
                ],
                timeout: 3
            )
            return
        }

        let prospectiveCallChallenge = WebRTCMacHostedCallChallenge(
            sequence: 1,
            callEpochNonce: UUID()
        )
        try await viewer.requestMacHostedCallEvidenceIfTransportHealthy(
            challenge: prospectiveCallChallenge
        )
        await fulfillment(
            of: [expectations.macHostedCallChallengeReceived],
            timeout: 2
        )
        let receivedCallChallenges =
            await recorder.macHostedCallChallenges()
        XCTAssertEqual(receivedCallChallenges, [prospectiveCallChallenge])

        let receivedHostIPhoneMicrophoneTrack =
            await recorder.hostIPhoneMicrophoneTrack()
        let hostIPhoneMicrophoneTrack = try XCTUnwrap(
            receivedHostIPhoneMicrophoneTrack
        )
        XCTAssertEqual(
            hostIPhoneMicrophoneTrack.receiverID,
            constructedReceiverID
        )
        XCTAssertEqual(
            hostIPhoneMicrophoneTrack.logicalLane,
            .iPhoneMicrophone
        )
        XCTAssertFalse(hostIPhoneMicrophoneTrack.nativeTrackID.isEmpty)
        XCTAssertNotEqual(
            hostIPhoneMicrophoneTrack.nativeTrackID,
            hostIPhoneMicrophoneTrack.logicalLane.rawValue,
            "The logical lane label must remain distinct from the native track token."
        )
        XCTAssertFalse(
            hostIPhoneMicrophoneTrack.isEnabled,
            "The incoming iPhone microphone must remain disabled until peer-owned admission."
        )

        let initialMicrophonePublicationCount =
            await recorder.hostIPhoneMicrophoneTrackPublicationCount()
        XCTAssertEqual(initialMicrophonePublicationCount, 1)

        let consumedUnexpectedReceiver =
            await host.consumeIPhoneMicrophoneReceiverCallbackForTesting(
                receiverID: constructedReceiverID + "-unexpected"
            )
        XCTAssertTrue(consumedUnexpectedReceiver)
        XCTAssertFalse(
            hostIPhoneMicrophoneTrack.isEnabled,
            "A nonmatching host receiver must be rejected and remain muted."
        )

        let consumedDuplicateReceiver =
            await host.consumeIPhoneMicrophoneReceiverCallbackForTesting(
                receiverID: constructedReceiverID
            )
        XCTAssertTrue(consumedDuplicateReceiver)
        let proxyRepublishedDuplicate =
            await host.replayIPhoneMicrophoneReceiverCallbackForTesting()
        XCTAssertFalse(
            proxyRepublishedDuplicate,
            "The modern delegate proxy must emit one event per receiver ID."
        )
        let deduplicatedMicrophonePublicationCount =
            await recorder.hostIPhoneMicrophoneTrackPublicationCount()
        XCTAssertEqual(deduplicatedMicrophonePublicationCount, 1)
        XCTAssertFalse(hostIPhoneMicrophoneTrack.isEnabled)

        let staleTrackValue =
            await host.makeStaleIPhoneMicrophoneTrackForTesting()
        let staleIPhoneMicrophoneTrack = try XCTUnwrap(staleTrackValue)
        XCTAssertFalse(
            staleIPhoneMicrophoneTrack === hostIPhoneMicrophoneTrack
        )
        XCTAssertEqual(
            staleIPhoneMicrophoneTrack.receiverID,
            constructedReceiverID
        )
        XCTAssertEqual(
            staleIPhoneMicrophoneTrack.logicalLane,
            .iPhoneMicrophone
        )
        do {
            try await host.enableRemoteIPhoneMicrophonePlaybackIfTransportHealthy(
                staleIPhoneMicrophoneTrack
            )
            XCTFail("A non-current wrapper for the receiver must remain rejected.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .transportNotHealthy)
        }
        XCTAssertFalse(staleIPhoneMicrophoneTrack.isEnabled)
        XCTAssertFalse(hostIPhoneMicrophoneTrack.isEnabled)

        try await host.enableRemoteIPhoneMicrophonePlaybackIfTransportHealthy(
            hostIPhoneMicrophoneTrack
        )
        XCTAssertTrue(hostIPhoneMicrophoneTrack.isEnabled)

        let initialOffer = try XCTUnwrap(connectedSnapshot.hostOffers.first)
        let initialOfferAudioSections = mediaSections(
            kind: "audio",
            in: initialOffer
        )
        XCTAssertEqual(initialOfferAudioSections.count, 2)
        XCTAssertTrue(initialOfferAudioSections[0].contains("a=sendonly"))
        XCTAssertNotNil(
            initialOfferAudioSections[0].range(
                of: #"a=rtpmap:\d+ opus/48000/2"#,
                options: [.regularExpression, .caseInsensitive]
            ),
            "The send-only system-audio section must negotiate 48 kHz Opus."
        )
        assertHighFidelityOpusPolicy(in: initialOfferAudioSections[0])
        XCTAssertTrue(initialOfferAudioSections[1].contains("a=recvonly"))
        assertIPhoneMicrophoneOpusPolicy(in: initialOfferAudioSections[1])

        let initialAnswer = try XCTUnwrap(connectedSnapshot.viewerAnswers.first)
        let initialAnswerAudioSections = mediaSections(
            kind: "audio",
            in: initialAnswer
        )
        XCTAssertEqual(initialAnswerAudioSections.count, 2)
        XCTAssertTrue(initialAnswerAudioSections[0].contains("a=recvonly"))
        assertHighFidelityOpusPolicy(in: initialAnswerAudioSections[0])
        XCTAssertTrue(
            initialAnswerAudioSections[1].contains("a=sendonly")
                || initialAnswerAudioSections[1].contains("a=inactive")
        )
        assertIPhoneMicrophoneOpusPolicy(in: initialAnswerAudioSections[1])

        let initialMicrophoneSenderState =
            await viewer.iPhoneMicrophoneSenderStateForTesting()
        XCTAssertEqual(
            initialMicrophoneSenderState.bindingNegotiationEpoch,
            initialMicrophoneSenderState.currentNegotiationEpoch
        )
        XCTAssertTrue(initialMicrophoneSenderState.senderOwnsLocalTrack)
        XCTAssertGreaterThanOrEqual(
            initialMicrophoneSenderState.rawProcessingStoredResultCount,
            2
        )
        XCTAssertEqual(
            initialMicrophoneSenderState.rawProcessingAppliedResultCount,
            0
        )
        XCTAssertEqual(
            initialMicrophoneSenderState.lastRawProcessingResultCodeRawValue,
            1,
            "A disabled negotiated sender must retain raw options as Stored."
        )
        XCTAssertEqual(
            initialMicrophoneSenderState.nativeApprovedRecordingGeneration,
            0
        )
        XCTAssertGreaterThanOrEqual(
            initialMicrophoneSenderState.rawProcessingRequestCount,
            2
        )
        XCTAssertFalse(
            initialMicrophoneSenderState
                .rawProcessingWasEverRequestedWithoutCurrentSender,
            "Raw processing must only be requested after the offer-selected sender owns the track."
        )

        let admittedMicrophoneProcessingState =
            try await viewer.debugEnableIPhoneMicrophoneTrackAfterRawProcessingForTesting()
        let viewerMicrophoneTrackEnabled =
            await viewer.isLocalIPhoneMicrophoneTrackEnabledForTesting
        XCTAssertTrue(viewerMicrophoneTrackEnabled)

        let admittedMicrophoneSenderState =
            await viewer.iPhoneMicrophoneSenderStateForTesting()
        XCTAssertGreaterThan(
            admittedMicrophoneSenderState.rawProcessingRequestCount,
            initialMicrophoneSenderState.rawProcessingRequestCount,
            "The active exact sender must issue an additional raw processing request after activation."
        )
        XCTAssertGreaterThan(
            admittedMicrophoneSenderState.rawProcessingStoredResultCount,
            initialMicrophoneSenderState.rawProcessingStoredResultCount,
            "The active exact sender's post-activation raw processing request must be accepted and stored."
        )
        XCTAssertEqual(
            admittedMicrophoneSenderState.lastRawProcessingResultCodeRawValue,
            1
        )
        let admittedRecordingGeneration = try XCTUnwrap(
            admittedMicrophoneSenderState.nativeRecordingGeneration
        )
        XCTAssertGreaterThan(admittedRecordingGeneration, 0)
        XCTAssertEqual(
            admittedMicrophoneSenderState.nativeApprovedRecordingGeneration,
            admittedRecordingGeneration
        )
        XCTAssertEqual(
            admittedMicrophoneSenderState.nativeDeliveryCallbackCount,
            initialMicrophoneSenderState.nativeDeliveryCallbackCount,
            "The headless sender activation/raw-proof phase must deliver no source callbacks."
        )
        XCTAssertEqual(
            admittedMicrophoneSenderState.nativeDeliveredFrameCount,
            initialMicrophoneSenderState.nativeDeliveredFrameCount,
            "The headless sender activation/raw-proof phase must deliver no source PCM."
        )

        for (name, component) in [
            ("AEC", admittedMicrophoneProcessingState.echoCancellation),
            ("NS", admittedMicrophoneProcessingState.noiseSuppression),
            ("AGC", admittedMicrophoneProcessingState.autoGainControl),
            ("HPF", admittedMicrophoneProcessingState.highPassFilter)
        ] {
            XCTAssertEqual(
                component.requestedEnabled,
                false,
                "\(name) must be explicitly disabled before microphone admission."
            )
            XCTAssertFalse(
                component.softwareActive,
                "\(name) software processing must be inactive before microphone admission."
            )
            XCTAssertFalse(
                component.platformActive,
                "\(name) platform processing must be inactive before microphone admission."
            )
        }

        await viewer.debugDisableIPhoneMicrophoneTrackForTesting()
        let viewerMicrophoneTrackDisabled =
            await viewer.isLocalIPhoneMicrophoneTrackEnabledForTesting
        XCTAssertFalse(viewerMicrophoneTrackDisabled)
        let disabledMicrophoneSenderState =
            await viewer.iPhoneMicrophoneSenderStateForTesting()
        XCTAssertEqual(
            disabledMicrophoneSenderState.nativeApprovedRecordingGeneration,
            0
        )

        let senderEncodings = await host.audioSenderEncodingParametersForTesting()
        XCTAssertFalse(senderEncodings.isEmpty)
        for encoding in senderEncodings {
            XCTAssertEqual(encoding.maximumBitrateBps, 192_000)
            XCTAssertNil(encoding.minimumBitrateBps)
        }
        XCTAssertNotNil(host.externalAudioCapturer)

        let revokedAudioAuthorization = WebRTCAudioAuthorization()
        revokedAudioAuthorization.revoke()
        do {
            try await host.enableSystemAudioIfTransportHealthy(
                authorization: revokedAudioAuthorization
            )
            XCTFail("A revoked audio authorization must not expose system audio.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .audioAuthorizationRevoked)
        }

        let receivedAudioTrack = await recorder.remoteAudioTrack()
        let remoteAudioTrack = try XCTUnwrap(receivedAudioTrack)
        XCTAssertEqual(remoteAudioTrack.logicalLane, .systemAudio)
        XCTAssertEqual(
            remoteAudioTrack.nativeTrackID,
            WebRTCAudioTrackIdentifiers.systemAudio
        )
        XCTAssertFalse(remoteAudioTrack.receiverID.isEmpty)
        XCTAssertFalse(
            remoteAudioTrack.isEnabled,
            "A newly received native audio track must remain muted until lifecycle health passes."
        )
        remoteAudioTrack.setEnabled(true)
        XCTAssertTrue(remoteAudioTrack.isEnabled)
        let audioAuthorization = WebRTCAudioAuthorization()
        try await host.enableSystemAudioIfTransportHealthy(
            authorization: audioAuthorization
        )
        XCTAssertTrue(audioAuthorization.isValid)
        let callEvidenceAuthorization =
            WebRTCMacHostedCallEvidenceAuthorization(
                callEpochNonce:
                    prospectiveCallChallenge.callEpochNonce
            )
        try await host.updateMacHostedCallEvidenceIfTransportHealthy(
            state: .preflightArmed,
            challenge: prospectiveCallChallenge,
            nativeObservationSequence: 1,
            authorization: audioAuthorization,
            evidenceAuthorization: callEvidenceAuthorization
        )
        await fulfillment(
            of: [expectations.macHostedCallPreflightArmedReceived],
            timeout: 2
        )
        let allReceivedCallEvidence =
            await recorder.macHostedCallEvidence()
        let receivedCallEvidence = try XCTUnwrap(
            allReceivedCallEvidence.last
        )
        XCTAssertTrue(receivedCallEvidence.matches(prospectiveCallChallenge))
        XCTAssertEqual(receivedCallEvidence.state, .preflightArmed)
        let audioEnabledBeforeShow = await host.isSystemAudioEnabledForTesting
        XCTAssertTrue(audioEnabledBeforeShow)

        let audioCapturer = try XCTUnwrap(host.externalAudioCapturer)
        let readyAudioDiagnostics = audioCapturer.diagnosticsForTesting()
        XCTAssertTrue(readyAudioDiagnostics.playerIsReady, "\(readyAudioDiagnostics)")
        XCTAssertTrue(readyAudioDiagnostics.usesCustomStereoDevice, "\(readyAudioDiagnostics)")
        XCTAssertTrue(readyAudioDiagnostics.customDeviceRecording, "\(readyAudioDiagnostics)")
        XCTAssertEqual(
            readyAudioDiagnostics.admInputCallbackCount,
            0,
            "No source callback means no synthetic ADM callback or silence; \(readyAudioDiagnostics)"
        )
        XCTAssertEqual(readyAudioDiagnostics.admInputSampleRate, 48_000)
        XCTAssertEqual(readyAudioDiagnostics.admInputChannelCount, 2)
        XCTAssertEqual(readyAudioDiagnostics.admInputCommonFormat, .pcmFormatInt16)
        XCTAssertEqual(readyAudioDiagnostics.admInputIsInterleaved, true)
        XCTAssertEqual(readyAudioDiagnostics.customDeviceDeliveryFailures, 0)

        let processingState = await host.audioProcessingStateForTesting()
        XCTAssertTrue(processingState.hasAudioProcessingModule)
        for (name, component) in [
            ("AEC", processingState.echoCancellation),
            ("NS", processingState.noiseSuppression),
            ("AGC", processingState.autoGainControl),
            ("HPF", processingState.highPassFilter)
        ] {
            XCTAssertEqual(
                component.requestedEnabled,
                false,
                "\(name) must be explicitly disabled by the raw system-audio track."
            )
            XCTAssertFalse(
                component.softwareActive,
                "\(name) software processing must not touch system audio."
            )
            XCTAssertFalse(
                component.platformActive,
                "\(name) platform processing must not touch system audio."
            )
        }

        // Right-only PCM fails both the old mono input and a fake dual-mono SDP patch: channel one
        // must arrive with energy while channel zero remains quiet after an actual Opus round trip.
        // Each source probe is 100 ms / 4,800 frames after conversion. Requiring materially more
        // than 2,400 decoded qualifying frames catches the pinned native direct-input bug that
        // consumed only `frameCount` Int16 elements (half of interleaved stereo) per callback.
        let requiredSustainedAudioFrames = 3_840
        let rightOnlyProbe = DecodedAudioProbe(
            mode: .rightOnly,
            requiredQualifyingFrames: requiredSustainedAudioFrames
        )
        let rightOnlyRenderer = WebRTCAudioPCMRenderer { buffer in
            rightOnlyProbe.observe(buffer)
        }
        remoteAudioTrack.addRendererForTesting(rightOnlyRenderer)
        let rightOnlyLongTone = try makeStereoToneSampleBuffer(
            frameCount: 4_800,
            leftAmplitude: 0,
            rightAmplitude: 0.20
        )
        audioCapturer.capture(sampleBuffer: rightOnlyLongTone)
        await fulfillment(of: [rightOnlyProbe.receivedAudio], timeout: 5)
        remoteAudioTrack.removeRendererForTesting(rightOnlyRenderer)
        let rightOnlyMeasurement = rightOnlyProbe.measurement
        let captureDiagnostics = audioCapturer.diagnosticsForTesting()
        let rightOnlyFailureContext = "\(captureDiagnostics); "
            + rightOnlyProbe.diagnosticSummary
        XCTAssertEqual(rightOnlyMeasurement.channelCount, 2, rightOnlyFailureContext)
        XCTAssertGreaterThanOrEqual(
            rightOnlyMeasurement.frameCount,
            requiredSustainedAudioFrames,
            rightOnlyFailureContext
        )
        XCTAssertGreaterThan(rightOnlyMeasurement.rightRMS, 0.05, rightOnlyFailureContext)
        XCTAssertLessThan(
            rightOnlyMeasurement.leftRMS,
            rightOnlyMeasurement.rightRMS * 0.15,
            "Right-only input must not become dual mono; \(rightOnlyFailureContext)"
        )

        // Anti-phase stereo cancels to silence in any mono fold-down. Surviving equal energy with
        // strongly negative correlation proves two independent encoded and decoded channels.
        let antiPhaseProbe = DecodedAudioProbe(
            mode: .antiPhase,
            requiredQualifyingFrames: requiredSustainedAudioFrames
        )
        let antiPhaseRenderer = WebRTCAudioPCMRenderer { buffer in
            antiPhaseProbe.observe(buffer)
        }
        remoteAudioTrack.addRendererForTesting(antiPhaseRenderer)
        audioCapturer.reset()
        let antiPhaseStereoTone = try makeStereoFloatToneSampleBuffer(
            frameCount: 4_410,
            sampleRate: 44_100,
            leftAmplitude: 0.35,
            rightAmplitude: -0.35,
            leftFrequency: 1_000,
            rightFrequency: 1_000
        )
        audioCapturer.capture(sampleBuffer: antiPhaseStereoTone)
        await fulfillment(of: [antiPhaseProbe.receivedAudio], timeout: 5)
        remoteAudioTrack.removeRendererForTesting(antiPhaseRenderer)
        let antiPhaseMeasurement = antiPhaseProbe.measurement
        let antiPhaseFailureContext = "\(audioCapturer.diagnosticsForTesting()); "
            + antiPhaseProbe.diagnosticSummary
        if ProcessInfo.processInfo.environment["OPENSTEAMER_AUDIO_TEST_DIAGNOSTICS"] == "1" {
            print("OPENSTEAMER_AUDIO_RIGHT_ONLY \(rightOnlyFailureContext)")
            print("OPENSTEAMER_AUDIO_ANTI_PHASE \(antiPhaseFailureContext)")
            let hostStatistics = await host.statisticsSnapshot()
            let viewerStatistics = await viewer.statisticsSnapshot()
            print(
                "OPENSTEAMER_AUDIO_SDP "
                    + initialOfferAudioSections[0]
                        .replacingOccurrences(of: "\r\n", with: " | ")
            )
            print("OPENSTEAMER_AUDIO_HOST_STATS \(hostStatistics)")
            print("OPENSTEAMER_AUDIO_VIEWER_STATS \(viewerStatistics)")
        }
        XCTAssertEqual(antiPhaseMeasurement.channelCount, 2, antiPhaseFailureContext)
        XCTAssertGreaterThan(antiPhaseMeasurement.leftRMS, 0.10, antiPhaseFailureContext)
        XCTAssertGreaterThan(antiPhaseMeasurement.rightRMS, 0.10, antiPhaseFailureContext)
        XCTAssertLessThan(antiPhaseMeasurement.correlation, -0.85, antiPhaseFailureContext)
        XCTAssertEqual(
            antiPhaseMeasurement.leftRMS,
            antiPhaseMeasurement.rightRMS,
            accuracy: 0.03,
            antiPhaseFailureContext
        )

        // Recognize an explicit stereo preamble before arming the evidence window. A delayed tail
        // from the preceding anti-phase probe therefore cannot become frame zero. Once armed, keep
        // every decoded batch: unlike DecodedAudioProbe, this window cannot hide a bad interval by
        // discarding silence or batches that fail a shape predicate before measurement.
        let synchronizationPreamble = DeterministicStereoWaveform.synchronizationPreamble()
        let oracleWaveform = DeterministicStereoWaveform(frameCount: 38_400)
        XCTAssertGreaterThan(
            oracleWaveform.peakMagnitude,
            0.65,
            "The production proof must exercise music-like high-level PCM."
        )
        XCTAssertLessThan(
            oracleWaveform.peakMagnitude,
            0.85,
            "The expected production waveform itself must remain unclipped."
        )
        XCTAssertGreaterThan(
            oracleWaveform.spectralAmplitude(frequency: 8_003, leftChannel: true),
            0.035,
            "The source must retain a measurable left-channel pilot above telephone bandwidth."
        )
        XCTAssertGreaterThan(
            oracleWaveform.spectralAmplitude(frequency: 11_003, leftChannel: false),
            0.035,
            "The source must retain a measurable right-channel pilot above telephone bandwidth."
        )
        // Keep one extra 100 ms source block after the waveform. Native Opus/WebRTC decoding is
        // delayed relative to the source, so without this guard a fixed-size receive window loses
        // the waveform's real tail and can only test an interior slice.
        let trailingGuardFrames = 4_800
        let unfilteredProbe = UnfilteredDecodedAudioProbe(
            requiredEvidenceFrames: oracleWaveform.frameCount + trailingGuardFrames,
            synchronizationPreamble: synchronizationPreamble
        )
        let unfilteredRenderer = WebRTCAudioPCMRenderer { buffer in
            unfilteredProbe.observe(buffer)
        }
        remoteAudioTrack.addRendererForTesting(unfilteredRenderer)
        audioCapturer.reset()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(
            unfilteredProbe.beginPostPreambleCapture(),
            "Residual decoded audio must not be mistaken for the synchronization preamble."
        )
        audioCapturer.capture(
            sampleBuffer: try makeStereoOracleSampleBuffer(
                waveform: synchronizationPreamble,
                range: 0..<synchronizationPreamble.frameCount
            )
        )
        await fulfillment(
            of: [unfilteredProbe.recognizedSynchronizationPreamble],
            timeout: 5
        )
        audioCapturer.reset()
        XCTAssertTrue(
            unfilteredProbe.beginPostPreambleCapture(),
            "The decoded waveform window must not arm before its unique preamble is recognized."
        )
        for chunkStart in stride(from: 0, to: oracleWaveform.frameCount, by: 4_800) {
            let chunkEnd = min(chunkStart + 4_800, oracleWaveform.frameCount)
            audioCapturer.capture(
                sampleBuffer: try makeStereoOracleSampleBuffer(
                    waveform: oracleWaveform,
                    range: chunkStart..<chunkEnd
                )
            )
        }
        audioCapturer.capture(
            sampleBuffer: try makeStereoOracleSampleBuffer(
                waveform: oracleWaveform,
                range: 0..<trailingGuardFrames
            )
        )
        await fulfillment(of: [unfilteredProbe.receivedWindow], timeout: 8)
        remoteAudioTrack.removeRendererForTesting(unfilteredRenderer)

        let decodedWindow = unfilteredProbe.window
        let genuineWaveformReport = AudioWaveformOracle.evaluate(
            expected: oracleWaveform,
            decoded: decodedWindow
        )
        if ProcessInfo.processInfo.environment["OPENSTEAMER_AUDIO_TEST_DIAGNOSTICS"] == "1" {
            print(
                "OPENSTEAMER_AUDIO_UNFILTERED \(unfilteredProbe.diagnosticSummary); "
                    + "\(genuineWaveformReport)"
            )
        }
        XCTAssertTrue(
            genuineWaveformReport.violations.isEmpty,
            "The production Opus/WebRTC round trip must preserve one continuous, unfiltered "
                + "stereo waveform; \(unfilteredProbe.diagnosticSummary); "
                + "\(genuineWaveformReport)"
        )

        // These mutations run against the PCM decoded by the genuine transport. They keep the
        // codec's normal lossiness in the baseline while proving each critical failure mode is
        // observable by the oracle instead of merely asserting that the happy path passes.
        let requiredMutationViolations: [String: AudioWaveformViolation] = [
            "leading edge silence": .dropout,
            "trailing edge silence": .dropout,
            "periodic silence": .dropout,
            "misaligned short dropout": .dropout,
            "repeated decoded blocks": .temporalDiscontinuity,
            "dropped decoded samples": .temporalDiscontinuity,
            "misaligned corruption burst": .temporalDiscontinuity,
            "moderate broadband distortion": .fidelity,
            "telephone-band low-pass": .fidelity,
            "linear gain distortion": .gainDistortion,
            "clipping": .clipping,
            "dual-mono channel corruption": .channelCorruption
        ]
        let mutations = decodedWindow.criticalMutationCases(
            alignmentOffset: genuineWaveformReport.alignmentOffsetFrames,
            expectedFrameCount: oracleWaveform.frameCount
        )
        XCTAssertEqual(
            mutations.count,
            requiredMutationViolations.count,
            "Removing a negative control must fail the regression suite."
        )
        XCTAssertEqual(
            Set(mutations.map(\.name)),
            Set(requiredMutationViolations.keys),
            "Mutation names are an independent contract owned by this test."
        )
        for mutation in mutations {
            let requiredViolation = try XCTUnwrap(requiredMutationViolations[mutation.name])
            let report = AudioWaveformOracle.evaluate(
                expected: oracleWaveform,
                decoded: mutation.window
            )
            if ProcessInfo.processInfo.environment["OPENSTEAMER_AUDIO_TEST_DIAGNOSTICS"] == "1" {
                print("OPENSTEAMER_AUDIO_MUTATION \(mutation.name): \(report)")
            }
            XCTAssertTrue(
                report.violations.contains(requiredViolation),
                "The oracle accepted \(mutation.name), or rejected it for the wrong reason: "
                    + "\(report)"
            )
        }

        var audioTargetBitrate: Double?
        for _ in 0..<100 where audioTargetBitrate == nil {
            audioTargetBitrate = await host.statisticsSnapshot().outboundAudio?.targetBitrate
            if audioTargetBitrate == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        XCTAssertEqual(
            try XCTUnwrap(audioTargetBitrate),
            192_000,
            accuracy: 1,
            "Native outbound stats must reflect the product's 192 kbps Opus policy."
        )

        // Source-clock delivery is synchronous and queue-free: the finite probe callbacks produce
        // only source-backed frames, with no application timer continuing after the input ends.
        let drainedAudioDiagnostics = audioCapturer.diagnosticsForTesting()
        XCTAssertEqual(
            drainedAudioDiagnostics.runtime.phase,
            "direct",
            "The custom input path must remain source-clock direct; "
                + "\(drainedAudioDiagnostics)"
        )
        XCTAssertEqual(
            drainedAudioDiagnostics.runtime.queuedFrames,
            0,
            "Source-clock delivery must not create an application PCM queue; \(drainedAudioDiagnostics)"
        )
        XCTAssertGreaterThanOrEqual(
            drainedAudioDiagnostics.customDeviceDeliveredFrames,
            57_600,
            "All probes, the synchronization preamble, and the tail guard must reach WebRTC; "
                + "\(drainedAudioDiagnostics)"
        )
        XCTAssertGreaterThanOrEqual(drainedAudioDiagnostics.admInputCallbackCount, 12)
        XCTAssertEqual(drainedAudioDiagnostics.customDeviceRejectedFrames, 0)
        XCTAssertEqual(drainedAudioDiagnostics.customDeviceNativeDeliveryErrors, 0)
        XCTAssertEqual(drainedAudioDiagnostics.customDeviceRenderInvocations, 12)
        XCTAssertEqual(drainedAudioDiagnostics.customDeviceRenderCopiedFrames, 57_600)
        XCTAssertEqual(
            drainedAudioDiagnostics.customDeviceRenderCopiedSampleElements,
            115_200
        )
        XCTAssertEqual(drainedAudioDiagnostics.customDeviceRenderNotInvoked, 0)
        XCTAssertEqual(drainedAudioDiagnostics.customDeviceRenderMultipleInvocations, 0)
        XCTAssertEqual(drainedAudioDiagnostics.customDeviceRenderValidationFailures, 0)
        XCTAssertEqual(drainedAudioDiagnostics.customDevicePrefilledInputDeliveries, 0)
        XCTAssertGreaterThanOrEqual(drainedAudioDiagnostics.customDeviceTimestampResets, 1)
        XCTAssertEqual(drainedAudioDiagnostics.runtime.underruns, 0)
        XCTAssertEqual(drainedAudioDiagnostics.runtime.rebuffers, 0)
        XCTAssertEqual(drainedAudioDiagnostics.runtime.overflowDrops, 0)
        XCTAssertEqual(drainedAudioDiagnostics.customDeviceDeliveryFailures, 0)

        let showID = try await viewer.setScreenVisible(true)
        await fulfillment(of: [expectations.showRequestReceived], timeout: 3)
        let showSnapshot = await recorder.snapshot()
        XCTAssertEqual(showSnapshot.controlRequests, [
            WebRTCControlRequest(id: showID, command: .showScreen)
        ])

        do {
            try await host.acknowledgeControlRequest(id: showID, state: .active)
            XCTFail("A Show/Active transition must require a capture authorization.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .controlAuthorizationRequired)
        }
        let revokedAuthorization = WebRTCControlAuthorization()
        revokedAuthorization.revoke()
        do {
            try await host.acknowledgeActiveControlRequestIfTransportHealthy(
                id: showID,
                authorization: revokedAuthorization
            )
            XCTFail("A revoked capture authorization must not emit an Active acknowledgement.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .controlAuthorizationRevoked)
        }
        let closedForwardingAuthorization = WebRTCControlAuthorization()
        do {
            try await host.acknowledgeActiveControlRequestIfTransportHealthy(
                id: showID,
                authorization: closedForwardingAuthorization,
                finalAuthorizationCheck: { false }
            )
            XCTFail("A closed forwarding generation must not emit an Active acknowledgement.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .controlAuthorizationRevoked)
        }
        XCTAssertTrue(closedForwardingAuthorization.isValid)
        let inputCapability = WebRTCInputCapability(
            inputSessionID: UUID(),
            screenRequestID: showID,
            supportsPrimaryDrag: true
        )
        let hostInputAuthorization = WebRTCInputAuthorization()
        try await host.acknowledgeActiveControlRequestIfTransportHealthy(
            id: showID,
            authorization: WebRTCControlAuthorization(),
            inputCapability: inputCapability,
            inputAuthorization: hostInputAuthorization
        )
        await fulfillment(of: [expectations.showAcknowledged], timeout: 3)
        let activeSnapshot = await recorder.snapshot()
        XCTAssertEqual(activeSnapshot.controlAcknowledgements, [
            WebRTCControlAcknowledgement(
                id: showID,
                state: .active,
                inputCapability: inputCapability
            )
        ])
        let viewerInputAuthorization = try XCTUnwrap(
            activeSnapshot.viewerInputAuthorizations.first
        )
        XCTAssertTrue(viewerInputAuthorization.isValid)
        XCTAssertTrue(hostInputAuthorization.isValid)
        XCTAssertFalse(viewerInputAuthorization === hostInputAuthorization)

        let inputID = try await viewer.sendInput(
            .primaryDrag(
                start: .init(x: 0.25, y: 0.75),
                end: .init(x: 0.75, y: 0.25)
            ),
            viewerVideoSize: .init(width: 450, height: 981),
            capability: inputCapability,
            authorization: viewerInputAuthorization
        )
        await fulfillment(of: [expectations.inputRequestReceived], timeout: 3)
        let inputRequestSnapshot = await recorder.snapshot()
        XCTAssertEqual(inputRequestSnapshot.inputRequests, [
            WebRTCInputRequest(
                id: inputID,
                screenRequestID: showID,
                inputSessionID: inputCapability.inputSessionID,
                action: .primaryDrag(
                    start: .init(x: 0.25, y: 0.75),
                    end: .init(x: 0.75, y: 0.25)
                ),
                viewerVideoSize: .init(width: 450, height: 981)
            )
        ])
        XCTAssertTrue(
            inputRequestSnapshot.hostInputAuthorizations.first === hostInputAuthorization
        )
        try await host.sendInputFeedback(
            for: inputID,
            result: .accepted,
            focus: .editable(generation: 1, secure: false)
        )
        await fulfillment(of: [expectations.inputFeedbackReceived], timeout: 3)
        let inputFeedbackSnapshot = await recorder.snapshot()
        XCTAssertEqual(inputFeedbackSnapshot.inputFeedback, [
            WebRTCInputFeedback(
                id: inputID,
                screenRequestID: showID,
                inputSessionID: inputCapability.inputSessionID,
                result: .accepted,
                focus: .editable(generation: 1, secure: false)
            )
        ])

        let pixelBuffer = try makePixelBuffer(width: 64, height: 64)
        guard let capturer = host.externalVideoCapturer else {
            XCTFail("The host did not expose its external screen capturer.")
            await host.close(reason: .protocolError)
            return
        }
        capturer.capture(
            pixelBuffer: pixelBuffer,
            timestampNanoseconds: Int64(clamping: DispatchTime.now().uptimeNanoseconds)
        )

        let hideID = try await viewer.setScreenVisible(false)
        do {
            _ = try await viewer.sendInput(.backspace(focusGeneration: 1))
            XCTFail("Sending Hide must synchronously revoke the viewer input capability.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .inputUnavailable)
        }
        await fulfillment(of: [expectations.hideRequestReceived], timeout: 3)
        XCTAssertFalse(viewerInputAuthorization.isValid)
        XCTAssertFalse(hostInputAuthorization.isValid)
        XCTAssertEqual(hideID, showID + 1)

        do {
            try await host.acknowledgeControlRequest(id: showID, state: .active)
            XCTFail("A superseded acknowledgement must be rejected as stale.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .staleControlRequest(showID))
        }

        try await host.acknowledgeControlRequest(id: hideID, state: .inactive)
        await fulfillment(of: [expectations.hideAcknowledged], timeout: 3)
        let hideSnapshot = await recorder.snapshot()
        XCTAssertEqual(hideSnapshot.controlRequests.last, .init(id: hideID, command: .hideScreen))
        XCTAssertEqual(
            hideSnapshot.controlAcknowledgements.last,
            .init(id: hideID, state: .inactive)
        )
        XCTAssertTrue(
            audioAuthorization.isValid,
            "Hiding video must not revoke the independent system-audio session."
        )
        let audioEnabledAfterHide = await host.isSystemAudioEnabledForTesting
        XCTAssertTrue(audioEnabledAfterHide)

        // Repeating an identical host acknowledgement is safe. The wire replay is suppressed at
        // the viewer, while a contradictory acknowledgement for the same ID fails closed.
        try await host.acknowledgeControlRequest(id: hideID, state: .inactive)
        try await Task.sleep(for: .milliseconds(100))
        let duplicateSnapshot = await recorder.snapshot()
        XCTAssertEqual(duplicateSnapshot.controlAcknowledgements.count, 2)
        do {
            try await host.acknowledgeControlRequest(id: hideID, state: .active)
            XCTFail("A contradictory acknowledgement must be rejected.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .conflictingControlAcknowledgement(hideID))
        }

        let keyFrameID = try await viewer.requestControl(.requestKeyFrame)
        await fulfillment(of: [expectations.keyFrameRequestReceived], timeout: 3)
        XCTAssertEqual(keyFrameID, hideID + 1)
        try await host.acknowledgeControlRequest(id: keyFrameID, state: .inactive)
        await fulfillment(of: [expectations.keyFrameAcknowledged], timeout: 3)

        let inactiveProcessingComponent = WebRTCAudioProcessingComponentSnapshot(
            requestedEnabled: false,
            softwareActive: false,
            platformActive: false
        )
        await viewer.debugSetIPhoneMicrophoneAudioProcessingStateForTesting(
            WebRTCAudioProcessingSnapshot(
                hasAudioProcessingModule: true,
                echoCancellation: WebRTCAudioProcessingComponentSnapshot(
                    requestedEnabled: false,
                    softwareActive: true,
                    platformActive: false
                ),
                noiseSuppression: inactiveProcessingComponent,
                autoGainControl: inactiveProcessingComponent,
                highPassFilter: inactiveProcessingComponent
            )
        )
        do {
            _ = try await viewer.debugEnableIPhoneMicrophoneTrackAfterRawProcessingForTesting(
                maximumAttempts: 0
            )
            XCTFail("Active processing must fail-close iPhone microphone admission.")
        } catch let error as WebRTCTransportError {
            switch error {
            case .nativeFailure:
                break
            default:
                XCTFail("Unexpected processing-admission error: \(error)")
            }
        } catch {
            XCTFail("Unexpected processing-admission error: \(error)")
        }
        let processingFailureLeftTrackEnabled =
            await viewer.isLocalIPhoneMicrophoneTrackEnabledForTesting
        XCTAssertFalse(processingFailureLeftTrackEnabled)
        await viewer.debugSetIPhoneMicrophoneAudioProcessingStateForTesting(
            nil
        )

        await viewer.debugSetIPhoneMicrophoneAudioProcessingStateForTesting(
            WebRTCAudioProcessingSnapshot(
                hasAudioProcessingModule: true,
                echoCancellation: WebRTCAudioProcessingComponentSnapshot(
                    requestedEnabled: false,
                    softwareActive: true,
                    platformActive: false
                ),
                noiseSuppression: inactiveProcessingComponent,
                autoGainControl: inactiveProcessingComponent,
                highPassFilter: inactiveProcessingComponent
            )
        )
        let delayedAdmissionBaseline =
            await viewer.iPhoneMicrophoneSenderStateForTesting()
        let delayedRawProcessingAdmission = Task {
            try await viewer
                .debugEnableIPhoneMicrophoneTrackAfterRawProcessingForTesting(
                    maximumAttempts: 100,
                    rawProcessingMaximumAttempts: nil
                )
        }
        var observedDelayedRawProcessingRequest = false
        for _ in 0..<100 {
            let senderState =
                await viewer.iPhoneMicrophoneSenderStateForTesting()
            if senderState.rawProcessingRequestCount
                > delayedAdmissionBaseline.rawProcessingRequestCount {
                observedDelayedRawProcessingRequest = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(observedDelayedRawProcessingRequest)
        try await Task.sleep(for: .milliseconds(350))
        await viewer.debugSetIPhoneMicrophoneAudioProcessingStateForTesting(
            WebRTCAudioProcessingSnapshot(
                hasAudioProcessingModule: true,
                echoCancellation: inactiveProcessingComponent,
                noiseSuppression: inactiveProcessingComponent,
                autoGainControl: inactiveProcessingComponent,
                highPassFilter: inactiveProcessingComponent
            )
        )
        let delayedProcessingState = try await delayedRawProcessingAdmission.value
        XCTAssertFalse(delayedProcessingState.echoCancellation.softwareActive)
        await viewer.debugDisableIPhoneMicrophoneTrackForTesting()
        await viewer.debugSetIPhoneMicrophoneAudioProcessingStateForTesting(
            nil
        )

        let preRestartMicrophoneSenderState =
            await viewer.iPhoneMicrophoneSenderStateForTesting()
        let rawProcessingRequestsBeforeRestart =
            preRestartMicrophoneSenderState.rawProcessingRequestCount
        let storedRawProcessingResultsBeforeRestart =
            preRestartMicrophoneSenderState.rawProcessingStoredResultCount

        await viewer.debugMakeIPhoneMicrophoneSenderBindingStaleForTesting()
        let staleBindingState =
            await viewer.iPhoneMicrophoneSenderStateForTesting()
        XCTAssertNotEqual(
            staleBindingState.bindingNegotiationEpoch,
            staleBindingState.currentNegotiationEpoch
        )
        do {
            _ = try await viewer.debugEnableIPhoneMicrophoneTrackAfterRawProcessingForTesting(
                maximumAttempts: 0
            )
            XCTFail("A stale negotiated microphone sender must be rejected.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .transportNotHealthy)
        } catch {
            XCTFail("Unexpected stale-sender error: \(error)")
        }
        let staleSenderLeftTrackEnabled =
            await viewer.isLocalIPhoneMicrophoneTrackEnabledForTesting
        XCTAssertFalse(staleSenderLeftTrackEnabled)

        await viewer.debugClearIPhoneMicrophoneSenderBindingForTesting()
        do {
            _ = try await viewer.debugEnableIPhoneMicrophoneTrackAfterRawProcessingForTesting(
                maximumAttempts: 0
            )
            XCTFail("A missing negotiated microphone sender must be rejected.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .transportNotHealthy)
        } catch {
            XCTFail("Unexpected missing-sender error: \(error)")
        }
        let missingSenderLeftTrackEnabled =
            await viewer.isLocalIPhoneMicrophoneTrackEnabledForTesting
        XCTAssertFalse(missingSenderLeftTrackEnabled)

        try await host.restartICE()
        XCTAssertFalse(
            hostIPhoneMicrophoneTrack.isEnabled,
            "ICE restart must fail-close host-side iPhone microphone playout."
        )
        XCTAssertFalse(
            audioAuthorization.isValid,
            "ICE uncertainty must synchronously revoke system-audio capture."
        )
        let audioEnabledDuringRestart = await host.isSystemAudioEnabledForTesting
        XCTAssertFalse(audioEnabledDuringRestart)
        await fulfillment(
            of: [
                expectations.secondOfferEmitted,
                expectations.secondAnswerEmitted
            ],
            timeout: 10
        )

        do {
            try await host.enableRemoteIPhoneMicrophonePlaybackIfTransportHealthy(
                hostIPhoneMicrophoneTrack
            )
            XCTFail(
                "The incoming iPhone microphone must not be admitted before the restart answer is applied."
            )
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .transportNotHealthy)
        }
        XCTAssertFalse(hostIPhoneMicrophoneTrack.isEnabled)

        // The data channel can cross the WSS answer path. Prove that a privacy-monotone Hide
        // received before the second answer is applied cannot be acknowledged as recovered.
        let recoveryProbeID = try await viewer.setScreenVisible(false)
        XCTAssertEqual(recoveryProbeID, keyFrameID + 1)
        await fulfillment(of: [expectations.recoveryProbeRequestReceived], timeout: 3)
        do {
            try await host.acknowledgeControlRequestIfTransportHealthy(
                id: recoveryProbeID,
                state: .inactive,
                authorization: WebRTCControlAuthorization()
            )
            XCTFail("The recovery probe must not be acknowledged before the answer is applied.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .transportNotHealthy)
        }

        await secondAnswerDeliveryGate.release()
        await fulfillment(of: [expectations.secondAnswerDelivered], timeout: 10)
        let recoveredMicrophoneSenderState =
            await viewer.iPhoneMicrophoneSenderStateForTesting()
        XCTAssertEqual(
            recoveredMicrophoneSenderState.bindingNegotiationEpoch,
            recoveredMicrophoneSenderState.currentNegotiationEpoch
        )
        XCTAssertTrue(recoveredMicrophoneSenderState.senderOwnsLocalTrack)
        XCTAssertNotEqual(
            recoveredMicrophoneSenderState.bindingNegotiationEpoch,
            initialMicrophoneSenderState.bindingNegotiationEpoch
        )
        XCTAssertGreaterThanOrEqual(
            recoveredMicrophoneSenderState.rawProcessingRequestCount,
            rawProcessingRequestsBeforeRestart + 2
        )
        XCTAssertGreaterThanOrEqual(
            recoveredMicrophoneSenderState.rawProcessingStoredResultCount,
            storedRawProcessingResultsBeforeRestart + 2
        )
        XCTAssertEqual(
            recoveredMicrophoneSenderState.lastRawProcessingResultCodeRawValue,
            1,
            "The replacement disabled sender must again retain pre-admission raw requests as Stored."
        )
        XCTAssertFalse(
            recoveredMicrophoneSenderState
                .rawProcessingWasEverRequestedWithoutCurrentSender,
            "ICE renegotiation must reapply raw processing only after sender attachment."
        )

        let restartMicrophonePublicationCount =
            await recorder.hostIPhoneMicrophoneTrackPublicationCount()
        XCTAssertEqual(
            restartMicrophonePublicationCount,
            1,
            "ICE renegotiation must not republish the unchanged microphone receiver."
        )
        XCTAssertFalse(
            hostIPhoneMicrophoneTrack.isEnabled,
            "Answer installation must not implicitly reopen microphone playout."
        )

        let restartSnapshot = await recorder.snapshot()
        XCTAssertEqual(restartSnapshot.hostOffers.count, 2)
        XCTAssertEqual(restartSnapshot.viewerAnswers.count, 2)
        for description in restartSnapshot.hostOffers + restartSnapshot.viewerAnswers {
            let restartAudioSections = mediaSections(
                kind: "audio",
                in: description
            )
            XCTAssertEqual(restartAudioSections.count, 2)
            assertHighFidelityOpusPolicy(in: restartAudioSections[0])
            assertIPhoneMicrophoneOpusPolicy(in: restartAudioSections[1])
        }
        let firstOfferFragments = ICEUsernameFragmentParser.fragments(
            inSessionDescription: restartSnapshot.hostOffers[0]
        )
        let secondOfferFragments = ICEUsernameFragmentParser.fragments(
            inSessionDescription: restartSnapshot.hostOffers[1]
        )
        let firstAnswerFragments = ICEUsernameFragmentParser.fragments(
            inSessionDescription: restartSnapshot.viewerAnswers[0]
        )
        let secondAnswerFragments = ICEUsernameFragmentParser.fragments(
            inSessionDescription: restartSnapshot.viewerAnswers[1]
        )
        XCTAssertFalse(firstOfferFragments.isEmpty)
        XCTAssertFalse(firstAnswerFragments.isEmpty)
        XCTAssertNotEqual(firstOfferFragments, secondOfferFragments)
        XCTAssertNotEqual(firstAnswerFragments, secondAnswerFragments)
        XCTAssertTrue(firstOfferFragments.isDisjoint(with: secondOfferFragments))
        XCTAssertTrue(firstAnswerFragments.isDisjoint(with: secondAnswerFragments))

        let oldViewerCandidate = try XCTUnwrap(
            restartSnapshot.viewerCandidates.first(where: {
                $0.usernameFragment.map {
                    firstAnswerFragments.contains($0) && !secondAnswerFragments.contains($0)
                } == true
            })
        )
        let oldHostCandidate = try XCTUnwrap(
            restartSnapshot.hostCandidates.first(where: {
                $0.usernameFragment.map {
                    firstOfferFragments.contains($0) && !secondOfferFragments.contains($0)
                } == true
            })
        )
        // A delayed first-generation trickle candidate must be ignored after the second SDP is
        // installed instead of reaching native WebRTC and terminating the recovered session.
        try await host.handle(.candidate(oldViewerCandidate))
        try await viewer.handle(.candidate(oldHostCandidate))

        try await host.acknowledgeControlRequestIfTransportHealthy(
            id: recoveryProbeID,
            state: .inactive,
            authorization: WebRTCControlAuthorization()
        )
        await fulfillment(of: [expectations.recoveryProbeAcknowledged], timeout: 3)

        XCTAssertFalse(hostIPhoneMicrophoneTrack.isEnabled)
        try await host.enableRemoteIPhoneMicrophonePlaybackIfTransportHealthy(
            hostIPhoneMicrophoneTrack
        )
        XCTAssertTrue(hostIPhoneMicrophoneTrack.isEnabled)

        let consumedRecoveredDuplicate =
            await host.consumeIPhoneMicrophoneReceiverCallbackForTesting(
                receiverID: constructedReceiverID
            )
        XCTAssertTrue(consumedRecoveredDuplicate)
        XCTAssertTrue(
            hostIPhoneMicrophoneTrack.isEnabled,
            "Peer-level receiver-ID dedupe must preserve the admitted current gate."
        )

        let proxyRepublishedRecoveredDuplicate =
            await host.replayIPhoneMicrophoneReceiverCallbackForTesting()
        XCTAssertFalse(proxyRepublishedRecoveredDuplicate)
        XCTAssertTrue(
            hostIPhoneMicrophoneTrack.isEnabled,
            "A duplicate native callback must not disable an admitted receiver."
        )
        let recoveredMicrophonePublicationCount =
            await recorder.hostIPhoneMicrophoneTrackPublicationCount()
        XCTAssertEqual(recoveredMicrophonePublicationCount, 1)

        let recoveredAudioAuthorization = WebRTCAudioAuthorization()
        try await host.enableSystemAudioIfTransportHealthy(
            authorization: recoveredAudioAuthorization
        )
        let recoveredAudioEnabled = await host.isSystemAudioEnabledForTesting
        XCTAssertTrue(recoveredAudioEnabled)

        let recoveredShowID = try await viewer.setScreenVisible(true)
        XCTAssertEqual(recoveredShowID, recoveryProbeID + 1)
        await fulfillment(of: [expectations.postRestartShowRequestReceived], timeout: 3)
        try await host.acknowledgeActiveControlRequestIfTransportHealthy(
            id: recoveredShowID,
            authorization: WebRTCControlAuthorization()
        )
        await fulfillment(of: [expectations.postRestartShowAcknowledged], timeout: 3)

        capturer.capture(
            pixelBuffer: pixelBuffer,
            timestampNanoseconds: Int64(clamping: DispatchTime.now().uptimeNanoseconds)
        )

        let statistics = await host.statisticsSnapshot()
        XCTAssertEqual(statistics.route?.kind, .direct)

        let beforeClose = await recorder.snapshot()
        XCTAssertEqual(beforeClose.emitted.host.offers, 2)
        XCTAssertEqual(beforeClose.emitted.viewer.answers, 2)
        XCTAssertEqual(beforeClose.emitted.host.iceRestartRequests, 0)
        XCTAssertEqual(beforeClose.emitted.viewer.iceRestartRequests, 0)
        XCTAssertGreaterThan(beforeClose.emitted.host.candidates, 0)
        XCTAssertGreaterThan(beforeClose.emitted.viewer.candidates, 0)
        XCTAssertTrue(beforeClose.hostCandidates.allSatisfy { $0.usernameFragment != nil })
        XCTAssertTrue(beforeClose.viewerCandidates.allSatisfy { $0.usernameFragment != nil })
        XCTAssertTrue(beforeClose.forwardingErrors.isEmpty, beforeClose.forwardingErrors.joined(separator: "\n"))

        await host.close()
        await fulfillment(
            of: [
                expectations.hostForwarderFinished,
                expectations.viewerForwarderFinished
            ],
            timeout: 5
        )
        XCTAssertFalse(
            remoteAudioTrack.isEnabled,
            "Closing the transport must synchronously stop remote audio rendering."
        )
        XCTAssertFalse(hostIPhoneMicrophoneTrack.isEnabled)
        XCTAssertFalse(recoveredAudioAuthorization.isValid)

        let finalSnapshot = await recorder.snapshot()
        XCTAssertEqual(finalSnapshot.emitted.host.ends, 1)
        XCTAssertEqual(finalSnapshot.emitted, finalSnapshot.delivered)
        XCTAssertTrue(finalSnapshot.forwardingErrors.isEmpty, finalSnapshot.forwardingErrors.joined(separator: "\n"))
    }
}

/// Suspends the second answer so restart-generation ordering can be asserted deterministically.
private actor SecondAnswerDeliveryGate {
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

/// Identifies which in-process peer emitted a recorded event.
private enum LoopbackSide: Sendable {
    case host
    case viewer
}

/// Semantic outcomes required before the end-to-end loopback oracle may pass.
private enum LoopbackMilestone: Hashable, Sendable {
    case hostConnected
    case viewerConnected
    case hostDataChannelOpen
    case viewerDataChannelOpen
    case directRoute
    case hostIPhoneMicrophoneTrack
    case remoteAudioTrack
    case remoteTrack
    case inputRequestReceived
    case inputFeedbackReceived
    case showRequestReceived
    case hideRequestReceived
    case keyFrameRequestReceived
    case showAcknowledged
    case hideAcknowledged
    case keyFrameAcknowledged
    case secondOfferEmitted
    case secondAnswerEmitted
    case secondAnswerDelivered
    case recoveryProbeRequestReceived
    case recoveryProbeAcknowledged
    case postRestartShowRequestReceived
    case postRestartShowAcknowledged
    case macHostedCallChallengeReceived
    case macHostedCallPreflightArmedReceived
}

/// Per-kind signaling counts used to detect duplicates, omissions, or restart leakage.
private struct SignalCounts: Equatable, Sendable {
    var offers = 0
    var answers = 0
    var candidates = 0
    var ends = 0
    var controls = 0
    var identities = 0
    var iceRestartRequests = 0

    mutating func record(_ payload: RemoteSignalPayload) {
        switch payload {
        case .offer: offers += 1
        case .answer: answers += 1
        case .candidate: candidates += 1
        case .end: ends += 1
        case .control: controls += 1
        case .identity: identities += 1
        case .iceRestartRequest: iceRestartRequests += 1
        }
    }
}

/// Signaling counts split by host and viewer direction.
private struct DirectionalSignalCounts: Equatable, Sendable {
    var host = SignalCounts()
    var viewer = SignalCounts()

    mutating func record(_ payload: RemoteSignalPayload, from side: LoopbackSide) {
        switch side {
        case .host: host.record(payload)
        case .viewer: viewer.record(payload)
        }
    }
}

/// Lock-consistent observation of milestones, signaling, routes, and failures.
private struct LoopbackSnapshot: Sendable {
    let milestones: Set<LoopbackMilestone>
    let emitted: DirectionalSignalCounts
    let delivered: DirectionalSignalCounts
    let forwardingErrors: [String]
    let controlRequests: [WebRTCControlRequest]
    let controlAcknowledgements: [WebRTCControlAcknowledgement]
    let viewerInputAuthorizations: [WebRTCInputAuthorization]
    let inputRequests: [WebRTCInputRequest]
    let hostInputAuthorizations: [WebRTCInputAuthorization]
    let inputFeedback: [WebRTCInputFeedback]
    let hostOffers: [String]
    let viewerAnswers: [String]
    let hostCandidates: [RemoteICECandidate]
    let viewerCandidates: [RemoteICECandidate]

    var hasAllConnectionMilestones: Bool {
        milestones.isSuperset(of: [
            .hostConnected,
            .viewerConnected,
            .hostDataChannelOpen,
            .viewerDataChannelOpen,
            .directRoute,
            .hostIPhoneMicrophoneTrack,
            .remoteAudioTrack,
            .remoteTrack
        ])
    }

}

/// Serializes cross-peer events and exposes deterministic milestone snapshots to the test.
private actor LoopbackRecorder {
    private var milestones: Set<LoopbackMilestone> = []
    private var emitted = DirectionalSignalCounts()
    private var delivered = DirectionalSignalCounts()
    private var forwardingErrors: [String] = []
    private var retainedHostIPhoneMicrophoneTrack: WebRTCRemoteAudioTrack?
    private var hostIPhoneMicrophoneTrackPublicationCountStorage = 0
    private var retainedRemoteAudioTrack: WebRTCRemoteAudioTrack?
    private var retainedRemoteTrack: WebRTCRemoteVideoTrack?
    private var controlRequests: [WebRTCControlRequest] = []
    private var controlAcknowledgements: [WebRTCControlAcknowledgement] = []
    private var viewerInputAuthorizations: [WebRTCInputAuthorization] = []
    private var inputRequests: [WebRTCInputRequest] = []
    private var hostInputAuthorizations: [WebRTCInputAuthorization] = []
    private var inputFeedback: [WebRTCInputFeedback] = []
    private var hostOffers: [String] = []
    private var viewerAnswers: [String] = []
    private var hostCandidates: [RemoteICECandidate] = []
    private var viewerCandidates: [RemoteICECandidate] = []
    private var receivedMacHostedCallChallenges:
        [WebRTCMacHostedCallChallenge] = []
    private var receivedMacHostedCallEvidence:
        [WebRTCMacHostedCallEvidence] = []

    func observe(
        _ event: WebRTCTransportEvent,
        from side: LoopbackSide
    ) -> [LoopbackMilestone] {
        var observed: [LoopbackMilestone] = []

        switch event {
        case .peerStateChanged(.connected):
            observed.append(side == .host ? .hostConnected : .viewerConnected)
        case .dataChannelStateChanged(.open):
            observed.append(
                side == .host
                    ? .hostDataChannelOpen
                    : .viewerDataChannelOpen
            )
        case .routeChanged(let route) where route.kind == .direct:
            observed.append(.directRoute)
        case .remoteAudioTrack(let track):
            if side == .host {
                hostIPhoneMicrophoneTrackPublicationCountStorage += 1
                retainedHostIPhoneMicrophoneTrack = track
                observed.append(.hostIPhoneMicrophoneTrack)
            } else {
                retainedRemoteAudioTrack = track
                observed.append(.remoteAudioTrack)
            }
        case .remoteVideoTrack(let track) where side == .viewer:
            retainedRemoteTrack = track
            observed.append(.remoteTrack)
        case .controlRequestReceived(let request) where side == .host:
            controlRequests.append(request)
            switch request.command {
            case .showScreen:
                observed.append(
                    controlRequests.filter { $0.command == .showScreen }.count == 1
                        ? .showRequestReceived
                        : .postRestartShowRequestReceived
                )
            case .hideScreen:
                observed.append(
                    controlRequests.filter { $0.command == .hideScreen }.count == 1
                        ? .hideRequestReceived
                        : .recoveryProbeRequestReceived
                )
            case .requestKeyFrame: observed.append(.keyFrameRequestReceived)
            }
        case .controlAcknowledgementReceived(
            let acknowledgement,
            inputAuthorization: let inputAuthorization
        ) where side == .viewer:
            controlAcknowledgements.append(acknowledgement)
            if let inputAuthorization {
                viewerInputAuthorizations.append(inputAuthorization)
            }
            switch controlRequests.first(where: { $0.id == acknowledgement.id })?.command {
            case .showScreen:
                observed.append(
                    controlAcknowledgements.filter { acknowledgement in
                        controlRequests.first(where: { $0.id == acknowledgement.id })?.command
                            == .showScreen
                    }.count == 1 ? .showAcknowledged : .postRestartShowAcknowledged
                )
            case .hideScreen:
                observed.append(
                    controlAcknowledgements.filter { acknowledgement in
                        controlRequests.first(where: { $0.id == acknowledgement.id })?.command
                            == .hideScreen
                    }.count == 1 ? .hideAcknowledged : .recoveryProbeAcknowledged
                )
            case .requestKeyFrame: observed.append(.keyFrameAcknowledged)
            case nil: break
            }
        case .inputRequestReceived(
            let request,
            authorization: let authorization
        ) where side == .host:
            inputRequests.append(request)
            hostInputAuthorizations.append(authorization)
            observed.append(.inputRequestReceived)
        case .inputFeedbackReceived(let feedback) where side == .viewer:
            inputFeedback.append(feedback)
            observed.append(.inputFeedbackReceived)
        case .macHostedCallChallengeReceived(let challenge)
            where side == .host:
            receivedMacHostedCallChallenges.append(challenge)
            observed.append(.macHostedCallChallengeReceived)
        case .macHostedCallEvidenceChanged(let evidence?)
            where side == .viewer:
            receivedMacHostedCallEvidence.append(evidence)
            if evidence.state == .preflightArmed {
                observed.append(.macHostedCallPreflightArmedReceived)
            }
        default:
            break
        }

        return observed.filter { milestones.insert($0).inserted }
    }

    func recordEmitted(
        _ payload: RemoteSignalPayload,
        from side: LoopbackSide
    ) -> [LoopbackMilestone] {
        emitted.record(payload, from: side)
        switch (side, payload) {
        case (.host, .offer(let sdp)):
            hostOffers.append(sdp)
        case (.viewer, .answer(let sdp)):
            viewerAnswers.append(sdp)
        case (.host, .candidate(let candidate)):
            hostCandidates.append(candidate)
        case (.viewer, .candidate(let candidate)):
            viewerCandidates.append(candidate)
        default:
            break
        }
        var observed: [LoopbackMilestone] = []
        if side == .host, emitted.host.offers == 2 {
            observed.append(.secondOfferEmitted)
        }
        if side == .viewer, emitted.viewer.answers == 2 {
            observed.append(.secondAnswerEmitted)
        }
        return observed.filter { milestones.insert($0).inserted }
    }

    func recordDelivered(
        _ payload: RemoteSignalPayload,
        from side: LoopbackSide
    ) -> [LoopbackMilestone] {
        delivered.record(payload, from: side)
        var observed: [LoopbackMilestone] = []
        if side == .viewer, delivered.viewer.answers == 2,
           case .answer = payload {
            observed.append(.secondAnswerDelivered)
        }
        return observed.filter { milestones.insert($0).inserted }
    }

    func recordForwardingError(_ error: any Error) {
        forwardingErrors.append(String(describing: error))
    }

    func hostIPhoneMicrophoneTrack() -> WebRTCRemoteAudioTrack? {
        retainedHostIPhoneMicrophoneTrack
    }

    func hostIPhoneMicrophoneTrackPublicationCount() -> Int {
        hostIPhoneMicrophoneTrackPublicationCountStorage
    }

    func remoteAudioTrack() -> WebRTCRemoteAudioTrack? {
        retainedRemoteAudioTrack
    }

    func macHostedCallChallenges() -> [WebRTCMacHostedCallChallenge] {
        receivedMacHostedCallChallenges
    }

    func macHostedCallEvidence() -> [WebRTCMacHostedCallEvidence] {
        receivedMacHostedCallEvidence
    }

    func snapshot() -> LoopbackSnapshot {
        LoopbackSnapshot(
            milestones: milestones,
            emitted: emitted,
            delivered: delivered,
            forwardingErrors: forwardingErrors,
            controlRequests: controlRequests,
            controlAcknowledgements: controlAcknowledgements,
            viewerInputAuthorizations: viewerInputAuthorizations,
            inputRequests: inputRequests,
            hostInputAuthorizations: hostInputAuthorizations,
            inputFeedback: inputFeedback,
            hostOffers: hostOffers,
            viewerAnswers: viewerAnswers,
            hostCandidates: hostCandidates,
            viewerCandidates: viewerCandidates
        )
    }
}

/// XCTest expectations corresponding to externally observable loopback milestones.
private final class LoopbackExpectations: @unchecked Sendable {
    let hostConnected = XCTestExpectation(description: "host connected")
    let viewerConnected = XCTestExpectation(description: "viewer connected")
    let hostDataChannelOpen = XCTestExpectation(
        description: "host data channel opened"
    )
    let viewerDataChannelOpen = XCTestExpectation(description: "viewer data channel opened")
    let directRoute = XCTestExpectation(description: "ICE selected a direct route")
    let hostIPhoneMicrophoneTrack = XCTestExpectation(
        description: "host received the iPhone microphone track"
    )
    let remoteAudioTrack = XCTestExpectation(description: "viewer received the remote audio track")
    let remoteVideoTrack = XCTestExpectation(description: "viewer received the remote video track")
    let inputRequestReceived = XCTestExpectation(description: "host received remote input")
    let inputFeedbackReceived = XCTestExpectation(description: "viewer received input feedback")
    let showRequestReceived = XCTestExpectation(description: "host received Show request")
    let hideRequestReceived = XCTestExpectation(description: "host received Hide request")
    let keyFrameRequestReceived = XCTestExpectation(description: "host received key-frame request")
    let showAcknowledged = XCTestExpectation(description: "viewer received active acknowledgement")
    let hideAcknowledged = XCTestExpectation(description: "viewer received inactive acknowledgement")
    let keyFrameAcknowledged = XCTestExpectation(description: "viewer received key-frame acknowledgement")
    let secondOfferEmitted = XCTestExpectation(description: "host emitted a second ICE offer")
    let secondAnswerEmitted = XCTestExpectation(description: "viewer emitted a second ICE answer")
    let secondAnswerDelivered = XCTestExpectation(
        description: "host applied the second ICE answer"
    )
    let recoveryProbeRequestReceived = XCTestExpectation(
        description: "host received the post-answer Hide liveness probe"
    )
    let recoveryProbeAcknowledged = XCTestExpectation(
        description: "viewer received the probe's inactive acknowledgement"
    )
    let postRestartShowRequestReceived = XCTestExpectation(
        description: "host received a fresh Show request after restart"
    )
    let postRestartShowAcknowledged = XCTestExpectation(
        description: "viewer received a fresh active acknowledgement after restart"
    )
    let macHostedCallChallengeReceived = XCTestExpectation(
        description: "host received prospective call challenge"
    )
    let macHostedCallPreflightArmedReceived = XCTestExpectation(
        description: "viewer received preflight-armed evidence"
    )
    let hostForwarderFinished = XCTestExpectation(description: "host forwarder finished")
    let viewerForwarderFinished = XCTestExpectation(description: "viewer forwarder finished")

    func fulfill(_ milestone: LoopbackMilestone) {
        switch milestone {
        case .hostConnected: hostConnected.fulfill()
        case .viewerConnected: viewerConnected.fulfill()
        case .hostDataChannelOpen: hostDataChannelOpen.fulfill()
        case .viewerDataChannelOpen: viewerDataChannelOpen.fulfill()
        case .directRoute: directRoute.fulfill()
        case .hostIPhoneMicrophoneTrack: hostIPhoneMicrophoneTrack.fulfill()
        case .remoteAudioTrack: remoteAudioTrack.fulfill()
        case .remoteTrack: remoteVideoTrack.fulfill()
        case .inputRequestReceived: inputRequestReceived.fulfill()
        case .inputFeedbackReceived: inputFeedbackReceived.fulfill()
        case .showRequestReceived: showRequestReceived.fulfill()
        case .hideRequestReceived: hideRequestReceived.fulfill()
        case .keyFrameRequestReceived: keyFrameRequestReceived.fulfill()
        case .showAcknowledged: showAcknowledged.fulfill()
        case .hideAcknowledged: hideAcknowledged.fulfill()
        case .keyFrameAcknowledged: keyFrameAcknowledged.fulfill()
        case .secondOfferEmitted: secondOfferEmitted.fulfill()
        case .secondAnswerEmitted: secondAnswerEmitted.fulfill()
        case .secondAnswerDelivered: secondAnswerDelivered.fulfill()
        case .recoveryProbeRequestReceived: recoveryProbeRequestReceived.fulfill()
        case .recoveryProbeAcknowledged: recoveryProbeAcknowledged.fulfill()
        case .postRestartShowRequestReceived: postRestartShowRequestReceived.fulfill()
        case .postRestartShowAcknowledged: postRestartShowAcknowledged.fulfill()
        case .macHostedCallChallengeReceived:
            macHostedCallChallengeReceived.fulfill()
        case .macHostedCallPreflightArmedReceived:
            macHostedCallPreflightArmedReceived.fulfill()
        }
    }
}

private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
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
        throw PixelBufferTestError.creationFailed(status)
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
        memset(
            baseAddress,
            0x33,
            CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
        )
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    return pixelBuffer
}

private func mediaSection(kind: String, in sdp: String) -> String? {
    let lines = sdp
        .replacingOccurrences(of: "\r\n", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    guard let start = lines.firstIndex(where: { $0.hasPrefix("m=\(kind) ") }) else {
        return nil
    }
    let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("m=") })
        ?? lines.endIndex
    return lines[start..<end].joined(separator: "\n")
}

private func mediaSections(kind: String, in sdp: String) -> [String] {
    let lines = sdp
        .replacingOccurrences(of: "\r\n", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    let starts = lines.indices.filter { lines[$0].hasPrefix("m=\(kind) ") }
    return starts.enumerated().map { index, start in
        let end = index + 1 < starts.count ? starts[index + 1] : lines.endIndex
        return lines[start..<end].joined(separator: "\n")
    }
}

private func assertHighFidelityOpusPolicy(
    in audioSection: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(
        audioSection.lowercased().contains(
            "stereo=1;sprop-stereo=1;maxaveragebitrate=192000"
        ),
        "The negotiated Opus fmtp must carry the complete high-fidelity policy.\n\(audioSection)",
        file: file,
        line: line
    )
}

private func assertIPhoneMicrophoneOpusPolicy(
    in audioSection: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let lowercased = audioSection.lowercased()
    XCTAssertTrue(
        lowercased.contains("stereo=0"),
        "The iPhone microphone must negotiate mono Opus.\n\(audioSection)",
        file: file,
        line: line
    )
    XCTAssertTrue(
        lowercased.contains("sprop-stereo=0"),
        file: file,
        line: line
    )
    XCTAssertFalse(
        lowercased.contains("maxaveragebitrate=192000"),
        file: file,
        line: line
    )
}

/// Minimal decoded-PCM measurement used by focused stereo loopback assertions.
private struct DecodedAudioMeasurement: Sendable {
    let channelCount: Int
    let frameCount: Int
    let leftRMS: Double
    let rightRMS: Double
    let leftPeak: Double
    let rightPeak: Double
    let correlation: Double

    static let zero = DecodedAudioMeasurement(
        channelCount: 0,
        frameCount: 0,
        leftRMS: 0,
        rightRMS: 0,
        leftPeak: 0,
        rightPeak: 0,
        correlation: 0
    )
}

/// Thread-safe PCM sink that recognizes deterministic channel-specific loopback challenges.
private final class DecodedAudioProbe: @unchecked Sendable {
    /// The channel relationship encoded by the active challenge.
    enum Mode: Sendable {
        case rightOnly
        case antiPhase
    }

    let receivedAudio = XCTestExpectation(
        description: "viewer decoded qualifying two-channel PCM from the host"
    )

    /// One decoded callback converted to channel metrics.
    private struct Batch {
        let channelCount: Int
        let frameCount: Int
        let leftEnergy: Double
        let rightEnergy: Double
        let crossEnergy: Double
        let leftPeak: Double
        let rightPeak: Double

        var leftRMS: Double { sqrt(leftEnergy / Double(frameCount)) }
        var rightRMS: Double { sqrt(rightEnergy / Double(frameCount)) }
        var correlation: Double {
            let denominator = sqrt(leftEnergy * rightEnergy)
            return denominator > 0 ? crossEnergy / denominator : 0
        }
    }

    private let mode: Mode
    private let requiredQualifyingFrames: Int
    private let lock = NSLock()
    private var didReceiveAudio = false
    private var callbackCount = 0
    private var observedFormats: Set<String> = []
    private var channelCount = 0
    private var qualifyingFrames = 0
    private var leftEnergy = 0.0
    private var rightEnergy = 0.0
    private var crossEnergy = 0.0
    private var leftPeak = 0.0
    private var rightPeak = 0.0

    init(mode: Mode, requiredQualifyingFrames: Int) {
        precondition(requiredQualifyingFrames > 0)
        self.mode = mode
        self.requiredQualifyingFrames = requiredQualifyingFrames
    }

    var measurement: DecodedAudioMeasurement {
        lock.lock()
        defer { lock.unlock() }
        guard qualifyingFrames > 0 else { return .zero }
        let denominator = sqrt(leftEnergy * rightEnergy)
        return DecodedAudioMeasurement(
            channelCount: channelCount,
            frameCount: qualifyingFrames,
            leftRMS: sqrt(leftEnergy / Double(qualifyingFrames)),
            rightRMS: sqrt(rightEnergy / Double(qualifyingFrames)),
            leftPeak: leftPeak,
            rightPeak: rightPeak,
            correlation: denominator > 0 ? crossEnergy / denominator : 0
        )
    }

    var diagnosticSummary: String {
        lock.lock()
        defer { lock.unlock() }
        return "callbacks=\(callbackCount) formats=\(observedFormats.sorted()) "
            + "qualifyingFrames=\(qualifyingFrames) "
            + "measurement=\(measurementLocked())"
    }

    func observe(_ buffer: AVAudioPCMBuffer) {
        let format = "\(buffer.format.sampleRate)/\(buffer.format.channelCount)ch/"
            + "\(buffer.format.commonFormat.rawValue)/interleaved=\(buffer.format.isInterleaved)"
        let batch = Self.measure(buffer)
        var shouldFulfill = false
        lock.withLock {
            callbackCount += 1
            observedFormats.insert(format)
            if let batch, batch.channelCount == 2, qualifies(batch) {
                channelCount = batch.channelCount
                qualifyingFrames += batch.frameCount
                leftEnergy += batch.leftEnergy
                rightEnergy += batch.rightEnergy
                crossEnergy += batch.crossEnergy
                leftPeak = max(leftPeak, batch.leftPeak)
                rightPeak = max(rightPeak, batch.rightPeak)
                if !didReceiveAudio,
                   qualifyingFrames >= requiredQualifyingFrames {
                    didReceiveAudio = true
                    shouldFulfill = true
                }
            }
        }

        if shouldFulfill {
            receivedAudio.fulfill()
        }
    }

    private func qualifies(_ batch: Batch) -> Bool {
        switch mode {
        case .rightOnly:
            return batch.rightRMS > 0.01
                && batch.leftRMS < batch.rightRMS * 0.25
        case .antiPhase:
            return batch.leftRMS > 0.01
                && batch.rightRMS > 0.01
                && batch.correlation < -0.5
        }
    }

    private func measurementLocked() -> DecodedAudioMeasurement {
        guard qualifyingFrames > 0 else { return .zero }
        let denominator = sqrt(leftEnergy * rightEnergy)
        return DecodedAudioMeasurement(
            channelCount: channelCount,
            frameCount: qualifyingFrames,
            leftRMS: sqrt(leftEnergy / Double(qualifyingFrames)),
            rightRMS: sqrt(rightEnergy / Double(qualifyingFrames)),
            leftPeak: leftPeak,
            rightPeak: rightPeak,
            correlation: denominator > 0 ? crossEnergy / denominator : 0
        )
    }

    private static func measure(_ buffer: AVAudioPCMBuffer) -> Batch? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount == 2 else { return nil }

        var leftEnergy = 0.0
        var rightEnergy = 0.0
        var crossEnergy = 0.0
        var leftPeak = 0.0
        var rightPeak = 0.0
        for frame in 0..<frameCount {
            guard let left = sample(buffer, frame: frame, channel: 0),
                  let right = sample(buffer, frame: frame, channel: 1) else {
                return nil
            }
            leftEnergy += left * left
            rightEnergy += right * right
            crossEnergy += left * right
            leftPeak = max(leftPeak, abs(left))
            rightPeak = max(rightPeak, abs(right))
        }

        return Batch(
            channelCount: channelCount,
            frameCount: frameCount,
            leftEnergy: leftEnergy,
            rightEnergy: rightEnergy,
            crossEnergy: crossEnergy,
            leftPeak: leftPeak,
            rightPeak: rightPeak
        )
    }

    private static func sample(
        _ buffer: AVAudioPCMBuffer,
        frame: Int,
        channel: Int
    ) -> Double? {
        let channelCount = Int(buffer.format.channelCount)
        let sampleIndex = buffer.format.isInterleaved
            ? frame * channelCount + channel
            : frame
        let dataIndex = buffer.format.isInterleaved ? 0 : channel

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return nil }
            return Double(data[dataIndex][sampleIndex])
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return nil }
            return Double(data[dataIndex][sampleIndex]) / Double(Int16.max)
        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else { return nil }
            return Double(data[dataIndex][sampleIndex]) / Double(Int32.max)
        default:
            return nil
        }
    }
}

private func makeStereoToneSampleBuffer(
    frameCount: Int = 960,
    leftAmplitude: Double = 0.08,
    rightAmplitude: Double = 0.08,
    leftFrequency: Double = 500,
    rightFrequency: Double = 1_000
) throws -> CMSampleBuffer {
    let sampleRate = 48_000.0
    let leftScale = leftAmplitude * Double(Int16.max)
    let rightScale = rightAmplitude * Double(Int16.max)
    var samples = [Int16](repeating: 0, count: frameCount * 2)
    for frame in 0..<frameCount {
        let time = Double(frame) / sampleRate
        samples[frame * 2] = Int16(
            (sin(2 * .pi * leftFrequency * time) * leftScale).rounded()
        )
        samples[frame * 2 + 1] = Int16(
            (sin(2 * .pi * rightFrequency * time) * rightScale).rounded()
        )
    }

    let byteCount = samples.count * MemoryLayout<Int16>.size
    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: byteCount,
        flags: 0,
        blockBufferOut: &blockBuffer
    )
    guard status == kCMBlockBufferNoErr, let blockBuffer else {
        throw AudioSampleBufferTestError.blockBufferCreationFailed(status)
    }
    status = samples.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
        return CMBlockBufferReplaceDataBytes(
            with: baseAddress,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
    }
    guard status == kCMBlockBufferNoErr else {
        throw AudioSampleBufferTestError.blockBufferCopyFailed(status)
    }

    var streamDescription = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 16,
        mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    status = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &streamDescription,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    )
    guard status == noErr, let formatDescription else {
        throw AudioSampleBufferTestError.formatDescriptionCreationFailed(status)
    }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
    )
    var sampleSize = 4
    var sampleBuffer: CMSampleBuffer?
    status = CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: frameCount,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sampleBuffer else {
        throw AudioSampleBufferTestError.sampleBufferCreationFailed(status)
    }
    return sampleBuffer
}

/// Models a non-WebRTC-native ScreenCaptureKit format so the end-to-end stereo proof also
/// exercises sample-format conversion and resampling into the custom device's exact 48 kHz
/// interleaved Int16 contract.
private func makeStereoFloatToneSampleBuffer(
    frameCount: Int,
    sampleRate: Double,
    leftAmplitude: Double,
    rightAmplitude: Double,
    leftFrequency: Double,
    rightFrequency: Double
) throws -> CMSampleBuffer {
    var samples = [Float32](repeating: 0, count: frameCount * 2)
    for frame in 0..<frameCount {
        let time = Double(frame) / sampleRate
        samples[frame * 2] = Float32(
            sin(2 * .pi * leftFrequency * time) * leftAmplitude
        )
        samples[frame * 2 + 1] = Float32(
            sin(2 * .pi * rightFrequency * time) * rightAmplitude
        )
    }

    let byteCount = samples.count * MemoryLayout<Float32>.size
    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: byteCount,
        flags: 0,
        blockBufferOut: &blockBuffer
    )
    guard status == kCMBlockBufferNoErr, let blockBuffer else {
        throw AudioSampleBufferTestError.blockBufferCreationFailed(status)
    }
    status = samples.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else {
            return kCMBlockBufferBadLengthParameterErr
        }
        return CMBlockBufferReplaceDataBytes(
            with: baseAddress,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
    }
    guard status == kCMBlockBufferNoErr else {
        throw AudioSampleBufferTestError.blockBufferCopyFailed(status)
    }

    var streamDescription = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8,
        mFramesPerPacket: 1,
        mBytesPerFrame: 8,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    status = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &streamDescription,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    )
    guard status == noErr, let formatDescription else {
        throw AudioSampleBufferTestError.formatDescriptionCreationFailed(status)
    }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
    )
    var sampleSize = 8
    var sampleBuffer: CMSampleBuffer?
    status = CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: frameCount,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sampleBuffer else {
        throw AudioSampleBufferTestError.sampleBufferCreationFailed(status)
    }
    return sampleBuffer
}

/// Construction failures for synthetic host audio buffers.
private enum AudioSampleBufferTestError: Error {
    case blockBufferCreationFailed(OSStatus)
    case blockBufferCopyFailed(OSStatus)
    case formatDescriptionCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
}

/// Construction failures for synthetic host video buffers.
private enum PixelBufferTestError: Error {
    case creationFailed(CVReturn)
}
