import Foundation
@testable import WebRTCTransport
import XCTest

final class ScreenMediaSuspensionProtocolTests: XCTestCase {
    func testViewerEchoesOnlyAnExactSessionLevelCapabilityAndNegotiationNeedsBothSides() {
        let offer = "v=0\r\na=x-opensteamer-screen-media-suspension:1\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"
        let answer = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"
        let echoed = ScreenMediaSuspensionSDP.advertisingViewerSupport(
            in: answer,
            remoteOfferSDP: offer
        )

        XCTAssertTrue(
            ScreenMediaSuspensionSDP.wasNegotiated(
                hostOfferSDP: offer,
                viewerAnswerSDP: echoed
            )
        )
        XCTAssertEqual(
            echoed.components(separatedBy: ScreenMediaSuspensionSDP.attributeLine).count - 1,
            1
        )

        for unsupportedOffer in [
            "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n",
            "v=0\r\na=x-opensteamer-screen-media-suspension:2\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n",
            "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=x-opensteamer-screen-media-suspension:1\r\n",
        ] {
            XCTAssertEqual(
                ScreenMediaSuspensionSDP.advertisingViewerSupport(
                    in: answer,
                    remoteOfferSDP: unsupportedOffer
                ),
                answer
            )
            XCTAssertFalse(
                ScreenMediaSuspensionSDP.wasNegotiated(
                    hostOfferSDP: unsupportedOffer,
                    viewerAnswerSDP: echoed
                )
            )
        }
        XCTAssertFalse(
            ScreenMediaSuspensionSDP.wasNegotiated(
                hostOfferSDP: offer,
                viewerAnswerSDP: answer
            )
        )
    }

    func testHostAdvertisementIsSessionLevelIdempotentAndPreservesLineEndings() {
        let input = "v=0\nm=audio 9 UDP/TLS/RTP/SAVPF 111\n"
        let once = ScreenMediaSuspensionSDP.advertisingHostSupport(in: input)
        let twice = ScreenMediaSuspensionSDP.advertisingHostSupport(in: once)

        XCTAssertEqual(once, twice)
        XCTAssertEqual(
            once,
            "v=0\na=x-opensteamer-screen-media-suspension:1\nm=audio 9 UDP/TLS/RTP/SAVPF 111\n"
        )
    }

    func testRTPSerialComparatorHandlesWrapAndRejectsHalfRangeAmbiguity() {
        XCTAssertEqual(WebRTCRTPSerialComparator.compare(7, relativeTo: 7), .same)
        XCTAssertEqual(WebRTCRTPSerialComparator.compare(8, relativeTo: 7), .newer)
        XCTAssertEqual(WebRTCRTPSerialComparator.compare(7, relativeTo: 8), .older)
        XCTAssertEqual(WebRTCRTPSerialComparator.compare(3, relativeTo: .max - 2), .newer)
        XCTAssertEqual(WebRTCRTPSerialComparator.compare(.max - 2, relativeTo: 3), .older)
        XCTAssertEqual(
            WebRTCRTPSerialComparator.compare(0x8000_0000, relativeTo: 0),
            .ambiguous
        )
        XCTAssertFalse(WebRTCRTPSerialComparator.isStrictlyNewer(0x8000_0000, than: 0))
        XCTAssertFalse(WebRTCRTPSerialComparator.isSameOrNewer(0x8000_0000, than: 0))
        XCTAssertTrue(WebRTCRTPSerialComparator.isSameOrNewer(44, than: 44))
        XCTAssertEqual(
            WebRTCRTPSerialComparator.strictlyNewerForwardDistance(
                from: .max - 2,
                to: 5
            ),
            8
        )
        XCTAssertNil(
            WebRTCRTPSerialComparator.strictlyNewerForwardDistance(
                from: 0,
                to: 0x8000_0000
            )
        )
    }

