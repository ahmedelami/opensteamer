import Foundation
import Testing
@testable import RemoteSessionCore

struct RendezvousSignalingClientTests {
    private let endpoint = URL(string: "wss://rendezvous.example.test")!

    @Test func endpointPolicyRequiresTLSExceptOnLoopback() throws {
        let invitation = try makeInvitation(byte: 1)

        for accepted in [
            "wss://rendezvous.example.test",
            "wss://203.0.113.7:443/",
            "ws://localhost:8788",
            "ws://worker.localhost:8788",
            "ws://127.0.0.2:8788",
            "ws://[::1]:8788"
        ] {
            _ = try RendezvousSignalingClient(
                endpoint: URL(string: accepted)!,
                invitation: invitation,
                role: .host,
                transport: FakeRendezvousSocketTransport()
            )
        }

        for rejected in [
            "ws://rendezvous.example.test",
            "http://127.0.0.1:8788",
            "https://rendezvous.example.test",
            "wss://user:password@rendezvous.example.test",
            "wss://rendezvous.example.test/base",
            "wss://rendezvous.example.test?secret=no",
            "wss://rendezvous.example.test/#fragment"
        ] {
            #expect(throws: RendezvousSignalingError.invalidEndpoint) {
                try RendezvousSignalingClient(
                    endpoint: URL(string: rejected)!,
                    invitation: invitation,
                    role: .host,
                    transport: FakeRendezvousSocketTransport()
                )
            }
        }
    }

    @Test func joinedURLContainsNoSessionMaterialAndJoinHeadersAreDerived() async throws {
        let invitation = try makeInvitation(byte: 2)
        let fake = FakeRendezvousSocketTransport()
        let client = try RendezvousSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .viewer,
            transport: fake
        )

        let stream = try await client.connect()
        let connectedURL = try #require(await fake.connectedURL())
        let components = try #require(URLComponents(url: connectedURL, resolvingAgainstBaseURL: false))
        let cipher = RemoteSignalingCipher(
            invitation: invitation,
            role: .viewer
        )
        let expectedChannel = cipher.channelID.wireValue
        let connectedChannel = try #require(await fake.connectedChannelID())
        let connectedRole = try #require(await fake.connectedRole())
        let connectedAdmissionProof = try #require(await fake.connectedAdmissionProof())

        #expect(components.scheme == "wss")
        #expect(components.path == "/v1/rendezvous")
        #expect(components.query == nil)
        #expect(connectedChannel.wireValue == expectedChannel)
        #expect(connectedRole == .viewer)
        #expect(connectedAdmissionProof == cipher.admissionProof)
        #expect(connectedAdmissionProof.wireValue.utf8.count == 43)
        #expect(connectedAdmissionProof.wireValue.utf8.allSatisfy(isBase64URLByte))
        #expect(!connectedURL.absoluteString.contains(invitation.exportedCode))
        #expect(!connectedURL.absoluteString.contains(invitation.canonicalCode))
        #expect(!connectedURL.absoluteString.contains(expectedChannel))

        var iterator = stream.makeAsyncIterator()
        await client.close()
        #expect(try await iterator.next() == nil)
        #expect(await fake.closeCount() == 1)
    }

    @Test func outboundWireFormatMatchesNodeSchemaAndIsEndToEndEncrypted() async throws {
        let invitation = try makeInvitation(byte: 3)
        let fake = FakeRendezvousSocketTransport()
        let client = try RendezvousSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .host,
            transport: fake
        )
        _ = try await client.connect()

        let payload = RemoteSignalPayload.offer(sdp: "v=0\r\na=setup:actpass\r\n")
        try await client.send(payload)
        let text = try #require(await fake.sentTexts().first)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        #expect(Set(object.keys) == ["type", "seq", "envelope"])
        #expect(object["type"] as? String == "signal")
        #expect(object["seq"] as? Int == 0)

        let encodedEnvelope = try #require(object["envelope"] as? String)
        #expect(encodedEnvelope.utf8.allSatisfy(isBase64URLByte))
        let envelopeData = try #require(decodeBase64URL(encodedEnvelope))
        let envelope = try JSONDecoder().decode(SealedSignalingEnvelope.self, from: envelopeData)
        #expect(envelope.sequence == 0)
        #expect(envelope.direction == .hostToViewer)

        let viewer = RemoteSignalingCipher(invitation: invitation, role: .viewer)
        #expect(try viewer.open(envelope) == payload)
        await client.close()
    }

    @Test func candidateUsernameFragmentIsBounded() async throws {
        let invitation = try makeInvitation(byte: 14)
        let fake = FakeRendezvousSocketTransport()
        let client = try RendezvousSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .host,
            transport: fake
        )
        _ = try await client.connect()

        let candidateSDP = "candidate:1 1 UDP 1 192.0.2.1 50000 typ host"
        try await client.send(
            .candidate(
                RemoteICECandidate(
                    sdp: candidateSDP,
                    sdpMid: "0",
                    sdpMLineIndex: 0,
                    usernameFragment: "valid-generation"
                )
            )
        )

        for fragment in ["", "has whitespace", String(repeating: "x", count: 257)] {
            do {
                try await client.send(
                    .candidate(
                        RemoteICECandidate(
                            sdp: candidateSDP,
                            sdpMid: "0",
                            sdpMLineIndex: 0,
                            usernameFragment: fragment
                        )
                    )
                )
                Issue.record("Expected invalid ICE username fragment to be rejected")
            } catch let error as RemoteSessionCoreError {
                #expect(error == .invalidSignalPayload)
            }
        }
        await client.close()
    }

    @Test func waitingReadyErrorAndPeerLeftMessagesParseWithBoundedICEData() async throws {
        let invitation = try makeInvitation(byte: 4)
        let fake = FakeRendezvousSocketTransport()
        let client = try RendezvousSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .host,
            transport: fake
        )
        let stream = try await client.connect()
        var iterator = stream.makeAsyncIterator()

        await fake.push(text: #"{"type":"waiting","invitationExpiresAt":"2026-07-13T12:34:56.000Z"}"#)
        let waiting = try #require(try await iterator.next())
        guard case .waiting(let expiration) = waiting else {
            Issue.record("Expected waiting event")
            return
        }
        let expectedExpiration = try parseFixtureDate("2026-07-13T12:34:56.000Z")
        #expect(expiration == expectedExpiration)

        await fake.push(text: #"{"type":"ready","role":"host","invitationExpiresAt":"2026-07-13T12:34:56.000Z","iceServers":[{"urls":["stun:stun.example.test:3478"]},{"urls":["turn:turn.example.test:3478?transport=udp","turns:turn.example.test:5349?transport=tcp"],"username":"1700000600:opaque","credential":"temporary-password","credentialType":"password"}]}"#)
        let ready = try #require(try await iterator.next())
        guard case .ready(let role, let readyExpiration, let iceServers) = ready else {
            Issue.record("Expected ready event")
            return
        }
        #expect(role == .host)
        #expect(readyExpiration == expiration)
        #expect(iceServers == [
            RemoteICEServer(urls: ["stun:stun.example.test:3478"]),
            RemoteICEServer(
                urls: [
                    "turn:turn.example.test:3478?transport=udp",
                    "turns:turn.example.test:5349?transport=tcp"
                ],
                username: "1700000600:opaque",
                credential: "temporary-password"
            )
        ])

        await fake.push(text: #"{"type":"error","error":"peer_unavailable"}"#)
        #expect(try await iterator.next() == .serverError(.peerUnavailable))
        await fake.push(text: #"{"type":"peer-left","role":"viewer"}"#)
        #expect(try await iterator.next() == .peerLeft(.viewer))
        await client.close()
    }

    @Test func inboundSignalVerifiesOuterMetadataAndDecryptsPayload() async throws {
        let invitation = try makeInvitation(byte: 5)
        let fake = FakeRendezvousSocketTransport()
        let client = try RendezvousSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .host,
            transport: fake
        )
        let stream = try await client.connect()
        var iterator = stream.makeAsyncIterator()

        let viewer = RemoteSignalingCipher(invitation: invitation, role: .viewer)
        let payload = RemoteSignalPayload.candidate(
            RemoteICECandidate(
                sdp: "candidate:1 1 UDP 2122260223 192.0.2.1 50000 typ host",
                sdpMid: "0",
                sdpMLineIndex: 0
            )
        )
        let envelope = try viewer.seal(payload, sequence: 0)
        await fake.push(text: try inboundSignalText(envelope: envelope, from: .viewer))

        #expect(try await iterator.next() == .signal(payload))
        await client.close()
    }

    @Test func iceRestartRequestsAreValidOnlyFromViewerToHost() async throws {
        let invitation = try makeInvitation(byte: 13)
        let request = RemoteICERestartRequest(requestID: 1)

        let viewerFake = FakeRendezvousSocketTransport()
        let viewer = try RendezvousSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .viewer,
            transport: viewerFake
        )
        let viewerEvents = try await viewer.connect()
        try await viewer.send(.iceRestartRequest(request))
        #expect(await viewerFake.sentTexts().count == 1)

        for invalid in [
            RemoteICERestartRequest(requestID: 0),
            RemoteICERestartRequest(requestID: 2, protocolVersion: 2)
        ] {
            do {
                try await viewer.send(.iceRestartRequest(invalid))
                Issue.record("Expected invalid viewer restart request to be rejected")
            } catch let error as RemoteSessionCoreError {
                #expect(error == .invalidSignalPayload)
            }
        }
        _ = viewerEvents
        await viewer.close()

        let hostOutboundFake = FakeRendezvousSocketTransport()
        let hostOutbound = try RendezvousSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .host,
            transport: hostOutboundFake
        )
        let hostOutboundEvents = try await hostOutbound.connect()
        do {
            try await hostOutbound.send(.iceRestartRequest(request))
            Issue.record("Expected host restart request to be rejected")
        } catch let error as RemoteSessionCoreError {
            #expect(error == .invalidSignalPayload)
        }
        _ = hostOutboundEvents
        await hostOutbound.close()

        let hostInboundFake = FakeRendezvousSocketTransport()
        let hostInbound = try RendezvousSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .host,
            transport: hostInboundFake
        )
        let hostStream = try await hostInbound.connect()
        var hostIterator = hostStream.makeAsyncIterator()
        let viewerCipher = RemoteSignalingCipher(invitation: invitation, role: .viewer)
        let viewerEnvelope = try viewerCipher.seal(.iceRestartRequest(request), sequence: 0)
        await hostInboundFake.push(
            text: try inboundSignalText(envelope: viewerEnvelope, from: .viewer)
        )
        #expect(try await hostIterator.next() == .signal(.iceRestartRequest(request)))
        await hostInbound.close()

        let viewerInboundFake = FakeRendezvousSocketTransport()
        let viewerInbound = try RendezvousSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .viewer,
            transport: viewerInboundFake
        )
        let viewerStream = try await viewerInbound.connect()
        var viewerIterator = viewerStream.makeAsyncIterator()
        let hostCipher = RemoteSignalingCipher(invitation: invitation, role: .host)
        let hostEnvelope = try hostCipher.seal(.iceRestartRequest(request), sequence: 0)
        await viewerInboundFake.push(
            text: try inboundSignalText(envelope: hostEnvelope, from: .host)
        )
        await expectFailure(&viewerIterator, equals: RemoteSessionCoreError.invalidSignalPayload)
    }

    @Test func wrongOuterRoleIsRejected() async throws {
        let invitation = try makeInvitation(byte: 6)
        let fake = FakeRendezvousSocketTransport()
        let client = try RendezvousSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .host,
            transport: fake
        )
        let stream = try await client.connect()
        var iterator = stream.makeAsyncIterator()
        let viewer = RemoteSignalingCipher(invitation: invitation, role: .viewer)
        let envelope = try viewer.seal(.control(.showScreen), sequence: 0)

        await fake.push(text: try inboundSignalText(envelope: envelope, from: .host))
        await expectFailure(&iterator, equals: RendezvousSignalingError.invalidServerMessage)
    }

    @Test func outerAndInnerSequenceMismatchIsRejected() async throws {
        let invitation = try makeInvitation(byte: 7)
        let fake = FakeRendezvousSocketTransport()
        let client = try RendezvousSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .host,
            transport: fake
        )
        let stream = try await client.connect()
        var iterator = stream.makeAsyncIterator()
        let viewer = RemoteSignalingCipher(invitation: invitation, role: .viewer)
        let envelope = try viewer.seal(.control(.showScreen), sequence: 0)

        await fake.push(
            text: try inboundSignalText(envelope: envelope, from: .viewer, outerSequence: 1)
        )
        await expectFailure(&iterator, equals: RendezvousSignalingError.invalidServerMessage)
    }

    @Test func authenticatedCiphertextTamperIsRejected() async throws {
        let invitation = try makeInvitation(byte: 8)
        let fake = FakeRendezvousSocketTransport()
        let client = try RendezvousSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .host,
            transport: fake
        )
        let stream = try await client.connect()
        var iterator = stream.makeAsyncIterator()
        let viewer = RemoteSignalingCipher(invitation: invitation, role: .viewer)
        let original = try viewer.seal(.control(.hideScreen), sequence: 0)
        var ciphertext = original.ciphertext
        ciphertext[ciphertext.index(before: ciphertext.endIndex)] ^= 1
        let tampered = SealedSignalingEnvelope(
            channelID: original.channelID,
            direction: original.direction,
            sequence: original.sequence,
            ciphertext: ciphertext
        )

        await fake.push(text: try inboundSignalText(envelope: tampered, from: .viewer))
        await expectFailure(&iterator, equals: RemoteSessionCoreError.authenticationFailed)
    }

    @Test func replayedEnvelopeIsRejectedAfterFirstDelivery() async throws {
        let invitation = try makeInvitation(byte: 9)
        let fake = FakeRendezvousSocketTransport()
        let client = try RendezvousSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .host,
            transport: fake
        )
        let stream = try await client.connect()
        var iterator = stream.makeAsyncIterator()
        let viewer = RemoteSignalingCipher(invitation: invitation, role: .viewer)
        let envelope = try viewer.seal(.control(.requestKeyFrame), sequence: 0)
        let text = try inboundSignalText(envelope: envelope, from: .viewer)

        await fake.push(text: text)
        #expect(try await iterator.next() == .signal(.control(.requestKeyFrame)))
        await fake.push(text: text)
        await expectFailure(&iterator, equals: RemoteSessionCoreError.replayedSequence)
    }

    @Test func innerChannelAndDirectionAreVerified() async throws {
        let invitation = try makeInvitation(byte: 10)

        do {
            let fake = FakeRendezvousSocketTransport()
            let client = try RendezvousSignalingClient(
                endpoint: endpoint,
                invitation: invitation,
                role: .host,
                transport: fake
            )
            let stream = try await client.connect()
            var iterator = stream.makeAsyncIterator()
            let wrongInvitation = try makeInvitation(byte: 11)
            let wrongViewer = RemoteSignalingCipher(invitation: wrongInvitation, role: .viewer)
            let envelope = try wrongViewer.seal(.control(.showScreen), sequence: 0)
            await fake.push(text: try inboundSignalText(envelope: envelope, from: .viewer))
            await expectFailure(&iterator, equals: RemoteSessionCoreError.wrongRendezvousChannel)
        }

        do {
            let fake = FakeRendezvousSocketTransport()
            let client = try RendezvousSignalingClient(
                endpoint: endpoint,
                invitation: invitation,
                role: .host,
                transport: fake
            )
            let stream = try await client.connect()
            var iterator = stream.makeAsyncIterator()
            let reflectedHost = RemoteSignalingCipher(invitation: invitation, role: .host)
            let envelope = try reflectedHost.seal(.control(.showScreen), sequence: 0)
            await fake.push(text: try inboundSignalText(envelope: envelope, from: .viewer))
            await expectFailure(&iterator, equals: RemoteSessionCoreError.unexpectedSignalDirection)
        }
    }

    @Test func oversizedAndExtraFieldSchemasAreRejectedGenerically() async throws {
        let invitation = try makeInvitation(byte: 12)
        let fake = FakeRendezvousSocketTransport()
        let client = try RendezvousSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .host,
            transport: fake
        )
        let stream = try await client.connect()
        var iterator = stream.makeAsyncIterator()

        await fake.push(text: #"{"type":"waiting","invitationExpiresAt":"2026-07-13T12:34:56.000Z","secret":"must-not-pass"}"#)
        await expectFailure(&iterator, equals: RendezvousSignalingError.invalidServerMessage)
        #expect(!RendezvousSignalingError.invalidServerMessage.localizedDescription.contains("must-not-pass"))
        #expect(!RendezvousSignalingError.connectionFailed.localizedDescription.contains(endpoint.host!))
    }

    private func makeInvitation(byte: UInt8) throws -> RemoteInvitationCode {
        try RemoteInvitationCode(secret: Data(repeating: byte, count: 20))
    }

    private func inboundSignalText(
        envelope: SealedSignalingEnvelope,
        from: RemotePeerRole,
        outerSequence: UInt64? = nil
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let envelopeData = try encoder.encode(envelope)
        let object: [String: Any] = [
            "type": "signal",
            "from": from.rawValue,
            "seq": outerSequence ?? envelope.sequence,
            "envelope": encodeBase64URL(envelopeData)
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try #require(String(data: data, encoding: .utf8))
    }

    private func expectFailure<E: Error & Equatable>(
        _ iterator: inout RendezvousSignalingClient.EventStream.Iterator,
        equals expected: E
    ) async {
        do {
            _ = try await iterator.next()
            Issue.record("Expected stream to fail")
        } catch let error as E {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error type: \(type(of: error))")
        }
    }

    private func parseFixtureDate(_ text: String) throws -> Date {
        try Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

private enum FakeSocketError: Error {
    case closed
}

private actor FakeRendezvousSocketTransport: RendezvousSocketTransport {
    private var url: URL?
    private var channelID: RendezvousChannelID?
    private var role: RemotePeerRole?
    private var admissionProof: RendezvousAdmissionProof?
    private var sent = [String]()
    private var queued = [RendezvousSocketMessage]()
    private var waiter: CheckedContinuation<RendezvousSocketMessage, any Error>?
    private var closes = 0

    func connect(
        to url: URL,
        channelID: RendezvousChannelID,
        role: RemotePeerRole,
        admissionProof: RendezvousAdmissionProof
    ) async throws {
        self.url = url
        self.channelID = channelID
        self.role = role
        self.admissionProof = admissionProof
    }

    func send(text: String) async throws {
        sent.append(text)
    }

    func receive() async throws -> RendezvousSocketMessage {
        if !queued.isEmpty {
            return queued.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    func close() async {
        closes += 1
        waiter?.resume(throwing: FakeSocketError.closed)
        waiter = nil
    }

    func push(text: String) {
        push(.text(text))
    }

    func push(_ message: RendezvousSocketMessage) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
        } else {
            queued.append(message)
        }
    }

    func connectedURL() -> URL? { url }
    func connectedChannelID() -> RendezvousChannelID? { channelID }
    func connectedRole() -> RemotePeerRole? { role }
    func connectedAdmissionProof() -> RendezvousAdmissionProof? { admissionProof }
    func sentTexts() -> [String] { sent }
    func closeCount() -> Int { closes }
}

private func encodeBase64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func decodeBase64URL(_ value: String) -> Data? {
    var standard = value.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    standard.append(String(repeating: "=", count: (4 - standard.count % 4) % 4))
    return Data(base64Encoded: standard)
}

private func isBase64URLByte(_ byte: UInt8) -> Bool {
    switch byte {
    case 45, 48...57, 65...90, 95, 97...122:
        true
    default:
        false
    }
}
