@testable import WebRTCTransport
import XCTest

/// Locks the route classifier: a relay candidate dominates, complete known non-relay pairs are
/// direct, and incomplete or unknown evidence remains unknown.
final class WebRTCNativeDiagnosticsTests: XCTestCase {
    func testRouteIsUnknownWhenCandidatePairIsIncomplete() {
        XCTAssertEqual(route(local: nil, remote: nil), .unknown)
        XCTAssertEqual(route(local: .host, remote: nil), .unknown)
        XCTAssertEqual(route(local: nil, remote: .serverReflexive), .unknown)
    }

    func testRouteIsUnknownWhenEitherCandidateTypeIsUnknown() {
        XCTAssertEqual(route(local: .unknown, remote: .host), .unknown)
        XCTAssertEqual(route(local: .host, remote: .unknown), .unknown)
        XCTAssertEqual(route(local: .unknown, remote: .unknown), .unknown)
    }

    func testRouteIsDirectOnlyForCompleteKnownNonRelayPair() {
        XCTAssertEqual(route(local: .host, remote: .host), .direct)
        XCTAssertEqual(route(local: .host, remote: .serverReflexive), .direct)
        XCTAssertEqual(route(local: .serverReflexive, remote: .host), .direct)
        XCTAssertEqual(route(local: .serverReflexive, remote: .peerReflexive), .direct)
    }

    func testRelayCandidateTakesPrecedenceOverMissingOrUnknownPeer() {
        XCTAssertEqual(route(local: .relay, remote: nil), .relayed)
        XCTAssertEqual(route(local: nil, remote: .relay), .relayed)
        XCTAssertEqual(route(local: .relay, remote: .unknown), .relayed)
        XCTAssertEqual(route(local: .unknown, remote: .relay), .relayed)
        XCTAssertEqual(route(local: .relay, remote: .host), .relayed)
        XCTAssertEqual(route(local: .serverReflexive, remote: .relay), .relayed)
    }

    private func route(
        local: WebRTCCandidateType?,
        remote: WebRTCCandidateType?
    ) -> WebRTCICERouteKind {
        WebRTCNativeDiagnostics.route(
            local: local.map { WebRTCCandidateDiagnostics(type: $0) },
            remote: remote.map { WebRTCCandidateDiagnostics(type: $0) }
        ).kind
    }
}
