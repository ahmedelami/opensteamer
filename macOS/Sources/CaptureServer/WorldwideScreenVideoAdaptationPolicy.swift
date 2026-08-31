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
    let maximumFramesPerSecond: Int
    let scaleResolutionDownBy: Double

    var webRTCLimits: WebRTCScreenVideoEncodingLimits {
        WebRTCScreenVideoEncodingLimits(
            maximumBitrateBps: maximumBitrateBps,
            maximumFramesPerSecond: maximumFramesPerSecond,
            scaleResolutionDownBy: scaleResolutionDownBy
        )
    }
}

enum WorldwideScreenVideoAutomaticSuspensionDecision: Equatable, Sendable {
    case suspend
    case resume
}

/// Converts transport capacity into a stable, single-layer screen-video encoding ceiling.
struct WorldwideScreenVideoAdaptationPolicy: Equatable, Sendable {
    private struct AutomaticResumeProbeRestoration: Equatable, Sendable {
        let belowReserveProbeDisprovedSenderLimitation: Bool
        let applicationLimitedProbeCooldownSamplesRemaining: Int
        let applicationLimitedProbeFailureCount: Int
    }

    static let requiredHealthyUpgradeSampleCount = 8
    static let requiredPositiveBandwidthBootstrapSampleCount = 3
    static let requiredApplicationLimitedUpgradeSampleCount = 4
    static let applicationLimitedProbeGraceSampleCount = 5
    static let initialApplicationLimitedProbeCooldownSampleCount = 8
    static let maximumApplicationLimitedProbeCooldownSampleCount = 64
    /// When native candidate-pair bandwidth is unavailable, use a slower additive probe backed by
    /// both a stable RTT baseline and advancing low-delay outbound packets. This prevents an
    /// optional stats field from pinning a healthy session at its conservative startup tier.
    static let requiredUnavailableBandwidthUpgradeSampleCount = 4
    static let requiredSuspensionPressureSampleCount = 3
    /// A paused sender cannot produce a useful outbound bitrate estimate. Even when the last
    /// estimate remains positive-but-low, a long latency-stable window permits one bounded probe;
    /// a failed probe resets this counter and therefore supplies the same full cooldown again.
    static let requiredStableSuspensionResumeProbeSampleCount = 16
    static let requiredMaximumSuspensionResumeProbeSampleCount = 64

    private static let minimumVideoBitrateBps = 32_000
    private static let audioAndControlReserveBps = 320_000.0
    private static let baselineReferenceMaximumVideoBitrateBps = 9_344_000
    private static let downgradeHeadroomMultiplier = 1.25
    private static let upgradeMarginMultiplier = 1.35
    /// The native controller is capped at the same configured total. Treat a small estimator gap
    /// at that ceiling as cap saturation rather than requiring an exact floating-point sample.
    private static let configuredCapacitySaturationRatio = 0.95
    private static let applicationLimitedSaturationRatio = 0.85
    private static let applicationLimitedProbeImmediateAbortRatio = 0.75
    private static let roundTripTimeRelativeInflationMultiplier = 1.5
    private static let roundTripTimeAbsoluteInflationSeconds = 0.050
    private static let maximumRoundTripTimeBaselineFallPerSample = 0.010
    private static let roundTripTimeBootstrapSampleCount = 3
    private static let maximumAveragePacketSendDelaySeconds = 0.100
    private static let maximumUpgradePacketSendDelaySeconds = 0.020

    let configuredTotalRTPBitrateBps: Int
    let maximumTierVideoBitrateBps: Int
    let baseFramesPerSecond: Int
    private(set) var peerGeneration: UInt64?
    private(set) var currentTier: WorldwideScreenVideoAdaptationTier
    private(set) var healthyUpgradeSampleCount = 0
    private(set) var unavailableBandwidthSampleCount = 0
    private(set) var positiveBandwidthBootstrapSampleCount = 0
    private(set) var applicationLimitedUpgradeSampleCount = 0
    private(set) var applicationLimitedProbeGraceSamplesRemaining = 0
    private(set) var applicationLimitedProbeCooldownSamplesRemaining = 0
    private(set) var applicationLimitedProbeFailureCount = 0
    private(set) var belowReserveProbeDisprovedSenderLimitation = false
    private var automaticResumeProbeRestoration:
        AutomaticResumeProbeRestoration?
    private(set) var applicationLimitedProbeOriginTier:
        WorldwideScreenVideoAdaptationTier?
    private(set) var automaticSuspensionPressureSampleCount = 0
    private(set) var stableSuspensionResumeProbeSampleCount = 0
    private(set) var maximumSuspensionResumeProbeSampleCount = 0
    private(set) var bandwidthEstimateIsUnavailable = false
    private(set) var lastSampleHasLatencyPressure = false
    private(set) var lastSampleHasPositiveSuspensionPressure = false
    private(set) var lastAveragePacketSendDelaySeconds: Double?
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
        recommendation(for: currentTier)
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

