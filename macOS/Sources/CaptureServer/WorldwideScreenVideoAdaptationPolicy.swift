import WebRTCTransport

enum WorldwideScreenVideoAdaptationTier: Int, CaseIterable, Equatable, Sendable {
    case full
    case high
    case balanced
    case constrained
    case critical
    case survival
    case emergency
    case audioPriority

    fileprivate var bitrateBasisPoints: Int {
        switch self {
        case .full: 10_000
        case .high: 6_700
        case .balanced: 4_200
        case .constrained: 2_100
        case .critical: 800
        case .survival: 300
        case .emergency: 100
        case .audioPriority: 25
        }
    }

    fileprivate var framesPerSecond: Int {
        switch self {
        case .full: 60
        case .high: 45
        case .balanced: 30
        case .constrained: 20
        case .critical: 10
        case .survival: 5
        case .emergency: 2
        case .audioPriority: 1
        }
    }

    fileprivate var scaleResolutionDownBy: Double {
        switch self {
        case .full: 1
        case .high: 1.25
        case .balanced: 1.5
        case .constrained: 2
        case .critical: 3
        case .survival: 4
        case .emergency: 8
        case .audioPriority: 12
        }
    }

    fileprivate var nextHigherQuality: Self? {
        Self(rawValue: rawValue - 1)
    }

    fileprivate var nextLowerQuality: Self? {
        Self(rawValue: rawValue + 1)
    }
}

struct WorldwideScreenVideoEncodingRecommendation: Equatable, Sendable {
    let tier: WorldwideScreenVideoAdaptationTier
    let maximumBitrateBps: Int
    let maximumTotalRTPBitrateBps: Int
    let maximumFramesPerSecond: Int
    let scaleResolutionDownBy: Double

    var webRTCLimits: WebRTCScreenVideoEncodingLimits {
        WebRTCScreenVideoEncodingLimits(
            maximumBitrateBps: maximumBitrateBps,
            maximumFramesPerSecond: maximumFramesPerSecond,
            scaleResolutionDownBy: scaleResolutionDownBy,
            maximumTotalRTPBitrateBps: maximumTotalRTPBitrateBps
        )
    }
}

enum WorldwideScreenVideoAutomaticSuspensionDecision: Equatable, Sendable {
    case suspend
    case resume
}

/// Converts transport capacity into a stable, single-layer screen-video encoding ceiling.
struct WorldwideScreenVideoAdaptationPolicy: Equatable, Sendable {
    private enum PacketQueueObservation: Equatable, Sendable {
        case measured(Double)
        case noNewPackets
        case unavailableOrReset
    }

    private struct AutomaticResumeProbeRestoration: Equatable, Sendable {
        let belowReserveProbeDisprovedSenderLimitation: Bool
        let applicationLimitedProbeCooldownSamplesRemaining: Int
        let applicationLimitedProbeFailureCount: Int
    }

    /// The dedicated video sampler runs independently from the one-second microphone-health
    /// stream. Calibrate evidence windows to its 500 ms cadence, then keep first-reaction counts
    /// bounded below five seconds when the one-second statistics stream is used as a fallback.
    static let sampleIntervalMilliseconds = 500
    static let fallbackSampleIntervalMilliseconds = 1_000
    static let requiredHealthyUpgradeSampleCount = sampleCount(for: 1_000)
    static let requiredSuspendedHealthyUpgradeSampleCount = fallbackSampleCount(
        for: 8_000
    )
    static let requiredPositiveBandwidthBootstrapSampleCount = sampleCount(for: 500)
    // Raising the peer-wide BWE ceiling does not change decoded geometry. Once RTT and advancing
    // low-delay packet evidence are established, one fresh 500 ms sample may request the bounded
    // native probe instead of waiting through another visible-quality interval.
    static let requiredApplicationLimitedUpgradeSampleCount = sampleCount(for: 500)
    static let applicationLimitedProbeGraceSampleCount = sampleCount(for: 3_500)
    static let applicationLimitedProbeGraceDuration = Duration.milliseconds(3_500)
    static let initialApplicationLimitedProbeCooldownSampleCount = sampleCount(for: 8_000)
    static let maximumApplicationLimitedProbeCooldownSampleCount = sampleCount(for: 64_000)
    /// A visible sender drains stale probe cooldown within two one-second fallback samples even
    /// when an older failed probe installed the longer backoff retained for suspended recovery.
    static let maximumActiveApplicationLimitedProbeCooldownSampleCount =
        sampleCount(for: 1_000)
    /// When native candidate-pair bandwidth is unavailable, use a slower additive probe backed by
    /// both a stable RTT baseline and advancing low-delay outbound packets. This prevents an
    /// optional stats field from pinning a healthy session at its conservative startup tier.
    /// With no optional BWE field, require two consecutive low-delay RTT/queue reports for each
    /// additive tier. This reacts within one second while preventing alternating pressure samples
    /// from bouncing the encoder ceiling every poll.
    static let requiredUnavailableBandwidthUpgradeSampleCount = sampleCount(for: 1_000)
    static let requiredSuspensionPressureSampleCount = fallbackSampleCount(
        for: 3_000
    )
    /// A paused sender cannot produce a useful outbound bitrate estimate. Even when the last
    /// estimate remains positive-but-low, a long latency-stable window permits one bounded probe;
    /// a failed probe resets this counter and therefore supplies the same full cooldown again.
    static let requiredStableSuspensionResumeProbeSampleCount =
        fallbackSampleCount(for: 16_000)
    static let requiredMaximumSuspensionResumeProbeSampleCount =
        fallbackSampleCount(for: 64_000)
    static let requiredBandwidthOnlyDowngradeSampleCount = sampleCount(for: 1_000)
    /// Encoder reconfiguration and key-frame bursts can produce one high packet-send-delay delta
    /// even when the path is healthy. Require a second consecutive queue-pressure sample before
    /// treating queue delay as congestion; RTT inflation and bandwidth collapse remain immediate.
    static let requiredQueuePressureSampleCount = sampleCount(for: 1_000)

    private static let minimumVideoBitrateBps = 32_000
    private static let audioAndControlReserveBps = 320_000.0
    private static let baselineReferenceMaximumVideoBitrateBps = 9_344_000
    private static let downgradeHeadroomMultiplier = 1.25
    private static let upgradeMarginMultiplier = 1.35
    /// The native controller is capped at the same configured total. Treat a small estimator gap
    /// at that ceiling as cap saturation rather than requiring an exact floating-point sample.
    private static let configuredCapacitySaturationRatio = 0.95
    private static let applicationLimitedSaturationRatio = 0.80
    private static let applicationLimitedProbeImmediateAbortRatio = 0.75
    private static let roundTripTimeRelativeInflationMultiplier = 1.5
    private static let roundTripTimeAbsoluteInflationSeconds = 0.050
    private static let maximumRoundTripTimeBaselineFallPerSample = 0.010
    static let roundTripTimeBootstrapSampleCount = 3
    private static let maximumAveragePacketSendDelaySeconds = 0.100
    private static let immediateAveragePacketSendDelaySeconds = 0.200
    private static let maximumUpgradePacketSendDelaySeconds = 0.020
    private static let lowDelayPacketQueueObservationValidity =
        Duration.milliseconds(1_500)

    private static func sampleCount(for windowMilliseconds: Int) -> Int {
        max(
            1,
            (windowMilliseconds + sampleIntervalMilliseconds - 1)
                / sampleIntervalMilliseconds
        )
    }

    private static func fallbackSampleCount(
        for windowMilliseconds: Int
    ) -> Int {
        max(
            1,
            (windowMilliseconds + fallbackSampleIntervalMilliseconds - 1)
                / fallbackSampleIntervalMilliseconds
        )
    }

