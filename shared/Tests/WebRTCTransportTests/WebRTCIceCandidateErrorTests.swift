import Foundation
import Testing
@testable import WebRTCTransport

struct WebRTCIceCandidateErrorTests {
    @Test func preservesEveryNativeDiagnosticField() throws {
        let error = WebRTCIceCandidateError(
            address: "192.0.2.10",
            port: 54_321,
            url: "stun:stun.example.test:3478",
            errorCode: 701,
            reason: "STUN host lookup received error."
        )

        let decoded = try JSONDecoder().decode(
            WebRTCIceCandidateError.self,
            from: JSONEncoder().encode(error)
        )

        #expect(decoded == error)
        #expect(decoded.address == "192.0.2.10")
        #expect(decoded.port == 54_321)
        #expect(decoded.url == "stun:stun.example.test:3478")
        #expect(decoded.errorCode == 701)
        #expect(decoded.reason == "STUN host lookup received error.")
    }
}
