import WebRTCTransport
@testable import CaptureServer
import XCTest

final class WorldwideScreenVideoAdaptationPolicyTests: XCTestCase {
    func testLadderScalesBitrateFrameRateAndResolution() {
        let policy = makePolicy()

        XCTAssertEqual(
            policy.recommendation(for: .full),
            recommendation(.full, bitrate: 9_344_000, fps: 60, scale: 1)
        )
        XCTAssertEqual(
            policy.recommendation(for: .high),
            recommendation(.high, bitrate: 6_260_480, fps: 45, scale: 1.25)
        )
        XCTAssertEqual(
            policy.recommendation(for: .balanced),
            recommendation(.balanced, bitrate: 3_924_480, fps: 30, scale: 1.5)
        )
        XCTAssertEqual(
            policy.recommendation(for: .constrained),
            recommendation(.constrained, bitrate: 1_962_240, fps: 20, scale: 2)
        )
        XCTAssertEqual(
            policy.recommendation(for: .critical),
            recommendation(.critical, bitrate: 747_520, fps: 10, scale: 3)
        )
        XCTAssertEqual(
            policy.recommendation(for: .survival),
            recommendation(.survival, bitrate: 280_320, fps: 5, scale: 4)
        )
        XCTAssertEqual(
            policy.recommendation(for: .emergency),
            recommendation(.emergency, bitrate: 93_440, fps: 2, scale: 8)
        )
        XCTAssertEqual(
            policy.recommendation(for: .audioPriority),
            recommendation(.audioPriority, bitrate: 32_000, fps: 1, scale: 12)
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
            recommendation(.full, bitrate: 39_744_000, fps: 60, scale: 1)
        )
        XCTAssertEqual(
            policy.recommendation(for: .high),
            recommendation(.high, bitrate: 26_628_480, fps: 45, scale: 1.25)
        )
        XCTAssertEqual(
            policy.recommendation(for: .balanced),
            recommendation(.balanced, bitrate: 16_692_480, fps: 30, scale: 1.5)
        )
        XCTAssertEqual(
            policy.recommendation(for: .constrained),
            recommendation(.constrained, bitrate: 8_346_240, fps: 20, scale: 2)
        )
        XCTAssertEqual(
            policy.recommendation(for: .critical),
            recommendation(.critical, bitrate: 3_179_520, fps: 10, scale: 3)
        )
        XCTAssertEqual(
            policy.recommendation(for: .survival),
            recommendation(.survival, bitrate: 1_192_320, fps: 5, scale: 4)
        )
    }