    let configuredTotalRTPBitrateBps: Int
    let maximumTierVideoBitrateBps: Int
    let baseFramesPerSecond: Int
    private(set) var peerGeneration: UInt64?
    private(set) var currentTier: WorldwideScreenVideoAdaptationTier
    private(set) var healthyUpgradeSampleCount = 0
    private(set) var bandwidthOnlyDowngradeSampleCount = 0
    private(set) var queuePressureSampleCount = 0
    private(set) var unavailableBandwidthSampleCount = 0
    private(set) var positiveBandwidthBootstrapSampleCount = 0
    private(set) var applicationLimitedUpgradeSampleCount = 0
    private(set) var applicationLimitedProbeHealthySampleCount = 0
    private(set) var applicationLimitedProbeGraceSamplesRemaining = 0
    private(set) var applicationLimitedProbeDeadline:
        ContinuousClock.Instant?
    private(set) var applicationLimitedProbeCooldownSamplesRemaining = 0
    private(set) var applicationLimitedProbeFailureCount = 0
    private(set) var belowReserveProbeDisprovedSenderLimitation = false
    private var automaticResumeProbeRestoration:
        AutomaticResumeProbeRestoration?
    private(set) var applicationLimitedProbeOriginTier:
        WorldwideScreenVideoAdaptationTier?
    private(set) var applicationLimitedProbeBestQualifiedTier:
        WorldwideScreenVideoAdaptationTier?
    private(set) var applicationLimitedProbeMaximumTotalRTPBitrateBps: Int?
    private(set) var automaticSuspensionPressureSampleCount = 0
    private(set) var stableSuspensionResumeProbeSampleCount = 0
    private(set) var maximumSuspensionResumeProbeSampleCount = 0
    private(set) var bandwidthEstimateIsUnavailable = false
    private(set) var lastSampleHasLatencyPressure = false
    private(set) var lastSampleHasPositiveSuspensionPressure = false
    private(set) var lastAveragePacketSendDelaySeconds: Double?
    private var lastLowDelayPacketQueueObservation:
        ContinuousClock.Instant?
    private var lastSoftPacketQueuePressureObservation:
        ContinuousClock.Instant?
    private(set) var roundTripTimeBaselineSeconds: Double?
    private var roundTripTimeBootstrapSamples: [Double] = []
    private(set) var selectedRoute: WebRTCICERouteDiagnostics?
    private var lastOutboundVideoPacketsSent: UInt64?
    private var lastOutboundVideoTotalPacketSendDelaySeconds: Double?

    init(
        configuredTotalRTPBitrateBps: Int,
        baseFramesPerSecond: Int
    ) {
        self.configuredTotalRTPBitrateBps = min(
            Int(UInt32.max),
            max(1, configuredTotalRTPBitrateBps)
        )
        let videoBudget = max(
            0,
            Double(self.configuredTotalRTPBitrateBps)
                - Self.audioAndControlReserveBps
        ) / Self.downgradeHeadroomMultiplier
        maximumTierVideoBitrateBps = min(
            self.configuredTotalRTPBitrateBps,
            max(Self.minimumVideoBitrateBps, Int(videoBudget.rounded(.down)))
        )
        self.baseFramesPerSecond = max(1, baseFramesPerSecond)
        currentTier = Self.initialTier(
            configuredTotalRTPBitrateBps: self.configuredTotalRTPBitrateBps
        )
    }

    var currentRecommendation: WorldwideScreenVideoEncodingRecommendation {
        let ordinaryRecommendation = recommendation(for: currentTier)
        guard applicationLimitedProbeOriginTier != nil,
              let applicationLimitedProbeMaximumTotalRTPBitrateBps else {
            return ordinaryRecommendation
        }
        // A capacity probe raises libwebrtc's peer-wide BWE ceiling in bounded steps while keeping
        // scale and frame cadence stable. The global-ceiling path can initiate or extend a native
        // probe without requiring ALR; the 2x bound prevents its padding burst from starving audio.
        return WorldwideScreenVideoEncodingRecommendation(
            tier: currentTier,
            maximumBitrateBps: maximumTierVideoBitrateBps,
            maximumTotalRTPBitrateBps:
                applicationLimitedProbeMaximumTotalRTPBitrateBps,
            maximumFramesPerSecond:
                ordinaryRecommendation.maximumFramesPerSecond,
            scaleResolutionDownBy:
                ordinaryRecommendation.scaleResolutionDownBy
        )
    }

    var currentTierMinimumSustainableBitrateBps: Int {
        Int(requiredOutgoingBitrateBps(for: currentTier).rounded(.up))
    }

    var nextHigherTierMinimumDirectUpgradeBitrateBps: Int? {
        guard let nextHigherTier = currentTier.nextHigherQuality else {
            return nil
        }
        let requiredBitrate = requiredOutgoingBitrateBps(for: nextHigherTier)
        guard requiredBitrate <= Double(configuredTotalRTPBitrateBps) else {
            return nil
        }
        return Int(
            min(
                Double(configuredTotalRTPBitrateBps),
                requiredBitrate * Self.upgradeMarginMultiplier
            ).rounded(.up)
        )
    }

    func recommendation(
        for tier: WorldwideScreenVideoAdaptationTier
    ) -> WorldwideScreenVideoEncodingRecommendation {
        let maximumBitrateBps = min(
            maximumTierVideoBitrateBps,
            referenceVideoBitrateBps(for: tier)
        )
        return WorldwideScreenVideoEncodingRecommendation(
            tier: tier,
            maximumBitrateBps: maximumBitrateBps,
            maximumTotalRTPBitrateBps:
                maximumTotalRTPBitrateBps(for: tier),
            maximumFramesPerSecond: min(
                baseFramesPerSecond,
                tier.framesPerSecond
            ),
            scaleResolutionDownBy: tier.scaleResolutionDownBy
        )
    }

    /// Returns true only when a different peer lifetime reset the adaptation state.
    @discardableResult
    mutating func bind(toPeerGeneration generation: UInt64) -> Bool {
        guard peerGeneration != generation else { return false }
        peerGeneration = generation
        currentTier = Self.initialTier(
            configuredTotalRTPBitrateBps: configuredTotalRTPBitrateBps
        )
        selectedRoute = nil
        resetPathMeasurements()
        resetAutomaticSuspensionMeasurements()
        return true
    }

    /// Clears latency history when ICE invalidates the selected path, while retaining the
    /// conservative quality tier learned for this peer lifetime.
    mutating func invalidateSelectedRoute() {
        selectedRoute = nil
        revertApplicationLimitedProbeIfActive()
        resetPathMeasurements()
    }

    /// Prevents threshold evidence collected on one cadence, or before a long observation gap,
    /// from being combined with a later sample. Stable route baselines and any already-applied
    /// probe remain intact; only incomplete evidence windows are discarded.
    mutating func resetIncompleteEvidenceWindow() {
        healthyUpgradeSampleCount = 0
        bandwidthOnlyDowngradeSampleCount = 0
        queuePressureSampleCount = 0
        lastLowDelayPacketQueueObservation = nil
        lastSoftPacketQueuePressureObservation = nil
        unavailableBandwidthSampleCount = 0
        positiveBandwidthBootstrapSampleCount = 0
        applicationLimitedUpgradeSampleCount = 0
        applicationLimitedProbeHealthySampleCount = 0
        applicationLimitedProbeBestQualifiedTier = nil
    }