    func testCompleteRTPDomainLifecycleRoundTripsWithExactEchoes() throws {
        let values = makeValidLifecycle()
        XCTAssertTrue(values.covered.isExactEcho(of: values.suspension))
        XCTAssertTrue(values.markerReady.belongs(to: values.suspension))
        XCTAssertTrue(values.markerPresentation.isExactEcho(of: values.markerReady))
        XCTAssertTrue(values.resumeReady.isValid)
        XCTAssertTrue(values.presentation.isValid)
        XCTAssertTrue(values.request.isValid)
        XCTAssertTrue(values.resumed.isValid)
        let cancellation = WebRTCScreenMediaCancellation(
            suspension: values.suspension,
            cancellationID: UUID(
                uuidString: "11111111-2222-4333-8444-555555555555"
            )!
        )
        XCTAssertTrue(cancellation.isExactCancellation(of: values.suspension))

        try assertRoundTrip(values.suspension)
        try assertRoundTrip(values.covered)
        try assertRoundTrip(values.markerReady)
        try assertRoundTrip(values.markerPresentation)
        try assertRoundTrip(values.resumeReady)
        try assertRoundTrip(values.presentation)
        try assertRoundTrip(values.request)
        try assertRoundTrip(values.resumed)
        try assertRoundTrip(cancellation)

        let encoded = try JSONEncoder().encode(values.resumed)
        let wire = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(wire.localizedCaseInsensitiveContains("nanosecond"))
        XCTAssertTrue(wire.contains("encoderMarkerRTPTimestamp"))
        XCTAssertTrue(wire.contains("encoderRealFrameRTPTimestamp"))
        XCTAssertTrue(wire.contains("receiverMarkerRTPTimestamp"))
        XCTAssertTrue(wire.contains("receiverRealFrameFloorRTPTimestamp"))
    }

