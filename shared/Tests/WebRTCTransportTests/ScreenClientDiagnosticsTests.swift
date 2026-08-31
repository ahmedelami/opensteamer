import Foundation
@testable import WebRTCTransport
import XCTest

final class ScreenClientDiagnosticsTests: XCTestCase {
    func testDiagnosticsBacklogCannotFailCriticalNativeEventDelivery() {
        let proxy = WebRTCDelegateProxy()
        let authorization = WebRTCInputAuthorization()
        proxy.markNativeTransportHealthyForTesting()
        XCTAssertTrue(proxy.installInputAuthorization(authorization))

        for sequence in 1...512 {
            proxy.emitScreenDiagnosticsForTesting(
                .message(Data(String(sequence).utf8))
            )
        }

        XCTAssertFalse(proxy.didFailEventDelivery())
        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(
            proxy.hasHealthyInstalledInputAuthorization(authorization)
        )
        proxy.close()
    }

    func testCapabilityNeedsExactSessionLevelOfferAndAnswerEcho() {
        let base = "v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n"
        let offer = ScreenClientDiagnosticsSDP.advertisingHostSupport(in: base)
        let answer = ScreenClientDiagnosticsSDP.advertisingViewerSupport(
            in: base,
            remoteOfferSDP: offer
        )

        XCTAssertTrue(
            ScreenClientDiagnosticsSDP.wasNegotiated(
                hostOfferSDP: offer,
                viewerAnswerSDP: answer
            )
        )
        XCTAssertEqual(
            ScreenClientDiagnosticsSDP.advertisingHostSupport(in: offer),
            offer
        )
        XCTAssertFalse(
            ScreenClientDiagnosticsSDP.wasNegotiated(
                hostOfferSDP: base,
                viewerAnswerSDP: answer
            )
        )

        let wrongVersion = base.replacingOccurrences(
            of: "v=0\r\n",
            with: "v=0\r\na=x-opensteamer-screen-client-diagnostics:2\r\n"
        )
        XCTAssertEqual(
            ScreenClientDiagnosticsSDP.advertisingViewerSupport(
                in: base,
                remoteOfferSDP: wrongVersion
            ),
            base
        )
        let mediaLevelOnly = base
            + ScreenClientDiagnosticsSDP.attributeLine + "\r\n"
        XCTAssertFalse(
            ScreenClientDiagnosticsSDP.peerSupportsDiagnostics(
                in: mediaLevelOnly
            )
        )
    }

    func testHeartbeatRoundTripsWithoutContentOrNetworkIdentity() throws {
        let heartbeat = makeHeartbeat()
        XCTAssertTrue(heartbeat.isValid)

        let data = try JSONEncoder().encode(
            ScreenClientDiagnosticsChannelMessage.heartbeat(heartbeat)
        )
        XCTAssertLessThan(
            data.count,
            WebRTCWireConstants.maximumScreenDiagnosticsMessageBytes
        )
        let wire = try XCTUnwrap(String(data: data, encoding: .utf8))
        for prohibited in ["digest", "candidate", "sdp", "ssrc", "trackID"] {
            XCTAssertFalse(wire.lowercased().contains(prohibited.lowercased()))
        }

        XCTAssertEqual(
            try JSONDecoder().decode(
                ScreenClientDiagnosticsChannelMessage.self,
                from: data
            ),
            .heartbeat(heartbeat)
        )
    }

    func testHeartbeatValidationIsBoundedAndCoverStateIsExact() throws {
        XCTAssertFalse(makeHeartbeat(sequence: 0).isValid)
        XCTAssertFalse(
            makeHeartbeat(
                liveness: .presentingLive,
                coverVisible: true
            ).isValid
        )
        XCTAssertFalse(
            makeHeartbeat(
                liveness: .intentionallyCovered,
                coverVisible: false
            ).isValid
        )
        XCTAssertFalse(
            makeHeartbeat(
                presentationAgeMilliseconds:
                    WebRTCScreenClientDiagnosticsHeartbeat
                        .maximumPresentationAgeMilliseconds + 1
            ).isValid
        )
        XCTAssertFalse(
            makeHeartbeat(
                frameWidth:
                    WebRTCScreenClientDiagnosticsHeartbeat.maximumDimension + 1
            ).isValid
        )
        XCTAssertFalse(makeHeartbeat(framesPerSecond: .infinity).isValid)
        XCTAssertFalse(
            makeHeartbeat(
                framesPresented: 88,
                contentSamples: nil,
                contentChanges: nil
            ).isValid
        )
        XCTAssertFalse(
            makeHeartbeat(
                liveness: .awaitingEvidence,
                framesPresented: 88,
                contentSamples: nil,
                contentChanges: 1
            ).isValid
        )
        XCTAssertFalse(
            makeHeartbeat(
                liveness: .awaitingEvidence,
                framesPresented: nil,
                contentSamples: 1,
                contentChanges: 0
            ).isValid
        )

        let encoded = try JSONEncoder().encode(
            ScreenClientDiagnosticsChannelMessage.heartbeat(makeHeartbeat())
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["version"] = 99
        let wrongUnionVersion = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ScreenClientDiagnosticsChannelMessage.self,
                from: wrongUnionVersion
            )
        )
    }

    private func makeHeartbeat(
        sequence: UInt64 = 1,
        liveness: WebRTCScreenClientLiveness = .presentingLive,
        coverVisible: Bool = false,
        coverReason: WebRTCScreenClientCoverReason = .none,
        framesPresented: UInt64? = 88,
        contentSamples: UInt64? = 40,
        contentChanges: UInt64? = 20,
        presentationAgeMilliseconds: UInt64? = 20,
        frameWidth: Int? = 1_080,
        framesPerSecond: Double? = 30
    ) -> WebRTCScreenClientDiagnosticsHeartbeat {
        WebRTCScreenClientDiagnosticsHeartbeat(
            sequence: sequence,
            screenRequestID: 7,
            liveness: liveness,
            trackAttached: true,
            coverVisible: coverVisible,
            coverReason: coverReason,
            inboundBytes: 10_000,
            inboundPackets: 100,
            framesDecoded: 90,
            framesPresented: framesPresented,
            contentSamples: contentSamples,
            contentChanges: contentChanges,
            presentationAgeMilliseconds: presentationAgeMilliseconds,
            frameWidth: frameWidth,
            frameHeight: 1_920,
            framesPerSecond: framesPerSecond
        )
    }
}