    /// Returns a recommendation only when the current sender should apply new limits.
    mutating func update(
        peerGeneration generation: UInt64,
        isCaptureActive: Bool,
        isAutomaticallySuspended: Bool = false,
        availableOutgoingBitrateBps: Double?,
        currentRoundTripTimeSeconds: Double?,
        selectedRoute: WebRTCICERouteDiagnostics? = nil,
        outboundVideoPacketsSent: UInt64? = nil,
        outboundVideoTotalPacketSendDelaySeconds: Double? = nil,
        observedAt: ContinuousClock.Instant = .now
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        let didResetForNewPeer = bind(toPeerGeneration: generation)
        if let selectedRoute,
           selectedRoute != self.selectedRoute {
            self.selectedRoute = selectedRoute
            revertApplicationLimitedProbeIfActive()
            resetPathMeasurements()
        }

        // Pre-Show and manually hidden sessions have no outbound video with which to interpret
        // WebRTC's optional bandwidth estimate or packet-send delay. V27 treated those absent
        // samples as congestion and could walk all the way to audioPriority before the first Show.
        // Reset to the configured conservative start tier and consume path samples only for an
        // active sender or an explicit automatic-pause recovery probe.
        guard isCaptureActive || isAutomaticallySuspended else {
            currentTier = Self.initialTier(
                configuredTotalRTPBitrateBps: configuredTotalRTPBitrateBps
            )
            resetPathMeasurements()
            resetAutomaticSuspensionMeasurements()
            return nil
        }

        let currentRoundTripTimeSeconds = validRoundTripTime(
            currentRoundTripTimeSeconds
        )
        let roundTripTimeIsInflated = roundTripTimeIsInflated(
            currentRoundTripTimeSeconds
        )
        if let currentRoundTripTimeSeconds {
            updateRoundTripTimeBaseline(currentRoundTripTimeSeconds)
        }
        let packetQueueObservation = packetQueueObservationSinceLastSample(
                packetsSent: outboundVideoPacketsSent,
                totalPacketSendDelaySeconds:
                    outboundVideoTotalPacketSendDelaySeconds
            )
        let averagePacketSendDelaySeconds: Double?
        switch packetQueueObservation {
        case let .measured(value):
            averagePacketSendDelaySeconds = value
        case .noNewPackets, .unavailableOrReset:
            averagePacketSendDelaySeconds = nil
        }
        lastAveragePacketSendDelaySeconds = averagePacketSendDelaySeconds
        let packetQueueSampleIsInflated = averagePacketSendDelaySeconds.map {
            $0 > Self.maximumAveragePacketSendDelaySeconds
        } ?? false
        let packetQueueSampleRequiresImmediateResponse =
            averagePacketSendDelaySeconds.map {
                $0 >= Self.immediateAveragePacketSendDelaySeconds
            } ?? false
        switch packetQueueObservation {
        case .measured where packetQueueSampleIsInflated
            && !roundTripTimeIsInflated:
            if let lastSoftPacketQueuePressureObservation,
               !isFreshPacketQueueObservation(
                   lastSoftPacketQueuePressureObservation,
                   at: observedAt
               ) {
                queuePressureSampleCount = 0
            }
            if queuePressureSampleCount < Int.max {
                queuePressureSampleCount += 1
            }
            lastSoftPacketQueuePressureObservation = observedAt
        case .noNewPackets where !roundTripTimeIsInflated:
            if let lastSoftPacketQueuePressureObservation,
               !isFreshPacketQueueObservation(
                   lastSoftPacketQueuePressureObservation,
                   at: observedAt
               ) {
                queuePressureSampleCount = 0
                self.lastSoftPacketQueuePressureObservation = nil
            }
        case .measured, .unavailableOrReset, .noNewPackets:
            queuePressureSampleCount = 0
            lastSoftPacketQueuePressureObservation = nil
        }
        let packetQueueIsInflated = packetQueueSampleIsInflated
            && (packetQueueSampleRequiresImmediateResponse
                || queuePressureSampleCount >= Self.requiredQueuePressureSampleCount)
        switch packetQueueObservation {
        case let .measured(averagePacketSendDelaySeconds):
            lastLowDelayPacketQueueObservation =
                averagePacketSendDelaySeconds
                    <= Self.maximumUpgradePacketSendDelaySeconds
                ? observedAt
                : nil
        case .noNewPackets:
            if let lastLowDelayPacketQueueObservation,
               !isFreshPacketQueueObservation(
                   lastLowDelayPacketQueueObservation,
                   at: observedAt
               ) {
                self.lastLowDelayPacketQueueObservation = nil
            }
        case .unavailableOrReset:
            lastLowDelayPacketQueueObservation = nil
        }
        let packetQueueAllowsUpgrade: Bool
        if let averagePacketSendDelaySeconds {
            packetQueueAllowsUpgrade = averagePacketSendDelaySeconds
                <= Self.maximumUpgradePacketSendDelaySeconds
        } else if let lastLowDelayPacketQueueObservation {
            let observationAge = lastLowDelayPacketQueueObservation.duration(
                to: observedAt
            )
            packetQueueAllowsUpgrade = observationAge >= .zero
                && observationAge
                    <= Self.lowDelayPacketQueueObservationValidity
        } else {
            packetQueueAllowsUpgrade = false
        }
        let roundTripTimeAllowsUpgrade = roundTripTimeAllowsUpgrade(
            currentRoundTripTimeSeconds
        )
        let directUpgradeEvidenceIsHealthy = averagePacketSendDelaySeconds.map {
            $0 <= Self.maximumUpgradePacketSendDelaySeconds
                && (currentRoundTripTimeSeconds == nil
                    || roundTripTimeAllowsUpgrade)
        } ?? roundTripTimeAllowsUpgrade
        let strictUpgradeEvidenceIsHealthy = packetQueueAllowsUpgrade
            && roundTripTimeAllowsUpgrade
        let latencyPressure = roundTripTimeIsInflated || packetQueueIsInflated
        let latencyEvidenceIsPositivelyHealthy = !latencyPressure
            && directUpgradeEvidenceIsHealthy
        lastSampleHasLatencyPressure = latencyPressure

        guard let availableOutgoingBitrateBps,
              availableOutgoingBitrateBps.isFinite,
              availableOutgoingBitrateBps > 0 else {
            bandwidthOnlyDowngradeSampleCount = 0
            applicationLimitedUpgradeSampleCount = 0
            if let probeOriginTier = applicationLimitedProbeOriginTier {
                let probeDeadlineExpired = applicationLimitedProbeDeadline.map {
                    observedAt >= $0
                } ?? true
                if latencyPressure {
                    failApplicationLimitedProbe(
                        revertingTo: probeOriginTier
                    )
                    lastSampleHasPositiveSuspensionPressure = true
                    return isCaptureActive ? currentRecommendation : nil
                } else if probeDeadlineExpired {
                    finishApplicationLimitedProbe(
                        revertingTo: probeOriginTier
                    )
                    lastSampleHasPositiveSuspensionPressure = false
                    return isCaptureActive ? currentRecommendation : nil
                } else if applicationLimitedProbeGraceSamplesRemaining > 1 {
                    applicationLimitedProbeGraceSamplesRemaining -= 1
                    lastSampleHasPositiveSuspensionPressure = false
                    return isCaptureActive && didResetForNewPeer
                        ? currentRecommendation
                        : nil
                } else {
                    finishApplicationLimitedProbe(
                        revertingTo: probeOriginTier
                    )
                    lastSampleHasPositiveSuspensionPressure = false
                    return isCaptureActive ? currentRecommendation : nil
                }
            }
            if !bandwidthEstimateIsUnavailable {
                healthyUpgradeSampleCount = 0
            }
            bandwidthEstimateIsUnavailable = true
            if unavailableBandwidthSampleCount < Int.max {
                unavailableBandwidthSampleCount += 1
            }
            // Missing BWE is telemetry, not new proof of congestion. Preserve a prior failed
            // raised-ceiling probe below the reserved floor, however: that probe already removed
            // the sender-limit ambiguity and remains actionable until capacity is positively
            // re-established or an automatic resume authorizes a fresh recovery probe.
            lastSampleHasPositiveSuspensionPressure = latencyPressure
                || belowReserveProbeDisprovedSenderLimitation
            if latencyPressure {
                healthyUpgradeSampleCount = 0
                guard let lowerTier = currentTier.nextLowerQuality else {
                    return isCaptureActive && didResetForNewPeer
                        ? currentRecommendation
                        : nil
                }
                currentTier = lowerTier
                resetQueueEvidenceForTierTransition()
                return isCaptureActive ? currentRecommendation : nil
            }
            if consumeApplicationLimitedProbeCooldown(
                isCaptureActive: isCaptureActive
            ) {
                healthyUpgradeSampleCount = 0
                return isCaptureActive && didResetForNewPeer
                    ? currentRecommendation
                    : nil
            }

            // Candidate-pair availableOutgoingBitrate is optional. Once both independent latency
            // signals are healthy, cautiously probe one tier at a time instead of freezing the
            // startup scale forever. Each probe must earn a fresh complete window.
            guard isCaptureActive,
                  let upgradeTier = currentTier.nextHigherQuality,
                  requiredOutgoingBitrateBps(for: upgradeTier)
                    <= Double(configuredTotalRTPBitrateBps),
                  packetQueueAllowsUpgrade,
                  roundTripTimeAllowsUpgrade else {
                healthyUpgradeSampleCount = 0
                return isCaptureActive && didResetForNewPeer
                    ? currentRecommendation
                    : nil
            }
            healthyUpgradeSampleCount += 1
            guard healthyUpgradeSampleCount
                    >= Self.requiredUnavailableBandwidthUpgradeSampleCount else {
                return isCaptureActive && didResetForNewPeer
                    ? currentRecommendation
                    : nil
            }
            currentTier = upgradeTier
            resetQueueEvidenceForTierTransition()
            healthyUpgradeSampleCount = 0
            return currentRecommendation
        }
        if bandwidthEstimateIsUnavailable {
            healthyUpgradeSampleCount = 0
        }
        bandwidthEstimateIsUnavailable = false
        unavailableBandwidthSampleCount = 0
        let effectiveAvailableOutgoingBitrateBps: Double
        if availableOutgoingBitrateBps
            >= Double(configuredTotalRTPBitrateBps)
                * Self.configuredCapacitySaturationRatio {
            effectiveAvailableOutgoingBitrateBps = Double(
                configuredTotalRTPBitrateBps
            )
        } else {
            effectiveAvailableOutgoingBitrateBps = availableOutgoingBitrateBps
        }
        let capacitySustainableTier = sustainableTier(
            for: effectiveAvailableOutgoingBitrateBps
        )
        let independentlyQualifiedUpgradeTier = highestQualifiedUpgradeTier(
            for: effectiveAvailableOutgoingBitrateBps
        )
        let requiredAudioPriorityBitrateBps = requiredOutgoingBitrateBps(
            for: .audioPriority
        )
        if effectiveAvailableOutgoingBitrateBps
            >= requiredAudioPriorityBitrateBps {
            belowReserveProbeDisprovedSenderLimitation = false
            automaticResumeProbeRestoration = nil
        }
        let estimatorMayBeApplicationLimited = estimatorIsApplicationLimited(
            effectiveAvailableOutgoingBitrateBps
        )

        // Only a positive estimate already near the sender ceiling can be self-limited. Give that
        // exact cold-start case one bounded window for RTT/queue evidence; a genuinely low or
        // flapping estimate remains actionable on its first valid sample.
        if latencyPressure {
            positiveBandwidthBootstrapSampleCount =
                Self.requiredPositiveBandwidthBootstrapSampleCount
            applicationLimitedUpgradeSampleCount = 0
        } else if positiveBandwidthBootstrapSampleCount
            < Self.requiredPositiveBandwidthBootstrapSampleCount {
            if independentlyQualifiedUpgradeTier != nil {
                positiveBandwidthBootstrapSampleCount =
                    Self.requiredPositiveBandwidthBootstrapSampleCount
            } else if estimatorMayBeApplicationLimited {
                positiveBandwidthBootstrapSampleCount += 1
                applicationLimitedUpgradeSampleCount = 0
                lastSampleHasPositiveSuspensionPressure = false
                return isCaptureActive && didResetForNewPeer
                    ? currentRecommendation
                    : nil
            } else {
                positiveBandwidthBootstrapSampleCount =
                    Self.requiredPositiveBandwidthBootstrapSampleCount
            }
        }

        if let probeOriginTier = applicationLimitedProbeOriginTier {
            let probeQualifiedTier = capacitySustainableTier.rawValue
                < probeOriginTier.rawValue
                ? capacitySustainableTier
                : nil
            let probeCapacityCollapsed =
                effectiveAvailableOutgoingBitrateBps
                    < max(
                        requiredAudioPriorityBitrateBps,
                        Double(
                            recommendation(for: probeOriginTier)
                                .maximumBitrateBps
                        ) * Self.applicationLimitedProbeImmediateAbortRatio
                    )
            let probeDeadlineExpired = applicationLimitedProbeDeadline.map {
                observedAt >= $0
            } ?? true
            if latencyPressure || probeCapacityCollapsed {
                if probeCapacityCollapsed,
                   effectiveAvailableOutgoingBitrateBps
                    < requiredAudioPriorityBitrateBps {
                    // Raising the sender ceiling removed the censoring ambiguity but the estimate
                    // stayed below the reserved floor. Preserve that evidence across backoff so a
                    // genuinely constrained path can still accumulate bounded pause pressure.
                    belowReserveProbeDisprovedSenderLimitation = true
                }
                failApplicationLimitedProbe(revertingTo: probeOriginTier)
                if capacitySustainableTier.rawValue > probeOriginTier.rawValue {
                    // This is still one terminal decision for the report: independently worse BWE
                    // may protect the audio/control reserve, while probe-only latency merely
                    // restores the unchanged visible origin tier.
                    currentTier = capacitySustainableTier
                    resetQueueEvidenceForTierTransition()
                }
                lastSampleHasPositiveSuspensionPressure = latencyPressure
                    || effectiveAvailableOutgoingBitrateBps
                        < requiredAudioPriorityBitrateBps
                return isCaptureActive ? currentRecommendation : nil
            } else if packetQueueSampleIsInflated,
                      !packetQueueIsInflated,
                      !roundTripTimeIsInflated {
                // A single transition burst neither confirms capacity nor consumes sample grace.
                // The absolute deadline still bounds the ceiling-only probe.
                applicationLimitedUpgradeSampleCount = 0
                lastSampleHasPositiveSuspensionPressure = false
                if probeDeadlineExpired {
                    if applicationLimitedProbeBestQualifiedTier == nil,
                       effectiveAvailableOutgoingBitrateBps
                        < requiredAudioPriorityBitrateBps {
                        belowReserveProbeDisprovedSenderLimitation = true
                    }
                    finishApplicationLimitedProbe(
                        revertingTo: probeOriginTier
                    )
                    return isCaptureActive ? currentRecommendation : nil
                }
                return isCaptureActive && didResetForNewPeer
                    ? currentRecommendation
                    : nil
            }

            if strictUpgradeEvidenceIsHealthy,
               let qualifiedTier = probeQualifiedTier {
                if applicationLimitedProbeBestQualifiedTier == qualifiedTier {
                    if applicationLimitedProbeHealthySampleCount < Int.max {
                        applicationLimitedProbeHealthySampleCount += 1
                    }
                } else {
                    applicationLimitedProbeBestQualifiedTier = qualifiedTier
                    applicationLimitedProbeHealthySampleCount = 1
                }
            } else {
                applicationLimitedProbeHealthySampleCount = 0
            }

            if applicationLimitedProbeHealthySampleCount
                >= Self.requiredHealthyUpgradeSampleCount,
               applicationLimitedProbeBestQualifiedTier == .full {
                completeApplicationLimitedProbe(committing: .full)
                lastSampleHasPositiveSuspensionPressure = false
                return isCaptureActive ? currentRecommendation : nil
            }

            if !probeDeadlineExpired,
               applicationLimitedProbeGraceSamplesRemaining > 1,
               strictUpgradeEvidenceIsHealthy,
               let currentProbeCeiling =
                applicationLimitedProbeMaximumTotalRTPBitrateBps {
                let nextProbeCeiling = boundedApplicationLimitedProbeCeiling(
                    availableOutgoingBitrateBps:
                        effectiveAvailableOutgoingBitrateBps,
                    currentCeilingBps: currentProbeCeiling
                )
                if nextProbeCeiling > currentProbeCeiling {
                    applicationLimitedProbeMaximumTotalRTPBitrateBps =
                        nextProbeCeiling
                    applicationLimitedProbeGraceSamplesRemaining -= 1
                    applicationLimitedUpgradeSampleCount = 0
                    lastSampleHasPositiveSuspensionPressure = false
                    return isCaptureActive ? currentRecommendation : nil
                }
            }

            if applicationLimitedProbeGraceSamplesRemaining > 0 {
                applicationLimitedProbeGraceSamplesRemaining -= 1
            }
            applicationLimitedUpgradeSampleCount = 0
            lastSampleHasPositiveSuspensionPressure = false
            if probeDeadlineExpired
                || applicationLimitedProbeGraceSamplesRemaining == 0 {
                if applicationLimitedProbeBestQualifiedTier == nil,
                   effectiveAvailableOutgoingBitrateBps
                    < requiredAudioPriorityBitrateBps {
                    belowReserveProbeDisprovedSenderLimitation = true
                }
                finishApplicationLimitedProbe(revertingTo: probeOriginTier)
                return isCaptureActive ? currentRecommendation : nil
            }
            return isCaptureActive && didResetForNewPeer
                ? currentRecommendation
                : nil
        }

        if independentlyQualifiedUpgradeTier != nil,
           directUpgradeEvidenceIsHealthy,
           !latencyPressure {
            resetApplicationLimitedProbeBackoff()
        }

        // A near-ceiling estimate is censored by the sender and therefore cannot prove that the
        // path itself is congested. Below the absolute audio/control reserve, extend that neutral
        // treatment only at audioPriority: applying it at higher tiers could pin a truly starved
        // path above the fail-closed floor when strict probe telemetry is unavailable. At the
        // floor, fresh RTT and queue evidence may authorize one bounded higher-ceiling probe.
        let audioPriorityProbeIsFeasible = currentTier == .audioPriority
            && currentTier.nextHigherQuality.map {
                requiredOutgoingBitrateBps(for: $0)
                    <= Double(configuredTotalRTPBitrateBps)
            } == true
        let senderLimitedEstimateCanHoldCurrentTier =
            effectiveAvailableOutgoingBitrateBps
                >= requiredAudioPriorityBitrateBps
            || (audioPriorityProbeIsFeasible
                && !belowReserveProbeDisprovedSenderLimitation)
        let applicationLimitedHoldIsHealthy = !latencyPressure
            && isCaptureActive
            && independentlyQualifiedUpgradeTier == nil
            && estimatorMayBeApplicationLimited
            && senderLimitedEstimateCanHoldCurrentTier
        if applicationLimitedHoldIsHealthy {
            bandwidthOnlyDowngradeSampleCount = 0
            guard currentTier.nextHigherQuality != nil else {
                applicationLimitedUpgradeSampleCount = 0
                lastSampleHasPositiveSuspensionPressure = false
                return isCaptureActive && didResetForNewPeer
                    ? currentRecommendation
                    : nil
            }
            guard !consumeApplicationLimitedProbeCooldown(
                isCaptureActive: isCaptureActive
            ) else {
                applicationLimitedUpgradeSampleCount = 0
                lastSampleHasPositiveSuspensionPressure = false
                return isCaptureActive && didResetForNewPeer
                    ? currentRecommendation
                    : nil
            }
            guard strictUpgradeEvidenceIsHealthy else {
                applicationLimitedUpgradeSampleCount = 0
                lastSampleHasPositiveSuspensionPressure = false
                return isCaptureActive && didResetForNewPeer
                    ? currentRecommendation
                    : nil
            }
            applicationLimitedUpgradeSampleCount += 1
            if applicationLimitedUpgradeSampleCount
                >= Self.requiredApplicationLimitedUpgradeSampleCount {
                applicationLimitedUpgradeSampleCount = 0
                if beginApplicationLimitedProbe(
                    from: currentTier,
                    availableOutgoingBitrateBps:
                        effectiveAvailableOutgoingBitrateBps,
                    observedAt: observedAt
                ) {
                    lastSampleHasPositiveSuspensionPressure = false
                    return isCaptureActive ? currentRecommendation : nil
                }
            }
            lastSampleHasPositiveSuspensionPressure = false
            return isCaptureActive && didResetForNewPeer
                ? currentRecommendation
                : nil
        } else {
            applicationLimitedUpgradeSampleCount = 0
        }

        if packetQueueSampleIsInflated,
           !packetQueueIsInflated,
           !roundTripTimeIsInflated,
           capacitySustainableTier.rawValue <= currentTier.rawValue {
            // One transition-sized queue delta is neither healthy upgrade evidence nor proof that
            // a sender-censored BWE is the path capacity. Hold the visible tier for one sample.
            healthyUpgradeSampleCount = 0
            bandwidthOnlyDowngradeSampleCount = 0
            lastSampleHasPositiveSuspensionPressure = false
            return isCaptureActive && didResetForNewPeer
                ? currentRecommendation
                : nil
        }

        lastSampleHasPositiveSuspensionPressure = latencyPressure
            || effectiveAvailableOutgoingBitrateBps
                < requiredOutgoingBitrateBps(for: .audioPriority)

        var sustainableTier = capacitySustainableTier
        if packetQueueIsInflated,
           !roundTripTimeIsInflated,
           let lowerTier = currentTier.nextLowerQuality {
            // Queue-only congestion walks down one tier per fresh sample. This remains a fast
            // 500 ms response while avoiding a direct collapse based on a censored BWE.
            if lowerTier.rawValue > sustainableTier.rawValue {
                sustainableTier = lowerTier
            }
        } else if latencyPressure,
           let lowerTier = currentTier.nextLowerQuality,
           lowerTier.rawValue > sustainableTier.rawValue {
            sustainableTier = lowerTier
        }
        if sustainableTier.rawValue > currentTier.rawValue {
            healthyUpgradeSampleCount = 0
            if latencyEvidenceIsPositivelyHealthy {
                if bandwidthOnlyDowngradeSampleCount < Int.max {
                    bandwidthOnlyDowngradeSampleCount += 1
                }
                guard bandwidthOnlyDowngradeSampleCount
                        >= Self.requiredBandwidthOnlyDowngradeSampleCount else {
                    return isCaptureActive && didResetForNewPeer
                        ? currentRecommendation
                        : nil
                }
            }
            bandwidthOnlyDowngradeSampleCount = 0
            currentTier = sustainableTier
            resetQueueEvidenceForTierTransition()
            return isCaptureActive ? currentRecommendation : nil
        }
        bandwidthOnlyDowngradeSampleCount = 0

        guard sustainableTier.rawValue < currentTier.rawValue,
              let highestUpgradeTier = independentlyQualifiedUpgradeTier else {
            healthyUpgradeSampleCount = 0
            return isCaptureActive && didResetForNewPeer
                ? currentRecommendation
                : nil
        }
        // A paused sender cannot supply a fresh trustworthy capacity estimate. Preserve the
        // historical one-tier recovery probe until exact receiver presentation reopens ordinary
        // capture; only an active sender may jump directly to the proven target.
        let upgradeTier = isCaptureActive
            ? highestUpgradeTier
            : (currentTier.nextHigherQuality ?? highestUpgradeTier)
        guard !latencyPressure,
              directUpgradeEvidenceIsHealthy else {
            healthyUpgradeSampleCount = 0
            return isCaptureActive && didResetForNewPeer
                ? currentRecommendation
                : nil
        }

        healthyUpgradeSampleCount += 1
        let requiredUpgradeSampleCount = isCaptureActive
            ? Self.requiredHealthyUpgradeSampleCount
            : Self.requiredSuspendedHealthyUpgradeSampleCount
        guard healthyUpgradeSampleCount
                >= requiredUpgradeSampleCount else {
            return isCaptureActive && didResetForNewPeer
                ? currentRecommendation
                : nil
        }
        // The estimate already proves this target with both downgrade headroom and its own
        // upgrade margin. Select the highest independently qualified tier so crossing into the
        // next tier's raw sustainable band can never make recovery worse.
        currentTier = upgradeTier
        resetQueueEvidenceForTierTransition()
        healthyUpgradeSampleCount = 0
        bandwidthOnlyDowngradeSampleCount = 0
        return isCaptureActive ? currentRecommendation : nil
    }

