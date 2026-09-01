#if DEBUG && os(macOS)
import AudioToolbox
import CaptureCore
import Foundation
import XCTest
@testable import CaptureServer
@testable import WebRTCTransport

final class WorldwideIPhoneMicrophoneForwardingWebRTCIntegrationTests:
    XCTestCase
{
    func testLateRealInboundRTPRevivesExhaustedForwardingOnSamePeerAndTrack()
        async throws
    {
        let host = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(
                role: .host,
                iceServers: []
            )
        )
        let viewer = try WebRTCPeer.makeHeadlessViewerForTesting(
            configuration: WebRTCTransportConfiguration(
                role: .viewer,
                iceServers: []
            )
        )
        let peerEvents = ForwardingIntegrationPeerEvents()
        let hostForwarder = Task<String?, Never> {
            do {
                for await event in host.events {
                    await peerEvents.observeHost(event)
                    if case .outboundSignal(let payload) = event {
                        try await viewer.handle(payload)
                    }
                }
                return nil
            } catch {
                return String(describing: error)
            }
        }
        let viewerForwarder = Task<String?, Never> {
            do {
                for await event in viewer.events {
                    if case .outboundSignal(let payload) = event {
                        try await host.handle(payload)
                    }
                }
                return nil
            } catch {
                return String(describing: error)
            }
        }

        let outputs = [
            ForwardingIntegrationOutput(),
            ForwardingIntegrationOutput(),
        ]
        let outputFactory = ForwardingIntegrationOutputFactory(
            outputs: outputs
        )
        let forwarding = ForwardingIntegrationHarness(
            outputFactory: outputFactory
        )

        do {
            try await host.start()
            let negotiated = await eventually {
                let sender = await viewer
                    .iPhoneMicrophoneSenderStateForTesting()
                let hostHealthy = await host
                    .isTransportHealthyForMediaForTesting
                let viewerHealthy = await viewer
                    .isTransportHealthyForMediaForTesting
                let track = await peerEvents.iPhoneMicrophoneTrack()
                return hostHealthy
                    && viewerHealthy
                    && track != nil
                    && sender.senderOwnsLocalTrack
                    && sender.bindingNegotiationEpoch
                        == sender.currentNegotiationEpoch
            }
            XCTAssertTrue(
                negotiated,
                "The real loopback never acquired its exact microphone sender and receiver."
            )

            let negotiatedTrack = await peerEvents
                .iPhoneMicrophoneTrack()
            let track = try XCTUnwrap(negotiatedTrack)
            let trackIdentity = ObjectIdentifier(track)
            let receiverID = track.receiverID
            let nativeTrackID = track.nativeTrackID

            _ = try await viewer
                .debugEnableIPhoneMicrophoneTrackAfterRawProcessingForTesting(
                    maximumAttempts: 100,
                    rawProcessingMaximumAttempts: 100
                )
            let armedWithoutPCM = await viewer
                .iPhoneMicrophoneSenderStateForTesting()
            XCTAssertTrue(armedWithoutPCM.trackIsEnabled)
            XCTAssertEqual(
                armedWithoutPCM.nativeDeliveryCallbackCount,
                0
            )
            XCTAssertEqual(
                armedWithoutPCM.nativeDeliveredFrameCount,
                0
            )
            do {
                _ = try await viewer
                    .awaitHeadlessMacIPhoneMicrophoneOutboundRTPForTesting(
                        timeout: .milliseconds(300),
                        callbackTimeout: .milliseconds(75)
                    )
                XCTFail(
                    "The exact sender must remain stalled before real source PCM starts."
                )
            } catch let error as WebRTCTransportError {
                guard case .iPhoneMicrophoneStageFailed(
                    .outboundRTPDidNotStart,
                    _
                ) = error else {
                    XCTFail("Unexpected pre-PCM sender failure: \(error)")
                    throw error
                }
            }
            _ = try await viewer
                .debugEnableIPhoneMicrophoneTrackAfterRawProcessingForTesting(
                    maximumAttempts: 100,
                    rawProcessingMaximumAttempts: 100
                )

            let peerGeneration: UInt64 = 1
            await forwarding.prepare(
                peer: host,
                peerGeneration: peerGeneration,
                track: track
            )
            let admitted = await forwarding.snapshot()
            XCTAssertTrue(admitted.exactTrackAdmitted)
            XCTAssertTrue(track.isEnabled)
            XCTAssertEqual(outputFactory.requestCount, 1)

            let stalledStatistics = await host.statisticsSnapshot()
            XCTAssertEqual(
                stalledStatistics.inboundAudio?.packets ?? 0,
                0
            )
            XCTAssertEqual(
                stalledStatistics.inboundAudio?.bytes ?? 0,
                0
            )
            await forwarding.publish(
                stalledStatistics.inboundAudio,
                peer: host,
                peerGeneration: peerGeneration
            )
            let exhausted = await forwarding.snapshot()
            XCTAssertEqual(exhausted.phase, .sourceMediaStalled)
            XCTAssertEqual(
                exhausted.lastFailureCategory,
                .sourceMediaStalled
            )
            XCTAssertNil(exhausted.currentAttemptID)
            XCTAssertFalse(track.isEnabled)
            XCTAssertEqual(outputs[0].stopCount, 1)
            let exhaustedKey = try XCTUnwrap(exhausted.lastAttemptedKey)

            let frameCount = 480
            let tone: [Int16] = (0..<(frameCount * 2)).map { index in
                ((index / 2) % 48) < 24 ? 6_000 : -6_000
            }
            let producer = Task<Int, Never> {
                var delivered = 0
                for _ in 0..<1_000 where !Task.isCancelled {
                    if await viewer
                        .deliverHeadlessMacIPhoneMicrophoneFramesForTesting(
                            tone,
                            frameCount: frameCount
                        ) {
                        delivered += 1
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return delivered
            }

            var lastInbound = stalledStatistics.inboundAudio
            var revivedKey:
                WorldwideIPhoneMicrophoneForwardingKey?
            var healthySnapshot:
                WorldwideIPhoneMicrophoneForwardingHostSnapshot?
            for _ in 0..<4 {
                let nextInbound = await awaitInboundAdvancement(
                    on: host,
                    after: lastInbound
                )
                guard let nextInbound else {
                    break
                }
                XCTAssertGreaterThan(
                    nextInbound.packets ?? 0,
                    lastInbound?.packets ?? 0
                )
                XCTAssertGreaterThan(
                    nextInbound.bytes ?? 0,
                    lastInbound?.bytes ?? 0
                )
                await forwarding.publish(
                    nextInbound,
                    peer: host,
                    peerGeneration: peerGeneration
                )
                lastInbound = nextInbound

                let current = await forwarding.snapshot()
                if current.currentAttemptID != nil {
                    revivedKey = current.currentKey
                }
                if current.phase == .forwardingHealthy {
                    healthySnapshot = current
                    break
                }
            }
            producer.cancel()
            let delivered = await producer.value

            let healthy = try XCTUnwrap(
                healthySnapshot,
                "Advancing exact receiver statistics did not revive forwarding health."
            )
            XCTAssertGreaterThan(delivered, 1)
            XCTAssertEqual(outputFactory.requestCount, 2)
            XCTAssertEqual(revivedKey, exhaustedKey)
            XCTAssertEqual(healthy.currentKey, exhaustedKey)
            XCTAssertEqual(healthy.peerGeneration, peerGeneration)
            XCTAssertEqual(healthy.trackGeneration, exhaustedKey.trackGeneration)
            XCTAssertTrue(healthy.exactTrackAdmitted)
            XCTAssertTrue(healthy.inboundMediaFresh)
            XCTAssertGreaterThan(healthy.inboundMediaAdvancementCount, 0)
            XCTAssertTrue(track.isEnabled)
            XCTAssertEqual(ObjectIdentifier(track), trackIdentity)
            XCTAssertEqual(track.receiverID, receiverID)
            XCTAssertEqual(track.nativeTrackID, nativeTrackID)
            XCTAssertEqual(outputs[1].stopCount, 0)
        } catch {
            await forwarding.shutdown()
            _ = await host.close(reason: .protocolError)
            _ = await viewer.close(reason: .protocolError)
            hostForwarder.cancel()
            viewerForwarder.cancel()
            _ = await hostForwarder.value
            _ = await viewerForwarder.value
            throw error
        }

        await forwarding.shutdown()
        let hostRetired = await host.close(reason: .normal)
        let viewerRetired = await viewer.close(reason: .normal)
        hostForwarder.cancel()
        viewerForwarder.cancel()
        let hostForwardingError = await hostForwarder.value
        let viewerForwardingError = await viewerForwarder.value
        XCTAssertTrue(hostRetired)
        XCTAssertTrue(viewerRetired)
        XCTAssertNil(hostForwardingError)
        XCTAssertNil(viewerForwardingError)
    }

    private func eventually(
        attempts: Int = 1_000,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func awaitInboundAdvancement(
        on host: WebRTCPeer,
        after previous: WebRTCAudioStatistics?,
        attempts: Int = 200
    ) async -> WebRTCAudioStatistics? {
        let previousPackets = previous?.packets ?? 0
        let previousBytes = previous?.bytes ?? 0
        for _ in 0..<attempts {
            let current = await host.statisticsSnapshot().inboundAudio
            if let current,
               let packets = current.packets,
               let bytes = current.bytes,
               packets > previousPackets,
               bytes > previousBytes {
                return current
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}

private actor ForwardingIntegrationPeerEvents {
    private var retainedIPhoneMicrophoneTrack:
        WebRTCRemoteAudioTrack?

    func observeHost(_ event: WebRTCTransportEvent) {
        guard case .remoteAudioTrack(let track) = event,
              track.logicalLane == .iPhoneMicrophone else {
            return
        }
        retainedIPhoneMicrophoneTrack = track
    }

    func iPhoneMicrophoneTrack() -> WebRTCRemoteAudioTrack? {
        retainedIPhoneMicrophoneTrack
    }
}

private actor ForwardingIntegrationHarness {
    private let driver:
        WorldwideIPhoneMicrophoneForwardingDriver<
            WebRTCPeer,
            WebRTCRemoteAudioTrack
        >
    private let monitorEpoch = UUID()

    init(outputFactory: ForwardingIntegrationOutputFactory) {
        driver = WorldwideIPhoneMicrophoneForwardingDriver(
            policy: .enabled,
            makeOutput: { _, _ in
                outputFactory.makeOutput()
            },
            startOutput: { output in
                try output.start()
            },
            admit: { peer, track in
                try await peer
                    .enableRemoteIPhoneMicrophonePlaybackIfTransportHealthy(
                        track
                    )
            },
            disableTrack: { track in
                track.setEnabled(false)
            },
            readinessSleep: {},
            readinessSampleLimit: 2,
            maximumStaleInboundMediaSamples: 1,
            mediaFreshnessTimeoutNanoseconds: 60_000_000_000,
            mediaFreshnessDeadlineSleep: { _ in
                try await Task.sleep(for: .seconds(60))
            },
            retrySleep: {},
            maximumAttemptCountPerKey: 1
        )
    }

    func prepare(
        peer: WebRTCPeer,
        peerGeneration: UInt64,
        track: WebRTCRemoteAudioTrack
    ) async {
        driver.beginMonitoring(epoch: monitorEpoch)
        driver.replacePeer(
            peer: peer,
            peerGeneration: peerGeneration
        )
        await driver.installTrack(track)
        await driver.authorizeTransport(
            peer: peer,
            peerGeneration: peerGeneration
        )
        await driver.updateDeviceSnapshot(
            BlackHoleDeviceAvailabilitySnapshot(
                monitorEpoch: monitorEpoch,
                deviceGeneration: 1,
                defaultInputEndpoint: .init(
                    deviceID: 79,
                    deviceUID:
                        WorldwideVirtualMicrophoneEndpointContract
                            .visibleDefaultInputDeviceUID
                ),
                hiddenMirrorSinkEndpoint: .init(
                    deviceID: 89,
                    deviceUID:
                        WorldwideVirtualMicrophoneEndpointContract
                            .hiddenMirrorSinkDeviceUID
                )
            )
        )
    }

    func publish(
        _ inbound: WebRTCAudioStatistics?,
        peer: WebRTCPeer,
        peerGeneration: UInt64
    ) async {
        await driver.updateInboundMediaFreshness(
            peer: peer,
            peerGeneration: peerGeneration,
            watermark: WorldwideIPhoneMicrophoneInboundMediaWatermark(
                packetsReceived: inbound?.packets,
                bytesReceived: inbound?.bytes,
                jitterBufferEmittedCount:
                    inbound?.jitterBufferEmittedCount,
                totalSamplesReceived: inbound?.totalSamplesReceived
            )
        )
    }

    func snapshot()
        -> WorldwideIPhoneMicrophoneForwardingHostSnapshot
    {
        driver.snapshot()
    }

    func shutdown() {
        driver.shutdown()
    }
}

private final class ForwardingIntegrationOutputFactory:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var outputs: [ForwardingIntegrationOutput]
    private var requests = 0

    init(outputs: [ForwardingIntegrationOutput]) {
        self.outputs = outputs
    }

    func makeOutput() -> (any WorldwideIPhoneMicrophoneOutput)? {
        lock.withLock {
            requests += 1
            guard !outputs.isEmpty else { return nil }
            return outputs.removeFirst()
        }
    }

    var requestCount: Int {
        lock.withLock { requests }
    }
}

private final class ForwardingIntegrationOutput:
    WorldwideIPhoneMicrophoneOutput,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var progressSnapshots = [
        BlackHoleMicrophoneOutputProgressSnapshot(
            queueRunning: true,
            postStartCallbackCount: 1,
            requestedFrameCount: 480,
            successfulPullCount: 1,
            successfulFrameCount: 480,
            silenceFallbackCount: 0,
            silenceFrameCount: 0,
            enqueueFailureCount: 0,
            lastEnqueueStatus: noErr
        ),
        BlackHoleMicrophoneOutputProgressSnapshot(
            queueRunning: true,
            postStartCallbackCount: 2,
            requestedFrameCount: 960,
            successfulPullCount: 2,
            successfulFrameCount: 960,
            silenceFallbackCount: 0,
            silenceFrameCount: 0,
            enqueueFailureCount: 0,
            lastEnqueueStatus: noErr
        ),
    ]
    private var starts = 0
    private var stops = 0

    func start() throws {
        lock.withLock {
            starts += 1
        }
    }

    func stop() {
        lock.withLock {
            stops += 1
        }
    }

    var forwardingProgressSnapshot:
        BlackHoleMicrophoneOutputProgressSnapshot
    {
        lock.withLock {
            if progressSnapshots.count > 1 {
                return progressSnapshots.removeFirst()
            }
            return progressSnapshots[0]
        }
    }

    var stopCount: Int {
        lock.withLock { stops }
    }
}
#endif