    func testStrictDecodeRejectsWrongVersionAndZeroMonotonicID() throws {
        let values = makeValidLifecycle()
        let suspensionData = try JSONEncoder().encode(values.suspension)
        let wrongVersion = try mutatedObjectData(suspensionData) {
            $0["protocolVersion"] = 2
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(WebRTCScreenMediaSuspensionNotice.self, from: wrongVersion)
        )

        let requestData = try JSONEncoder().encode(values.request)
        let zeroID = try mutatedObjectData(requestData) { $0["id"] = 0 }
        XCTAssertThrowsError(
            try JSONDecoder().decode(WebRTCScreenMediaResumeRequest.self, from: zeroID)
        )

        let zeroUUID = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        )
        let invalidCancellation = WebRTCScreenMediaCancellation(
            suspension: values.suspension,
            cancellationID: zeroUUID
        )
        XCTAssertFalse(invalidCancellation.isValid)
        XCTAssertThrowsError(try JSONEncoder().encode(invalidCancellation))
    }

    func testMarkerReadyRejectsZeroAttemptAndInvalidGenerationsOrGeometry() {
        let values = makeValidLifecycle()
        let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        for marker in [
            WebRTCScreenMediaMarkerReady(
                attemptID: zeroUUID,
                screenRequestID: 9,
                suspensionGeneration: 3,
                encoderGeneration: 4,
                encoderMarkerRTPTimestamp: 5,
                boundaryRevision: 6,
                geometry: values.geometry
            ),
            WebRTCScreenMediaMarkerReady(
                attemptID: values.markerReady.attemptID,
                screenRequestID: 9,
                suspensionGeneration: 0,
                encoderGeneration: 4,
                encoderMarkerRTPTimestamp: 5,
                boundaryRevision: 6,
                geometry: values.geometry
            ),
            WebRTCScreenMediaMarkerReady(
                attemptID: values.markerReady.attemptID,
                screenRequestID: 9,
                suspensionGeneration: 3,
                encoderGeneration: 4,
                encoderMarkerRTPTimestamp: 5,
                boundaryRevision: 6,
                geometry: WebRTCScreenMediaGeometry(
                    geometryRevision: 0,
                    captureWidth: 1,
                    captureHeight: 32_769
                )
            ),
        ] {
            XCTAssertFalse(marker.isValid)
            XCTAssertThrowsError(try JSONEncoder().encode(marker))
        }
    }

    func testMarkerPresentationRequiresBoundedStableReceiverSourceAndCompatibleShape() {
        let values = makeValidLifecycle()
        for presentation in [
            WebRTCScreenMediaMarkerPresentation(
                markerReady: values.markerReady,
                receiverMarkerRTPTimestamp: 1_000,
                receiverID: String(repeating: "r", count: 257),
                sourceID: 77,
                presentedWidth: 1_280,
                presentedHeight: 832
            ),
            WebRTCScreenMediaMarkerPresentation(
                markerReady: values.markerReady,
                receiverMarkerRTPTimestamp: 1_000,
                receiverID: "receiver\n2",
                sourceID: 77,
                presentedWidth: 1_280,
                presentedHeight: 832
            ),
            WebRTCScreenMediaMarkerPresentation(
                markerReady: values.markerReady,
                receiverMarkerRTPTimestamp: 1_000,
                receiverID: "receiver-1",
                sourceID: 0,
                presentedWidth: 1_280,
                presentedHeight: 832
            ),
            WebRTCScreenMediaMarkerPresentation(
                markerReady: values.markerReady,
                receiverMarkerRTPTimestamp: 1_000,
                receiverID: "receiver-1",
                sourceID: 77,
                presentedWidth: 832,
                presentedHeight: 1_280
            ),
            WebRTCScreenMediaMarkerPresentation(
                markerReady: values.markerReady,
                receiverMarkerRTPTimestamp: 1_000,
                receiverID: "receiver-1",
                sourceID: 77,
                presentedWidth: values.geometry.captureWidth * 2,
                presentedHeight: values.geometry.captureHeight * 2
            ),
        ] {
            XCTAssertFalse(presentation.isValid)
            XCTAssertThrowsError(try JSONEncoder().encode(presentation))
        }

        let differentBoundary = WebRTCScreenMediaMarkerReady(
            attemptID: values.markerReady.attemptID,
            screenRequestID: values.markerReady.screenRequestID,
            suspensionGeneration: values.markerReady.suspensionGeneration,
            encoderGeneration: values.markerReady.encoderGeneration,
            encoderMarkerRTPTimestamp: values.markerReady.encoderMarkerRTPTimestamp,
            boundaryRevision: values.markerReady.boundaryRevision + 1,
            geometry: values.geometry
        )
        XCTAssertFalse(values.markerPresentation.isExactEcho(of: differentBoundary))
    }

    func testResumeReadyRequiresExactMarkerGeometryAndStrictlyNewerRr() {
        let values = makeValidLifecycle()
        for ready in [
            WebRTCScreenMediaResumeReady(
                markerPresentation: values.markerPresentation,
                encoderMarkerRTPTimestamp:
                    values.markerReady.encoderMarkerRTPTimestamp &+ 1,
                encoderRealFrameRTPTimestamp:
                    values.resumeReady.encoderRealFrameRTPTimestamp,
                receiverMarkerRTPTimestamp:
                    values.markerPresentation.receiverMarkerRTPTimestamp,
                receiverRealFrameFloorRTPTimestamp:
                    values.resumeReady.receiverRealFrameFloorRTPTimestamp,
                geometry: values.geometry
            ),
            WebRTCScreenMediaResumeReady(
                markerPresentation: values.markerPresentation,
                encoderMarkerRTPTimestamp:
                    values.markerReady.encoderMarkerRTPTimestamp,
                encoderRealFrameRTPTimestamp:
                    values.markerReady.encoderMarkerRTPTimestamp,
                receiverMarkerRTPTimestamp:
                    values.markerPresentation.receiverMarkerRTPTimestamp,
                receiverRealFrameFloorRTPTimestamp:
                    values.resumeReady.receiverRealFrameFloorRTPTimestamp,
                geometry: values.geometry
            ),
            WebRTCScreenMediaResumeReady(
                markerPresentation: values.markerPresentation,
                encoderMarkerRTPTimestamp:
                    values.markerReady.encoderMarkerRTPTimestamp,
                encoderRealFrameRTPTimestamp:
                    values.markerReady.encoderMarkerRTPTimestamp &+ 0x8000_0000,
                receiverMarkerRTPTimestamp:
                    values.markerPresentation.receiverMarkerRTPTimestamp,
                receiverRealFrameFloorRTPTimestamp:
                    values.resumeReady.receiverRealFrameFloorRTPTimestamp,
                geometry: values.geometry
            ),
            WebRTCScreenMediaResumeReady(
                markerPresentation: values.markerPresentation,
                encoderMarkerRTPTimestamp:
                    values.markerReady.encoderMarkerRTPTimestamp,
                encoderRealFrameRTPTimestamp:
                    values.resumeReady.encoderRealFrameRTPTimestamp,
                receiverMarkerRTPTimestamp:
                    values.markerPresentation.receiverMarkerRTPTimestamp,
                receiverRealFrameFloorRTPTimestamp:
                    values.resumeReady.receiverRealFrameFloorRTPTimestamp,
                geometry: WebRTCScreenMediaGeometry(
                    geometryRevision: values.geometry.geometryRevision + 1,
                    captureWidth: values.geometry.captureWidth,
                    captureHeight: values.geometry.captureHeight
                )
            ),
            WebRTCScreenMediaResumeReady(
                markerPresentation: values.markerPresentation,
                encoderMarkerRTPTimestamp:
                    values.markerReady.encoderMarkerRTPTimestamp,
                encoderRealFrameRTPTimestamp:
                    values.resumeReady.encoderRealFrameRTPTimestamp,
                receiverMarkerRTPTimestamp:
                    values.markerPresentation.receiverMarkerRTPTimestamp &+ 1,
                receiverRealFrameFloorRTPTimestamp:
                    values.resumeReady.receiverRealFrameFloorRTPTimestamp,
                geometry: values.geometry
            ),
            WebRTCScreenMediaResumeReady(
                markerPresentation: values.markerPresentation,
                encoderMarkerRTPTimestamp:
                    values.markerReady.encoderMarkerRTPTimestamp,
                encoderRealFrameRTPTimestamp:
                    values.resumeReady.encoderRealFrameRTPTimestamp,
                receiverMarkerRTPTimestamp:
                    values.markerPresentation.receiverMarkerRTPTimestamp,
                receiverRealFrameFloorRTPTimestamp:
                    values.resumeReady.receiverRealFrameFloorRTPTimestamp &+ 1,
                geometry: values.geometry
            ),
        ] {
            XCTAssertFalse(ready.isValid)
            XCTAssertThrowsError(try JSONEncoder().encode(ready))
        }
    }

    func testRealPresentationFailsClosedAcrossReceiverSourceSizeAndRTPDiscontinuity() {
        let values = makeValidLifecycle()
        let invalidValues = [
            makePresentation(
                values: values,
                rtpTimestamp: values.markerPresentation.receiverMarkerRTPTimestamp
            ),
            makePresentation(
                values: values,
                rtpTimestamp:
                    values.resumeReady.receiverRealFrameFloorRTPTimestamp
                        &+ 0x8000_0000
            ),
            makePresentation(values: values, receiverID: "retired-receiver"),
            makePresentation(values: values, sourceID: 78),
            makePresentation(values: values, width: 640, height: 416),
        ]
        for presentation in invalidValues {
            XCTAssertFalse(presentation.isValid)
            XCTAssertThrowsError(try JSONEncoder().encode(presentation))
        }

        let later = makePresentation(
            values: values,
            rtpTimestamp:
                values.resumeReady.receiverRealFrameFloorRTPTimestamp &+ 90_000
        )
        XCTAssertTrue(later.isValid)
    }

    func testResumedAcknowledgementRejectsCapabilityForAnotherScreenRequest() {
        let values = makeValidLifecycle()
        let wrongCapability = WebRTCInputCapability(
            inputSessionID: UUID(),
            screenRequestID: values.suspension.screenRequestID + 1
        )
        let acknowledgement = WebRTCScreenMediaResumedAcknowledgement(
            request: values.request,
            inputCapability: wrongCapability
        )

        XCTAssertFalse(acknowledgement.isValid)
        XCTAssertThrowsError(try JSONEncoder().encode(acknowledgement))
    }

    private func makeValidLifecycle() -> LifecycleValues {
        let geometry = WebRTCScreenMediaGeometry(
            geometryRevision: 12,
            captureWidth: 3_024,
            captureHeight: 1_964
        )
        let suspension = WebRTCScreenMediaSuspensionNotice(
            screenRequestID: 42,
            suspensionGeneration: 7
        )
        let covered = WebRTCScreenMediaCoveredAcknowledgement(suspension: suspension)
        let markerReady = WebRTCScreenMediaMarkerReady(
            attemptID: UUID(uuidString: "A1B2C3D4-E5F6-4718-89AB-CDEF01234567")!,
            screenRequestID: suspension.screenRequestID,
            suspensionGeneration: suspension.suspensionGeneration,
            encoderGeneration: 19,
            encoderMarkerRTPTimestamp: .max - 2,
            boundaryRevision: 23,
            geometry: geometry
        )
        let markerPresentation = WebRTCScreenMediaMarkerPresentation(
            markerReady: markerReady,
            receiverMarkerRTPTimestamp: 1_000,
            receiverID: "receiver-1",
            sourceID: 77,
            presentedWidth: 1_280,
            presentedHeight: 832
        )
        let resumeReady = WebRTCScreenMediaResumeReady(
            markerPresentation: markerPresentation,
            encoderMarkerRTPTimestamp: markerReady.encoderMarkerRTPTimestamp,
            encoderRealFrameRTPTimestamp: 5,
            receiverMarkerRTPTimestamp:
                markerPresentation.receiverMarkerRTPTimestamp,
            receiverRealFrameFloorRTPTimestamp: 1_008,
            geometry: geometry
        )
        let presentation = WebRTCScreenMediaPresentation(
            resumeReady: resumeReady,
            presentedRTPTimestamp:
                resumeReady.receiverRealFrameFloorRTPTimestamp,
            receiverID: markerPresentation.receiverID,
            sourceID: markerPresentation.sourceID,
            presentedWidth: markerPresentation.presentedWidth,
            presentedHeight: markerPresentation.presentedHeight
        )
        let request = WebRTCScreenMediaResumeRequest(id: 55, presentation: presentation)
        let resumed = WebRTCScreenMediaResumedAcknowledgement(
            request: request,
            inputCapability: WebRTCInputCapability(
                inputSessionID: UUID(uuidString: "01234567-89AB-4CDE-8F01-23456789ABCD")!,
                screenRequestID: suspension.screenRequestID
            )
        )
        return LifecycleValues(
            geometry: geometry,
            suspension: suspension,
            covered: covered,
            markerReady: markerReady,
            markerPresentation: markerPresentation,
            resumeReady: resumeReady,
            presentation: presentation,
            request: request,
            resumed: resumed
        )
    }

    private func makePresentation(
        values: LifecycleValues,
        rtpTimestamp: UInt32? = nil,
        receiverID: String? = nil,
        sourceID: UInt32? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) -> WebRTCScreenMediaPresentation {
        WebRTCScreenMediaPresentation(
            resumeReady: values.resumeReady,
            presentedRTPTimestamp: rtpTimestamp
                ?? values.resumeReady.receiverRealFrameFloorRTPTimestamp,
            receiverID: receiverID ?? values.markerPresentation.receiverID,
            sourceID: sourceID ?? values.markerPresentation.sourceID,
            presentedWidth: width ?? values.markerPresentation.presentedWidth,
            presentedHeight: height ?? values.markerPresentation.presentedHeight
        )
    }

    private func assertRoundTrip<Value>(
        _ value: Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws where Value: Codable & Equatable {
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(Value.self, from: encoded)
        XCTAssertEqual(decoded, value, file: file, line: line)
    }

    private func mutatedObjectData(
        _ data: Data,
        mutate: (inout [String: Any]) -> Void
    ) throws -> Data {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private struct LifecycleValues {
    let geometry: WebRTCScreenMediaGeometry
    let suspension: WebRTCScreenMediaSuspensionNotice
    let covered: WebRTCScreenMediaCoveredAcknowledgement
    let markerReady: WebRTCScreenMediaMarkerReady
    let markerPresentation: WebRTCScreenMediaMarkerPresentation
    let resumeReady: WebRTCScreenMediaResumeReady
    let presentation: WebRTCScreenMediaPresentation
    let request: WebRTCScreenMediaResumeRequest
    let resumed: WebRTCScreenMediaResumedAcknowledgement
}
