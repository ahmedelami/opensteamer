import Foundation
import Testing
@testable import RemoteSessionCore

struct RemoteSignalModelsTests {
    @Test func rolesAndICEServersRoundTripThroughCodable() throws {
        let roles = RemotePeerRole.allCases
        let servers = [
            RemoteICEServer(urls: ["stun:stun.example.test:3478"]),
            RemoteICEServer(
                urls: ["turn:turn.example.test:3478?transport=udp", "turns:turn.example.test:5349"],
                username: "ephemeral-user",
                credential: "ephemeral-credential"
            )
        ]

        #expect(try roundTrip(roles) == roles)
        #expect(try roundTrip(servers) == servers)
    }

    @Test func everySignalPayloadRoundTripsThroughCodable() throws {
        let candidate = RemoteICECandidate(
            sdp: "candidate:1 1 UDP 2122260223 192.0.2.1 50000 typ host ufrag generation-one",
            sdpMid: "0",
            sdpMLineIndex: 0,
            usernameFragment: "generation-one"
        )
        let identity = RemotePeerIdentity(
            deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            role: .viewer,
            publicKey: Data(0..<32),
            displayName: "Test iPhone"
        )
        let payloads: [RemoteSignalPayload] = [
            .offer(sdp: "offer"),
            .answer(sdp: "answer"),
            .candidate(candidate),
            .end(.normal),
            .control(.showScreen),
            .control(.hideScreen),
            .control(.requestKeyFrame),
            .identity(identity),
            .iceRestartRequest(.init(requestID: 42))
        ]

        for payload in payloads {
            #expect(try roundTrip(payload) == payload)
        }
    }

    @Test func legacySignalJSONStillDecodesExactly() throws {
        let legacyOffer = Data(#"{"kind":"offer","sdp":"legacy offer"}"#.utf8)
        let legacyCandidate = Data(
            #"{"candidate":{"sdp":"candidate:1 1 UDP 1 192.0.2.1 50000 typ host","sdpMLineIndex":0,"sdpMid":"0"},"kind":"candidate"}"#.utf8
        )

        #expect(
            try JSONDecoder().decode(RemoteSignalPayload.self, from: legacyOffer)
                == .offer(sdp: "legacy offer")
        )
        #expect(
            try JSONDecoder().decode(RemoteSignalPayload.self, from: legacyCandidate)
                == .candidate(
                    RemoteICECandidate(
                        sdp: "candidate:1 1 UDP 1 192.0.2.1 50000 typ host",
                        sdpMid: "0",
                        sdpMLineIndex: 0
                    )
                )
        )
    }

    @Test func sealedEnvelopeRoundTripsThroughCodable() throws {
        let code = try RemoteInvitationCode(secret: Data(repeating: 0x44, count: 20))
        let host = RemoteSignalingCipher(invitation: code, role: .host)
        let envelope = try host.seal(.offer(sdp: "encrypted SDP"), sequence: 123)

        #expect(try roundTrip(envelope) == envelope)
    }

    @Test func rendezvousChannelDecoderRejectsNoncanonicalAndMalformedValues() throws {
        let code = try RemoteInvitationCode(secret: Data(repeating: 0x55, count: 20))
        let channel = RemoteSignalingCipher(invitation: code, role: .host).channelID
        #expect(try RendezvousChannelID(wireValue: channel.wireValue) == channel)

        #expect(throws: RemoteSessionCoreError.invalidRendezvousChannel) {
            try RendezvousChannelID(wireValue: channel.wireValue.lowercased())
        }

        var symbols = Array(channel.wireValue)
        symbols[symbols.index(before: symbols.endIndex)] = "Z"
        #expect(throws: RemoteSessionCoreError.invalidRendezvousChannel) {
            try RendezvousChannelID(wireValue: String(symbols))
        }
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try JSONDecoder().decode(Value.self, from: encoder.encode(value))
    }
}
