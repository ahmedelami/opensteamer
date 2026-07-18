import Foundation
import Testing
@testable import RemoteSessionCore

struct DurableSignalingClientTests {
    private let endpoint = URL(string: "wss://rendezvous.example.test")!

    @Test func pairingBootstrapUsesNegotiatedPairingModeAndBoundedPayloads() async throws {
        let invitation = try RemoteInvitationCode(secret: Data(repeating: 7, count: 20))
        let hostFake = DurableFakeSocketTransport()
        let viewerFake = DurableFakeSocketTransport()
        let hostClient = try PairingBootstrapSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .host,
            transport: hostFake
        )
        let viewerClient = try PairingBootstrapSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .viewer,
            transport: viewerFake
        )
        let hostEvents = try await hostClient.connect()
        let viewerEvents = try await viewerClient.connect()
        #expect(await hostFake.connectedMode() == .pairing)
        #expect(await viewerFake.connectedMode() == .pairing)
        #expect(await hostFake.connectedURL()?.path == "/v1/rendezvous")
        #expect(await viewerFake.connectedURL()?.path == "/v1/rendezvous")
        #expect(await hostFake.connectedViewerAdmissionProof() == nil)
        #expect(await viewerFake.connectedViewerAdmissionProof() == nil)

        let viewerIdentity = try RemoteDeviceIdentity(
            deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            role: .viewer,
            displayName: "iPhone",
            signingPrivateKeyRawRepresentation: Data(repeating: 0x22, count: 32)
        )
        let participant = try RemotePairingParticipant(
            identity: viewerIdentity,
            invitation: invitation,
            ephemeralPrivateKeyRawRepresentation: Data(repeating: 0x32, count: 32),
            nonce: Data(repeating: 0x42, count: 32)
        )
        let payload = RemotePairingPayload.hello(participant.hello)
        try await viewerClient.send(payload)
        let outbound = try #require(await viewerFake.sentTexts().first)
        let forwarded = try forwardedText(outbound, from: .viewer)
        await hostFake.push(text: forwarded)
        var iterator = hostEvents.makeAsyncIterator()
        #expect(try await iterator.next() == .signal(payload))
        _ = viewerEvents
        await hostClient.close()
        await viewerClient.close()
    }

    @Test func pairingBootstrapRestartsSequencesAndReplayWindowForReplacementPeer() async throws {
        let invitation = try RemoteInvitationCode(secret: Data(repeating: 0x17, count: 20))
        let hostFake = DurableFakeSocketTransport()
        let viewerFake = DurableFakeSocketTransport()
        let host = try PairingBootstrapSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .host,
            transport: hostFake
        )
        let viewer = try PairingBootstrapSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .viewer,
            transport: viewerFake
        )
        let hostEvents = try await host.connect()
        let viewerEvents = try await viewer.connect()
        var hostIterator = hostEvents.makeAsyncIterator()
        var viewerIterator = viewerEvents.makeAsyncIterator()

        let hostIdentity = try RemoteDeviceIdentity(
            deviceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            role: .host,
            displayName: "Mac",
            signingPrivateKeyRawRepresentation: Data(repeating: 0x21, count: 32)
        )
        let firstViewerIdentity = try RemoteDeviceIdentity(
            deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            role: .viewer,
            displayName: "First iPhone",
            signingPrivateKeyRawRepresentation: Data(repeating: 0x22, count: 32)
        )
        let firstHostHello = try RemotePairingParticipant(
            identity: hostIdentity,
            invitation: invitation
        ).hello
        let firstViewerHello = try RemotePairingParticipant(
            identity: firstViewerIdentity,
            invitation: invitation
        ).hello

        try await host.send(.hello(firstHostHello))
        try await viewer.send(.hello(firstViewerHello))
        await hostFake.push(
            text: try forwardedText(
                #require(await viewerFake.sentTexts().first),
                from: .viewer
            )
        )
        await viewerFake.push(
            text: try forwardedText(
                #require(await hostFake.sentTexts().first),
                from: .host
            )
        )
        #expect(try await hostIterator.next() == .signal(.hello(firstViewerHello)))
        #expect(try await viewerIterator.next() == .signal(.hello(firstHostHello)))

        await hostFake.push(text: #"{"type":"peer-left","role":"viewer"}"#)
        await viewerFake.push(text: #"{"type":"peer-left","role":"host"}"#)
        #expect(try await hostIterator.next() == .peerLeft(.viewer))
        #expect(try await viewerIterator.next() == .peerLeft(.host))

        let replacementViewerIdentity = try RemoteDeviceIdentity(
            deviceID: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            role: .viewer,
            displayName: "Replacement iPhone",
            signingPrivateKeyRawRepresentation: Data(repeating: 0x23, count: 32)
        )
        let replacementHostHello = try RemotePairingParticipant(
            identity: hostIdentity,
            invitation: invitation
        ).hello
        let replacementViewerHello = try RemotePairingParticipant(
            identity: replacementViewerIdentity,
            invitation: invitation
        ).hello
        try await host.send(.hello(replacementHostHello))
        try await viewer.send(.hello(replacementViewerHello))

        let secondHostOutbound = try #require(await hostFake.sentTexts().last)
        let secondViewerOutbound = try #require(await viewerFake.sentTexts().last)
        #expect(try outboundSequence(secondHostOutbound) == 0)
        #expect(try outboundSequence(secondViewerOutbound) == 0)
        await hostFake.push(text: try forwardedText(secondViewerOutbound, from: .viewer))
        await viewerFake.push(text: try forwardedText(secondHostOutbound, from: .host))
        #expect(try await hostIterator.next() == .signal(.hello(replacementViewerHello)))
        #expect(try await viewerIterator.next() == .signal(.hello(replacementHostHello)))

        await host.close()
        await viewer.close()
    }

    @Test func availabilityMapsBoundedUnavailableErrorForTransientRetry() async throws {
        let fake = DurableFakeSocketTransport()
        let client = try PairedAvailabilitySignalingClient(
            endpoint: endpoint,
            locator: makeLocator(role: .viewer),
            role: .viewer,
            transport: fake
        )
        let stream = try await client.connect()
        var iterator = stream.makeAsyncIterator()
        await fake.push(text: #"{"type":"error","error":"availability_unavailable"}"#)
        #expect(try await iterator.next() == .serverError(.peerUnavailable))
        await client.close()
    }

    @Test func availabilityClosesBeforeHeartbeatWhenFirstProtocolStateNeverArrives() async throws {
        let fake = DurableFakeSocketTransport()
        let client = try PairedAvailabilitySignalingClient(
            endpoint: endpoint,
            locator: makeLocator(role: .host),
            role: .host,
            transport: fake,
            firstProtocolStateTimeoutNanoseconds: 1,
            livenessIntervalNanoseconds: 0,
            livenessTimeoutNanoseconds: 1_000_000_000,
            firstProtocolStateSleep: { _ in },
            livenessSleep: { _ in }
        )
        let stream = try await client.connect()
        var iterator = stream.makeAsyncIterator()

        do {
            _ = try await iterator.next()
            Issue.record("Expected the first-protocol-state deadline to close availability")
        } catch {
            #expect(error as? RendezvousSignalingError == .connectionClosed)
        }
        #expect(await fake.sentPingCount() == 0)
    }

    @Test func availabilityValidFirstStateCancelsDeadlineAndStartsHeartbeat() async throws {
        let exchangeID = try RemoteAvailabilityExchangeID(rawValue: Data(0..<16))
        let states: [(String, PairedAvailabilitySignalingEvent)] = [
            (#"{"type":"availability-waiting"}"#, .waiting),
            (
                #"{"type":"availability-ready","role":"host","exchangeID":"\#(exchangeID.wireValue)"}"#,
                .ready(role: .host, exchangeID: exchangeID)
            ),
        ]

        for (text, expectedEvent) in states {
            let fake = DurableFakeSocketTransport()
            await fake.failPings()
            let client = try PairedAvailabilitySignalingClient(
                endpoint: endpoint,
                locator: makeLocator(role: .host),
                role: .host,
                transport: fake,
                firstProtocolStateTimeoutNanoseconds: 60_000_000_000,
                livenessIntervalNanoseconds: 0,
                livenessTimeoutNanoseconds: 1_000_000_000,
                livenessSleep: { _ in }
            )
            let stream = try await client.connect()
            var iterator = stream.makeAsyncIterator()
            await fake.push(text: text)

            #expect(try await iterator.next() == expectedEvent)
            do {
                _ = try await iterator.next()
                Issue.record("Expected failed post-state heartbeat to close availability")
            } catch {
                #expect(error as? RendezvousSignalingError == .connectionClosed)
            }
            #expect(await fake.sentPingCount() == 1)
        }
    }

    @Test func availabilityPingFailureClosesAVisiblyOpenGhostSocket() async throws {
        let fake = DurableFakeSocketTransport()
        await fake.failPings()
        let client = try PairedAvailabilitySignalingClient(
            endpoint: endpoint,
            locator: makeLocator(role: .host),
            role: .host,
            transport: fake,
            livenessIntervalNanoseconds: 0,
            livenessTimeoutNanoseconds: 1_000_000_000,
            livenessSleep: { _ in }
        )
        let stream = try await client.connect()
        var iterator = stream.makeAsyncIterator()
        await fake.push(text: #"{"type":"availability-waiting"}"#)

        #expect(try await iterator.next() == .waiting)
        do {
            _ = try await iterator.next()
            Issue.record("Expected the failed liveness probe to close availability")
        } catch {
            #expect(error as? RendezvousSignalingError == .connectionClosed)
        }
        #expect(await fake.sentPingCount() == 1)
    }

    @Test func availabilityRejectsUnboundedOrExtendedErrorSchemas() async throws {
        let oversizedError = String(repeating: "a", count: 65)
        for text in [
            #"{"type":"error","error":"availability unavailable"}"#,
            #"{"type":"error","error":"availability_unavailable","extra":true}"#,
            #"{"type":"error","error":"\#(oversizedError)"}"#,
        ] {
            let fake = DurableFakeSocketTransport()
            let client = try PairedAvailabilitySignalingClient(
                endpoint: endpoint,
                locator: makeLocator(role: .viewer),
                role: .viewer,
                transport: fake
            )
            let stream = try await client.connect()
            var iterator = stream.makeAsyncIterator()
            await fake.push(text: text)
            do {
                _ = try await iterator.next()
                Issue.record("Availability accepted an invalid server-error schema")
            } catch let error as RendezvousSignalingError {
                #expect(error == .invalidServerMessage)
            }
            await client.close()
        }
    }

    @Test func availabilityRejectsLegacyWaitingAndUsesExactAvailabilityMode() async throws {
        let fake = DurableFakeSocketTransport()
        let client = try PairedAvailabilitySignalingClient(
            endpoint: endpoint,
            locator: makeLocator(role: .host),
            role: .host,
            transport: fake
        )
        let stream = try await client.connect()
        #expect(await fake.connectedMode() == .availability)
        #expect(await fake.connectedURL()?.path == "/v2/availability")
        #expect(await fake.connectedViewerAdmissionProof() != nil)
        var iterator = stream.makeAsyncIterator()
        await fake.push(
            text: #"{"type":"waiting","invitationExpiresAt":"2026-07-13T12:34:56.000Z"}"#
        )
        do {
            _ = try await iterator.next()
            Issue.record("Availability accepted the legacy invitation waiting schema")
        } catch let error as RendezvousSignalingError {
            #expect(error == .invalidServerMessage)
        }
    }

    @Test func availabilityLocatorsSeparateRoleCapabilitiesAndRejectRoleSubstitution() throws {
        let host = try makeLocator(role: .host)
        let viewer = try makeLocator(role: .viewer)
        let pairRoot = Data(repeating: 0xA1, count: 32)
        let pairID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let transcript = Data(repeating: 0xB2, count: 32)
        let routingMaterial = remoteHKDF(
            input: pairRoot,
            salt: remoteDomainSeparated(
                "AudioStreamer.Availability.Route.Salt.v1",
                remoteUUIDData(pairID),
                transcript
            ),
            label: "AudioStreamer.Availability.Route.v1"
        )
        let legacyChannel = RendezvousChannelID(
            derivedBytes: remoteHKDF(
                input: routingMaterial,
                salt: transcript,
                label: "AudioStreamer.Availability.Channel.v1"
            )
        )
        let expectedHostProof = RendezvousAdmissionProof(
            derivedBytes: remoteHKDF(
                input: routingMaterial,
                salt: transcript,
                label: "AudioStreamer.Availability.Admission.Host.v2"
            )
        )
        let expectedViewerProof = RendezvousAdmissionProof(
            derivedBytes: remoteHKDF(
                input: routingMaterial,
                salt: transcript,
                label: "AudioStreamer.Availability.Admission.Viewer.v2"
            )
        )

        #expect(host.localRole == .host)
        #expect(viewer.localRole == .viewer)
        #expect(host.channelID == viewer.channelID)
        #expect(host.channelID != legacyChannel)
        #expect(host.admissionProof == expectedHostProof)
        #expect(viewer.admissionProof == expectedViewerProof)
        #expect(host.admissionProof != viewer.admissionProof)
        #expect(host.viewerRegistrationProof == viewer.admissionProof)
        #expect(viewer.viewerRegistrationProof == nil)

        #expect(throws: RemoteSessionCoreError.invalidRendezvousCredential) {
            try PairedAvailabilitySignalingClient(
                endpoint: endpoint,
                locator: viewer,
                role: .host,
                transport: DurableFakeSocketTransport()
            )
        }
        #expect(throws: RemoteSessionCoreError.invalidRendezvousCredential) {
            try PairedAvailabilitySignalingClient(
                endpoint: endpoint,
                locator: host,
                role: .viewer,
                transport: DurableFakeSocketTransport()
            )
        }
    }

    @Test func availabilityBindsExactExchangeToEnvelopeAndRotatesKeys() async throws {
        let hostLocator = try makeLocator(role: .host)
        let viewerLocator = try makeLocator(role: .viewer)
        let firstID = try RemoteAvailabilityExchangeID(rawValue: Data(0..<16))
        let secondID = try RemoteAvailabilityExchangeID(rawValue: Data(16..<32))
        let firstHostCredential = try hostLocator.credential(exchangeID: firstID)
        let firstViewerCredential = try viewerLocator.credential(exchangeID: firstID)
        let secondHostCredential = try hostLocator.credential(exchangeID: secondID)

        #expect(firstHostCredential.channelID == firstViewerCredential.channelID)
        #expect(firstHostCredential.channelID == secondHostCredential.channelID)
        #expect(firstHostCredential.admissionProof != firstViewerCredential.admissionProof)
        #expect(firstHostCredential.admissionProof == secondHostCredential.admissionProof)
        #expect(firstHostCredential != firstViewerCredential)
        #expect(firstHostCredential != secondHostCredential)

        let hostCipher = RemoteAvailabilityCipher(
            credential: firstHostCredential,
            exchangeID: firstID,
            role: .host
        )
        let viewerCipher = RemoteAvailabilityCipher(
            credential: firstViewerCredential,
            exchangeID: firstID,
            role: .viewer
        )
        let request = dummyReconnectRequest()
        let envelope = try viewerCipher.seal(.reconnectRequest(request), sequence: 9)
        #expect(try hostCipher.open(envelope) == .reconnectRequest(request))
        #expect(throws: RemoteSessionCoreError.authenticationFailed) {
            try RemoteAvailabilityCipher(
                credential: secondHostCredential,
                exchangeID: secondID,
                role: .host
            ).open(envelope)
        }

        let encoded = try JSONEncoder().encode(envelope)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == [
            "version", "channelID", "exchangeID", "direction", "sequence", "ciphertext"
        ])
    }

    @Test func availabilityClientRekeysAfterReadyAndRelaysSignedReconnectMessage() async throws {
        let hostLocator = try makeLocator(role: .host)
        let viewerLocator = try makeLocator(role: .viewer)
        let exchangeID = try RemoteAvailabilityExchangeID(rawValue: Data(0..<16))
        let hostFake = DurableFakeSocketTransport()
        let viewerFake = DurableFakeSocketTransport()
        let host = try PairedAvailabilitySignalingClient(
            endpoint: endpoint,
            locator: hostLocator,
            role: .host,
            transport: hostFake
        )
        let viewer = try PairedAvailabilitySignalingClient(
            endpoint: endpoint,
            locator: viewerLocator,
            role: .viewer,
            transport: viewerFake
        )
        let hostEvents = try await host.connect()
        let viewerEvents = try await viewer.connect()
        #expect(await hostFake.connectedURL()?.path == "/v2/availability")
        #expect(await viewerFake.connectedURL()?.path == "/v2/availability")
        #expect(await hostFake.connectedAdmissionProof() == hostLocator.admissionProof)
        #expect(await viewerFake.connectedAdmissionProof() == viewerLocator.admissionProof)
        #expect(
            await hostFake.connectedViewerAdmissionProof()
                == viewerLocator.admissionProof
        )
        #expect(await viewerFake.connectedViewerAdmissionProof() == nil)
        var hostIterator = hostEvents.makeAsyncIterator()
        var viewerIterator = viewerEvents.makeAsyncIterator()
        await hostFake.push(
            text: #"{"type":"availability-ready","role":"host","exchangeID":"\#(exchangeID.wireValue)"}"#
        )
        await viewerFake.push(
            text: #"{"type":"availability-ready","role":"viewer","exchangeID":"\#(exchangeID.wireValue)"}"#
        )
        #expect(try await hostIterator.next() == .ready(role: .host, exchangeID: exchangeID))
        #expect(try await viewerIterator.next() == .ready(role: .viewer, exchangeID: exchangeID))

        let request = dummyReconnectRequest()
        try await viewer.send(.reconnectRequest(request))
        let outbound = try #require(await viewerFake.sentTexts().first)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(outbound.utf8)) as? [String: Any]
        )
        #expect(Set(object.keys) == ["type", "exchangeID", "seq", "envelope"])
        #expect(object["type"] as? String == "availability-signal")
        #expect(object["exchangeID"] as? String == exchangeID.wireValue)
        await hostFake.push(text: try forwardedText(outbound, from: .viewer))
        #expect(try await hostIterator.next() == .signal(.reconnectRequest(request)))
        await host.close()
        await viewer.close()
    }

    private func makeLocator(role: RemotePeerRole) throws -> RemoteAvailabilityLocator {
        try RemoteAvailabilityLocator(
            pairRootKey: Data(repeating: 0xA1, count: 32),
            pairID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            pairingTranscriptHash: Data(repeating: 0xB2, count: 32),
            localRole: role
        )
    }

    private func dummyReconnectRequest() -> RemoteReconnectRequest {
        RemoteReconnectRequest(
            protocolVersion: RemoteReconnectRequest.currentProtocolVersion,
            pairID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            requesterDeviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            requesterRole: .viewer,
            targetDeviceID: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            sequence: 1,
            ephemeralKeyAgreementPublicKey: Data(repeating: 1, count: 32),
            nonce: Data(repeating: 2, count: 32),
            signature: Data(repeating: 3, count: 64)
        )
    }

    private func forwardedText(_ outbound: String, from: RemotePeerRole) throws -> String {
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(outbound.utf8)) as? [String: Any]
        )
        object["from"] = from.rawValue
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try #require(String(data: data, encoding: .utf8))
    }

    private func outboundSequence(_ outbound: String) throws -> UInt64 {
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(outbound.utf8)) as? [String: Any]
        )
        return try #require(object["seq"] as? UInt64)
    }
}