    /// Returns a recommendation only when the current sender should apply new limits.
    mutating func update(
        peerGeneration generation: UInt64,
        isCaptureActive: Bool,
        isAutomaticallySuspended: Bool = false,
        availableOutgoingBitrateBps: Double?,
        currentRoundTripTimeSeconds: Double?,
        selectedRoute: WebRTCICERouteDiagnostics? = nil,
        outboundVideoPacketsSent: UInt64? = nil,
        outboundVideoTotalPacketSendDelaySeconds: Double? = nil
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
        let averagePacketSendDelaySeconds =
            averagePacketSendDelaySinceLastSample(
                packetsSent: outboundVideoPacketsSent,
                totalPacketSendDelaySeconds:
                    outboundVideoTotalPacketSendDelaySeconds
            )
        lastAveragePacketSendDelaySeconds = averagePacketSendDelaySeconds
        let packetQueueIsInflated = averagePacketSendDelaySeconds.map {
            $0 > Self.maximumAveragePacketSendDelaySeconds
        } ?? false
        let packetQueueAllowsUpgrade = averagePacketSendDelaySeconds.map {
            $0 <= Self.maximumUpgradePacketSendDelaySeconds
        } ?? false
        let roundTripTimeAllowsUpgrade = roundTripTimeAllowsUpgrade(
            currentRoundTripTimeSeconds
        )
        let directUpgradeEvidenceIsHealthy = averagePacketSendDelaySeconds.map {
            $0 <= Self.maximumUpgradePacketSendDelaySeconds
                && (currentRoundTripTimeSeconds == nil
                    || roundTripTimeAllowsUpgrade)
        } ?? roundTripTimeAllowsUpgrade
        let latencyPressure = roundTripTimeIsInflated || packetQueueIsInflated
        lastSampleHasLatencyPressure = latencyPressure

        guard let availableOutgoingBitrateBps,
              availableOutgoingBitrateBps.isFinite,
              availableOutgoingBitrateBps > 0 else {
            applicationLimitedUpgradeSampleCount = 0
            if let probeOriginTier = applicationLimitedProbeOriginTier {
                if latencyPressure {
                    failApplicationLimitedProbe(
                        revertingTo: probeOriginTier
                    )
                } else if applicationLimitedProbeGraceSamplesRemaining > 1 {
                    applicationLimitedProbeGraceSamplesRemaining -= 1
                    lastSampleHasPositiveSuspensionPressure = false
                    return isCaptureActive && didResetForNewPeer
                        ? currentRecommendation
                        : nil
                } else {
                    failApplicationLimitedProbe(
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
                return isCaptureActive ? currentRecommendation : nil
            }
            if applicationLimitedProbeCooldownSamplesRemaining > 0 {
                applicationLimitedProbeCooldownSamplesRemaining -= 1
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

        let strictUpgradeEvidenceIsHealthy = packetQueueAllowsUpgrade
            && roundTripTimeAllowsUpgrade
        if let probeOriginTier = applicationLimitedProbeOriginTier {
            let probeCapacityCollapsed =
                effectiveAvailableOutgoingBitrateBps
                    < max(
                        requiredAudioPriorityBitrateBps,
                        Double(
                            recommendation(for: probeOriginTier)
                                .maximumBitrateBps
                        ) * Self.applicationLimitedProbeImmediateAbortRatio
                    )
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
            } else if estimatorMayBeApplicationLimited,
                      strictUpgradeEvidenceIsHealthy {
                completeApplicationLimitedProbe()
                lastSampleHasPositiveSuspensionPressure = false
                return isCaptureActive && didResetForNewPeer
                    ? currentRecommendation
                    : nil
            } else if applicationLimitedProbeGraceSamplesRemaining > 1 {
                applicationLimitedProbeGraceSamplesRemaining -= 1
                applicationLimitedUpgradeSampleCount = 0
                lastSampleHasPositiveSuspensionPressure = false
                return isCaptureActive && didResetForNewPeer
                    ? currentRecommendation
                    : nil
            } else {
                failApplicationLimitedProbe(revertingTo: probeOriginTier)
                lastSampleHasPositiveSuspensionPressure = false
                return isCaptureActive ? currentRecommendation : nil
            }
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
            && independentlyQualifiedUpgradeTier == nil
            && estimatorMayBeApplicationLimited
            && senderLimitedEstimateCanHoldCurrentTier
        if applicationLimitedHoldIsHealthy {
            guard currentTier.nextHigherQuality != nil else {
                applicationLimitedUpgradeSampleCount = 0
                lastSampleHasPositiveSuspensionPressure = false
                return isCaptureActive && didResetForNewPeer
                    ? currentRecommendation
                    : nil
            }
            guard applicationLimitedProbeCooldownSamplesRemaining == 0 else {
                applicationLimitedProbeCooldownSamplesRemaining -= 1
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
                if let probeTier = currentTier.nextHigherQuality,
                   requiredOutgoingBitrateBps(for: probeTier)
                    <= Double(configuredTotalRTPBitrateBps) {
                    applicationLimitedProbeOriginTier = currentTier
                    currentTier = probeTier
                    applicationLimitedProbeGraceSamplesRemaining =
                        Self.applicationLimitedProbeGraceSampleCount
                    healthyUpgradeSampleCount = 0
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

        lastSampleHasPositiveSuspensionPressure = latencyPressure
            || effectiveAvailableOutgoingBitrateBps
                < requiredOutgoingBitrateBps(for: .audioPriority)

        var sustainableTier = sustainableTier(
            for: effectiveAvailableOutgoingBitrateBps
        )
        if latencyPressure,
           let lowerTier = currentTier.nextLowerQuality,
           lowerTier.rawValue > sustainableTier.rawValue {
            sustainableTier = lowerTier
        }
        if sustainableTier.rawValue > currentTier.rawValue {
            currentTier = sustainableTier
            healthyUpgradeSampleCount = 0
            return isCaptureActive ? currentRecommendation : nil
        }

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
        guard healthyUpgradeSampleCount
                >= Self.requiredHealthyUpgradeSampleCount else {
            return isCaptureActive && didResetForNewPeer
                ? currentRecommendation
                : nil
        }
        // The estimate already proves this target with both downgrade headroom and its own
        // upgrade margin. Select the highest independently qualified tier so crossing into the
        // next tier's raw sustainable band can never make recovery worse.
        currentTier = upgradeTier
        healthyUpgradeSampleCount = 0
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
        healthyUpgradeSampleCount = 0
        applicationLimitedUpgradeSampleCount = 0
        applicationLimitedProbeGraceSamplesRemaining = 0
        applicationLimitedProbeOriginTier = nil
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
        let referenceVideoBitrate = referenceVideoBitrateBps(
            for: tier
        )
        let videoBitrate = max(
            referenceVideoBitrate,
            recommendation(for: tier).maximumBitrateBps
        )
        return Double(videoBitrate)
            * Self.downgradeHeadroomMultiplier
            + Self.audioAndControlReserveBps
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

    private func estimatorIsApplicationLimited(
        _ availableOutgoingBitrateBps: Double
    ) -> Bool {
        return availableOutgoingBitrateBps
            >= Double(currentRecommendation.maximumBitrateBps)
                * Self.applicationLimitedSaturationRatio
    }

    private mutating func completeApplicationLimitedProbe() {
        applicationLimitedProbeOriginTier = nil
        applicationLimitedProbeGraceSamplesRemaining = 0
        applicationLimitedUpgradeSampleCount = 0
        belowReserveProbeDisprovedSenderLimitation = false
        automaticResumeProbeRestoration = nil
        resetApplicationLimitedProbeBackoff()
    }

    private mutating func revertApplicationLimitedProbeIfActive() {
        guard let applicationLimitedProbeOriginTier else { return }
        currentTier = applicationLimitedProbeOriginTier
    }

    private mutating func failApplicationLimitedProbe(
        revertingTo originTier: WorldwideScreenVideoAdaptationTier
    ) {
        currentTier = originTier
        applicationLimitedProbeOriginTier = nil
        applicationLimitedProbeGraceSamplesRemaining = 0
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
        unavailableBandwidthSampleCount = 0
        positiveBandwidthBootstrapSampleCount = 0
        applicationLimitedUpgradeSampleCount = 0
        applicationLimitedProbeGraceSamplesRemaining = 0
        applicationLimitedProbeOriginTier = nil
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

    private mutating func averagePacketSendDelaySinceLastSample(
        packetsSent: UInt64?,
        totalPacketSendDelaySeconds: Double?
    ) -> Double? {
        guard let packetsSent,
              let totalPacketSendDelaySeconds,
              totalPacketSendDelaySeconds.isFinite,
              totalPacketSendDelaySeconds >= 0 else {
            return nil
        }
        defer {
            lastOutboundVideoPacketsSent = packetsSent
            lastOutboundVideoTotalPacketSendDelaySeconds =
                totalPacketSendDelaySeconds
        }
        guard let previousPackets = lastOutboundVideoPacketsSent,
              let previousDelay =
                lastOutboundVideoTotalPacketSendDelaySeconds,
              packetsSent > previousPackets,
              totalPacketSendDelaySeconds >= previousDelay else {
            return nil
        }
        return (totalPacketSendDelaySeconds - previousDelay)
            / Double(packetsSent - previousPackets)
    }
}