    /// Expires only an already-raised application-limited probe when both statistics lanes stop
    /// producing native reports. Absence is neither healthy nor congested evidence, so this path
    /// cannot alter baselines, evidence counts, ordinary tiers, or automatic-suspension state.
    mutating func expireApplicationLimitedProbeWithoutReport(
        peerGeneration generation: UInt64,
        isCaptureActive: Bool,
        observedAt: ContinuousClock.Instant = .now
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        guard peerGeneration == generation,
              isCaptureActive,
              let originTier = applicationLimitedProbeOriginTier,
              let deadline = applicationLimitedProbeDeadline,
              observedAt >= deadline else {
            return nil
        }
        finishApplicationLimitedProbe(revertingTo: originTier)
        return isCaptureActive ? currentRecommendation : nil
    }

    /// Recovers a session created by an older automatic-suspension policy, but never turns an
    /// acknowledged visible session opaque. Network adaptation owns encoding limits only: even
    /// under genuine congestion the audio-priority 1 fps recommendation remains the visible floor.
    /// Explicit Hide, authorization loss, and transport uncertainty continue to own fail-closed
    /// capture teardown outside this policy.
    mutating func automaticSuspensionDecision(
        isCaptureActive: Bool,
        isAutomaticallySuspended: Bool
    ) -> WorldwideScreenVideoAutomaticSuspensionDecision? {
        if isAutomaticallySuspended {
            automaticSuspensionPressureSampleCount = 0
            if maximumSuspensionResumeProbeSampleCount
                < Self.requiredMaximumSuspensionResumeProbeSampleCount {
                maximumSuspensionResumeProbeSampleCount += 1
            }
            if currentTier != .audioPriority {
                stableSuspensionResumeProbeSampleCount = 0
                maximumSuspensionResumeProbeSampleCount = 0
                return .resume
            }
            // Relative RTT pressure can remain permanently elevated after a path settles at a new
            // stable latency. Never turn that stale baseline into a permanent pause: permit one
            // bounded probe after a much longer maximum-pause window. A failed probe resets both
            // counters and therefore enforces the complete cooldown before another attempt.
            if maximumSuspensionResumeProbeSampleCount
                >= Self.requiredMaximumSuspensionResumeProbeSampleCount {
                stableSuspensionResumeProbeSampleCount = 0
                maximumSuspensionResumeProbeSampleCount = 0
                return .resume
            }
            guard !lastSampleHasLatencyPressure else {
                stableSuspensionResumeProbeSampleCount = 0
                return nil
            }
            if stableSuspensionResumeProbeSampleCount
                < Self.requiredStableSuspensionResumeProbeSampleCount {
                stableSuspensionResumeProbeSampleCount += 1
            }
            guard stableSuspensionResumeProbeSampleCount
                    >= Self.requiredStableSuspensionResumeProbeSampleCount else {
                return nil
            }
            stableSuspensionResumeProbeSampleCount = 0
            return .resume
        }

        stableSuspensionResumeProbeSampleCount = 0
        maximumSuspensionResumeProbeSampleCount = 0
        automaticSuspensionPressureSampleCount = 0
        return nil
    }

