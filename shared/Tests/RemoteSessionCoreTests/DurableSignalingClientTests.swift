import Foundation
import Testing
@testable import RemoteSessionCore

/// Exercises durable signaling as a bounded protocol state machine. The oracles require exact
/// modes, role-separated capabilities, exchange-bound encryption, liveness, and fail-closed races.
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

    @Test func pairingBootstrapCloseWinningSuspendedConnectCannotReopenClient() async throws {
        let fake = DurableFakeSocketTransport()
        await fake.suspendConnects()
        let invitation = try RemoteInvitationCode(secret: Data(repeating: 0x27, count: 20))
        let client = try PairingBootstrapSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .viewer,
            transport: fake
        )

        let connectTask = Task {
            try await client.connect()
        }
        #expect(await eventually { await fake.hasSuspendedConnect() })

        // Close must remain authoritative even if the transport later reports a successful open.
        await client.close()
        await fake.resumeSuspendedConnect()

        do {
            _ = try await connectTask.value
            Issue.record("A completed pairing transport connect must not resurrect a closed client")
        } catch {
            #expect(error as? RendezvousSignalingError == .connectionClosed)
        }
        #expect(await fake.closeCallCount() == 2)
    }

    @Test func sessionCloseWinningSuspendedConnectCannotReopenClient() async throws {
        let fake = DurableFakeSocketTransport()
        await fake.suspendConnects()
        let credential = RemoteRendezvousCredential(
            invitation: try RemoteInvitationCode(secret: Data(repeating: 0x37, count: 20))
        )
        let client = try RendezvousSignalingClient(
            endpoint: endpoint,
            credential: credential,
            role: .viewer,
            mode: .session,
            transport: fake
        )

        let connectTask = Task {
            try await client.connect()
        }
        #expect(await eventually { await fake.hasSuspendedConnect() })

        // Disconnect must not be undone by the actor resuming from its transport open await.
        await client.close()
        await fake.resumeSuspendedConnect()

        do {
            _ = try await connectTask.value
            Issue.record("A completed media transport connect must not resurrect a closed client")
        } catch {
            #expect(error as? RendezvousSignalingError == .connectionClosed)
        }
        #expect(await fake.closeCallCount() == 2)
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

    @Test func availabilityCloseWinningSuspendedConnectCannotReopenClient() async throws {
        let fake = DurableFakeSocketTransport()
        await fake.suspendConnects()
        let client = try PairedAvailabilitySignalingClient(
            endpoint: endpoint,
            locator: makeLocator(role: .viewer),
            role: .viewer,
            transport: fake
        )

        let connectTask = Task {
            try await client.connect()
        }
        #expect(await eventually { await fake.hasSuspendedConnect() })

        // Close must be allowed to win while `connect()` is suspended inside the transport.
        await client.close()
        await fake.resumeSuspendedConnect()

        do {
            _ = try await connectTask.value
            Issue.record("A completed transport connect must not resurrect a closed client")
        } catch {
            #expect(error as? RendezvousSignalingError == .connectionClosed)
        }
        // The resumed transport is closed again in case it installed a socket after the first
        // close raced ahead of its connect completion.
        #expect(await fake.closeCallCount() == 2)
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

    @Test func transportCancellationPingFailsClosedWhenLivenessTaskIsNotCancelled() async throws {
        let fake = DurableFakeSocketTransport()
        await fake.failPings(with: .cancellation)
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
        let pingWasAttempted = await eventually { await fake.sentPingCount() == 1 }
        #expect(pingWasAttempted)
        #expect(await fake.lastPingTaskWasCancelled() == false)

        // Never wait directly on the stream until the observable transport-close oracle fires.
        // That keeps this regression bounded even against the old bug, which left the stream open
        // forever after swallowing the transport's literal `CancellationError`.
        let transportWasClosed = await eventually { await fake.closeCallCount() >= 1 }
        guard transportWasClosed else {
            Issue.record("A cancellation-shaped transport failure left availability open")
            await client.close()
            return
        }

        do {
            _ = try await iterator.next()
            Issue.record("Expected the availability stream to finish with connectionClosed")
        } catch {
            #expect(error as? RendezvousSignalingError == .connectionClosed)
        }
    }

    @Test func hostSendsCanonicalProbeAndMatchingAckKeepsAvailabilityOpen() async throws {
        let fake = DurableFakeSocketTransport()
        let heartbeatSleep = FirstHeartbeatThenParkSleep()
        let nonce = Data(0..<16)
        let client = try PairedAvailabilitySignalingClient(
            endpoint: endpoint,
            locator: makeLocator(role: .host),
            role: .host,
            transport: fake,
            livenessIntervalNanoseconds: 0,
            livenessTimeoutNanoseconds: 1_000_000_000,
            livenessSleep: { nanoseconds in
                try await heartbeatSleep.sleep(nanoseconds: nanoseconds)
            },
            applicationProbeAckTimeoutNanoseconds: 60_000_000_000,
            applicationProbeNonceGenerator: { nonce }
        )
        let stream = try await client.connect()
        var iterator = stream.makeAsyncIterator()
        await fake.push(text: #"{"type":"availability-waiting"}"#)
        #expect(try await iterator.next() == .waiting)

        let probe = try await fake.waitForProbeSend()
        #expect(
            probe ==
                #"{"nonce":"AAECAwQFBgcICQoLDA0ODw","type":"availability-probe"}"#
        )
        #expect(await fake.sentPingCount() == 1)

        await fake.push(
            text: #"{"type":"availability-probe-ack","nonce":"AAECAwQFBgcICQoLDA0ODw"}"#
        )
        await fake.push(text: #"{"type":"availability-waiting"}"#)
        #expect(try await iterator.next() == .waiting)
        await client.close()
    }

    @Test func viewerHeartbeatsNeverSendApplicationProbes() async throws {
        let fake = DurableFakeSocketTransport()
        let heartbeatSleep = FirstHeartbeatThenParkSleep()
        let client = try PairedAvailabilitySignalingClient(
            endpoint: endpoint,
            locator: makeLocator(role: .viewer),
            role: .viewer,
            transport: fake,
            livenessIntervalNanoseconds: 0,
            livenessTimeoutNanoseconds: 1_000_000_000,
            livenessSleep: { nanoseconds in
                try await heartbeatSleep.sleep(nanoseconds: nanoseconds)
            }
        )
        let stream = try await client.connect()
        var iterator = stream.makeAsyncIterator()
        await fake.push(text: #"{"type":"availability-waiting"}"#)

        #expect(try await iterator.next() == .waiting)
        #expect(await eventually { await heartbeatSleep.isParked() })
        #expect(await fake.sentPingCount() == 1)
        #expect(await fake.sentTexts().isEmpty)
        await client.close()
    }

    @Test func missingApplicationProbeAckClosesHostAvailability() async throws {
        let fake = DurableFakeSocketTransport()
        let client = try PairedAvailabilitySignalingClient(
            endpoint: endpoint,
            locator: makeLocator(role: .host),
            role: .host,
            transport: fake,
            livenessIntervalNanoseconds: 0,
            livenessTimeoutNanoseconds: 1_000_000_000,
            livenessSleep: { _ in },
            applicationProbeAckTimeoutNanoseconds: 1,
            applicationProbeAckSleep: { _ in
                _ = try await fake.waitForProbeSend()
            },
            applicationProbeNonceGenerator: { Data(repeating: 0xA1, count: 16) }
        )
        let stream = try await client.connect()
        var iterator = stream.makeAsyncIterator()
        await fake.push(text: #"{"type":"availability-waiting"}"#)
        #expect(try await iterator.next() == .waiting)

        do {
            _ = try await iterator.next()
            Issue.record("Expected the missing probe acknowledgement to close availability")
        } catch {
            #expect(error as? RendezvousSignalingError == .connectionClosed)
        }
        #expect(await fake.sentTexts().count == 1)
        #expect(await fake.closeCallCount() >= 1)
    }

    @Test func probeDeadlineClosesHostWhileTransportSendIsSuspended() async throws {
        let fake = DurableFakeSocketTransport()
        await fake.suspendApplicationProbeSends()
        let client = try PairedAvailabilitySignalingClient(
            endpoint: endpoint,
            locator: makeLocator(role: .host),
            role: .host,
            transport: fake,
            livenessIntervalNanoseconds: 0,
            livenessTimeoutNanoseconds: 1_000_000_000,
            livenessSleep: { _ in },
            applicationProbeAckTimeoutNanoseconds: 1,
            applicationProbeAckSleep: { _ in
                _ = try await fake.waitForProbeSend()
            },
            applicationProbeNonceGenerator: { Data(repeating: 0xB2, count: 16) }
        )
        let stream = try await client.connect()
        var iterator = stream.makeAsyncIterator()
        await fake.push(text: #"{"type":"availability-waiting"}"#)
        #expect(try await iterator.next() == .waiting)

        do {
            _ = try await iterator.next()
            Issue.record("Expected the armed deadline to close a suspended probe send")
        } catch {
            #expect(error as? RendezvousSignalingError == .connectionClosed)
        }
        #expect(await fake.sentTexts().count == 1)
        #expect(await fake.closeCallCount() >= 1)
    }

    @Test func staleProbeAckFailsClosedAndCannotBlessReplacementClient() async throws {
        let fake = DurableFakeSocketTransport()
        let nonce = Data(repeating: 0xC3, count: 16)
        let oldClient = try PairedAvailabilitySignalingClient(
            endpoint: endpoint,
            locator: makeLocator(role: .host),
            role: .host,
            transport: fake,
            livenessIntervalNanoseconds: 0,
            livenessTimeoutNanoseconds: 1_000_000_000,
            livenessSleep: { _ in },
            applicationProbeAckTimeoutNanoseconds: 1,
            applicationProbeAckSleep: { _ in
                _ = try await fake.waitForProbeSend()
            },
            applicationProbeNonceGenerator: { nonce }
        )
        let oldStream = try await oldClient.connect()
        var oldIterator = oldStream.makeAsyncIterator()
        await fake.push(text: #"{"type":"availability-waiting"}"#)
        #expect(try await oldIterator.next() == .waiting)
        do {
            _ = try await oldIterator.next()
            Issue.record("Expected the old client probe to time out")
        } catch {
            #expect(error as? RendezvousSignalingError == .connectionClosed)
        }

        // Simulate an acknowledgement arriving on a reused test transport only after the old
        // client has been closed. A replacement with the same injected nonce still has no pending
        // probe, so the late acknowledgement must be rejected rather than authenticating it.
        await fake.push(
            text: #"{"type":"availability-probe-ack","nonce":"w8PDw8PDw8PDw8PDw8PDww"}"#
        )
        let replacement = try PairedAvailabilitySignalingClient(
            endpoint: endpoint,
            locator: makeLocator(role: .host),
            role: .host,
            transport: fake,
            firstProtocolStateTimeoutNanoseconds: 60_000_000_000,
            applicationProbeNonceGenerator: { nonce }
        )
        let replacementStream = try await replacement.connect()
        var replacementIterator = replacementStream.makeAsyncIterator()
        do {
            _ = try await replacementIterator.next()
            Issue.record("Expected a late acknowledgement to fail the replacement closed")
        } catch {
            #expect(error as? RendezvousSignalingError == .invalidServerMessage)
        }
        #expect(await fake.sentTexts().count == 1)
    }

    @Test func mismatchedAckForActiveProbeFailsClosed() async throws {
        let fake = DurableFakeSocketTransport()
        let heartbeatSleep = FirstHeartbeatThenParkSleep()
        let client = try PairedAvailabilitySignalingClient(
            endpoint: endpoint,
            locator: makeLocator(role: .host),
            role: .host,
            transport: fake,
            livenessIntervalNanoseconds: 0,
            livenessTimeoutNanoseconds: 1_000_000_000,
            livenessSleep: { nanoseconds in
                try await heartbeatSleep.sleep(nanoseconds: nanoseconds)
            },
            applicationProbeAckTimeoutNanoseconds: 60_000_000_000,
            applicationProbeNonceGenerator: { Data(repeating: 0xE5, count: 16) }
        )
        let stream = try await client.connect()
        var iterator = stream.makeAsyncIterator()
        await fake.push(text: #"{"type":"availability-waiting"}"#)
        #expect(try await iterator.next() == .waiting)
        _ = try await fake.waitForProbeSend()

        await fake.push(
            text: #"{"type":"availability-probe-ack","nonce":"AAAAAAAAAAAAAAAAAAAAAA"}"#
        )
        do {
            _ = try await iterator.next()
            Issue.record("Expected a mismatched active-probe acknowledgement to fail closed")
        } catch {
            #expect(error as? RendezvousSignalingError == .invalidServerMessage)
        }
        #expect(await fake.closeCallCount() >= 1)
    }

    @Test func matchingAckBeforeSuspendedSendReturnsCompletesExactProbe() async throws {
        let fake = DurableFakeSocketTransport()
        await fake.suspendApplicationProbeSends()
        let heartbeatSleep = FirstHeartbeatThenParkSleep()
        let client = try PairedAvailabilitySignalingClient(
            endpoint: endpoint,
            locator: makeLocator(role: .host),
            role: .host,
            transport: fake,
            livenessIntervalNanoseconds: 0,
            livenessTimeoutNanoseconds: 1_000_000_000,
            livenessSleep: { nanoseconds in
                try await heartbeatSleep.sleep(nanoseconds: nanoseconds)
            },
            applicationProbeAckTimeoutNanoseconds: 60_000_000_000,
            applicationProbeNonceGenerator: { Data(0..<16) }
        )
        let stream = try await client.connect()
        var iterator = stream.makeAsyncIterator()
        await fake.push(text: #"{"type":"availability-waiting"}"#)
        #expect(try await iterator.next() == .waiting)
        _ = try await fake.waitForProbeSend()

        await fake.push(
            text: #"{"type":"availability-probe-ack","nonce":"AAECAwQFBgcICQoLDA0ODw"}"#
        )
        // The receive loop asks for its next message only after it parsed and recorded the ack.
        #expect(await eventually { await fake.hasSuspendedReceive() })
        await fake.resumeSuspendedApplicationProbeSend()
        #expect(await eventually { await heartbeatSleep.isParked() })

        await fake.push(text: #"{"type":"availability-waiting"}"#)
        #expect(try await iterator.next() == .waiting)
        await client.close()
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

    private func eventually(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if await predicate() { return true }
            await Task.yield()
        }
        return false
    }
}

/// Deterministic terminal error from the in-memory durable socket.
private enum DurableFakeSocketError: Error { case closed }

/// Scripted ping outcomes used to distinguish cancellation from ordinary liveness failure.
private enum DurableFakePingFailure: Sendable {
    case none
    case closed
    case cancellation
}

/// Releases the first heartbeat immediately, then parks later intervals for deterministic tests.
private actor FirstHeartbeatThenParkSleep {
    private var callCount = 0
    private var parked = false

    func sleep(nanoseconds _: UInt64) async throws {
        callCount += 1
        guard callCount > 1 else { return }
        parked = true
        try await Task<Never, Never>.sleep(nanoseconds: 60_000_000_000)
    }

    func isParked() -> Bool { parked }
}

/// Actor-isolated socket double that records exact upgrade inputs and scripts connection races.
private actor DurableFakeSocketTransport: RendezvousSocketTransport {
    private var url: URL?
    private var role: RemotePeerRole?
    private var admissionProof: RendezvousAdmissionProof?
    private var viewerAdmissionProof: RendezvousAdmissionProof?
    private var mode: RemoteRendezvousMode?
    private var sent = [String]()
    private var pingFailure = DurableFakePingFailure.none
    private var pingCount = 0
    private var pingTaskCancellationStates = [Bool]()
    private var shouldSuspendApplicationProbeSends = false
    private var suspendedApplicationProbeSend: CheckedContinuation<Void, any Error>?
    private var shouldSuspendConnects = false
    private var suspendedConnect: CheckedContinuation<Void, any Error>?
    private var probeSendWaiter: CheckedContinuation<String, any Error>?
    private var closeCalls = 0
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
        if shouldSuspendConnects {
            try await withCheckedThrowingContinuation {
                suspendedConnect = $0
            }
        }
    }

    func send(text: String) async throws {
        sent.append(text)
        guard Self.isApplicationProbe(text) else { return }
        probeSendWaiter?.resume(returning: text)
        probeSendWaiter = nil
        if shouldSuspendApplicationProbeSends {
            try await withCheckedThrowingContinuation {
                suspendedApplicationProbeSend = $0
            }
        }
    }

    func receive() async throws -> RendezvousSocketMessage {
        if !queued.isEmpty { return queued.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func sendPing(timeoutNanoseconds _: UInt64) async throws {
        pingCount += 1
        pingTaskCancellationStates.append(Task.isCancelled)
        switch pingFailure {
        case .none:
            return
        case .closed:
            throw DurableFakeSocketError.closed
        case .cancellation:
            throw CancellationError()
        }
    }

    func close() async {
        closeCalls += 1
        waiter?.resume(throwing: DurableFakeSocketError.closed)
        waiter = nil
        suspendedApplicationProbeSend?.resume(throwing: DurableFakeSocketError.closed)
        suspendedApplicationProbeSend = nil
        probeSendWaiter?.resume(throwing: DurableFakeSocketError.closed)
        probeSendWaiter = nil
    }

    func failPings(with failure: DurableFakePingFailure = .closed) {
        pingFailure = failure
    }

    func suspendConnects() { shouldSuspendConnects = true }

    func hasSuspendedConnect() -> Bool { suspendedConnect != nil }

    func resumeSuspendedConnect() {
        shouldSuspendConnects = false
        suspendedConnect?.resume()
        suspendedConnect = nil
    }

    func sentPingCount() -> Int { pingCount }

    func lastPingTaskWasCancelled() -> Bool? { pingTaskCancellationStates.last }

    func suspendApplicationProbeSends() { shouldSuspendApplicationProbeSends = true }

    func resumeSuspendedApplicationProbeSend() {
        shouldSuspendApplicationProbeSends = false
        suspendedApplicationProbeSend?.resume()
        suspendedApplicationProbeSend = nil
    }

    func waitForProbeSend() async throws -> String {
        if let probe = sent.first(where: Self.isApplicationProbe) {
            return probe
        }
        return try await withCheckedThrowingContinuation { probeSendWaiter = $0 }
    }

    func closeCallCount() -> Int { closeCalls }

    func hasSuspendedReceive() -> Bool { waiter != nil }

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

    private static func isApplicationProbe(_ text: String) -> Bool {
        text.contains(#""type":"availability-probe""#)
    }
}