    func testFiftyMegabitCapRequiresFreshLowQueueEvidenceBeforeFullQuality() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))

        for sample in 1...9 {
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
            outboundVideoPacketsSent: 1_000,
            outboundVideoTotalPacketSendDelaySeconds: 5
        )
        XCTAssertEqual(full?.tier, .full)
        XCTAssertEqual(full?.maximumBitrateBps, 39_744_000)
        XCTAssertEqual(full?.maximumFramesPerSecond, 60)
        XCTAssertEqual(full?.scaleResolutionDownBy, 1)
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

        XCTAssertEqual(
            update(
                availableOutgoingBitrateBps: Double(
                    policy.currentRecommendation.maximumBitrateBps
                ) * 0.848
            )?.tier,
            .high
        )
    }

    func testApplicationLimitedEstimateEarnsOnlyOneTierProbe() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))
        let senderLimitedEstimate = Double(
            policy.currentRecommendation.maximumBitrateBps
        ) * 0.90

        for sample in 1...6 {
            XCTAssertNil(
                policy.update(
                    peerGeneration: 1,
                    isCaptureActive: true,
                    availableOutgoingBitrateBps: senderLimitedEstimate,
                    currentRoundTripTimeSeconds: 0.020,
                    outboundVideoPacketsSent: UInt64(sample * 100),
                    outboundVideoTotalPacketSendDelaySeconds:
                        Double(sample) * 0.5
                )
            )
            XCTAssertEqual(policy.currentTier, .survival)
        }

        let probe = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: senderLimitedEstimate,
            currentRoundTripTimeSeconds: 0.020,
            outboundVideoPacketsSent: 700,
            outboundVideoTotalPacketSendDelaySeconds: 3.5
        )
        XCTAssertEqual(probe?.tier, .critical)
        XCTAssertEqual(policy.currentTier, .critical)
        XCTAssertEqual(
            policy.applicationLimitedProbeGraceSamplesRemaining,
            WorldwideScreenVideoAdaptationPolicy
                .applicationLimitedProbeGraceSampleCount
        )
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .survival)
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

    func testMissingBandwidthCannotRearmLowPositiveBootstrap() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))

        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.020
            )
        )
        XCTAssertEqual(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 100_000,
                currentRoundTripTimeSeconds: 0.020
            )?.tier,
            .audioPriority
        )

        for _ in 0..<4 {
            XCTAssertNil(
                policy.update(
                    peerGeneration: 1,
                    isCaptureActive: true,
                    availableOutgoingBitrateBps: nil,
                    currentRoundTripTimeSeconds: 0.020
                )
            )
            XCTAssertNil(
                policy.update(
                    peerGeneration: 1,
                    isCaptureActive: true,
                    availableOutgoingBitrateBps: 100_000,
                    currentRoundTripTimeSeconds: 0.020
                )
            )
            XCTAssertEqual(policy.currentTier, .audioPriority)
        }
    }

    func testFailedApplicationLimitedProbeRevertsAndUsesExponentialCooldown() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))
        let fixedEstimate = Double(
            policy.currentRecommendation.maximumBitrateBps
        ) * 0.90
        var packetsSent: UInt64 = 0
        var totalPacketSendDelay = 0.0

        func update(
            _ availableOutgoingBitrateBps: Double?
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

        for _ in 0..<96 where policy.applicationLimitedProbeOriginTier == nil {
            _ = update(fixedEstimate)
        }
        XCTAssertNotNil(policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(policy.currentTier, .critical)

        for _ in 0..<WorldwideScreenVideoAdaptationPolicy
            .applicationLimitedProbeGraceSampleCount {
            _ = update(fixedEstimate)
        }
        XCTAssertEqual(policy.currentTier, .survival)
        XCTAssertNil(policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(policy.applicationLimitedProbeFailureCount, 1)
        XCTAssertEqual(
            policy.applicationLimitedProbeCooldownSamplesRemaining,
            WorldwideScreenVideoAdaptationPolicy
                .initialApplicationLimitedProbeCooldownSampleCount
        )

        for _ in 0..<(WorldwideScreenVideoAdaptationPolicy
            .initialApplicationLimitedProbeCooldownSampleCount / 2) {
            _ = update(nil)
            XCTAssertNil(policy.applicationLimitedProbeOriginTier)
            XCTAssertEqual(policy.currentTier, .survival)
        }
        for _ in 0..<(WorldwideScreenVideoAdaptationPolicy
            .initialApplicationLimitedProbeCooldownSampleCount / 2) {
            _ = update(fixedEstimate)
            XCTAssertNil(policy.applicationLimitedProbeOriginTier)
            XCTAssertEqual(policy.currentTier, .survival)
        }
        for _ in 1..<WorldwideScreenVideoAdaptationPolicy
            .requiredApplicationLimitedUpgradeSampleCount {
            _ = update(fixedEstimate)
        }
        XCTAssertEqual(update(fixedEstimate)?.tier, .critical)

        for _ in 0..<WorldwideScreenVideoAdaptationPolicy
            .applicationLimitedProbeGraceSampleCount {
            _ = update(fixedEstimate)
        }
        XCTAssertEqual(policy.currentTier, .survival)
        XCTAssertEqual(policy.applicationLimitedProbeFailureCount, 2)
        XCTAssertEqual(
            policy.applicationLimitedProbeCooldownSamplesRemaining,
            WorldwideScreenVideoAdaptationPolicy
                .initialApplicationLimitedProbeCooldownSampleCount * 2
        )
    }

    func testApplicationLimitedProbeNeedsFreshStrictEvidenceToSucceed() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))
        var packetsSent: UInt64 = 0
        var totalPacketSendDelay = 0.0
        let survivalEstimate = Double(
            policy.currentRecommendation.maximumBitrateBps
        ) * 0.90

        for _ in 0..<96 where policy.applicationLimitedProbeOriginTier == nil {
            packetsSent += 100
            totalPacketSendDelay += 0.5
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: survivalEstimate,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
        }
        XCTAssertEqual(policy.currentTier, .critical)
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .survival)
        let criticalEstimate = Double(
            policy.currentRecommendation.maximumBitrateBps
        ) * 0.90

        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: criticalEstimate,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
        )
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .survival)

        packetsSent += 100
        totalPacketSendDelay += 0.5
        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: criticalEstimate,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
        )
        XCTAssertEqual(policy.currentTier, .critical)
        XCTAssertNil(policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(policy.applicationLimitedProbeFailureCount, 0)
        XCTAssertEqual(policy.applicationLimitedProbeCooldownSamplesRemaining, 0)
    }

    func testCapacityCollapseAbortsApplicationLimitedProbeImmediately() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))
        let senderLimitedEstimate = Double(
            policy.currentRecommendation.maximumBitrateBps
        ) * 0.90
        var packetsSent: UInt64 = 0
        var totalPacketSendDelay = 0.0

        for _ in 0..<96 where policy.applicationLimitedProbeOriginTier == nil {
            packetsSent += 100
            totalPacketSendDelay += 0.5
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: senderLimitedEstimate,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
        }
        XCTAssertEqual(policy.currentTier, .critical)
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .survival)

        packetsSent += 100
        totalPacketSendDelay += 0.5
        let collapsed = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 100_000,
            currentRoundTripTimeSeconds: 0.020,
            outboundVideoPacketsSent: packetsSent,
            outboundVideoTotalPacketSendDelaySeconds:
                totalPacketSendDelay
        )

        XCTAssertEqual(collapsed?.tier, .audioPriority)
        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertNil(policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(policy.applicationLimitedProbeFailureCount, 1)
        XCTAssertTrue(policy.lastSampleHasPositiveSuspensionPressure)
    }

    func testLatencyFailedProbeKeepsBackoffDespiteHighBandwidth() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))
        let senderLimitedEstimate = Double(
            policy.currentRecommendation.maximumBitrateBps
        ) * 0.90
        var packetsSent: UInt64 = 0
        var totalPacketSendDelay = 0.0

        for _ in 0..<96 where policy.applicationLimitedProbeOriginTier == nil {
            packetsSent += 100
            totalPacketSendDelay += 0.5
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: senderLimitedEstimate,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
        }
        XCTAssertEqual(policy.currentTier, .critical)
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .survival)

        packetsSent += 100
        totalPacketSendDelay += 20
        let pressured = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 50_000_000,
            currentRoundTripTimeSeconds: 0.020,
            outboundVideoPacketsSent: packetsSent,
            outboundVideoTotalPacketSendDelaySeconds:
                totalPacketSendDelay
        )

        XCTAssertEqual(pressured?.tier, .emergency)
        XCTAssertEqual(policy.currentTier, .emergency)
        XCTAssertNil(policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(policy.applicationLimitedProbeFailureCount, 1)
        XCTAssertEqual(
            policy.applicationLimitedProbeCooldownSamplesRemaining,
            WorldwideScreenVideoAdaptationPolicy
                .initialApplicationLimitedProbeCooldownSampleCount
        )
        XCTAssertTrue(policy.lastSampleHasLatencyPressure)
    }

    func testFreshSenderLimitedEvidenceConvergesAcrossEveryTierAndHoldsFull() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: 60
        )
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))
        var packetsSent: UInt64 = 0
        var totalPacketSendDelay = 0.0
        var visitedTiers: Set<WorldwideScreenVideoAdaptationTier> = [
            policy.currentTier
        ]

        for _ in 0..<200 where policy.currentTier != .full {
            packetsSent += 100
            totalPacketSendDelay += 0.5
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: Double(
                    policy.currentRecommendation.maximumBitrateBps
                ) * 0.90,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
            visitedTiers.insert(policy.currentTier)
        }

        XCTAssertEqual(
            visitedTiers,
            Set([
                .survival,
                .critical,
                .constrained,
                .balanced,
                .high,
                .full,
            ])
        )
        XCTAssertEqual(policy.currentTier, .full)
        for _ in 0..<32 {
            packetsSent += 100
            totalPacketSendDelay += 0.5
            XCTAssertNil(
                policy.update(
                    peerGeneration: 1,
                    isCaptureActive: true,
                    availableOutgoingBitrateBps: Double(
                        policy.currentRecommendation.maximumBitrateBps
                    ) * 0.90,
                    currentRoundTripTimeSeconds: 0.020,
                    outboundVideoPacketsSent: packetsSent,
                    outboundVideoTotalPacketSendDelaySeconds:
                        totalPacketSendDelay
                )
            )
            XCTAssertEqual(policy.currentTier, .full)
        }
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

        XCTAssertEqual(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 50_000_000,
                currentRoundTripTimeSeconds: 0.020,
                outboundVideoPacketsSent: 1_200,
                outboundVideoTotalPacketSendDelaySeconds: 21.1
            )?.tier,
            .high
        )
    }

    func testBadSamplesDowngradeDirectlyThroughLowestBandwidthTiers() {
        var policy = makePolicy()
        move(&policy, to: .full)

        let critical = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 2_000_000,
            currentRoundTripTimeSeconds: 0.050
        )
        XCTAssertEqual(critical?.tier, .critical)
        XCTAssertEqual(policy.currentTier, .critical)

        let emergency = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 600_000,
            currentRoundTripTimeSeconds: 0.050
        )
        XCTAssertEqual(emergency?.tier, .emergency)
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

    func testHigherTierProbeCollapseBelowReserveLatchesAndSuspends() {
        var policy = makePolicy()
        move(&policy, to: .emergency)
        var packetsSent: UInt64 = 100
        var totalPacketSendDelay = 0.1

        _ = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 400_000,
            currentRoundTripTimeSeconds: 0.050,
            outboundVideoPacketsSent: packetsSent,
            outboundVideoTotalPacketSendDelaySeconds: totalPacketSendDelay
        )
        for _ in 0..<8 where policy.applicationLimitedProbeOriginTier == nil {
            packetsSent += 40
            totalPacketSendDelay += 0.004
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 400_000,
                currentRoundTripTimeSeconds: 0.050,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
        }
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .emergency)
        XCTAssertEqual(policy.currentTier, .survival)

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
        XCTAssertTrue(policy.belowReserveProbeDisprovedSenderLimitation)
        XCTAssertTrue(policy.lastSampleHasPositiveSuspensionPressure)
        XCTAssertNil(
            policy.automaticSuspensionDecision(
                isCaptureActive: true,
                isAutomaticallySuspended: false
            )
        )

        for pressureSample in 2...3 {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.050
            )
            XCTAssertEqual(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                ),
                pressureSample == 3 ? .suspend : nil
            )
        }
    }

    func testEightHealthySamplesRecoverDirectlyToSustainableTier() {
        var policy = makePolicy()
        move(&policy, to: .constrained)

        for _ in 0..<7 {
            XCTAssertNil(healthyUpdate(&policy))
        }
        XCTAssertEqual(policy.healthyUpgradeSampleCount, 7)
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

    func testPositiveBandwidthCanRecoverWhenRTTIsMissingButSendQueueIsHealthy() {
        var policy = makePolicy()
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))

        for sample in 1...8 {
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
                outboundVideoPacketsSent: 90,
                outboundVideoTotalPacketSendDelaySeconds: 0.450
            )?.tier,
            .full
        )
        XCTAssertEqual(policy.currentTier, .full)
    }

    func testBandwidthEvidenceLaneChangeRequiresFreshPositiveWindow() {
        var policy = makePolicy()
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))

        for sample in 1...5 {
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
        XCTAssertEqual(policy.healthyUpgradeSampleCount, 3)

        for _ in 0..<(
            WorldwideScreenVideoAdaptationPolicy.requiredHealthyUpgradeSampleCount
                - 1
        ) {
            XCTAssertNil(healthyUpdate(&policy))
        }
        XCTAssertEqual(policy.currentTier, .survival)
        XCTAssertEqual(healthyUpdate(&policy)?.tier, .full)
    }

    func testBandwidthEvidenceLaneChangeRequiresFreshUnavailableWindow() {
        var policy = makePolicy()
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))

        for _ in 0..<9 {
            XCTAssertNil(healthyUpdate(&policy))
        }
        XCTAssertEqual(
            policy.healthyUpgradeSampleCount,
            WorldwideScreenVideoAdaptationPolicy.requiredHealthyUpgradeSampleCount
                - 1
        )

        for sample in 1...4 {
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
                outboundVideoPacketsSent: 50,
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
        let senderLimitedEstimate = Double(
            policy.currentRecommendation.maximumBitrateBps
        ) * 0.90
        var packetsSent: UInt64 = 0
        var totalPacketSendDelay = 0.0

        for _ in 0..<96 where policy.applicationLimitedProbeOriginTier == nil {
            packetsSent += 100
            totalPacketSendDelay += 0.5
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: senderLimitedEstimate,
                currentRoundTripTimeSeconds: 0.020,
                selectedRoute: direct,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
        }
        XCTAssertNotNil(policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(policy.currentTier, .critical)
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .survival)

        packetsSent += 100
        totalPacketSendDelay += 0.5
        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: senderLimitedEstimate,
                currentRoundTripTimeSeconds: 0.020,
                selectedRoute: relayed,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
        )
        XCTAssertEqual(policy.currentTier, .survival)
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

    func testEstimateBelowSenderCeilingSuspendsOnlyAfterThreeActivePressureSamples() {
        var policy = makePolicy()
        move(&policy, to: .audioPriority)

        for sample in 1...3 {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 10_000,
                currentRoundTripTimeSeconds: 0.050
            )
            let decision = policy.automaticSuspensionDecision(
                isCaptureActive: true,
                isAutomaticallySuspended: false
            )
            XCTAssertEqual(decision, sample == 3 ? .suspend : nil)
        }
    }

    func testSenderLimitedFloorEstimateProbesUpWithoutBlackoutWhenCapacityExpands() {
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

        var probeRecommendation: WorldwideScreenVideoEncodingRecommendation?
        var packetsSent: UInt64 = 100
        var totalPacketSendDelay = 0.1
        for _ in 1...8 {
            packetsSent += 40
            totalPacketSendDelay += 0.004
            let update = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 251_000,
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
            if update?.tier == .emergency {
                probeRecommendation = update
                break
            }
        }

        XCTAssertEqual(probeRecommendation?.tier, .emergency)
        XCTAssertEqual(policy.currentTier, .emergency)

        packetsSent += 40
        totalPacketSendDelay += 0.004
        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 517_000,
                currentRoundTripTimeSeconds: 0.029,
                outboundVideoPacketsSent: packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    totalPacketSendDelay
            )
        )
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

    func testFailedFloorProbeLatchesTrueCongestionAndSuspends() {
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
        for _ in 0..<8 where policy.applicationLimitedProbeOriginTier == nil {
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

        for pressureSample in 2...3 {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.029
            )
            XCTAssertTrue(policy.lastSampleHasPositiveSuspensionPressure)
            XCTAssertEqual(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                ),
                pressureSample == 3 ? .suspend : nil
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

        fixture.packetsSent += 40
        fixture.totalPacketSendDelay += 0.004
        XCTAssertNil(
            policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 517_000,
                currentRoundTripTimeSeconds: 0.029,
                outboundVideoPacketsSent: fixture.packetsSent,
                outboundVideoTotalPacketSendDelaySeconds:
                    fixture.totalPacketSendDelay
            )
        )
        policy.automaticResumeAttemptSucceeded()
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

    func testAutomaticResumeRelatchesAndResuspendsWhenCapacityStaysLow() {
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
        for pressureSample in 1...3 {
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
            XCTAssertEqual(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                ),
                pressureSample == 3 ? .suspend : nil
            )
        }
        XCTAssertTrue(policy.belowReserveProbeDisprovedSenderLimitation)
    }

    func testAutomaticResumeAllowsMissingBandwidthRecoveryWindow() {
        var fixture = makeSuspendedPolicyAfterFailedFloorProbe()
        var policy = fixture.policy
        reachStableAutomaticResumeDecision(&policy)
        policy.automaticResumeAttemptBegan()

        for sample in 1...WorldwideScreenVideoAdaptationPolicy
            .requiredUnavailableBandwidthUpgradeSampleCount {
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
            if sample < WorldwideScreenVideoAdaptationPolicy
                .requiredUnavailableBandwidthUpgradeSampleCount {
                XCTAssertNil(update)
                XCTAssertEqual(policy.currentTier, .audioPriority)
            } else {
                XCTAssertEqual(update?.tier, .emergency)
            }
        }
        policy.automaticResumeAttemptSucceeded()
        XCTAssertFalse(policy.belowReserveProbeDisprovedSenderLimitation)
    }

    func testMissingBandwidthSuspendsOnlyWithActiveLatencyPressure() {
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

        for sample in 1...3 {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.200
            )
            let decision = policy.automaticSuspensionDecision(
                isCaptureActive: true,
                isAutomaticallySuspended: false
            )
            XCTAssertEqual(decision, sample == 3 ? .suspend : nil)
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

        for sample in 1...10 {
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
                sample == 10 ? .resume : nil
            )
        }

        XCTAssertEqual(policy.currentTier, .emergency)
    }

    func testSuspendedStableHighRTTEventuallyGetsBoundedProbeAndFullCooldown() {
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

        for sample in 1...3 {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: nil,
                currentRoundTripTimeSeconds: 0.200
            )
            XCTAssertEqual(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                ),
                sample == 3 ? .suspend : nil
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

    func testMinimumSupportedTotalCapSuspendsWhenReserveAndProbeAreImpossible() {
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

        for pressureSample in 1...WorldwideScreenVideoAdaptationPolicy
            .requiredSuspensionPressureSampleCount {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 250_000,
                currentRoundTripTimeSeconds: 0.050
            )
            XCTAssertEqual(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                ),
                pressureSample == WorldwideScreenVideoAdaptationPolicy
                    .requiredSuspensionPressureSampleCount ? .suspend : nil
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
        for _ in 0..<8 {
            packetsSent += 40
            totalPacketSendDelay += 0.004
            let update = policy.update(
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
            if update?.tier == .emergency {
                issuedProbe = true
                break
            }
        }
        XCTAssertTrue(issuedProbe, file: file, line: line)

        for pressureSample in 1...3 {
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
            XCTAssertEqual(
                policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                ),
                pressureSample == 3 ? .suspend : nil,
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
        for _ in 0..<8 {
            packetsSent += 40
            totalPacketSendDelay += 0.004
            let update = policy.update(
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
            if update?.tier == .emergency {
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
        fps: Int,
        scale: Double
    ) -> WorldwideScreenVideoEncodingRecommendation {
        WorldwideScreenVideoEncodingRecommendation(
            tier: tier,
            maximumBitrateBps: bitrate,
            maximumFramesPerSecond: fps,
            scaleResolutionDownBy: scale
        )
    }
}