    /// Consumes retained below-reserve evidence only after the suspension coordinator accepts the
    /// exact resume attempt. A rejected decision therefore cannot weaken the pause invariant.
    mutating func automaticResumeAttemptBegan() {
        guard automaticResumeProbeRestoration == nil else { return }
        automaticResumeProbeRestoration = AutomaticResumeProbeRestoration(
            belowReserveProbeDisprovedSenderLimitation:
                belowReserveProbeDisprovedSenderLimitation,
            applicationLimitedProbeCooldownSamplesRemaining:
                applicationLimitedProbeCooldownSamplesRemaining,
            applicationLimitedProbeFailureCount:
                applicationLimitedProbeFailureCount
        )
        belowReserveProbeDisprovedSenderLimitation = false
        applicationLimitedUpgradeSampleCount = 0
        resetApplicationLimitedProbeBackoff()
    }

    mutating func automaticResumeAttemptSucceeded() {
        automaticResumeProbeRestoration = nil
    }

    mutating func automaticResumeAttemptFailed() {
        if let restoration = automaticResumeProbeRestoration {
            belowReserveProbeDisprovedSenderLimitation =
                restoration.belowReserveProbeDisprovedSenderLimitation
            applicationLimitedProbeCooldownSamplesRemaining =
                restoration.applicationLimitedProbeCooldownSamplesRemaining
            applicationLimitedProbeFailureCount =
                restoration.applicationLimitedProbeFailureCount
        }
        automaticResumeProbeRestoration = nil
        currentTier = .audioPriority
        resetQueueEvidenceForTierTransition()
        healthyUpgradeSampleCount = 0
        bandwidthOnlyDowngradeSampleCount = 0
        applicationLimitedUpgradeSampleCount = 0
        applicationLimitedProbeHealthySampleCount = 0
        applicationLimitedProbeGraceSamplesRemaining = 0
        applicationLimitedProbeDeadline = nil
        applicationLimitedProbeOriginTier = nil
        applicationLimitedProbeBestQualifiedTier = nil
        applicationLimitedProbeMaximumTotalRTPBitrateBps = nil
        resetAutomaticSuspensionMeasurements()
    }

