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

/// Converts transport capacity into a stable, single-layer screen-video encoding ceiling.
struct WorldwideScreenVideoAdaptationPolicy: Equatable, Sendable {
    static let requiredHealthyUpgradeSampleCount = 8
    static let unavailableBandwidthDowngradeSampleCount = 3

    private static let minimumVideoBitrateBps = 32_000
    private static let audioAndControlReserveBps = 320_000.0
    private static let referenceMaximumVideoBitrateBps = 9_344_000
    private static let downgradeHeadroomMultiplier = 1.25
    private static let upgradeMarginMultiplier = 1.35
    private static let roundTripTimeRelativeInflationMultiplier = 1.5
    private static let roundTripTimeAbsoluteInflationSeconds = 0.050
    private static let maximumRoundTripTimeBaselineFallPerSample = 0.010
    private static let roundTripTimeBootstrapSampleCount = 3
    private static let maximumAveragePacketSendDelaySeconds = 0.100

    let configuredTotalRTPBitrateBps: Int
    let maximumTierVideoBitrateBps: Int
    let baseFramesPerSecond: Int
    private(set) var peerGeneration: UInt64?
    private(set) var currentTier: WorldwideScreenVideoAdaptationTier
    private(set) var healthyUpgradeSampleCount = 0
    private(set) var unavailableBandwidthSampleCount = 0
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
            Self.referenceVideoBitrateBps(for: tier)
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
        healthyUpgradeSampleCount = 0
        unavailableBandwidthSampleCount = 0
        roundTripTimeBaselineSeconds = nil
        roundTripTimeBootstrapSamples = []
        selectedRoute = nil
        lastOutboundVideoPacketsSent = nil
        lastOutboundVideoTotalPacketSendDelaySeconds = nil
        return true
    }

    /// Clears latency history when ICE invalidates the selected path, while retaining the
    /// conservative quality tier learned for this peer lifetime.
    mutating func invalidateSelectedRoute() {
        selectedRoute = nil
        resetPathMeasurements()
    }

    /// Returns a recommendation only when the current sender should apply new limits.
    mutating func update(
        peerGeneration generation: UInt64,
        isCaptureActive: Bool,
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
            resetPathMeasurements()
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
        let packetQueueIsInflated = averagePacketSendDelaySeconds.map {
            $0 > Self.maximumAveragePacketSendDelaySeconds
        } ?? false
        let latencyPressure = roundTripTimeIsInflated || packetQueueIsInflated

        guard let availableOutgoingBitrateBps,
              availableOutgoingBitrateBps.isFinite,
              availableOutgoingBitrateBps > 0 else {
            healthyUpgradeSampleCount = 0
            unavailableBandwidthSampleCount = min(
                Self.unavailableBandwidthDowngradeSampleCount,
                unavailableBandwidthSampleCount + 1
            )
            let unavailableTooLong = unavailableBandwidthSampleCount
                >= Self.unavailableBandwidthDowngradeSampleCount
            guard latencyPressure || unavailableTooLong,
                  let lowerTier = currentTier.nextLowerQuality else {
                return isCaptureActive && didResetForNewPeer
                    ? currentRecommendation
                    : nil
            }
            currentTier = lowerTier
            if unavailableTooLong {
                unavailableBandwidthSampleCount = 0
            }
            return isCaptureActive ? currentRecommendation : nil
        }
        unavailableBandwidthSampleCount = 0

        var sustainableTier = sustainableTier(
            for: availableOutgoingBitrateBps
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

        guard let upgradeTier = currentTier.nextHigherQuality else {
            healthyUpgradeSampleCount = 0
            return isCaptureActive && didResetForNewPeer
                ? currentRecommendation
                : nil
        }
        let requiredUpgradeBitrate = requiredOutgoingBitrateBps(
            for: upgradeTier
        )
        guard requiredUpgradeBitrate
                <= Double(configuredTotalRTPBitrateBps) else {
            healthyUpgradeSampleCount = 0
            return isCaptureActive && didResetForNewPeer
                ? currentRecommendation
                : nil
        }
        let upgradeThreshold = min(
            Double(configuredTotalRTPBitrateBps),
            requiredUpgradeBitrate * Self.upgradeMarginMultiplier
        )
        guard availableOutgoingBitrateBps >= upgradeThreshold,
              !latencyPressure,
              roundTripTimeAllowsUpgrade(currentRoundTripTimeSeconds) else {
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
        currentTier = upgradeTier
        healthyUpgradeSampleCount = 0
        return isCaptureActive ? currentRecommendation : nil
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

    private func requiredOutgoingBitrateBps(
        for tier: WorldwideScreenVideoAdaptationTier
    ) -> Double {
        let referenceVideoBitrate = Self.referenceVideoBitrateBps(
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
                let referenceVideoBitrate = referenceVideoBitrateBps(
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

    private static func referenceVideoBitrateBps(
        for tier: WorldwideScreenVideoAdaptationTier
    ) -> Int {
        max(
            minimumVideoBitrateBps,
            referenceMaximumVideoBitrateBps
                * tier.bitrateBasisPoints / 10_000
        )
    }

    private mutating func resetPathMeasurements() {
        healthyUpgradeSampleCount = 0
        unavailableBandwidthSampleCount = 0
        roundTripTimeBaselineSeconds = nil
        roundTripTimeBootstrapSamples = []
        lastOutboundVideoPacketsSent = nil
        lastOutboundVideoTotalPacketSendDelaySeconds = nil
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