private enum DurableFakeSocketError: Error { case closed }

private actor DurableFakeSocketTransport: RendezvousSocketTransport {
    private var url: URL?
    private var role: RemotePeerRole?
    private var admissionProof: RendezvousAdmissionProof?
    private var viewerAdmissionProof: RendezvousAdmissionProof?
    private var mode: RemoteRendezvousMode?
    private var sent = [String]()
    private var pingsFail = false
    private var pingCount = 0
    private var queued = [RendezvousSocketMessage]()
    private var waiter: CheckedContinuation<RendezvousSocketMessage, any Error>?

    func connect(
        to url: URL,
        channelID _: RendezvousChannelID,
        role: RemotePeerRole,
        admissionProof: RendezvousAdmissionProof,
        viewerAdmissionProof: RendezvousAdmissionProof?,
        mode: RemoteRendezvousMode
    ) async throws {
        self.url = url
        self.role = role
        self.admissionProof = admissionProof
        self.viewerAdmissionProof = viewerAdmissionProof
        self.mode = mode
    }

    func send(text: String) async throws { sent.append(text) }

    func receive() async throws -> RendezvousSocketMessage {
        if !queued.isEmpty { return queued.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func sendPing(timeoutNanoseconds _: UInt64) async throws {
        pingCount += 1
        if pingsFail { throw DurableFakeSocketError.closed }
    }

    func close() async {
        waiter?.resume(throwing: DurableFakeSocketError.closed)
        waiter = nil
    }

    func failPings() { pingsFail = true }

    func sentPingCount() -> Int { pingCount }

    func push(text: String) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: .text(text))
        } else {
            queued.append(.text(text))
        }
    }

    func connectedURL() -> URL? { url }
    func connectedRole() -> RemotePeerRole? { role }
    func connectedAdmissionProof() -> RendezvousAdmissionProof? { admissionProof }
    func connectedViewerAdmissionProof() -> RendezvousAdmissionProof? {
        viewerAdmissionProof
    }
    func connectedMode() -> RemoteRendezvousMode? { mode }
    func sentTexts() -> [String] { sent }
}