    mutating func resetForInactiveCapture() {
        currentTier = Self.initialTier(
            configuredTotalRTPBitrateBps: configuredTotalRTPBitrateBps
        )
        resetPathMeasurements()
        resetAutomaticSuspensionMeasurements()
    }

    private func sustainableTier(
        for availableOutgoingBitrateBps: Double
    ) -> WorldwideScreenVideoAdaptationTier {
        WorldwideScreenVideoAdaptationTier.allCases.first { tier in
            let requiredBitrate = requiredOutgoingBitrateBps(for: tier)
            return requiredBitrate <= Double(configuredTotalRTPBitrateBps)
                && availableOutgoingBitrateBps >= requiredBitrate
        } ?? .audioPriority
    }

    private func highestQualifiedUpgradeTier(
        for availableOutgoingBitrateBps: Double
    ) -> WorldwideScreenVideoAdaptationTier? {
        WorldwideScreenVideoAdaptationTier.allCases.first { tier in
            guard tier.rawValue < currentTier.rawValue else { return false }
            let requiredBitrate = requiredOutgoingBitrateBps(for: tier)
            guard requiredBitrate <= Double(configuredTotalRTPBitrateBps) else {
                return false
            }
            let upgradeThreshold = min(
                Double(configuredTotalRTPBitrateBps),
                requiredBitrate * Self.upgradeMarginMultiplier
            )
            return availableOutgoingBitrateBps >= upgradeThreshold
        }
    }

