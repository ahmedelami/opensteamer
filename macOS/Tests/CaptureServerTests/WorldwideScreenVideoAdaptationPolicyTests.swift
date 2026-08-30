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

    func testEightHealthySamplesUpgradeExactlyOneTier() {
        var policy = makePolicy()
        move(&policy, to: .constrained)

        for _ in 0..<7 {
            XCTAssertNil(healthyUpdate(&policy))
        }
        XCTAssertEqual(policy.healthyUpgradeSampleCount, 7)
        XCTAssertEqual(healthyUpdate(&policy)?.tier, .balanced)
        XCTAssertEqual(policy.currentTier, .balanced)

        for _ in 0..<7 {
            XCTAssertNil(healthyUpdate(&policy))
        }
        XCTAssertEqual(policy.currentTier, .balanced)
        XCTAssertEqual(healthyUpdate(&policy)?.tier, .high)
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

        XCTAssertFalse(policy.bind(toPeerGeneration: 1))
        XCTAssertEqual(policy.currentTier, .critical)
        XCTAssertEqual(policy.roundTripTimeBaselineSeconds, 0.050)

        XCTAssertTrue(policy.bind(toPeerGeneration: 2))
        XCTAssertEqual(policy.currentTier, .survival)
        XCTAssertEqual(policy.healthyUpgradeSampleCount, 0)
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

    func testConservativeStartupRecoversToFullAtTheConfiguredCeiling() {
        var policy = makePolicy()
        XCTAssertEqual(policy.currentTier, .survival)
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))

        for expectedTier in [
            WorldwideScreenVideoAdaptationTier.critical,
            .constrained,
            .balanced,
            .high,
            .full,
        ] {
            let originalTier = policy.currentTier
            var recommendation: WorldwideScreenVideoEncodingRecommendation?
            for _ in 0..<16 where policy.currentTier == originalTier {
                recommendation = healthyUpdate(&policy) ?? recommendation
            }
            XCTAssertEqual(recommendation?.tier, expectedTier)
            XCTAssertEqual(policy.currentTier, expectedTier)
        }
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

        XCTAssertEqual(policy.currentTier, .balanced)
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

    func testLowValidBandwidthSuspendsOnlyAfterThreeActivePressureSamples() {
        var policy = makePolicy()
        move(&policy, to: .audioPriority)

        for sample in 1...3 {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 100_000,
                currentRoundTripTimeSeconds: 0.050
            )
            let decision = policy.automaticSuspensionDecision(
                isCaptureActive: true,
                isAutomaticallySuspended: false
            )
            XCTAssertEqual(decision, sample == 3 ? .suspend : nil)
        }
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

    func testMinimumSupportedTotalCapCannotSelectFullQuality() {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 250_000,
            baseFramesPerSecond: 60
        )
        XCTAssertEqual(policy.currentTier, .audioPriority)
        XCTAssertTrue(policy.bind(toPeerGeneration: 1))

        for _ in 0..<32 {
            _ = policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 250_000,
                currentRoundTripTimeSeconds: 0.050
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
        let bandwidth: Double = switch expectedTier {
        case .full: 12_000_000
        case .high: 11_500_000
        case .balanced: 8_000_000
        case .constrained: 3_000_000
        case .critical: 2_000_000
        case .survival: 700_000
        case .emergency: 500_000
        case .audioPriority: 300_000
        }
        let update = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: bandwidth,
            currentRoundTripTimeSeconds: roundTripTime
        )
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
