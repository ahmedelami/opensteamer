import Foundation
import WebRTCTransport
@testable import CaptureServer
import XCTest

final class WorldwideScreenVideoAdaptationPolicyTests: XCTestCase {
    func testLadderScalesBitrateFrameRateAndResolution() {
        let policy = makePolicy()

        XCTAssertEqual(
            policy.recommendation(for: .full),
            recommendation(
                .full, bitrate: 9_344_000, totalBitrate: 12_000_000,
                fps: 60, scale: 1
            )
        )
        XCTAssertEqual(
            policy.recommendation(for: .high),
            recommendation(
                .high, bitrate: 6_260_480, totalBitrate: 10_996_560,
                fps: 45, scale: 1.25
            )
        )
        XCTAssertEqual(
            policy.recommendation(for: .balanced),
            recommendation(
                .balanced, bitrate: 3_924_480, totalBitrate: 7_054_560,
                fps: 30, scale: 1.5
            )
        )
        XCTAssertEqual(
            policy.recommendation(for: .constrained),
            recommendation(
                .constrained, bitrate: 1_962_240, totalBitrate: 3_743_281,
                fps: 20, scale: 2
            )
        )
        XCTAssertEqual(
            policy.recommendation(for: .critical),
            recommendation(
                .critical, bitrate: 747_520, totalBitrate: 1_693_440,
                fps: 10, scale: 3
            )
        )
        XCTAssertEqual(
            policy.recommendation(for: .survival),
            recommendation(
                .survival, bitrate: 280_320, totalBitrate: 905_041,
                fps: 5, scale: 4
            )
        )
        XCTAssertEqual(
            policy.recommendation(for: .emergency),
            recommendation(
                .emergency, bitrate: 93_440, totalBitrate: 589_680,
                fps: 2, scale: 8
            )
        )
        XCTAssertEqual(
            policy.recommendation(for: .audioPriority),
            recommendation(
                .audioPriority, bitrate: 32_000, totalBitrate: 486_001,
                fps: 1, scale: 12
            )
        )

        let thirtyFPSPolicy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 12_000_000,
            baseFramesPerSecond: 30
        )
        XCTAssertEqual(
            thirtyFPSPolicy.recommendation(for: .full).maximumFramesPerSecond,
            30
        )
        XCTAssertEqual(
            thirtyFPSPolicy.recommendation(for: .high).maximumFramesPerSecond,
            30
        )
    }

    func testFiftyMegabitTotalCeilingScalesTheQualityLadder() {
        let policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )

        XCTAssertEqual(policy.currentTier, .survival)
        XCTAssertEqual(policy.maximumTierVideoBitrateBps, 39_744_000)
        XCTAssertEqual(
            policy.recommendation(for: .full),
            recommendation(
                .full, bitrate: 39_744_000, totalBitrate: 16_200_001,
                fps: 60, scale: 1
            )
        )
        XCTAssertEqual(
            policy.recommendation(for: .high),
            recommendation(
                .high, bitrate: 26_628_480, totalBitrate: 10_996_560,
                fps: 45, scale: 1.25
            )
        )
        XCTAssertEqual(
            policy.recommendation(for: .balanced),
            recommendation(
                .balanced, bitrate: 16_692_480, totalBitrate: 7_054_560,
                fps: 30, scale: 1.5
            )
        )
        XCTAssertEqual(
            policy.recommendation(for: .constrained),
            recommendation(
                .constrained, bitrate: 8_346_240, totalBitrate: 3_743_281,
                fps: 20, scale: 2
            )
        )
        XCTAssertEqual(
            policy.recommendation(for: .critical),
            recommendation(
                .critical, bitrate: 3_179_520, totalBitrate: 1_693_440,
                fps: 10, scale: 3
            )
        )
        XCTAssertEqual(
            policy.recommendation(for: .survival),
            recommendation(
                .survival, bitrate: 1_192_320, totalBitrate: 905_041,
                fps: 5, scale: 4
            )
        )
    }

    func testFiftyMegabitCapRequiresFreshLowQueueEvidenceBeforeFullQuality() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))

        let coldStrongCapacitySampleCount =
            WorldwideScreenVideoAdaptationPolicy.roundTripTimeBootstrapSampleCount - 1
            + WorldwideScreenVideoAdaptationPolicy.requiredHealthyUpgradeSampleCount
        for sample in 1..<coldStrongCapacitySampleCount {
            XCTAssertNil(
                policy.update(
                    peerGeneration: 1,
                    isCaptureActive: true,
                    availableOutgoingBitrateBps: 47_500_000,
                    currentRoundTripTimeSeconds: 0.020,
                    outboundVideoPacketsSent: UInt64(sample * 100),
                    outboundVideoTotalPacketSendDelaySeconds:
                        Double(sample) * 0.5
                )
            )
        }
        XCTAssertEqual(policy.currentTier, .survival)

        let full = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 47_500_000,
            currentRoundTripTimeSeconds: 0.020,
            outboundVideoPacketsSent: UInt64(coldStrongCapacitySampleCount * 100),
            outboundVideoTotalPacketSendDelaySeconds:
                Double(coldStrongCapacitySampleCount) * 0.5
        )
        XCTAssertEqual(full?.tier, .full)
        XCTAssertEqual(full?.maximumBitrateBps, 39_744_000)
        XCTAssertEqual(full?.maximumFramesPerSecond, 60)
        XCTAssertEqual(full?.scaleResolutionDownBy, 1)
    }

    func testFiftyMegabitTransportCapDoesNotInflateTierDecisionThresholds() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))

        var update: WorldwideScreenVideoEncodingRecommendation?
        for sample in 1...4 {
            update = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 2_262_000,
                currentRoundTripTimeSeconds: 0.012,
                outboundVideoPacketsSent: UInt64(sample * 100),
                outboundVideoTotalPacketSendDelaySeconds:
                    Double(sample) * 0.5
            ) ?? update
        }

        XCTAssertEqual(update?.tier, .critical)
        XCTAssertEqual(policy.currentTier, .critical)
        XCTAssertNil(policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(
            policy.currentRecommendation.maximumBitrateBps,
            3_179_520
        )
        XCTAssertEqual(
            policy.currentTierMinimumSustainableBitrateBps,
            1_254_400
        )
        XCTAssertEqual(
            policy.nextHigherTierMinimumDirectUpgradeBitrateBps,
            3_743_281
        )
    }

    func testSenderLimitedFullTierHoldsUntilCapacityLeavesItsHealthyBand() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))
        var packetsSent: UInt64 = 0
        var totalPacketSendDelay = 0.0

        func update(
            availableOutgoingBitrateBps: Double
        ) -> WorldwideScreenVideoEncodingRecommendation? {
            packetsSent += 100
            totalPacketSendDelay += 0.5
            return policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: availableOutgoingBitrateBps,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
        }

        for _ in 0..<96 where policy.currentTier != .full {
            _ = update(availableOutgoingBitrateBps: 50_000_000)
        }
        XCTAssertEqual(policy.currentTier, .full)
        let senderLimitedEstimate = Double(
            policy.currentRecommendation.maximumBitrateBps
        ) * 0.90
        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: senderLimitedEstimate,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
        )
        XCTAssertEqual(policy.currentTier, .full)
        packetsSent += 100
        totalPacketSendDelay += 0.5
        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: senderLimitedEstimate,
                currentRoundTripTimeSeconds: nil,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
        )
        XCTAssertEqual(policy.currentTier, .full)
        for _ in 0..<32 {
            XCTAssertNil(
                update(
                    availableOutgoingBitrateBps: senderLimitedEstimate
                )
            )
            XCTAssertEqual(policy.currentTier, .full)
        }

        let reducedEstimate = 9_344_000.0 * 0.848
        XCTAssertNil(update(availableOutgoingBitrateBps: reducedEstimate))
        XCTAssertEqual(policy.currentTier, .full)
        XCTAssertEqual(
            update(availableOutgoingBitrateBps: reducedEstimate)?.tier,
            .balanced
        )
    }

    func testApplicationLimitedEstimateRaisesOnlyTheBitrateCeiling() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))
        XCTAssertEqual(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 100_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: 100,
                outboundVideoTotalPacketSendDelaySeconds: 0.1
            )?.tier,
            .audioPriority
        )
        let originRecommendation = policy.currentRecommendation

        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 400_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: 140,
                outboundVideoTotalPacketSendDelaySeconds: 0.104
            )
        )
        let probe = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 400_000,
            currentRoundTripTimeSeconds: 0.020,
            outboundVideoPacketsSent: 180,
            outboundVideoTotalPacketSendDelaySeconds: 0.108
        )
        XCTAssertEqual(probe?.tier, .audioPriority)
        XCTAssertEqual(probe?.maximumBitrateBps, policy.maximumTierVideoBitrateBps)
        XCTAssertGreaterThan(
            probe?.maximumTotalRTPBitrateBps ?? 0,
            originRecommendation.maximumTotalRTPBitrateBps
        )
        XCTAssertEqual(
            probe?.maximumTotalRTPBitrateBps,
            800_000
        )
        XCTAssertLessThanOrEqual(
            probe?.maximumTotalRTPBitrateBps ?? Int.max,
            2 * 400_000
        )
        XCTAssertEqual(
            probe?.maximumFramesPerSecond,
            originRecommendation.maximumFramesPerSecond
        )
        XCTAssertEqual(
            probe?.scaleResolutionDownBy,
            originRecommendation.scaleResolutionDownBy
        )
        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertEqual(
            policy.applicationLimitedProbeGraceSamplesRemaining,
            WorldwideScreenVideoAdaptationPolicy
                .applicationLimitedProbeGraceSampleCount
        )
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .audioPriority)
    }

    func testMissingReportsExpireOnlyTheRaisedProbeAtItsMonotonicDeadline() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))
        let startedAt = ContinuousClock.now
        _ = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 100_000,
            currentRoundTripTimeSeconds: 0.020,
            outboundVideoPacketsSent: 100,
            outboundVideoTotalPacketSendDelaySeconds: 0.1,
            observedAt: startedAt
        )
        _ = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 400_000,
            currentRoundTripTimeSeconds: 0.020,
            outboundVideoPacketsSent: 140,
            outboundVideoTotalPacketSendDelaySeconds: 0.104,
            observedAt: startedAt.advanced(by: .milliseconds(500))
        )
        let probeStartedAt = startedAt.advanced(by: .milliseconds(1_000))
        _ = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 400_000,
            currentRoundTripTimeSeconds: 0.020,
            outboundVideoPacketsSent: 180,
            outboundVideoTotalPacketSendDelaySeconds: 0.108,
            observedAt: probeStartedAt
        )

        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .audioPriority)
        let baselineRTT = policy.roundTripTimeBaselineSeconds
        let baselineQueueDelay = policy.lastAveragePacketSendDelaySeconds

        for elapsed in [500, 1_000, 1_999] {
            XCTAssertNil(
                policy.expireApplicationLimitedProbeWithoutReport(
                    peerGeneration: 1,
                    isCaptureActive: true,
                    observedAt: probeStartedAt.advanced(
                        by: .milliseconds(elapsed)
                    )
                )
            )
            XCTAssertEqual(policy.currentTier, .audioPriority)
            XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .audioPriority)
            XCTAssertEqual(policy.applicationLimitedProbeFailureCount, 0)
            XCTAssertEqual(policy.roundTripTimeBaselineSeconds, baselineRTT)
            XCTAssertEqual(
                policy.lastAveragePacketSendDelaySeconds,
                baselineQueueDelay
            )
        }

        XCTAssertEqual(
            policy.expireApplicationLimitedProbeWithoutReport(
                peerGeneration: 1,
                isCaptureActive: true,
                observedAt: probeStartedAt.advanced(
                    by: WorldwideScreenVideoAdaptationPolicy
                        .applicationLimitedProbeGraceDuration
                )
            )?.tier,
            .audioPriority
        )
        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertNil(policy.applicationLimitedProbeOriginTier)
        XCTAssertNil(policy.applicationLimitedProbeDeadline)
        XCTAssertEqual(policy.applicationLimitedProbeFailureCount, 1)
        XCTAssertEqual(
            policy.applicationLimitedProbeCooldownSamplesRemaining,
            WorldwideScreenVideoAdaptationPolicy
                .initialApplicationLimitedProbeCooldownSampleCount
        )
        XCTAssertEqual(policy.roundTripTimeBaselineSeconds, baselineRTT)
        XCTAssertEqual(
            policy.lastAveragePacketSendDelaySeconds,
            baselineQueueDelay
        )
    }

    func testVeryLowPositiveEstimateBypassesBootstrapAndDowngradesImmediately() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))

        let update = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 100_000,
            currentRoundTripTimeSeconds: 0.020
        )

        XCTAssertEqual(update?.tier, .audioPriority)
        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertEqual(
            policy.positiveBandwidthBootstrapSampleCount,
            WorldwideScreenVideoAdaptationPolicy
                .requiredPositiveBandwidthBootstrapSampleCount
        )
    }

    func testSenderLimitedEstimateCannotProbeWithoutRTTOrSendQueueEvidence() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))

        XCTAssertEqual(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 100_000,
                currentRoundTripTimeSeconds: nil
            )?.tier,
            .audioPriority
        )

        for _ in 0..<16 {
            XCTAssertNil(
                policy.update(
                    peerGeneration: 1,
                    isCaptureActive: true,
                    availableOutgoingBitrateBps: nil,
                    currentRoundTripTimeSeconds: nil
                )
            )
            XCTAssertNil(
                policy.update(
                    peerGeneration: 1,
                    isCaptureActive: true,
                    availableOutgoingBitrateBps: 100_000,
                    currentRoundTripTimeSeconds: nil
                )
            )
            XCTAssertEqual(policy.currentTier, .audioPriority)
        }
    }

    func testFailedApplicationLimitedProbeBoundsVisibleReevaluationAndRetainsBackoff() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))
        var packetsSent: UInt64 = 100
        var totalPacketSendDelay = 0.1

        XCTAssertEqual(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 100_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )?.tier,
            .audioPriority
        )

        func update(
            _ availableOutgoingBitrateBps: Double? = 400_000
        ) -> WorldwideScreenVideoEncodingRecommendation? {
            packetsSent += 40
            totalPacketSendDelay += 0.004
            return policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: availableOutgoingBitrateBps,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
        }

        for _ in 0..<16 where policy.applicationLimitedProbeOriginTier == nil {
            _ = update()
        }
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .audioPriority)
        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertEqual(
            policy.currentRecommendation.maximumBitrateBps,
            policy.maximumTierVideoBitrateBps
        )

        for _ in 0..<16 where policy.applicationLimitedProbeFailureCount == 0 {
            _ = update()
        }
        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertNil(policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(policy.applicationLimitedProbeFailureCount, 1)
        XCTAssertEqual(
            policy.applicationLimitedProbeCooldownSamplesRemaining,
            WorldwideScreenVideoAdaptationPolicy
                .initialApplicationLimitedProbeCooldownSampleCount
        )

        let boundedCooldown = WorldwideScreenVideoAdaptationPolicy
            .maximumActiveApplicationLimitedProbeCooldownSampleCount
        for _ in 0..<boundedCooldown {
            XCTAssertNil(update())
            XCTAssertNil(policy.applicationLimitedProbeOriginTier)
            XCTAssertEqual(policy.currentTier, .audioPriority)
        }
        for _ in 1..<WorldwideScreenVideoAdaptationPolicy
            .requiredApplicationLimitedUpgradeSampleCount {
            XCTAssertNil(update())
        }
        XCTAssertEqual(update()?.tier, .audioPriority)
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .audioPriority)
        XCTAssertLessThan(
            (boundedCooldown
                + WorldwideScreenVideoAdaptationPolicy
                    .requiredApplicationLimitedUpgradeSampleCount)
                * WorldwideScreenVideoAdaptationPolicy
                    .sampleIntervalMilliseconds,
            5_000
        )

        for _ in 0..<16 where policy.applicationLimitedProbeFailureCount < 2 {
            _ = update()
        }
        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertEqual(policy.applicationLimitedProbeFailureCount, 2)
        XCTAssertEqual(
            policy.applicationLimitedProbeCooldownSamplesRemaining,
            WorldwideScreenVideoAdaptationPolicy
                .initialApplicationLimitedProbeCooldownSampleCount * 2
        )
    }

    func testApplicationLimitedProbeRequiresRTTAndSendQueueEvidence() {
        var roundTripTimeOnlyPolicy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(roundTripTimeOnlyPolicy.bind(toPeerGeneration: 1))
        XCTAssertEqual(
            roundTripTimeOnlyPolicy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 100_000,
                currentRoundTripTimeSeconds: 0.020
            )?.tier,
            .audioPriority
        )

        for _ in 0..<16 {
            _ = roundTripTimeOnlyPolicy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 400_000,
                currentRoundTripTimeSeconds: 0.020
            )
        }
        XCTAssertEqual(roundTripTimeOnlyPolicy.currentTier, .audioPriority)
        XCTAssertNil(roundTripTimeOnlyPolicy.applicationLimitedProbeOriginTier)

        var sendQueueOnlyPolicy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(sendQueueOnlyPolicy.bind(toPeerGeneration: 1))
        XCTAssertEqual(
            sendQueueOnlyPolicy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 100_000,
                currentRoundTripTimeSeconds: nil,
                outboundVideoPacketsSent: 100,
                outboundVideoTotalPacketSendDelaySeconds: 0.1
            )?.tier,
            .audioPriority
        )
        for sample in 1...16 {
            _ = sendQueueOnlyPolicy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 400_000,
                currentRoundTripTimeSeconds: nil,
                outboundVideoPacketsSent: UInt64(100 + sample * 40),
                outboundVideoTotalPacketSendDelaySeconds:
                    0.1 + Double(sample) * 0.004
            )
        }
        XCTAssertEqual(sendQueueOnlyPolicy.currentTier, .audioPriority)
        XCTAssertNil(sendQueueOnlyPolicy.applicationLimitedProbeOriginTier)
    }

    func testSevereBandwidthCollapseWinsOverSoftQueueDuringProbe() {
        var fixture = makeLiveCeilingProbeFromAudioPriority()

        fixture.packetsSent += 100
        fixture.totalPacketSendDelay += 10.5
        let collapsed = fixture.policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 100_000,
            currentRoundTripTimeSeconds: 0.020,
            outboundVideoPacketsSent: fixture.packetsSent,
            outboundVideoTotalPacketSendDelaySeconds:
                fixture.totalPacketSendDelay
        )

        XCTAssertEqual(collapsed?.tier, .audioPriority)
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, 1)
        XCTAssertTrue(fixture.policy.lastSampleHasPositiveSuspensionPressure)
    }

    func testLatencyFailedProbeKeepsBackoffDespiteHighBandwidth() {
        var fixture = makeLiveCeilingProbeFromAudioPriority()

        fixture.packetsSent += 100
        fixture.totalPacketSendDelay += 20
        let pressured = fixture.policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 50_000_000,
            currentRoundTripTimeSeconds: 0.020,
            outboundVideoPacketsSent: fixture.packetsSent,
            outboundVideoTotalPacketSendDelaySeconds:
                fixture.totalPacketSendDelay
        )

        XCTAssertEqual(pressured?.tier, .audioPriority)
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, 1)
        XCTAssertEqual(
            fixture.policy.applicationLimitedProbeCooldownSamplesRemaining,
            WorldwideScreenVideoAdaptationPolicy
                .initialApplicationLimitedProbeCooldownSampleCount
        )
        XCTAssertTrue(fixture.policy.lastSampleHasLatencyPressure)
    }

    func testCeilingOnlyProbeRecoversFullyWithOneFinalGeometryTransition() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))
        let startedAt = ContinuousClock.now
        var packetsSent: UInt64 = 100
        var totalPacketSendDelay = 0.1
        XCTAssertEqual(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 100_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay,
                observedAt: startedAt
            )?.tier,
            .audioPriority
        )
        let originRecommendation = policy.currentRecommendation
        var recoveryRecommendations:
            [WorldwideScreenVideoEncodingRecommendation] = []
        var appliedProbeCaps: [(
            availableOutgoingBitrateBps: Double,
            maximumTotalRTPBitrateBps: Int
        )] = []
        var recoverySampleCount = 0

        packetsSent += 40
        totalPacketSendDelay += 0.004
        recoverySampleCount += 1
        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 400_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay,
                observedAt: startedAt.advanced(by: .milliseconds(500))
            )
        )

        packetsSent += 40
        totalPacketSendDelay += 0.004
        recoverySampleCount += 1
        let bitrateOnlyProbe = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 400_000,
            currentRoundTripTimeSeconds: 0.020,
            outboundVideoPacketsSent: packetsSent,
            outboundVideoTotalPacketSendDelaySeconds:
                totalPacketSendDelay,
            observedAt: startedAt.advanced(by: .milliseconds(1_000))
        )
        if let bitrateOnlyProbe {
            recoveryRecommendations.append(bitrateOnlyProbe)
            appliedProbeCaps.append(
                (400_000, bitrateOnlyProbe.maximumTotalRTPBitrateBps)
            )
        }
        XCTAssertEqual(bitrateOnlyProbe?.tier, .audioPriority)
        XCTAssertEqual(
            bitrateOnlyProbe?.maximumBitrateBps,
            policy.maximumTierVideoBitrateBps
        )
        XCTAssertGreaterThan(
            bitrateOnlyProbe?.maximumTotalRTPBitrateBps ?? 0,
            originRecommendation.maximumTotalRTPBitrateBps
        )
        XCTAssertEqual(
            bitrateOnlyProbe?.maximumTotalRTPBitrateBps,
            800_000
        )
        XCTAssertEqual(
            bitrateOnlyProbe?.maximumFramesPerSecond,
            originRecommendation.maximumFramesPerSecond
        )
        XCTAssertEqual(
            bitrateOnlyProbe?.scaleResolutionDownBy,
            originRecommendation.scaleResolutionDownBy
        )
        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .audioPriority)
        let graceBeforeSpike = policy.applicationLimitedProbeGraceSamplesRemaining

        packetsSent += 100
        totalPacketSendDelay += 10.5
        recoverySampleCount += 1
        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 50_000_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay,
                observedAt: startedAt.advanced(by: .milliseconds(1_500))
            )
        )
        XCTAssertEqual(policy.queuePressureSampleCount, 1)
        XCTAssertEqual(
            policy.applicationLimitedProbeGraceSamplesRemaining,
            graceBeforeSpike
        )
        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertEqual(
            policy.currentRecommendation.maximumTotalRTPBitrateBps,
            bitrateOnlyProbe?.maximumTotalRTPBitrateBps
        )

        let chainedProbeSamples: [(
            availableOutgoingBitrateBps: Double,
            elapsedMilliseconds: Int
        )] = [
            (800_000, 2_000),
            (1_600_000, 2_500),
            (4_100_000, 3_000),
            (8_200_000, 3_500),
            (50_000_000, 4_000),
            (50_000_000, 4_500),
        ]
        for sample in chainedProbeSamples {
            packetsSent += 100
            totalPacketSendDelay += 0.5
            recoverySampleCount += 1
            if let recommendation = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps:
                    sample.availableOutgoingBitrateBps,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay,
                observedAt: startedAt.advanced(
                    by: .milliseconds(sample.elapsedMilliseconds)
                )
            ) {
                recoveryRecommendations.append(recommendation)
                if recommendation.tier == .audioPriority {
                    appliedProbeCaps.append(
                        (
                            sample.availableOutgoingBitrateBps,
                            recommendation.maximumTotalRTPBitrateBps
                        )
                    )
                    XCTAssertEqual(
                        recommendation.maximumFramesPerSecond,
                        originRecommendation.maximumFramesPerSecond
                    )
                    XCTAssertEqual(
                        recommendation.scaleResolutionDownBy,
                        originRecommendation.scaleResolutionDownBy
                    )
                    XCTAssertEqual(policy.currentTier, .audioPriority)
                    XCTAssertEqual(
                        policy.applicationLimitedProbeOriginTier,
                        .audioPriority
                    )
                }
            }
        }

        XCTAssertEqual(
            recoveryRecommendations.map(\.tier),
            [
                .audioPriority,
                .audioPriority,
                .audioPriority,
                .audioPriority,
                .audioPriority,
                .full,
            ]
        )
        XCTAssertEqual(
            appliedProbeCaps.map(\.maximumTotalRTPBitrateBps),
            [800_000, 1_600_000, 3_200_000, 8_200_000, 16_200_001]
        )
        XCTAssertTrue(
            appliedProbeCaps.allSatisfy { appliedProbe in
                Double(appliedProbe.maximumTotalRTPBitrateBps)
                    <= appliedProbe.availableOutgoingBitrateBps * 2
            }
        )
        XCTAssertEqual(
            recoveryRecommendations.filter {
                $0.maximumFramesPerSecond
                    != originRecommendation.maximumFramesPerSecond
                    || $0.scaleResolutionDownBy
                        != originRecommendation.scaleResolutionDownBy
            }.count,
            1
        )
        XCTAssertEqual(policy.currentTier, .full)
        XCTAssertNil(policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(policy.currentRecommendation.maximumFramesPerSecond, 60)
        XCTAssertEqual(policy.currentRecommendation.scaleResolutionDownBy, 1)
        XCTAssertEqual(
            policy.currentRecommendation.maximumTotalRTPBitrateBps,
            appliedProbeCaps.last?.maximumTotalRTPBitrateBps
        )
        XCTAssertLessThan(
            recoverySampleCount
                * WorldwideScreenVideoAdaptationPolicy
                    .sampleIntervalMilliseconds,
            5_000
        )
    }

    func testSoftQueuePressureSurvivesOneNoPacketPoll() {
        var policy = makeFiftyMegabitPolicyAtFull()
        let startedAt = ContinuousClock.now
        var packetsSent: UInt64 = 100
        var totalPacketSendDelay = 0.5
        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 50_000_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay,
                observedAt: startedAt
            )
        )

        packetsSent += 100
        totalPacketSendDelay += 10.5
        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 50_000_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay,
                observedAt: startedAt.advanced(by: .milliseconds(500))
            )
        )
        XCTAssertEqual(policy.queuePressureSampleCount, 1)

        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 50_000_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay,
                observedAt: startedAt.advanced(by: .milliseconds(1_000))
            )
        )
        XCTAssertEqual(policy.queuePressureSampleCount, 1)
        XCTAssertEqual(policy.currentTier, .full)

        packetsSent += 100
        totalPacketSendDelay += 10.5
        XCTAssertEqual(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 50_000_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay,
                observedAt: startedAt.advanced(by: .milliseconds(1_500))
            )?.tier,
            .high
        )
        XCTAssertEqual(policy.currentTier, .high)
    }

    func testSevereBandwidthCollapseReachesAudioFloorWithSoftOrConfirmedQueue() {
        let startedAt = ContinuousClock.now

        var softPolicy = makeFiftyMegabitPolicyAtFull()
        _ = softPolicy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 50_000_000,
            currentRoundTripTimeSeconds: 0.020,
            outboundVideoPacketsSent: 100,
            outboundVideoTotalPacketSendDelaySeconds: 0.5,
            observedAt: startedAt
        )
        XCTAssertEqual(
            softPolicy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 100_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: 200,
                outboundVideoTotalPacketSendDelaySeconds: 11,
                observedAt: startedAt.advanced(by: .milliseconds(500))
            )?.tier,
            .audioPriority
        )
        XCTAssertEqual(softPolicy.currentTier, .audioPriority)

        var confirmedPolicy = makeFiftyMegabitPolicyAtFull()
        _ = confirmedPolicy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 50_000_000,
            currentRoundTripTimeSeconds: 0.020,
            outboundVideoPacketsSent: 100,
            outboundVideoTotalPacketSendDelaySeconds: 0.5,
            observedAt: startedAt
        )
        XCTAssertNil(
            confirmedPolicy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 50_000_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: 200,
                outboundVideoTotalPacketSendDelaySeconds: 11,
                observedAt: startedAt.advanced(by: .milliseconds(500))
            )
        )
        XCTAssertEqual(confirmedPolicy.queuePressureSampleCount, 1)
        XCTAssertEqual(
            confirmedPolicy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 100_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: 300,
                outboundVideoTotalPacketSendDelaySeconds: 21.5,
                observedAt: startedAt.advanced(by: .milliseconds(1_000))
            )?.tier,
            .audioPriority
        )
        XCTAssertEqual(confirmedPolicy.currentTier, .audioPriority)
    }

    func testSubCeilingEstimatesAreNotHeldAsApplicationLimited() {
        var survivalPolicy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(survivalPolicy.bind(toPeerGeneration: 1))
        XCTAssertEqual(
            survivalPolicy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 400_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: 100,
                outboundVideoTotalPacketSendDelaySeconds: 0.5
            )?.tier,
            .audioPriority
        )
        XCTAssertNil(survivalPolicy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(survivalPolicy.currentTier, .audioPriority)

        var fullPolicy = makeFiftyMegabitPolicyAtFull()
        _ = fullPolicy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 50_000_000,
            currentRoundTripTimeSeconds: 0.020,
            outboundVideoPacketsSent: 100,
            outboundVideoTotalPacketSendDelaySeconds: 0.5
        )
        var fullUpdate: WorldwideScreenVideoEncodingRecommendation?
        for sample in 2...4 where fullPolicy.currentTier == .full {
            fullUpdate = fullPolicy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 8_000_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: UInt64(sample * 100),
                outboundVideoTotalPacketSendDelaySeconds:
                    Double(sample) * 0.5
            ) ?? fullUpdate
            XCTAssertNil(fullPolicy.applicationLimitedProbeOriginTier)
        }
        XCTAssertEqual(fullUpdate?.tier, .balanced)
        XCTAssertEqual(fullPolicy.currentTier, .balanced)
    }

    func testRetainedIntermediateProbeProofSurvivesTelemetryEnding() {
        var missingBandwidthFixture = makeLiveCeilingProbeFromAudioPriority()
        for sample in 1...2 {
            missingBandwidthFixture.packetsSent += 40
            missingBandwidthFixture.totalPacketSendDelay += 0.004
            let update = missingBandwidthFixture.policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 2_500_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent:
                    missingBandwidthFixture.packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    missingBandwidthFixture.totalPacketSendDelay
            )
            if sample == 1 {
                XCTAssertEqual(update?.tier, .audioPriority)
                XCTAssertEqual(update?.maximumTotalRTPBitrateBps, 5_000_000)
                XCTAssertLessThanOrEqual(
                    update?.maximumTotalRTPBitrateBps ?? Int.max,
                    2 * 2_500_000
                )
                XCTAssertEqual(update?.maximumFramesPerSecond, 1)
                XCTAssertEqual(update?.scaleResolutionDownBy, 12)
            } else {
                XCTAssertNil(update)
            }
        }
        XCTAssertEqual(
            missingBandwidthFixture.policy
                .applicationLimitedProbeBestQualifiedTier,
            .critical
        )
        XCTAssertEqual(
            missingBandwidthFixture.policy
                .applicationLimitedProbeHealthySampleCount,
            WorldwideScreenVideoAdaptationPolicy
                .requiredHealthyUpgradeSampleCount
        )
        let missingBandwidthSampleCount = missingBandwidthFixture.policy
            .applicationLimitedProbeGraceSamplesRemaining
        for sample in 1...missingBandwidthSampleCount {
            let update = missingBandwidthFixture.policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: missingBandwidthFixture.packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    missingBandwidthFixture.totalPacketSendDelay
            )
            if sample < missingBandwidthSampleCount {
                XCTAssertNil(update)
                XCTAssertEqual(
                    missingBandwidthFixture.policy.currentTier,
                    .audioPriority
                )
                XCTAssertEqual(
                    missingBandwidthFixture.policy
                        .applicationLimitedProbeOriginTier,
                    .audioPriority
                )
            } else {
                XCTAssertEqual(update?.tier, .critical)
            }
        }
        XCTAssertEqual(missingBandwidthFixture.policy.currentTier, .critical)
        XCTAssertNil(
            missingBandwidthFixture.policy.applicationLimitedProbeOriginTier
        )

        var noReportFixture = makeLiveCeilingProbeFromAudioPriority()
        for _ in 0..<2 {
            noReportFixture.packetsSent += 40
            noReportFixture.totalPacketSendDelay += 0.004
            _ = noReportFixture.policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 2_500_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: noReportFixture.packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    noReportFixture.totalPacketSendDelay
            )
        }
        let deadline = try! XCTUnwrap(
            noReportFixture.policy.applicationLimitedProbeDeadline
        )
        XCTAssertEqual(
            noReportFixture.policy.expireApplicationLimitedProbeWithoutReport(
                peerGeneration: 1,
                isCaptureActive: true,
                observedAt: deadline
            )?.tier,
            .critical
        )
        XCTAssertEqual(noReportFixture.policy.currentTier, .critical)
        XCTAssertNil(noReportFixture.policy.applicationLimitedProbeOriginTier)
    }

    func testQueueGrayZoneHoldsAndInflationDowngradesAtFiftyMegabits() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))
        for sample in 1...10 {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 50_000_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: UInt64(sample * 100),
                outboundVideoTotalPacketSendDelaySeconds:
                    Double(sample) * 0.5
            )
        }
        XCTAssertEqual(policy.currentTier, .full)

        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 50_000_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: 1_100,
                outboundVideoTotalPacketSendDelaySeconds: 10
            )
        )
        XCTAssertEqual(policy.currentTier, .full)

        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 50_000_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: 1_200,
                outboundVideoTotalPacketSendDelaySeconds: 21.1
            )
        )
        XCTAssertEqual(policy.currentTier, .full)
        XCTAssertEqual(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 50_000_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: 1_300,
                outboundVideoTotalPacketSendDelaySeconds: 32.2
            )?.tier,
            .high
        )
    }

    func testLiveSoftQueueSpikeDoesNotUndoCeilingProbe() {
        var fixture = makeLiveCeilingProbeFromAudioPriority()
        let probeGrace = fixture.policy
            .applicationLimitedProbeGraceSamplesRemaining

        fixture.packetsSent += 100
        fixture.totalPacketSendDelay += 10.5
        XCTAssertNil(
            fixture.policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 2_262_000,
                currentRoundTripTimeSeconds: 0.012,
                outboundVideoPacketsSent: fixture.packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    fixture.totalPacketSendDelay
            )
        )
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
        XCTAssertEqual(
            fixture.policy.applicationLimitedProbeOriginTier,
            .audioPriority
        )
        XCTAssertEqual(
            fixture.policy.applicationLimitedProbeGraceSamplesRemaining,
            probeGrace
        )
        XCTAssertEqual(fixture.policy.queuePressureSampleCount, 1)
        XCTAssertFalse(fixture.policy.lastSampleHasLatencyPressure)

        fixture.packetsSent += 100
        fixture.totalPacketSendDelay += 0.5
        let chainedProbe = fixture.policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 2_262_000,
            currentRoundTripTimeSeconds: 0.012,
            outboundVideoPacketsSent: fixture.packetsSent,
            outboundVideoTotalPacketSendDelaySeconds:
                fixture.totalPacketSendDelay
        )
        XCTAssertEqual(chainedProbe?.tier, .audioPriority)
        XCTAssertEqual(
            chainedProbe?.maximumTotalRTPBitrateBps,
            4_524_000
        )
        XCTAssertLessThanOrEqual(
            chainedProbe?.maximumTotalRTPBitrateBps ?? Int.max,
            2 * 2_262_000
        )
        XCTAssertEqual(chainedProbe?.maximumFramesPerSecond, 1)
        XCTAssertEqual(chainedProbe?.scaleResolutionDownBy, 12)
        XCTAssertEqual(
            fixture.policy.applicationLimitedProbeGraceSamplesRemaining,
            probeGrace - 1
        )
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
        XCTAssertEqual(
            fixture.policy.applicationLimitedProbeOriginTier,
            .audioPriority
        )
        XCTAssertEqual(
            fixture.policy.applicationLimitedProbeBestQualifiedTier,
            .critical
        )
        XCTAssertEqual(
            fixture.policy.applicationLimitedProbeHealthySampleCount,
            1
        )
    }

    func testTwoSoftQueueSamplesFailOnlyTheCeilingProbe() {
        var fixture = makeLiveCeilingProbeFromAudioPriority()

        for sample in 1...2 {
            fixture.packetsSent += 100
            fixture.totalPacketSendDelay += 10.5
            let update = fixture.policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 2_262_000,
                currentRoundTripTimeSeconds: 0.012,
                outboundVideoPacketsSent: fixture.packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    fixture.totalPacketSendDelay
            )
            XCTAssertEqual(
                update?.tier,
                sample == 2 ? .audioPriority : nil
            )
        }

        XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, 1)
        XCTAssertEqual(fixture.policy.queuePressureSampleCount, 0)
        XCTAssertTrue(fixture.policy.lastSampleHasLatencyPressure)
    }

    func testMissingBandwidthProbeFailureIsTerminalForItsReport() {
        var fixture = makeLiveCeilingProbeFromAudioPriority()
        fixture.packetsSent += 100
        fixture.totalPacketSendDelay += 20

        XCTAssertEqual(
            fixture.policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.012,
                outboundVideoPacketsSent: fixture.packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    fixture.totalPacketSendDelay
            )?.tier,
            .audioPriority
        )
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, 1)
        XCTAssertTrue(fixture.policy.lastSampleHasLatencyPressure)
    }

    func testLowFPSNoPacketPollReusesFreshHealthyQueueEvidence() {
        var policy = makePolicy()
        move(&policy, to: .audioPriority, roundTripTime: 0.020)
        let startedAt = ContinuousClock.now
        var packetsSent: UInt64 = 100
        var totalPacketSendDelay = 0.1

        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 400_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay,
                observedAt: startedAt
            )
        )
        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 400_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay,
                observedAt: startedAt.advanced(by: .milliseconds(500))
            )
        )
        packetsSent += 40
        totalPacketSendDelay += 0.004
        XCTAssertEqual(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 400_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay,
                observedAt: startedAt.advanced(by: .milliseconds(1_000))
            )?.tier,
            .audioPriority
        )
        XCTAssertEqual(policy.applicationLimitedUpgradeSampleCount, 0)
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .audioPriority)

        let chainedProbe = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 600_000,
            currentRoundTripTimeSeconds: 0.020,
            outboundVideoPacketsSent: packetsSent,
            outboundVideoTotalPacketSendDelaySeconds:
                totalPacketSendDelay,
            observedAt: startedAt.advanced(by: .milliseconds(1_500))
        )
        XCTAssertEqual(chainedProbe?.tier, .audioPriority)
        XCTAssertEqual(chainedProbe?.maximumTotalRTPBitrateBps, 1_200_000)
        XCTAssertEqual(chainedProbe?.maximumFramesPerSecond, 1)
        XCTAssertEqual(chainedProbe?.scaleResolutionDownBy, 12)
        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertEqual(
            policy.applicationLimitedProbeOriginTier,
            .audioPriority
        )
        XCTAssertEqual(
            policy.applicationLimitedProbeBestQualifiedTier,
            .emergency
        )
        XCTAssertEqual(
            policy.applicationLimitedProbeHealthySampleCount,
            1
        )
    }

    func testLowFPSHealthyQueueEvidenceCannotCrossCadenceReset() {
        var policy = makePolicy()
        move(&policy, to: .audioPriority, roundTripTime: 0.020)
        let startedAt = ContinuousClock.now

        _ = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 300_000,
            currentRoundTripTimeSeconds: 0.020,
            outboundVideoPacketsSent: 100,
            outboundVideoTotalPacketSendDelaySeconds: 0.1,
            observedAt: startedAt
        )
        _ = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 300_000,
            currentRoundTripTimeSeconds: 0.020,
            outboundVideoPacketsSent: 140,
            outboundVideoTotalPacketSendDelaySeconds: 0.104,
            observedAt: startedAt.advanced(by: .milliseconds(500))
        )
        XCTAssertEqual(policy.applicationLimitedUpgradeSampleCount, 0)
        XCTAssertNil(policy.applicationLimitedProbeOriginTier)

        policy.resetIncompleteEvidenceWindow()
        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 400_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: 140,
                outboundVideoTotalPacketSendDelaySeconds: 0.104,
                observedAt: startedAt.advanced(by: .milliseconds(1_000))
            )
        )
        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertEqual(policy.applicationLimitedUpgradeSampleCount, 0)
    }

    func testPersistentBandwidthOnlyPressureDowngradesAfterTwoHealthyLatencySamples() {
        var policy = makePolicy()
        move(&policy, to: .full)

        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 2_000_000,
                currentRoundTripTimeSeconds: 0.050
            )
        )
        XCTAssertEqual(policy.currentTier, .full)
        let critical = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 2_000_000,
            currentRoundTripTimeSeconds: 0.050
        )
        XCTAssertEqual(critical?.tier, .critical)
        XCTAssertEqual(policy.currentTier, .critical)

        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 600_000,
                currentRoundTripTimeSeconds: 0.050
            )
        )
        XCTAssertEqual(policy.currentTier, .critical)
        let emergency = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 600_000,
            currentRoundTripTimeSeconds: 0.050
        )
        XCTAssertEqual(emergency?.tier, .emergency)
        XCTAssertEqual(policy.currentTier, .emergency)

        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 300_000,
                currentRoundTripTimeSeconds: 0.050
            )
        )
        XCTAssertEqual(policy.currentTier, .emergency)
        let audioPriority = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 300_000,
            currentRoundTripTimeSeconds: 0.050
        )
        XCTAssertEqual(audioPriority?.tier, .audioPriority)
        XCTAssertEqual(policy.currentTier, .audioPriority)
    }

    func testBandwidthOnlyDowngradeDebounceResetsAfterOneHealthySample() {
        var policy = makePolicy()
        move(&policy, to: .full)

        func lowCapacityUpdate()
            -> WorldwideScreenVideoEncodingRecommendation? {
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 2_000_000,
                currentRoundTripTimeSeconds: 0.050
            )
        }

        XCTAssertNil(lowCapacityUpdate())
        XCTAssertEqual(policy.bandwidthOnlyDowngradeSampleCount, 1)
        XCTAssertNil(healthyUpdate(&policy))
        XCTAssertEqual(policy.currentTier, .full)
        XCTAssertEqual(policy.bandwidthOnlyDowngradeSampleCount, 0)

        XCTAssertNil(lowCapacityUpdate())
        XCTAssertEqual(policy.currentTier, .full)
        XCTAssertEqual(lowCapacityUpdate()?.tier, .critical)
    }

    func testHigherTierProbeCollapseBelowReserveLatchesAndKeepsVisibleFloor() {
        var policy = makePolicy()
        move(&policy, to: .emergency)
        var packetsSent: UInt64 = 100
        var totalPacketSendDelay = 0.1

        _ = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 853_000,
            currentRoundTripTimeSeconds: 0.050,
            outboundVideoPacketsSent: packetsSent,
            outboundVideoTotalPacketSendDelaySeconds: totalPacketSendDelay
        )
        for _ in 0..<32 where policy.applicationLimitedProbeOriginTier == nil {
            packetsSent += 40
            totalPacketSendDelay += 0.004
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 853_000,
                currentRoundTripTimeSeconds: 0.050,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
        }
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .emergency)
        XCTAssertEqual(policy.currentTier, .emergency)

        packetsSent += 40
        totalPacketSendDelay += 0.004
        XCTAssertEqual(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 300_000,
                currentRoundTripTimeSeconds: 0.050,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )?.tier,
            .audioPriority
        )
        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertNil(policy.applicationLimitedProbeOriginTier)
        XCTAssertTrue(policy.belowReserveProbeDisprovedSenderLimitation)
        XCTAssertTrue(policy.lastSampleHasPositiveSuspensionPressure)
        XCTAssertNil(
            policy.automaticSuspensionDecision(
                isCaptureActive: true,
                isAutomaticallySuspended: false
            )
        )

        for _ in 2...3 {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.050
            )
            XCTAssertNil(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                )
            )
        }
    }

    func testFourHealthySamplesRecoverDirectlyToSustainableTier() {
        var policy = makePolicy()
        move(&policy, to: .constrained)

        for _ in 1..<WorldwideScreenVideoAdaptationPolicy
            .requiredHealthyUpgradeSampleCount {
            XCTAssertNil(healthyUpdate(&policy))
        }
        XCTAssertEqual(
            policy.healthyUpgradeSampleCount,
            WorldwideScreenVideoAdaptationPolicy
                .requiredHealthyUpgradeSampleCount - 1
        )
        XCTAssertEqual(healthyUpdate(&policy)?.tier, .full)
        XCTAssertEqual(policy.currentTier, .full)
    }

    func testPersistentMissingOrInvalidBandwidthHoldsWithoutLatencyPressure() {
        var policy = makePolicy()
        move(&policy, to: .balanced)

        for _ in 0..<64 {
            XCTAssertNil(
                policy.update(
                    peerGeneration: 1,
                    isCaptureActive: true,
                    availableOutgoingBitrateBps: nil,
                    currentRoundTripTimeSeconds: 0.050
                )
            )
            XCTAssertEqual(policy.currentTier, .balanced)
        }
        XCTAssertEqual(policy.unavailableBandwidthSampleCount, 64)
        XCTAssertTrue(policy.bandwidthEstimateIsUnavailable)

        for invalidBandwidth in [Double.nan, .infinity, 0] {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: invalidBandwidth,
                currentRoundTripTimeSeconds: 0.050
            )
        }
        XCTAssertEqual(policy.currentTier, .balanced)
        XCTAssertEqual(policy.healthyUpgradeSampleCount, 0)
    }

    func testInflatedRoundTripTimeImmediatelyDowngradesAndNeverBecomesBaseline() {
        var policy = makePolicy()
        move(&policy, to: .full, roundTripTime: 0.040)
        XCTAssertEqual(policy.roundTripTimeBaselineSeconds, 0.040)

        XCTAssertEqual(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 12_000_000,
                currentRoundTripTimeSeconds: 0.200
            )?.tier,
            .high
        )

        for _ in 0..<12 {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 12_000_000,
                currentRoundTripTimeSeconds: 0.200
            )
        }
        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertEqual(policy.roundTripTimeBaselineSeconds, 0.040)
    }

    func testMissingRoundTripTimeDoesNotDelaySafetyDowngrade() {
        var policy = makePolicy()
        move(&policy, to: .balanced)

        let update = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 600_000,
            currentRoundTripTimeSeconds: nil
        )

        XCTAssertEqual(update?.tier, .emergency)
        XCTAssertEqual(policy.currentTier, .emergency)
    }

    func testHiddenCaptureIgnoresVideoAbsentStatsAndRestoresInitialTier() {
        var policy = makePolicy()
        move(&policy, to: .constrained)

        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: false,
                availableOutgoingBitrateBps: 300_000,
                currentRoundTripTimeSeconds: 0.050
            )
        )
        XCTAssertEqual(policy.currentTier, .survival)
        XCTAssertEqual(policy.healthyUpgradeSampleCount, 0)
        XCTAssertEqual(policy.unavailableBandwidthSampleCount, 0)

        for _ in 0..<8 {
            XCTAssertNil(
                policy.update(
                    peerGeneration: 1,
                    isCaptureActive: false,
                    availableOutgoingBitrateBps: 12_000_000,
                    currentRoundTripTimeSeconds: 0.050
                )
            )
        }
        XCTAssertEqual(policy.currentTier, .survival)
    }

    func testPeerGenerationResetAndSamePeerRetention() {
        var policy = makePolicy()
        move(&policy, to: .critical)
        XCTAssertEqual(policy.roundTripTimeBaselineSeconds, 0.050)
        XCTAssertGreaterThan(
            policy.positiveBandwidthBootstrapSampleCount,
            0
        )

        XCTAssertFalse(policy.bind(toPeerGeneration: 1))
        XCTAssertEqual(policy.currentTier, .critical)
        XCTAssertEqual(policy.roundTripTimeBaselineSeconds, 0.050)

        XCTAssertTrue(policy.bind(toPeerGeneration: 2))
        XCTAssertEqual(policy.currentTier, .survival)
        XCTAssertEqual(policy.healthyUpgradeSampleCount, 0)
        XCTAssertEqual(policy.positiveBandwidthBootstrapSampleCount, 0)
        XCTAssertEqual(policy.applicationLimitedUpgradeSampleCount, 0)
        XCTAssertEqual(policy.applicationLimitedProbeGraceSamplesRemaining, 0)
        XCTAssertNil(policy.roundTripTimeBaselineSeconds)

        XCTAssertNil(
            policy.update(
                peerGeneration: 3,
                isCaptureActive: false,
                availableOutgoingBitrateBps: 600_000,
                currentRoundTripTimeSeconds: 0.200
            )
        )
        XCTAssertEqual(policy.peerGeneration, 3)
        XCTAssertEqual(policy.currentTier, .survival)
        XCTAssertNil(policy.roundTripTimeBaselineSeconds)

        let activeReset = policy.update(
            peerGeneration: 4,
            isCaptureActive: true,
            availableOutgoingBitrateBps: nil,
            currentRoundTripTimeSeconds: nil
        )
        XCTAssertEqual(activeReset?.tier, .survival)
    }

    func testConservativeStartupRecoversToFullAfterOneHealthyWindow() {
        var policy = makePolicy()
        XCTAssertEqual(policy.currentTier, .survival)
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))

        for _ in 0..<(
            WorldwideScreenVideoAdaptationPolicy.requiredHealthyUpgradeSampleCount
                + 1
        ) {
            XCTAssertNil(healthyUpdate(&policy))
        }
        XCTAssertEqual(policy.currentTier, .survival)
        XCTAssertEqual(healthyUpdate(&policy)?.tier, .full)
        XCTAssertEqual(policy.currentTier, .full)
    }

    func testHealthyEstimateRecoversOnlyToItsSustainableTier() {
        var policy = makePolicy()
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))

        for _ in 0..<(
            WorldwideScreenVideoAdaptationPolicy.requiredHealthyUpgradeSampleCount
                + 1
        ) {
            XCTAssertNil(
                policy.update(
                    peerGeneration: 1,
                    isCaptureActive: true,
                    availableOutgoingBitrateBps: 8_000_000,
                    currentRoundTripTimeSeconds: 0.050
                )
            )
        }
        XCTAssertEqual(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 8_000_000,
                currentRoundTripTimeSeconds: 0.050
            )?.tier,
            .balanced
        )
        XCTAssertEqual(policy.currentTier, .balanced)
    }

    func testUpgradeTargetRemainsMonotonicAcrossSustainableTierBoundaries() {
        let cases: [(
            bandwidth: Double,
            expectedTier: WorldwideScreenVideoAdaptationTier
        )] = [
            (5_300_000, .constrained),
            (8_200_000, .balanced),
        ]

        for testCase in cases {
            var policy = makePolicy()
            XCTAssertTrue(policy.bind(toPeerGeneration: 1))
            var recommendation: WorldwideScreenVideoEncodingRecommendation?

            for _ in 0..<(
                WorldwideScreenVideoAdaptationPolicy.requiredHealthyUpgradeSampleCount
                    + 2
            ) {
                recommendation = policy.update(
                    peerGeneration: 1,
                    isCaptureActive: true,
                    availableOutgoingBitrateBps: testCase.bandwidth,
                    currentRoundTripTimeSeconds: 0.050
                ) ?? recommendation
            }

            XCTAssertEqual(recommendation?.tier, testCase.expectedTier)
            XCTAssertEqual(policy.currentTier, testCase.expectedTier)
        }
    }

    func testNearConfiguredEstimatorCeilingCanReachFullQuality() {
        var policy = makePolicy()
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))
        var recommendation: WorldwideScreenVideoEncodingRecommendation?

        for _ in 0..<(
            WorldwideScreenVideoAdaptationPolicy.requiredHealthyUpgradeSampleCount
                + 2
        ) {
            recommendation = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 11_500_000,
                currentRoundTripTimeSeconds: 0.050
            ) ?? recommendation
        }

        XCTAssertEqual(recommendation?.tier, .full)
        XCTAssertEqual(policy.currentTier, .full)
    }

    func testMissingBandwidthUsesStableRTTAndSendQueueForAdditiveRecovery() {
        var policy = makePolicy()
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))
        let requiredSamples = WorldwideScreenVideoAdaptationPolicy
            .requiredUnavailableBandwidthUpgradeSampleCount

        for sample in 1..<(requiredSamples + 2) {
            XCTAssertNil(
                policy.update(
                    peerGeneration: 1,
                    isCaptureActive: true,
                    availableOutgoingBitrateBps: nil,
                    currentRoundTripTimeSeconds: 0.050,
                    outboundVideoPacketsSent: UInt64(sample * 10),
                    outboundVideoTotalPacketSendDelaySeconds:
                        Double(sample) * 0.050
                )
            )
        }
        XCTAssertEqual(policy.currentTier, .survival)
        XCTAssertEqual(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.050,
                outboundVideoPacketsSent: UInt64((requiredSamples + 2) * 10),
                outboundVideoTotalPacketSendDelaySeconds:
                    Double(requiredSamples + 2) * 0.050
            )?.tier,
            .critical
        )
        XCTAssertEqual(policy.currentTier, .critical)
        XCTAssertTrue(policy.bandwidthEstimateIsUnavailable)
    }

    func testAlternatingMissingBandwidthPressureCannotPingPongUpward() {
        var policy = makePolicy()
        move(&policy, to: .balanced)
        var packetsSent: UInt64 = 100
        var totalPacketSendDelay = 0.1
        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.050,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
        )

        for expectedPressureTier in [
            WorldwideScreenVideoAdaptationTier.constrained,
            .critical,
            .survival,
        ] {
            let tierBeforeHealthySample = policy.currentTier
            packetsSent += 100
            totalPacketSendDelay += 0.1
            XCTAssertNil(
                policy.update(
                    peerGeneration: 1,
                    isCaptureActive: true,
                    availableOutgoingBitrateBps: nil,
                    currentRoundTripTimeSeconds: 0.050,
                    outboundVideoPacketsSent: packetsSent,
                    outboundVideoTotalPacketSendDelaySeconds:
                        totalPacketSendDelay
                )
            )
            XCTAssertEqual(policy.currentTier, tierBeforeHealthySample)

            packetsSent += 100
            totalPacketSendDelay += 20
            XCTAssertEqual(
                policy.update(
                    peerGeneration: 1,
                    isCaptureActive: true,
                    availableOutgoingBitrateBps: nil,
                    currentRoundTripTimeSeconds: 0.200,
                    outboundVideoPacketsSent: packetsSent,
                    outboundVideoTotalPacketSendDelaySeconds:
                        totalPacketSendDelay
                )?.tier,
                expectedPressureTier
            )
        }
    }

    func testColdMissingBandwidthFirstReactionIsFastAndEveryTierNeedsFreshEvidence() {
        var policy = makePolicy()
        move(&policy, to: .audioPriority)
        policy.invalidateSelectedRoute()
        var tierTransitions: [WorldwideScreenVideoAdaptationTier] = []
        var transitionSamples: [Int] = []
        let sampleLimit = WorldwideScreenVideoAdaptationPolicy
            .roundTripTimeBootstrapSampleCount - 1
            + (WorldwideScreenVideoAdaptationTier.allCases.count - 1)
                * WorldwideScreenVideoAdaptationPolicy
                    .requiredUnavailableBandwidthUpgradeSampleCount

        for sample in 1...sampleLimit {
            let recommendation = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.050,
                outboundVideoPacketsSent: UInt64(sample * 10),
                outboundVideoTotalPacketSendDelaySeconds:
                    Double(sample) * 0.050
            )
            if let recommendation {
                tierTransitions.append(recommendation.tier)
                transitionSamples.append(sample)
            }
        }

        XCTAssertEqual(
            tierTransitions,
            [
                .emergency,
                .survival,
                .critical,
                .constrained,
                .balanced,
                .high,
                .full,
            ]
        )
        XCTAssertEqual(policy.currentTier, .full)
        XCTAssertEqual(
            transitionSamples.first,
            WorldwideScreenVideoAdaptationPolicy
                .roundTripTimeBootstrapSampleCount - 1
                + WorldwideScreenVideoAdaptationPolicy
                    .requiredUnavailableBandwidthUpgradeSampleCount
        )
        XCTAssertLessThan(
            (transitionSamples.first ?? Int.max)
                * WorldwideScreenVideoAdaptationPolicy
                    .sampleIntervalMilliseconds,
            5_000
        )
        XCTAssertTrue(
            zip(transitionSamples, transitionSamples.dropFirst())
                .allSatisfy { earlier, later in
                    later - earlier
                        == WorldwideScreenVideoAdaptationPolicy
                            .requiredUnavailableBandwidthUpgradeSampleCount
                }
        )
    }

    func testPositiveBandwidthCanRecoverWhenRTTIsMissingButSendQueueIsHealthy() {
        var policy = makePolicy()
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))
        let requiredSamples = WorldwideScreenVideoAdaptationPolicy
            .requiredHealthyUpgradeSampleCount

        for sample in 1...requiredSamples {
            let recommendation = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 12_000_000,
                currentRoundTripTimeSeconds: nil,
                outboundVideoPacketsSent: UInt64(sample * 10),
                outboundVideoTotalPacketSendDelaySeconds:
                    Double(sample) * 0.050
            )
            XCTAssertNil(recommendation)
        }
        XCTAssertEqual(policy.currentTier, .survival)

        XCTAssertEqual(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 12_000_000,
                currentRoundTripTimeSeconds: nil,
                outboundVideoPacketsSent: UInt64((requiredSamples + 1) * 10),
                outboundVideoTotalPacketSendDelaySeconds:
                    Double(requiredSamples + 1) * 0.050
            )?.tier,
            .full
        )
        XCTAssertEqual(policy.currentTier, .full)
    }

    func testBandwidthEvidenceLaneChangeRequiresFreshPositiveWindow() {
        var policy = makePolicy()
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))

        var missingBandwidthRecommendation:
            WorldwideScreenVideoEncodingRecommendation?
        let samplesBeforeFirstMissingBandwidthUpgrade =
            WorldwideScreenVideoAdaptationPolicy
                .roundTripTimeBootstrapSampleCount - 1
                + WorldwideScreenVideoAdaptationPolicy
                    .requiredUnavailableBandwidthUpgradeSampleCount
        for sample in 1...samplesBeforeFirstMissingBandwidthUpgrade {
            missingBandwidthRecommendation = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.050,
                outboundVideoPacketsSent: UInt64(sample * 10),
                outboundVideoTotalPacketSendDelaySeconds:
                    Double(sample) * 0.050
            )
        }
        XCTAssertEqual(missingBandwidthRecommendation?.tier, .critical)
        XCTAssertEqual(policy.currentTier, .critical)

        for _ in 0..<(
            WorldwideScreenVideoAdaptationPolicy.requiredHealthyUpgradeSampleCount
                - 1
        ) {
            XCTAssertNil(healthyUpdate(&policy))
        }
        XCTAssertEqual(policy.currentTier, .critical)
        XCTAssertEqual(healthyUpdate(&policy)?.tier, .full)
    }

    func testBandwidthEvidenceLaneChangeRequiresFreshUnavailableWindow() {
        var policy = makePolicy()
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))

        let positiveSamplesBeforeUpgrade =
            WorldwideScreenVideoAdaptationPolicy
                .roundTripTimeBootstrapSampleCount
                + WorldwideScreenVideoAdaptationPolicy
                .requiredHealthyUpgradeSampleCount - 2
        for _ in 0..<positiveSamplesBeforeUpgrade {
            XCTAssertNil(healthyUpdate(&policy))
        }
        XCTAssertEqual(
            policy.healthyUpgradeSampleCount,
            WorldwideScreenVideoAdaptationPolicy.requiredHealthyUpgradeSampleCount
                - 1
        )

        let unavailableSamplesBeforeUpgrade =
            WorldwideScreenVideoAdaptationPolicy
                .requiredUnavailableBandwidthUpgradeSampleCount
        for sample in 1...unavailableSamplesBeforeUpgrade {
            XCTAssertNil(
                policy.update(
                    peerGeneration: 1,
                    isCaptureActive: true,
                    availableOutgoingBitrateBps: nil,
                    currentRoundTripTimeSeconds: 0.050,
                    outboundVideoPacketsSent: UInt64(sample * 10),
                    outboundVideoTotalPacketSendDelaySeconds:
                        Double(sample) * 0.050
                )
            )
        }
        XCTAssertEqual(policy.currentTier, .survival)
        XCTAssertEqual(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.050,
                outboundVideoPacketsSent:
                    UInt64((unavailableSamplesBeforeUpgrade + 1) * 10),
                outboundVideoTotalPacketSendDelaySeconds: 0.250
            )?.tier,
            .critical
        )
    }

    func testRouteChangeRebasesRoundTripTimeWithoutResettingTier() {
        let direct = WebRTCICERouteDiagnostics(kind: .direct)
        let relayed = WebRTCICERouteDiagnostics(kind: .relayed)
        var policy = makePolicy()
        move(&policy, to: .constrained, roundTripTime: 0.040)

        for _ in 0..<3 {
            XCTAssertNil(
                policy.update(
                    peerGeneration: 1,
                    isCaptureActive: true,
                    availableOutgoingBitrateBps: 12_000_000,
                    currentRoundTripTimeSeconds: 0.040,
                    selectedRoute: direct
                )
            )
        }
        XCTAssertEqual(policy.roundTripTimeBaselineSeconds, 0.040)

        for _ in 0..<3 {
            XCTAssertNil(
                policy.update(
                    peerGeneration: 1,
                    isCaptureActive: true,
                    availableOutgoingBitrateBps: 12_000_000,
                    currentRoundTripTimeSeconds: 0.200,
                    selectedRoute: relayed
                )
            )
        }
        XCTAssertEqual(policy.currentTier, .constrained)
        XCTAssertEqual(policy.roundTripTimeBaselineSeconds, 0.200)
        XCTAssertEqual(policy.healthyUpgradeSampleCount, 1)
    }

    func testRouteChangeRevertsAnUnconfirmedApplicationLimitedProbe() {
        let direct = WebRTCICERouteDiagnostics(kind: .direct)
        let relayed = WebRTCICERouteDiagnostics(kind: .relayed)
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))
        var packetsSent: UInt64 = 100
        var totalPacketSendDelay = 0.1
        XCTAssertEqual(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 100_000,
                currentRoundTripTimeSeconds: 0.020,
                selectedRoute: direct,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )?.tier,
            .audioPriority
        )

        for _ in 0..<16 where policy.applicationLimitedProbeOriginTier == nil {
            packetsSent += 40
            totalPacketSendDelay += 0.004
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 400_000,
                currentRoundTripTimeSeconds: 0.020,
                selectedRoute: direct,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
        }
        XCTAssertNotNil(policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .audioPriority)

        packetsSent += 40
        totalPacketSendDelay += 0.004
        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 400_000,
                currentRoundTripTimeSeconds: 0.020,
                selectedRoute: relayed,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
        )
        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertNil(policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(policy.applicationLimitedProbeFailureCount, 0)
        XCTAssertEqual(policy.applicationLimitedProbeCooldownSamplesRemaining, 0)
    }

    func testExplicitRouteInvalidationRebasesAnIdenticalReplacementRoute() {
        let direct = WebRTCICERouteDiagnostics(kind: .direct)
        var policy = makePolicy()
        move(&policy, to: .constrained, roundTripTime: 0.040)

        for _ in 0..<3 {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 12_000_000,
                currentRoundTripTimeSeconds: 0.040,
                selectedRoute: direct
            )
        }
        XCTAssertEqual(policy.roundTripTimeBaselineSeconds, 0.040)

        policy.invalidateSelectedRoute()
        XCTAssertNil(policy.selectedRoute)
        XCTAssertNil(policy.roundTripTimeBaselineSeconds)
        XCTAssertEqual(policy.healthyUpgradeSampleCount, 0)

        for _ in 0..<3 {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 12_000_000,
                currentRoundTripTimeSeconds: 0.200,
                selectedRoute: direct
            )
        }
        XCTAssertEqual(policy.currentTier, .constrained)
        XCTAssertEqual(policy.roundTripTimeBaselineSeconds, 0.200)
        XCTAssertEqual(policy.healthyUpgradeSampleCount, 1)
    }

    func testCadenceChangeDiscardsIncompleteEvidenceButKeepsRouteBaseline() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))

        for sample in 1...3 {
            XCTAssertNil(
                policy.update(
                    peerGeneration: 1,
                    isCaptureActive: true,
                    availableOutgoingBitrateBps: 47_500_000,
                    currentRoundTripTimeSeconds: 0.020,
                    outboundVideoPacketsSent: UInt64(sample * 100),
                    outboundVideoTotalPacketSendDelaySeconds:
                        Double(sample) * 0.5
                )
            )
        }
        XCTAssertEqual(policy.healthyUpgradeSampleCount, 1)
        XCTAssertEqual(policy.roundTripTimeBaselineSeconds, 0.020)

        policy.resetIncompleteEvidenceWindow()
        XCTAssertEqual(policy.healthyUpgradeSampleCount, 0)
        XCTAssertEqual(policy.roundTripTimeBaselineSeconds, 0.020)

        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 47_500_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: 400,
                outboundVideoTotalPacketSendDelaySeconds: 2
            )
        )
        XCTAssertEqual(policy.currentTier, .survival)
        XCTAssertEqual(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 47_500_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: 500,
                outboundVideoTotalPacketSendDelaySeconds: 2.5
            )?.tier,
            .full
        )
    }

    func testLowRoundTripTimeOutlierCannotBlockRecoveryForever() {
        var policy = makePolicy()
        move(&policy, to: .constrained, roundTripTime: 0.100)

        _ = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 12_000_000,
            currentRoundTripTimeSeconds: 0.001
        )
        XCTAssertEqual(
            policy.roundTripTimeBaselineSeconds ?? .nan,
            0.090,
            accuracy: 0.000_001
        )

        for _ in 0..<8 {
            _ = healthyUpdate(&policy, roundTripTime: 0.100)
        }

        XCTAssertEqual(policy.currentTier, .full)
        XCTAssertEqual(
            policy.roundTripTimeBaselineSeconds ?? .nan,
            0.090,
            accuracy: 0.000_001
        )
    }

    func testPacketSendQueueDelayForcesImmediateDescent() {
        var policy = makePolicy()
        move(&policy, to: .full)

        _ = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 12_000_000,
            currentRoundTripTimeSeconds: 0.050,
            outboundVideoPacketsSent: 100,
            outboundVideoTotalPacketSendDelaySeconds: 1
        )
        let update = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 12_000_000,
            currentRoundTripTimeSeconds: 0.050,
            outboundVideoPacketsSent: 110,
            outboundVideoTotalPacketSendDelaySeconds: 3
        )

        XCTAssertEqual(update?.tier, .high)
        XCTAssertEqual(policy.currentTier, .high)
    }

    func testInactiveMissingBandwidthNeverArmsAutomaticSuspension() {
        var policy = makePolicy()

        for _ in 0..<64 {
            XCTAssertNil(
                policy.update(
                    peerGeneration: 1,
                    isCaptureActive: false,
                    availableOutgoingBitrateBps: nil,
                    currentRoundTripTimeSeconds: 0.250
                )
            )
            XCTAssertNil(
                policy.automaticSuspensionDecision(
                    isCaptureActive: false,
                    isAutomaticallySuspended: false
                )
            )
        }

        XCTAssertEqual(policy.currentTier, .survival)
        XCTAssertFalse(policy.bandwidthEstimateIsUnavailable)
    }

    func testEstimateBelowSenderCeilingKeepsVisibleFloorDuringPressure() {
        var policy = makePolicy()
        move(&policy, to: .audioPriority)

        for _ in 1...3 {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 10_000,
                currentRoundTripTimeSeconds: 0.050
            )
            XCTAssertNil(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                )
            )
        }
    }

    func testLiveRTTSpikeWithAdvancingLowDelaySenderNeverBlackensScreen() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        move(&policy, to: .emergency, roundTripTime: 0.028)

        var packetsSent: UInt64 = 100
        var totalPacketSendDelay = 0.100
        _ = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 1_936_000,
            currentRoundTripTimeSeconds: 0.028,
            outboundVideoPacketsSent: packetsSent,
            outboundVideoTotalPacketSendDelaySeconds: totalPacketSendDelay
        )

        for _ in 1...3 {
            packetsSent += 40
            totalPacketSendDelay += 0.004
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 1_936_000,
                currentRoundTripTimeSeconds: 0.130,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
            XCTAssertTrue(policy.lastSampleHasLatencyPressure)
            XCTAssertLessThan(
                policy.lastAveragePacketSendDelaySeconds ?? .infinity,
                0.001
            )
            XCTAssertNil(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                )
            )
        }

        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertEqual(policy.currentRecommendation.maximumFramesPerSecond, 1)
        XCTAssertGreaterThan(policy.currentRecommendation.maximumBitrateBps, 0)
        XCTAssertEqual(policy.automaticSuspensionPressureSampleCount, 0)
    }

    func testSingleRTTSpikeCannotCauseDelayedBlackoutAfterFloorProbe() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 12_000_000,
            baseFramesPerSecond: 60
        )
        move(&policy, to: .audioPriority, roundTripTime: 0.029)

        var packetsSent: UInt64 = 100
        let totalPacketSendDelay = 0.0
        _ = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 400_000,
            currentRoundTripTimeSeconds: 0.029,
            outboundVideoPacketsSent: packetsSent,
            outboundVideoTotalPacketSendDelaySeconds: totalPacketSendDelay
        )

        var openedProbe = policy.applicationLimitedProbeOriginTier
            == .audioPriority
        for _ in 0..<WorldwideScreenVideoAdaptationPolicy
            .requiredApplicationLimitedUpgradeSampleCount where !openedProbe {
            packetsSent += 40
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 400_000,
                currentRoundTripTimeSeconds: 0.029,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds: totalPacketSendDelay
            )
            openedProbe = openedProbe
                || policy.applicationLimitedProbeOriginTier == .audioPriority
            XCTAssertNil(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                )
            )
        }
        XCTAssertTrue(openedProbe)

        packetsSent += 40
        _ = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 400_000,
            currentRoundTripTimeSeconds: 0.130,
            outboundVideoPacketsSent: packetsSent,
            outboundVideoTotalPacketSendDelaySeconds: totalPacketSendDelay
        )
        XCTAssertTrue(policy.lastSampleHasLatencyPressure)
        XCTAssertNil(
            policy.automaticSuspensionDecision(
                isCaptureActive: true,
                isAutomaticallySuspended: false
            )
        )

        for _ in 1...3 {
            packetsSent += 40
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 400_000,
                currentRoundTripTimeSeconds: 0.029,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds: totalPacketSendDelay
            )
            XCTAssertFalse(policy.lastSampleHasLatencyPressure)
            XCTAssertEqual(policy.lastAveragePacketSendDelaySeconds, 0)
            XCTAssertNil(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                )
            )
        }

        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertGreaterThan(policy.currentRecommendation.maximumBitrateBps, 0)
        XCTAssertEqual(policy.currentRecommendation.maximumFramesPerSecond, 1)
        XCTAssertEqual(policy.currentRecommendation.scaleResolutionDownBy, 12)
        XCTAssertEqual(policy.automaticSuspensionPressureSampleCount, 0)
    }

    func testServiceAdaptationCannotStartOpaqueBandwidthPause() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/Sources/CaptureServer/WorldwideScreenService.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(
            source.range(
                of: "    private func adaptScreenVideoForNetworkConditions("
            )?.lowerBound
        )
        let end = try XCTUnwrap(
            source.range(
                of: "    private func beginAutomaticScreenMediaResumeIfPossible(",
                range: start..<source.endIndex
            )?.lowerBound
        )
        let adaptationMethod = String(source[start..<end])

        XCTAssertFalse(
            adaptationMethod.contains("beginAutomaticScreenMediaSuspensionIfPossible")
        )
        XCTAssertFalse(source.contains("sendScreenMediaSuspensionNotice("))
        XCTAssertFalse(
            adaptationMethod.contains(
                "automaticSuspensionDecision(\n            isCaptureActive: true"
            )
        )
        XCTAssertTrue(
            adaptationMethod.contains("screenVideoAdaptationPolicy = proposedPolicy")
        )
    }

    func testSenderLimitedFloorEstimateProbesUpWithoutBlackoutWhenCapacityExpands() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))

        var packetsSent: UInt64 = 0
        var totalPacketSendDelay = 0.0
        var floorRecommendation: WorldwideScreenVideoEncodingRecommendation?
        for _ in 0..<3 where policy.currentTier != .audioPriority {
            packetsSent += 100
            totalPacketSendDelay += 0.1
            floorRecommendation = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 50_000,
                currentRoundTripTimeSeconds: 0.029,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            ) ?? floorRecommendation
        }
        XCTAssertEqual(floorRecommendation?.tier, .audioPriority)
        XCTAssertEqual(policy.currentTier, .audioPriority)

        var probeRecommendation: WorldwideScreenVideoEncodingRecommendation?
        for _ in 0..<32 {
            packetsSent += 40
            totalPacketSendDelay += 0.004
            let update = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 400_000,
                currentRoundTripTimeSeconds: 0.029,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
            XCTAssertFalse(policy.lastSampleHasLatencyPressure)
            XCTAssertFalse(policy.lastSampleHasPositiveSuspensionPressure)
            XCTAssertNil(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                )
            )
            if policy.applicationLimitedProbeOriginTier == .audioPriority {
                probeRecommendation = update
                break
            }
        }

        XCTAssertEqual(probeRecommendation?.tier, .audioPriority)
        XCTAssertEqual(
            probeRecommendation?.maximumBitrateBps,
            policy.maximumTierVideoBitrateBps
        )
        XCTAssertEqual(probeRecommendation?.maximumFramesPerSecond, 1)
        XCTAssertEqual(probeRecommendation?.scaleResolutionDownBy, 12)
        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .audioPriority)

        var fullRecommendation:
            WorldwideScreenVideoEncodingRecommendation?
        for _ in 0..<8 where policy.currentTier != .full {
            packetsSent += 40
            totalPacketSendDelay += 0.004
            fullRecommendation = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 50_000_000,
                currentRoundTripTimeSeconds: 0.029,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            ) ?? fullRecommendation
        }
        XCTAssertEqual(fullRecommendation?.tier, .full)
        XCTAssertEqual(policy.currentTier, .full)
        XCTAssertNil(policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(policy.applicationLimitedProbeFailureCount, 0)
        XCTAssertFalse(
            policy.belowReserveProbeDisprovedSenderLimitation
        )
        XCTAssertNil(
            policy.automaticSuspensionDecision(
                isCaptureActive: true,
                isAutomaticallySuspended: false
            )
        )
    }

    func testFailedFloorProbeLatchesTrueCongestionAtVisibleFloor() {
        let policy = makeSuspendedPolicyAfterFailedFloorProbe().policy
        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertEqual(policy.applicationLimitedProbeFailureCount, 1)
        XCTAssertTrue(policy.belowReserveProbeDisprovedSenderLimitation)
    }

    func testFailedFloorProbePressureSurvivesMissingBandwidthTelemetry() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))
        XCTAssertEqual(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 50_000,
                currentRoundTripTimeSeconds: 0.029,
                outboundVideoPacketsSent: 100,
                outboundVideoTotalPacketSendDelaySeconds: 0.1
            )?.tier,
            .audioPriority
        )

        var packetsSent: UInt64 = 100
        var totalPacketSendDelay = 0.1
        for _ in 0..<32 where policy.applicationLimitedProbeOriginTier == nil {
            packetsSent += 40
            totalPacketSendDelay += 0.004
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 400_000,
                currentRoundTripTimeSeconds: 0.029,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
        }
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .audioPriority)

        packetsSent += 40
        totalPacketSendDelay += 0.004
        _ = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 251_000,
            currentRoundTripTimeSeconds: 0.029,
            outboundVideoPacketsSent: packetsSent,
            outboundVideoTotalPacketSendDelaySeconds:
                totalPacketSendDelay
        )
        XCTAssertTrue(
            policy.belowReserveProbeDisprovedSenderLimitation
        )
        XCTAssertNil(
            policy.automaticSuspensionDecision(
                isCaptureActive: true,
                isAutomaticallySuspended: false
            )
        )

        for _ in 2...3 {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.029
            )
            XCTAssertTrue(policy.lastSampleHasPositiveSuspensionPressure)
            XCTAssertNil(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                )
            )
        }
    }

    func testSuccessfulResumeCannotImmediatelyReenterSenderLimitedPauseCycle() {
        var fixture = makeSuspendedPolicyAfterFailedFloorProbe()
        var policy = fixture.policy
        reachStableAutomaticResumeDecision(&policy)

        // Returning `.resume` is only a proposal. The coordinator-owned attempt consumes the old
        // disproof and opens exactly one fresh raised-ceiling recovery window.
        XCTAssertTrue(policy.belowReserveProbeDisprovedSenderLimitation)
        policy.automaticResumeAttemptBegan()
        XCTAssertFalse(policy.belowReserveProbeDisprovedSenderLimitation)
        XCTAssertEqual(policy.applicationLimitedProbeFailureCount, 0)
        XCTAssertEqual(policy.applicationLimitedProbeCooldownSamplesRemaining, 0)

        XCTAssertTrue(
            issueFreshFloorProbe(
                &policy,
                packetsSent: &fixture.packetsSent,
                totalPacketSendDelay: &fixture.totalPacketSendDelay
            )
        )

        var fullRecommendation:
            WorldwideScreenVideoEncodingRecommendation?
        for _ in 0..<8 where policy.currentTier != .full {
            fixture.packetsSent += 40
            fixture.totalPacketSendDelay += 0.004
            fullRecommendation = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 50_000_000,
                currentRoundTripTimeSeconds: 0.029,
                outboundVideoPacketsSent: fixture.packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    fixture.totalPacketSendDelay
            ) ?? fullRecommendation
        }
        XCTAssertEqual(fullRecommendation?.tier, .full)
        policy.automaticResumeAttemptSucceeded()
        XCTAssertEqual(policy.currentTier, .full)
        XCTAssertNil(policy.applicationLimitedProbeOriginTier)
        XCTAssertFalse(policy.belowReserveProbeDisprovedSenderLimitation)
        XCTAssertNil(
            policy.automaticSuspensionDecision(
                isCaptureActive: true,
                isAutomaticallySuspended: false
            )
        )
    }

    func testFailedAutomaticResumeRestoresLatchedEvidenceAndBackoff() {
        var policy = makeSuspendedPolicyAfterFailedFloorProbe().policy
        reachStableAutomaticResumeDecision(&policy)
        let failureCount = policy.applicationLimitedProbeFailureCount
        let cooldown = policy.applicationLimitedProbeCooldownSamplesRemaining

        policy.automaticResumeAttemptBegan()
        XCTAssertFalse(policy.belowReserveProbeDisprovedSenderLimitation)
        XCTAssertEqual(policy.applicationLimitedProbeFailureCount, 0)
        XCTAssertEqual(policy.applicationLimitedProbeCooldownSamplesRemaining, 0)

        policy.automaticResumeAttemptFailed()
        XCTAssertTrue(policy.belowReserveProbeDisprovedSenderLimitation)
        XCTAssertEqual(policy.applicationLimitedProbeFailureCount, failureCount)
        XCTAssertEqual(policy.applicationLimitedProbeCooldownSamplesRemaining, cooldown)
    }

    func testAutomaticResumeRelatchesAndKeepsVisibleFloorWhenCapacityStaysLow() {
        var fixture = makeSuspendedPolicyAfterFailedFloorProbe()
        var policy = fixture.policy
        reachStableAutomaticResumeDecision(&policy)
        policy.automaticResumeAttemptBegan()

        XCTAssertTrue(
            issueFreshFloorProbe(
                &policy,
                packetsSent: &fixture.packetsSent,
                totalPacketSendDelay: &fixture.totalPacketSendDelay
            )
        )
        for _ in 1...3 {
            fixture.packetsSent += 40
            fixture.totalPacketSendDelay += 0.004
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 251_000,
                currentRoundTripTimeSeconds: 0.029,
                outboundVideoPacketsSent: fixture.packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    fixture.totalPacketSendDelay
            )
            XCTAssertNil(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                )
            )
        }
        XCTAssertTrue(policy.belowReserveProbeDisprovedSenderLimitation)
    }

    func testAutomaticResumeAllowsMissingBandwidthRecoveryWindow() {
        var fixture = makeSuspendedPolicyAfterFailedFloorProbe()
        var policy = fixture.policy
        reachStableAutomaticResumeDecision(&policy)
        policy.automaticResumeAttemptBegan()

        let recoveryReportCount = WorldwideScreenVideoAdaptationPolicy
            .requiredUnavailableBandwidthUpgradeSampleCount + 1
        for sample in 1...recoveryReportCount {
            fixture.packetsSent += 40
            fixture.totalPacketSendDelay += 0.004
            let update = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.029,
                outboundVideoPacketsSent: fixture.packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    fixture.totalPacketSendDelay
            )
            XCTAssertNil(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                )
            )
            if sample < recoveryReportCount {
                XCTAssertNil(update)
                XCTAssertEqual(policy.currentTier, .audioPriority)
            } else {
                XCTAssertEqual(update?.tier, .emergency)
            }
        }
        policy.automaticResumeAttemptSucceeded()
        XCTAssertFalse(policy.belowReserveProbeDisprovedSenderLimitation)
    }

    func testMissingBandwidthKeepsVisibleFloorWithActiveLatencyPressure() {
        var policy = makePolicy()
        move(&policy, to: .audioPriority, roundTripTime: 0.040)
        for _ in 0..<3 {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.040
            )
        }
        XCTAssertEqual(policy.roundTripTimeBaselineSeconds, 0.040)

        for _ in 1...3 {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.200
            )
            XCTAssertNil(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                )
            )
        }
    }

    func testSuspendedMissingBandwidthNeedsLongStableWindowForOneResumeProbe() {
        var policy = makePolicy()
        move(&policy, to: .audioPriority)
        let requiredSamples = WorldwideScreenVideoAdaptationPolicy
            .requiredStableSuspensionResumeProbeSampleCount

        for sample in 1...requiredSamples {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: false,
                isAutomaticallySuspended: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.050
            )
            let decision = policy.automaticSuspensionDecision(
                isCaptureActive: false,
                isAutomaticallySuspended: true
            )
            XCTAssertEqual(
                decision,
                sample == requiredSamples ? .resume : nil
            )
        }
    }

    func testSuspendedPositiveLowBandwidthGetsPeriodicStableResumeProbeCooldown() {
        var policy = makePolicy()
        move(&policy, to: .audioPriority)
        let requiredSamples = WorldwideScreenVideoAdaptationPolicy
            .requiredStableSuspensionResumeProbeSampleCount

        for cycle in 0..<2 {
            for sample in 1...requiredSamples {
                _ = policy.update(
                    peerGeneration: 1,
                    isCaptureActive: false,
                    isAutomaticallySuspended: true,
                    availableOutgoingBitrateBps: 100_000,
                    currentRoundTripTimeSeconds: 0.050
                )
                let decision = policy.automaticSuspensionDecision(
                    isCaptureActive: false,
                    isAutomaticallySuspended: true
                )
                XCTAssertEqual(decision, sample == requiredSamples ? .resume : nil)
            }
            if cycle == 0 {
                policy.automaticResumeAttemptFailed()
                XCTAssertEqual(policy.currentTier, .audioPriority)
                XCTAssertEqual(policy.stableSuspensionResumeProbeSampleCount, 0)
            }
        }
    }

    func testSuspendedHighBandwidthResumesThroughOneTierProbe() {
        var policy = makePolicy()
        move(&policy, to: .audioPriority)
        policy.invalidateSelectedRoute()

        let requiredSamples = WorldwideScreenVideoAdaptationPolicy
            .roundTripTimeBootstrapSampleCount - 1
            + WorldwideScreenVideoAdaptationPolicy
            .requiredSuspendedHealthyUpgradeSampleCount
        for sample in 1...requiredSamples {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: false,
                isAutomaticallySuspended: true,
                availableOutgoingBitrateBps: 12_000_000,
                currentRoundTripTimeSeconds: 0.050
            )
            XCTAssertEqual(
                policy.automaticSuspensionDecision(
                    isCaptureActive: false,
                    isAutomaticallySuspended: true
                ),
                sample == requiredSamples ? .resume : nil
            )
        }

        XCTAssertEqual(policy.currentTier, .emergency)
    }

    func testPreexistingSuspensionWithStableHighRTTGetsBoundedProbeAndFullCooldown() {
        var policy = makePolicy()
        move(&policy, to: .audioPriority, roundTripTime: 0.040)
        for _ in 0..<3 {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.040
            )
        }
        XCTAssertEqual(policy.roundTripTimeBaselineSeconds, 0.040)

        for _ in 1...3 {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.200
            )
            XCTAssertNil(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                )
            )
        }

        let requiredSamples = WorldwideScreenVideoAdaptationPolicy
            .requiredMaximumSuspensionResumeProbeSampleCount
        for sample in 1...requiredSamples {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: false,
                isAutomaticallySuspended: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.200
            )
            XCTAssertEqual(
                policy.automaticSuspensionDecision(
                    isCaptureActive: false,
                    isAutomaticallySuspended: true
                ),
                sample == requiredSamples ? .resume : nil
            )
        }

        policy.automaticResumeAttemptFailed()
        XCTAssertEqual(policy.maximumSuspensionResumeProbeSampleCount, 0)
        for _ in 0..<(requiredSamples - 1) {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: false,
                isAutomaticallySuspended: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.200
            )
            XCTAssertNil(
                policy.automaticSuspensionDecision(
                    isCaptureActive: false,
                    isAutomaticallySuspended: true
                )
            )
        }
    }

    func testMinimumSupportedTotalCapKeepsVisibleFloorWhenReserveIsImpossible() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 250_000,
            baseFramesPerSecond: 60
        )
        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))

        for _ in 0..<WorldwideScreenVideoAdaptationPolicy
            .requiredPositiveBandwidthBootstrapSampleCount {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 250_000,
                currentRoundTripTimeSeconds: 0.050
            )
            XCTAssertNil(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                )
            )
        }

        for _ in 1...WorldwideScreenVideoAdaptationPolicy
            .requiredSuspensionPressureSampleCount {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 250_000,
                currentRoundTripTimeSeconds: 0.050
            )
            XCTAssertNil(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                )
            )
        }

        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertEqual(policy.currentRecommendation.maximumFramesPerSecond, 1)
        XCTAssertEqual(policy.currentRecommendation.scaleResolutionDownBy, 12)
    }

    func testNondefaultCapsUseAbsoluteTierBitratesWithoutUnderfilling() {
        let cases: [(
            totalBitrate: Int,
            expectedTier: WorldwideScreenVideoAdaptationTier,
            expectedVideoBitrate: Int
        )] = [
            (1_000_000, .survival, 280_320),
            (2_000_000, .critical, 747_520),
            (4_000_000, .constrained, 1_962_240),
        ]

        for testCase in cases {
            var policy = WorldwideScreenVideoAdaptationPolicy(
                configuredTotalRTPBitrateBps: testCase.totalBitrate,
                baseFramesPerSecond: 60
            )
            XCTAssertTrue(policy.bind(toPeerGeneration: 1))
            for _ in 0..<96 {
                _ = policy.update(
                    peerGeneration: 1,
                    isCaptureActive: true,
                    availableOutgoingBitrateBps: Double(testCase.totalBitrate),
                    currentRoundTripTimeSeconds: 0.050
                )
            }

            XCTAssertEqual(policy.currentTier, testCase.expectedTier)
            XCTAssertEqual(
                policy.currentRecommendation.maximumBitrateBps,
                testCase.expectedVideoBitrate
            )
        }
    }

    private func makeSuspendedPolicyAfterFailedFloorProbe(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (
        policy: WorldwideScreenVideoAdaptationPolicy,
        packetsSent: UInt64,
        totalPacketSendDelay: Double
    ) {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(
            policy.bind(toPeerGeneration: 1),
            file: file,
            line: line
        )
        XCTAssertEqual(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 50_000,
                currentRoundTripTimeSeconds: 0.029,
                outboundVideoPacketsSent: 100,
                outboundVideoTotalPacketSendDelaySeconds: 0.1
            )?.tier,
            .audioPriority,
            file: file,
            line: line
        )

        var packetsSent: UInt64 = 100
        var totalPacketSendDelay = 0.1
        var issuedProbe = false
        for _ in 0..<32 {
            packetsSent += 40
            totalPacketSendDelay += 0.004
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 400_000,
                currentRoundTripTimeSeconds: 0.029,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
            XCTAssertNil(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                ),
                file: file,
                line: line
            )
            if policy.applicationLimitedProbeOriginTier == .audioPriority {
                issuedProbe = true
                break
            }
        }
        XCTAssertTrue(issuedProbe, file: file, line: line)

        for _ in 1...3 {
            packetsSent += 40
            totalPacketSendDelay += 0.004
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 251_000,
                currentRoundTripTimeSeconds: 0.029,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
            XCTAssertNil(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                ),
                file: file,
                line: line
            )
        }
        XCTAssertTrue(
            policy.belowReserveProbeDisprovedSenderLimitation,
            file: file,
            line: line
        )
        return (policy, packetsSent, totalPacketSendDelay)
    }

    private func reachStableAutomaticResumeDecision(
        _ policy: inout WorldwideScreenVideoAdaptationPolicy,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resumeWindow = WorldwideScreenVideoAdaptationPolicy
            .requiredStableSuspensionResumeProbeSampleCount
        for sample in 1...resumeWindow {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: false,
                isAutomaticallySuspended: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.029
            )
            XCTAssertEqual(
                policy.automaticSuspensionDecision(
                    isCaptureActive: false,
                    isAutomaticallySuspended: true
                ),
                sample == resumeWindow ? .resume : nil,
                file: file,
                line: line
            )
        }
    }

    @discardableResult
    private func issueFreshFloorProbe(
        _ policy: inout WorldwideScreenVideoAdaptationPolicy,
        packetsSent: inout UInt64,
        totalPacketSendDelay: inout Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        for _ in 0..<32 {
            packetsSent += 40
            totalPacketSendDelay += 0.004
            let update = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 400_000,
                currentRoundTripTimeSeconds: 0.029,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
            XCTAssertNil(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                ),
                file: file,
                line: line
            )
            if policy.applicationLimitedProbeOriginTier == .audioPriority {
                XCTAssertEqual(update?.tier, .audioPriority, file: file, line: line)
                XCTAssertEqual(
                    update?.maximumBitrateBps,
                    policy.maximumTierVideoBitrateBps,
                    file: file,
                    line: line
                )
                return true
            }
        }
        return false
    }

    private func makePolicy() -> WorldwideScreenVideoAdaptationPolicy {
        WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 12_000_000,
            baseFramesPerSecond: 60
        )
    }

    private func makeFiftyMegabitPolicyAtFull(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> WorldwideScreenVideoAdaptationPolicy {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(
            policy.bind(toPeerGeneration: 1),
            file: file,
            line: line
        )
        for _ in 0..<8 where policy.currentTier != .full {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 50_000_000,
                currentRoundTripTimeSeconds: 0.020
            )
        }
        XCTAssertEqual(policy.currentTier, .full, file: file, line: line)
        return policy
    }

    private func makeLiveCeilingProbeFromAudioPriority(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (
        policy: WorldwideScreenVideoAdaptationPolicy,
        packetsSent: UInt64,
        totalPacketSendDelay: Double
    ) {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(
            policy.bind(toPeerGeneration: 1),
            file: file,
            line: line
        )
        XCTAssertEqual(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 100_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: 100,
                outboundVideoTotalPacketSendDelaySeconds: 0.1
            )?.tier,
            .audioPriority,
            file: file,
            line: line
        )
        var packetsSent: UInt64 = 100
        var totalPacketSendDelay = 0.1
        for _ in 0..<16 where policy.applicationLimitedProbeOriginTier == nil {
            packetsSent += 40
            totalPacketSendDelay += 0.004
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 400_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
        }
        XCTAssertEqual(policy.currentTier, .audioPriority, file: file, line: line)
        XCTAssertEqual(
            policy.applicationLimitedProbeOriginTier,
            .audioPriority,
            file: file,
            line: line
        )
        XCTAssertEqual(
            policy.currentRecommendation.maximumBitrateBps,
            policy.maximumTierVideoBitrateBps,
            file: file,
            line: line
        )
        XCTAssertEqual(
            policy.currentRecommendation.maximumTotalRTPBitrateBps,
            800_000,
            file: file,
            line: line
        )
        XCTAssertEqual(
            policy.currentRecommendation.maximumFramesPerSecond,
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            policy.currentRecommendation.scaleResolutionDownBy,
            12,
            file: file,
            line: line
        )
        return (policy, packetsSent, totalPacketSendDelay)
    }

    private func move(
        _ policy: inout WorldwideScreenVideoAdaptationPolicy,
        to expectedTier: WorldwideScreenVideoAdaptationTier,
        roundTripTime: Double = 0.050,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if policy.peerGeneration == nil {
            XCTAssertTrue(policy.bind(toPeerGeneration: 1), file: file, line: line)
        }
        var attempts = 0
        while policy.currentTier.rawValue > expectedTier.rawValue,
              attempts < 96 {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 12_000_000,
                currentRoundTripTimeSeconds: roundTripTime
            )
            attempts += 1
        }

        guard policy.currentTier.rawValue < expectedTier.rawValue else {
            XCTAssertEqual(policy.currentTier, expectedTier, file: file, line: line)
            return
        }
        for _ in 0..<3 {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 12_000_000,
                currentRoundTripTimeSeconds: roundTripTime
            )
        }
        var update: WorldwideScreenVideoEncodingRecommendation?
        var downgradeAttempts = 0
        while policy.currentTier.rawValue < expectedTier.rawValue,
              downgradeAttempts < WorldwideScreenVideoAdaptationTier.allCases.count {
            update = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 12_000_000,
                currentRoundTripTimeSeconds:
                    roundTripTime + max(0.100, roundTripTime)
            ) ?? update
            downgradeAttempts += 1
        }
        XCTAssertEqual(update?.tier, expectedTier, file: file, line: line)
        XCTAssertEqual(policy.currentTier, expectedTier, file: file, line: line)
    }

    private func healthyUpdate(
        _ policy: inout WorldwideScreenVideoAdaptationPolicy,
        roundTripTime: Double = 0.050
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 12_000_000,
            currentRoundTripTimeSeconds: roundTripTime
        )
    }

    private func recommendation(
        _ tier: WorldwideScreenVideoAdaptationTier,
        bitrate: Int,
        totalBitrate: Int,
        fps: Int,
        scale: Double
    ) -> WorldwideScreenVideoEncodingRecommendation {
        WorldwideScreenVideoEncodingRecommendation(
            tier: tier,
            maximumBitrateBps: bitrate,
            maximumTotalRTPBitrateBps: totalBitrate,
            maximumFramesPerSecond: fps,
            scaleResolutionDownBy: scale
        )
    }
}