    private func requiredOutgoingBitrateBps(
        for tier: WorldwideScreenVideoAdaptationTier
    ) -> Double {
        // Tier selection is based on calibrated codec demand. The separately configured 50 Mbps
        // RTP value remains a native sender ceiling, but must not multiply the bandwidth required
        // to choose a resolution/fps tier.
        return Double(Self.baselineReferenceVideoBitrateBps(for: tier))
            * Self.downgradeHeadroomMultiplier
            + Self.audioAndControlReserveBps
    }

    private func maximumTotalRTPBitrateBps(
        for tier: WorldwideScreenVideoAdaptationTier
    ) -> Int {
        Int(
            min(
                Double(configuredTotalRTPBitrateBps),
                requiredOutgoingBitrateBps(for: tier)
                    * Self.upgradeMarginMultiplier
            ).rounded(.up)
        )
    }

    private static func initialTier(
        configuredTotalRTPBitrateBps: Int
    ) -> WorldwideScreenVideoAdaptationTier {
        let configuredQualityCeiling =
            WorldwideScreenVideoAdaptationTier.allCases.first { tier in
                let referenceVideoBitrate = baselineReferenceVideoBitrateBps(
                    for: tier
                )
                let required = Double(referenceVideoBitrate)
                    * downgradeHeadroomMultiplier
                    + audioAndControlReserveBps
                return required <= Double(configuredTotalRTPBitrateBps)
            } ?? .audioPriority
        return WorldwideScreenVideoAdaptationTier(
            rawValue: max(
                WorldwideScreenVideoAdaptationTier.survival.rawValue,
                configuredQualityCeiling.rawValue
            )
        ) ?? .audioPriority
    }

    private func referenceVideoBitrateBps(
        for tier: WorldwideScreenVideoAdaptationTier
    ) -> Int {
        let referenceMaximumVideoBitrateBps = max(
            Self.baselineReferenceMaximumVideoBitrateBps,
            maximumTierVideoBitrateBps
        )
        return max(
            Self.minimumVideoBitrateBps,
            referenceMaximumVideoBitrateBps
                * tier.bitrateBasisPoints / 10_000
        )
    }

    private static func baselineReferenceVideoBitrateBps(
        for tier: WorldwideScreenVideoAdaptationTier
    ) -> Int {
        max(
            minimumVideoBitrateBps,
            baselineReferenceMaximumVideoBitrateBps
                * tier.bitrateBasisPoints / 10_000
        )
    }

    private func boundedApplicationLimitedProbeCeiling(
        availableOutgoingBitrateBps: Double,
        currentCeilingBps: Int
    ) -> Int {
        guard availableOutgoingBitrateBps.isFinite,
              availableOutgoingBitrateBps > 0 else {
            return currentCeilingBps
        }
        let fullProbeCeiling = maximumTotalRTPBitrateBps(for: .full)
        let doubledEstimate = min(
            Double(fullProbeCeiling),
            availableOutgoingBitrateBps * 2
        )
        return max(
            currentCeilingBps,
            Int(doubledEstimate.rounded(.down))
        )
    }

    private func estimatorIsApplicationLimited(
        _ availableOutgoingBitrateBps: Double
    ) -> Bool {
        return availableOutgoingBitrateBps
            >= Double(maximumTotalRTPBitrateBps(for: currentTier))
                * Self.applicationLimitedSaturationRatio
    }

    private mutating func beginApplicationLimitedProbe(
        from originTier: WorldwideScreenVideoAdaptationTier,
        availableOutgoingBitrateBps: Double,
        observedAt: ContinuousClock.Instant
    ) -> Bool {
        guard let probeTier = originTier.nextHigherQuality,
              requiredOutgoingBitrateBps(for: probeTier)
                <= Double(configuredTotalRTPBitrateBps) else {
            return false
        }
        applicationLimitedProbeOriginTier = originTier
        applicationLimitedProbeBestQualifiedTier = nil
        applicationLimitedProbeHealthySampleCount = 0
        let ordinaryCeiling = maximumTotalRTPBitrateBps(for: originTier)
        let probeCeiling = boundedApplicationLimitedProbeCeiling(
            availableOutgoingBitrateBps: availableOutgoingBitrateBps,
            currentCeilingBps: ordinaryCeiling
        )
        guard probeCeiling > ordinaryCeiling else {
            applicationLimitedProbeOriginTier = nil
            return false
        }
        applicationLimitedProbeMaximumTotalRTPBitrateBps = probeCeiling
        // This is a bitrate/BWE-ceiling-only transition. Preserve the fresh low-delay packet
        // observation so a 1 fps sender can evaluate the next no-packet poll; visible tier changes
        // still reset queue evidence through complete/fail paths.
        applicationLimitedProbeGraceSamplesRemaining =
            Self.applicationLimitedProbeGraceSampleCount
        applicationLimitedProbeDeadline = observedAt.advanced(
            by: Self.applicationLimitedProbeGraceDuration
        )
        applicationLimitedUpgradeSampleCount = 0
        healthyUpgradeSampleCount = 0
        return true
    }

    private mutating func completeApplicationLimitedProbe(
        committing tier: WorldwideScreenVideoAdaptationTier
    ) {
        currentTier = tier
        resetQueueEvidenceForTierTransition()
        applicationLimitedProbeOriginTier = nil
        applicationLimitedProbeBestQualifiedTier = nil
        applicationLimitedProbeMaximumTotalRTPBitrateBps = nil
        applicationLimitedProbeHealthySampleCount = 0
        applicationLimitedProbeGraceSamplesRemaining = 0
        applicationLimitedProbeDeadline = nil
        applicationLimitedUpgradeSampleCount = 0
        belowReserveProbeDisprovedSenderLimitation = false
        automaticResumeProbeRestoration = nil
        resetApplicationLimitedProbeBackoff()
    }

    private mutating func finishApplicationLimitedProbe(
        revertingTo originTier: WorldwideScreenVideoAdaptationTier
    ) {
        if applicationLimitedProbeHealthySampleCount
            >= Self.requiredHealthyUpgradeSampleCount,
           let qualifiedTier = applicationLimitedProbeBestQualifiedTier {
            completeApplicationLimitedProbe(committing: qualifiedTier)
        } else {
            failApplicationLimitedProbe(revertingTo: originTier)
        }
    }

    private mutating func revertApplicationLimitedProbeIfActive() {
        guard let applicationLimitedProbeOriginTier else { return }
        currentTier = applicationLimitedProbeOriginTier
        resetQueueEvidenceForTierTransition()
        self.applicationLimitedProbeOriginTier = nil
        applicationLimitedProbeBestQualifiedTier = nil
        applicationLimitedProbeMaximumTotalRTPBitrateBps = nil
        applicationLimitedProbeHealthySampleCount = 0
        applicationLimitedProbeGraceSamplesRemaining = 0
        applicationLimitedProbeDeadline = nil
    }

    /// Retains the long exponential backoff for an actually suspended legacy sender, but never
    /// lets stale failure history hide a changed network from a currently visible session for
    /// longer than the active reevaluation window.
    private mutating func consumeApplicationLimitedProbeCooldown(
        isCaptureActive: Bool
    ) -> Bool {
        if isCaptureActive {
            applicationLimitedProbeCooldownSamplesRemaining = min(
                applicationLimitedProbeCooldownSamplesRemaining,
                Self.maximumActiveApplicationLimitedProbeCooldownSampleCount
            )
        }
        guard applicationLimitedProbeCooldownSamplesRemaining > 0 else {
            return false
        }
        applicationLimitedProbeCooldownSamplesRemaining -= 1
        return true
    }

    private mutating func failApplicationLimitedProbe(
        revertingTo originTier: WorldwideScreenVideoAdaptationTier
    ) {
        currentTier = originTier
        resetQueueEvidenceForTierTransition()
        applicationLimitedProbeOriginTier = nil
        applicationLimitedProbeBestQualifiedTier = nil
        applicationLimitedProbeMaximumTotalRTPBitrateBps = nil
        applicationLimitedProbeHealthySampleCount = 0
        applicationLimitedProbeGraceSamplesRemaining = 0
        applicationLimitedProbeDeadline = nil
        applicationLimitedUpgradeSampleCount = 0
        applicationLimitedProbeFailureCount = min(
            applicationLimitedProbeFailureCount + 1,
            Int.bitWidth - 1
        )
        let exponent = min(
            applicationLimitedProbeFailureCount - 1,
            3
        )
        applicationLimitedProbeCooldownSamplesRemaining = min(
            Self.maximumApplicationLimitedProbeCooldownSampleCount,
            Self.initialApplicationLimitedProbeCooldownSampleCount
                * (1 << exponent)
        )
    }

    private mutating func resetApplicationLimitedProbeBackoff() {
        applicationLimitedProbeCooldownSamplesRemaining = 0
        applicationLimitedProbeFailureCount = 0
    }

    private mutating func resetPathMeasurements() {
        healthyUpgradeSampleCount = 0
        bandwidthOnlyDowngradeSampleCount = 0
        queuePressureSampleCount = 0
        lastLowDelayPacketQueueObservation = nil
        lastSoftPacketQueuePressureObservation = nil
        unavailableBandwidthSampleCount = 0
        positiveBandwidthBootstrapSampleCount = 0
        applicationLimitedUpgradeSampleCount = 0
        applicationLimitedProbeHealthySampleCount = 0
        applicationLimitedProbeGraceSamplesRemaining = 0
        applicationLimitedProbeDeadline = nil
        applicationLimitedProbeOriginTier = nil
        applicationLimitedProbeBestQualifiedTier = nil
        applicationLimitedProbeMaximumTotalRTPBitrateBps = nil
        belowReserveProbeDisprovedSenderLimitation = false
        automaticResumeProbeRestoration = nil
        resetApplicationLimitedProbeBackoff()
        roundTripTimeBaselineSeconds = nil
        roundTripTimeBootstrapSamples = []
        lastOutboundVideoPacketsSent = nil
        lastOutboundVideoTotalPacketSendDelaySeconds = nil
        bandwidthEstimateIsUnavailable = false
        lastSampleHasLatencyPressure = false
        lastSampleHasPositiveSuspensionPressure = false
        lastAveragePacketSendDelaySeconds = nil
    }

    private mutating func resetQueueEvidenceForTierTransition() {
        queuePressureSampleCount = 0
        lastLowDelayPacketQueueObservation = nil
        lastSoftPacketQueuePressureObservation = nil
    }

    private mutating func resetAutomaticSuspensionMeasurements() {
        automaticSuspensionPressureSampleCount = 0
        stableSuspensionResumeProbeSampleCount = 0
        maximumSuspensionResumeProbeSampleCount = 0
    }

    private func validRoundTripTime(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private mutating func updateRoundTripTimeBaseline(_ current: Double) {
        guard let baseline = roundTripTimeBaselineSeconds else {
            roundTripTimeBootstrapSamples.append(current)
            guard roundTripTimeBootstrapSamples.count
                    >= Self.roundTripTimeBootstrapSampleCount else {
                return
            }
            roundTripTimeBaselineSeconds = roundTripTimeBootstrapSamples
                .sorted()[roundTripTimeBootstrapSamples.count / 2]
            roundTripTimeBootstrapSamples = []
            return
        }
        if current < baseline {
            roundTripTimeBaselineSeconds = max(
                current,
                baseline - Self.maximumRoundTripTimeBaselineFallPerSample
            )
        }
    }

    private func roundTripTimeIsInflated(_ current: Double?) -> Bool {
        guard let current,
              let roundTripTimeBaselineSeconds else {
            return false
        }
        let inflationThreshold = max(
            roundTripTimeBaselineSeconds
                * Self.roundTripTimeRelativeInflationMultiplier,
            roundTripTimeBaselineSeconds
                + Self.roundTripTimeAbsoluteInflationSeconds
        )
        return current > inflationThreshold
    }

    private func roundTripTimeAllowsUpgrade(_ current: Double?) -> Bool {
        guard let current,
              let roundTripTimeBaselineSeconds else {
            return false
        }
        let inflationThreshold = max(
            roundTripTimeBaselineSeconds
                * Self.roundTripTimeRelativeInflationMultiplier,
            roundTripTimeBaselineSeconds
                + Self.roundTripTimeAbsoluteInflationSeconds
        )
        return current <= inflationThreshold
    }

    private func isFreshPacketQueueObservation(
        _ observation: ContinuousClock.Instant,
        at observedAt: ContinuousClock.Instant
    ) -> Bool {
        let age = observation.duration(to: observedAt)
        return age >= .zero
            && age <= Self.lowDelayPacketQueueObservationValidity
    }

    private mutating func packetQueueObservationSinceLastSample(
        packetsSent: UInt64?,
        totalPacketSendDelaySeconds: Double?
    ) -> PacketQueueObservation {
        guard let packetsSent,
              let totalPacketSendDelaySeconds,
              totalPacketSendDelaySeconds.isFinite,
              totalPacketSendDelaySeconds >= 0 else {
            lastOutboundVideoPacketsSent = nil
            lastOutboundVideoTotalPacketSendDelaySeconds = nil
            return .unavailableOrReset
        }
        defer {
            lastOutboundVideoPacketsSent = packetsSent
            lastOutboundVideoTotalPacketSendDelaySeconds =
                totalPacketSendDelaySeconds
        }
        guard let previousPackets = lastOutboundVideoPacketsSent,
              let previousDelay =
                lastOutboundVideoTotalPacketSendDelaySeconds else {
            return .unavailableOrReset
        }
        guard packetsSent >= previousPackets,
              totalPacketSendDelaySeconds >= previousDelay else {
            return .unavailableOrReset
        }
        guard packetsSent > previousPackets else {
            return totalPacketSendDelaySeconds == previousDelay
                ? .noNewPackets
                : .unavailableOrReset
        }
        return .measured(
            (totalPacketSendDelaySeconds - previousDelay)
                / Double(packetsSent - previousPackets)
        )
    }
}
