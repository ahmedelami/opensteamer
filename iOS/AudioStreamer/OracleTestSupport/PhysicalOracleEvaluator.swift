import Foundation

private enum PhysicalOracleFields {
    static func parse(
        _ value: String,
        requiredKeys: Set<String>
    ) -> [String: String]? {
        var fields: [String: String] = [:]
        for component in value.split(separator: "|", omittingEmptySubsequences: false) {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            let key = String(pair[0])
            guard !key.isEmpty, fields[key] == nil else { return nil }
            fields[key] = String(pair[1])
        }
        guard fields["v"] == "1", Set(fields.keys) == requiredKeys else { return nil }
        return fields
    }
}

struct PhysicalAudioPlayoutSnapshot: Equatable {
    let sessionGeneration: UUID
    let callbackCount: UInt64
    let frameCount: UInt64
    let failureCount: UInt64
    let pcmSampleCount: UInt64
    let pcmNonzeroSampleCount: UInt64
    let pcmAbsoluteSampleSum: UInt64
    let pcmLeftAbsoluteSampleSum: UInt64
    let pcmRightAbsoluteSampleSum: UInt64
    let pcmStereoDifferenceAbsoluteSampleSum: UInt64
    let pcmClippedSampleCount: UInt64
    let explicitSilenceCallbackCount: UInt64
    let callbackGapViolationCount: UInt64
    let maximumCallbackGapNanoseconds: UInt64
    let nearSilenceCallbackCount: UInt64
    let currentConsecutiveNearSilenceFrameCount: UInt64
    let maximumConsecutiveNearSilenceFrameCount: UInt64
    let pcmLeftZeroCrossingCount: UInt64
    let pcmRightZeroCrossingCount: UInt64
    let pcmEnvelopeTransitionCount: UInt64
    let pcmShapeAnomalyCallbackCount: UInt64
    let pcmBoundaryDiscontinuityCallbackCount: UInt64
    let lastCallbackMeanMagnitude: UInt32
    let recoveryRebuildCount: UInt64
    let lastPeakMagnitude: UInt32
    let inboundAudioEnergy: Double
    let inboundSamplesDuration: Double
    let fullQualityInvariantsHold: Bool

    init?(accessibilityValue: String) {
        guard let fields = PhysicalOracleFields.parse(
            accessibilityValue,
            requiredKeys: [
                "v", "session", "callbacks", "frames", "failures", "pcmSamples",
                "pcmNonzero", "pcmAbs", "pcmLeftAbs", "pcmRightAbs",
                "pcmStereoDiffAbs", "pcmClipped", "silenceCallbacks",
                "gapViolations", "maxGapNs", "nearSilenceCallbacks",
                "currentNearSilenceFrames", "maxNearSilenceFrames",
                "leftCrossings", "rightCrossings", "envelopeTransitions",
                "shapeAnomalies", "boundaryDiscontinuities", "callbackMean",
                "rebuilds", "peak",
                "inboundEnergy", "inboundDuration", "fullQuality",
            ]
        ), let session = fields["session"].flatMap(UUID.init(uuidString:)),
           let callbacks = fields["callbacks"].flatMap(UInt64.init),
           let frames = fields["frames"].flatMap(UInt64.init),
           let failures = fields["failures"].flatMap(UInt64.init),
           let pcmSamples = fields["pcmSamples"].flatMap(UInt64.init),
           let pcmNonzero = fields["pcmNonzero"].flatMap(UInt64.init),
           let pcmAbsolute = fields["pcmAbs"].flatMap(UInt64.init),
           let pcmLeftAbsolute = fields["pcmLeftAbs"].flatMap(UInt64.init),
           let pcmRightAbsolute = fields["pcmRightAbs"].flatMap(UInt64.init),
           let pcmStereoDifferenceAbsolute = fields["pcmStereoDiffAbs"].flatMap(UInt64.init),
           let pcmClipped = fields["pcmClipped"].flatMap(UInt64.init),
           let silenceCallbacks = fields["silenceCallbacks"].flatMap(UInt64.init),
           let gapViolations = fields["gapViolations"].flatMap(UInt64.init),
           let maxGap = fields["maxGapNs"].flatMap(UInt64.init),
           let nearSilenceCallbacks = fields["nearSilenceCallbacks"].flatMap(UInt64.init),
           let currentNearSilenceFrames = fields["currentNearSilenceFrames"].flatMap(UInt64.init),
           let maxNearSilenceFrames = fields["maxNearSilenceFrames"].flatMap(UInt64.init),
           let leftCrossings = fields["leftCrossings"].flatMap(UInt64.init),
           let rightCrossings = fields["rightCrossings"].flatMap(UInt64.init),
           let envelopeTransitions = fields["envelopeTransitions"].flatMap(UInt64.init),
           let shapeAnomalies = fields["shapeAnomalies"].flatMap(UInt64.init),
           let boundaryDiscontinuities = fields["boundaryDiscontinuities"].flatMap(UInt64.init),
           let callbackMean = fields["callbackMean"].flatMap(UInt32.init),
           let rebuilds = fields["rebuilds"].flatMap(UInt64.init),
           let peak = fields["peak"].flatMap(UInt32.init),
           let inboundEnergy = fields["inboundEnergy"].flatMap(Double.init),
           let inboundDuration = fields["inboundDuration"].flatMap(Double.init),
           inboundEnergy.isFinite, inboundEnergy >= 0,
           inboundDuration.isFinite, inboundDuration >= 0,
           let qualityText = fields["fullQuality"],
           qualityText == "0" || qualityText == "1" else {
            return nil
        }
        sessionGeneration = session
        callbackCount = callbacks
        frameCount = frames
        failureCount = failures
        pcmSampleCount = pcmSamples
        pcmNonzeroSampleCount = pcmNonzero
        pcmAbsoluteSampleSum = pcmAbsolute
        pcmLeftAbsoluteSampleSum = pcmLeftAbsolute
        pcmRightAbsoluteSampleSum = pcmRightAbsolute
        pcmStereoDifferenceAbsoluteSampleSum = pcmStereoDifferenceAbsolute
        pcmClippedSampleCount = pcmClipped
        explicitSilenceCallbackCount = silenceCallbacks
        callbackGapViolationCount = gapViolations
        maximumCallbackGapNanoseconds = maxGap
        nearSilenceCallbackCount = nearSilenceCallbacks
        currentConsecutiveNearSilenceFrameCount = currentNearSilenceFrames
        maximumConsecutiveNearSilenceFrameCount = maxNearSilenceFrames
        pcmLeftZeroCrossingCount = leftCrossings
        pcmRightZeroCrossingCount = rightCrossings
        pcmEnvelopeTransitionCount = envelopeTransitions
        pcmShapeAnomalyCallbackCount = shapeAnomalies
        pcmBoundaryDiscontinuityCallbackCount = boundaryDiscontinuities
        lastCallbackMeanMagnitude = callbackMean
        recoveryRebuildCount = rebuilds
        lastPeakMagnitude = peak
        inboundAudioEnergy = inboundEnergy
        inboundSamplesDuration = inboundDuration
        fullQualityInvariantsHold = qualityText == "1"
    }
}

enum PhysicalAudioPlayoutDelta: Equatable {
    case advancing
    case invalidPCMStructure
    case invalidInboundStructure
    case sessionChanged
    case callbackCounterRegressed
    case frameCounterRegressed
    case failureCounterChanged
    case renderFailurePresent
    case fullQualityMissing
    case callbackCounterStalled
    case frameCounterStalled
    case pcmCounterRegressed
    case pcmContentStalled
    case clippedSamplesPresent
    case explicitSilencePresent
    case callbackGapDetected
    case nearSilenceDetected
    case audioUnitRebuilt
    case inboundCounterRegressed
    case inboundContentStalled
    case peakMissing
}

enum PhysicalAudioPlayoutEvaluator {
    /// RemoteIO is configured for 10 ms callbacks. A 25 ms boundary tolerates one late callback
    /// while making two-or-more missed callback intervals machine-visible.
    static let maximumPermittedCallbackGapNanoseconds: UInt64 = 25_000_000

    static func hasValidStructure(_ snapshot: PhysicalAudioPlayoutSnapshot) -> Bool {
        guard snapshot.pcmNonzeroSampleCount <= snapshot.pcmSampleCount,
              snapshot.pcmClippedSampleCount <= snapshot.pcmSampleCount,
              snapshot.explicitSilenceCallbackCount <= snapshot.callbackCount,
              snapshot.callbackGapViolationCount <= snapshot.callbackCount,
              snapshot.nearSilenceCallbackCount <= snapshot.callbackCount,
              snapshot.currentConsecutiveNearSilenceFrameCount
                <= snapshot.maximumConsecutiveNearSilenceFrameCount,
              snapshot.maximumConsecutiveNearSilenceFrameCount <= snapshot.frameCount,
              snapshot.pcmLeftZeroCrossingCount <= snapshot.frameCount,
              snapshot.pcmRightZeroCrossingCount <= snapshot.frameCount,
              snapshot.pcmEnvelopeTransitionCount <= snapshot.callbackCount,
              snapshot.pcmShapeAnomalyCallbackCount <= snapshot.callbackCount,
              snapshot.pcmBoundaryDiscontinuityCallbackCount <= snapshot.callbackCount,
              snapshot.lastCallbackMeanMagnitude <= 32_768,
              snapshot.lastPeakMagnitude <= 32_768,
              snapshot.inboundAudioEnergy <= snapshot.inboundSamplesDuration * 1.05,
              (snapshot.maximumCallbackGapNanoseconds
                    > maximumPermittedCallbackGapNanoseconds)
                == (snapshot.callbackGapViolationCount > 0)
        else { return false }

        // These cumulative native counters are separately atomic. Permit one callback of read
        // skew, but reject impossible accounting relationships by a wide deterministic margin.
        let absolute = Double(snapshot.pcmAbsoluteSampleSum)
        let channelAbsolute = Double(snapshot.pcmLeftAbsoluteSampleSum)
            + Double(snapshot.pcmRightAbsoluteSampleSum)
        let channelAccountingRatio = channelAbsolute / max(1, absolute)
        let stereoDifferenceRatio = Double(snapshot.pcmStereoDifferenceAbsoluteSampleSum)
            / max(1, absolute)
        let renderedSampleRatio = Double(snapshot.pcmSampleCount)
            / max(1, Double(snapshot.frameCount) * 2)
        return (0.95...1.05).contains(channelAccountingRatio)
            && stereoDifferenceRatio <= 1.05
            && (0.95...1.05).contains(renderedSampleRatio)
    }

    static func evaluate(
        previous: PhysicalAudioPlayoutSnapshot,
        current: PhysicalAudioPlayoutSnapshot
    ) -> PhysicalAudioPlayoutDelta {
        guard hasValidStructure(previous) else { return .invalidPCMStructure }
        guard previous.sessionGeneration == current.sessionGeneration else {
            return .sessionChanged
        }
        guard current.callbackCount >= previous.callbackCount else {
            return .callbackCounterRegressed
        }
        guard current.frameCount >= previous.frameCount else {
            return .frameCounterRegressed
        }
        guard current.failureCount == previous.failureCount else {
            return .failureCounterChanged
        }
        guard previous.failureCount == 0 else { return .renderFailurePresent }
        guard previous.fullQualityInvariantsHold,
              current.fullQualityInvariantsHold else {
            return .fullQualityMissing
        }
        guard current.callbackCount > previous.callbackCount else {
            return .callbackCounterStalled
        }
        guard current.frameCount > previous.frameCount else {
            return .frameCounterStalled
        }
        let monotonicPCM = current.pcmSampleCount >= previous.pcmSampleCount
            && current.pcmNonzeroSampleCount >= previous.pcmNonzeroSampleCount
            && current.pcmAbsoluteSampleSum >= previous.pcmAbsoluteSampleSum
            && current.pcmLeftAbsoluteSampleSum >= previous.pcmLeftAbsoluteSampleSum
            && current.pcmRightAbsoluteSampleSum >= previous.pcmRightAbsoluteSampleSum
            && current.pcmStereoDifferenceAbsoluteSampleSum
                >= previous.pcmStereoDifferenceAbsoluteSampleSum
            && current.pcmClippedSampleCount >= previous.pcmClippedSampleCount
            && current.explicitSilenceCallbackCount
                >= previous.explicitSilenceCallbackCount
            && current.callbackGapViolationCount >= previous.callbackGapViolationCount
            && current.maximumCallbackGapNanoseconds
                >= previous.maximumCallbackGapNanoseconds
            && current.nearSilenceCallbackCount >= previous.nearSilenceCallbackCount
            && current.maximumConsecutiveNearSilenceFrameCount
                >= previous.maximumConsecutiveNearSilenceFrameCount
            && current.pcmLeftZeroCrossingCount >= previous.pcmLeftZeroCrossingCount
            && current.pcmRightZeroCrossingCount >= previous.pcmRightZeroCrossingCount
            && current.pcmEnvelopeTransitionCount
                >= previous.pcmEnvelopeTransitionCount
            && current.pcmShapeAnomalyCallbackCount
                >= previous.pcmShapeAnomalyCallbackCount
            && current.pcmBoundaryDiscontinuityCallbackCount
                >= previous.pcmBoundaryDiscontinuityCallbackCount
            && current.recoveryRebuildCount >= previous.recoveryRebuildCount
        guard monotonicPCM else { return .pcmCounterRegressed }
        guard hasValidStructure(current) else {
            let inboundIsValid = current.inboundAudioEnergy
                <= current.inboundSamplesDuration * 1.05
            return inboundIsValid ? .invalidPCMStructure : .invalidInboundStructure
        }
        guard current.pcmSampleCount > previous.pcmSampleCount,
              current.pcmNonzeroSampleCount > previous.pcmNonzeroSampleCount,
              current.pcmAbsoluteSampleSum > previous.pcmAbsoluteSampleSum,
              current.pcmLeftAbsoluteSampleSum > previous.pcmLeftAbsoluteSampleSum,
              current.pcmRightAbsoluteSampleSum > previous.pcmRightAbsoluteSampleSum,
              current.pcmStereoDifferenceAbsoluteSampleSum
                > previous.pcmStereoDifferenceAbsoluteSampleSum else {
            return .pcmContentStalled
        }
        guard current.pcmClippedSampleCount == previous.pcmClippedSampleCount else {
            return .clippedSamplesPresent
        }
        guard current.explicitSilenceCallbackCount
                == previous.explicitSilenceCallbackCount else {
            return .explicitSilencePresent
        }
        guard current.callbackGapViolationCount
                == previous.callbackGapViolationCount else {
            return .callbackGapDetected
        }
        guard current.nearSilenceCallbackCount
                == previous.nearSilenceCallbackCount,
              current.currentConsecutiveNearSilenceFrameCount == 0 else {
            return .nearSilenceDetected
        }
        guard current.recoveryRebuildCount == previous.recoveryRebuildCount else {
            return .audioUnitRebuilt
        }
        guard current.inboundSamplesDuration >= previous.inboundSamplesDuration,
              current.inboundAudioEnergy >= previous.inboundAudioEnergy else {
            return .inboundCounterRegressed
        }
        guard current.inboundSamplesDuration > previous.inboundSamplesDuration,
              current.inboundAudioEnergy > previous.inboundAudioEnergy else {
            return .inboundContentStalled
        }
        guard current.lastPeakMagnitude > 0,
              current.lastCallbackMeanMagnitude > 0 else { return .peakMissing }
        return .advancing
    }

    static func coversElapsedInterval(
        previous: PhysicalAudioPlayoutSnapshot,
        current: PhysicalAudioPlayoutSnapshot,
        elapsed: TimeInterval,
        minimumRealtimeCoverage: Double = 0.70,
        maximumRealtimeCoverage: Double = 1.35,
        minimumNonzeroSampleRatio: Double = 0.90,
        minimumChannelBalance: Double = 0.80,
        minimumStereoDifferenceRatio: Double = 0.35,
        maximumStereoDifferenceRatio: Double = 0.85,
        minimumMeanMagnitude: Double = 256,
        minimumInboundEnergyPerSecond: Double = 0.000_01
    ) -> Bool {
        guard elapsed > 0,
              minimumRealtimeCoverage > 0,
              minimumRealtimeCoverage <= 1,
              maximumRealtimeCoverage >= 1,
              minimumRealtimeCoverage < maximumRealtimeCoverage,
              evaluate(previous: previous, current: current) == .advancing else {
            return false
        }
        let frameDelta = current.frameCount - previous.frameCount
        let pcmSampleDelta = current.pcmSampleCount - previous.pcmSampleCount
        let pcmNonzeroDelta = current.pcmNonzeroSampleCount
            - previous.pcmNonzeroSampleCount
        let pcmAbsoluteDelta = current.pcmAbsoluteSampleSum
            - previous.pcmAbsoluteSampleSum
        let pcmLeftAbsoluteDelta = current.pcmLeftAbsoluteSampleSum
            - previous.pcmLeftAbsoluteSampleSum
        let pcmRightAbsoluteDelta = current.pcmRightAbsoluteSampleSum
            - previous.pcmRightAbsoluteSampleSum
        let pcmStereoDifferenceDelta = current.pcmStereoDifferenceAbsoluteSampleSum
            - previous.pcmStereoDifferenceAbsoluteSampleSum
        let leftCrossingDelta = current.pcmLeftZeroCrossingCount
            - previous.pcmLeftZeroCrossingCount
        let rightCrossingDelta = current.pcmRightZeroCrossingCount
            - previous.pcmRightZeroCrossingCount
        let envelopeTransitionDelta = current.pcmEnvelopeTransitionCount
            - previous.pcmEnvelopeTransitionCount
        let inboundDurationDelta = current.inboundSamplesDuration
            - previous.inboundSamplesDuration
        let inboundEnergyDelta = current.inboundAudioEnergy
            - previous.inboundAudioEnergy
        let realtimeFrames = elapsed * 48_000
        let renderedSampleCoverage = Double(pcmSampleDelta) / max(1, Double(frameDelta) * 2)
        let nonzeroRatio = Double(pcmNonzeroDelta) / max(1, Double(pcmSampleDelta))
        let channelBalance = Double(min(pcmLeftAbsoluteDelta, pcmRightAbsoluteDelta))
            / max(1, Double(max(pcmLeftAbsoluteDelta, pcmRightAbsoluteDelta)))
        let channelAccountingRatio = (
            Double(pcmLeftAbsoluteDelta) + Double(pcmRightAbsoluteDelta)
        ) / max(1, Double(pcmAbsoluteDelta))
        let stereoDifferenceRatio = Double(pcmStereoDifferenceDelta)
            / max(1, Double(pcmAbsoluteDelta))
        let meanMagnitude = Double(pcmAbsoluteDelta) / max(1, Double(pcmSampleDelta))
        let leftCrossingsPerSecond = Double(leftCrossingDelta) / elapsed
        let rightCrossingsPerSecond = Double(rightCrossingDelta) / elapsed
        let envelopeTransitionsPerSecond = Double(envelopeTransitionDelta) / elapsed
        return Double(frameDelta) >= realtimeFrames * minimumRealtimeCoverage
            && Double(frameDelta) <= realtimeFrames * maximumRealtimeCoverage
            && renderedSampleCoverage >= 0.95
            && renderedSampleCoverage <= 1.05
            && nonzeroRatio >= minimumNonzeroSampleRatio
            && nonzeroRatio <= 1.05
            && channelBalance >= minimumChannelBalance
            && channelAccountingRatio >= 0.95
            && channelAccountingRatio <= 1.05
            && stereoDifferenceRatio >= minimumStereoDifferenceRatio
            && stereoDifferenceRatio <= maximumStereoDifferenceRatio
            && meanMagnitude >= minimumMeanMagnitude
            && waveformAnomalyRatesAreAcceptable(previous: previous, current: current)
            && (7_000...11_000).contains(leftCrossingsPerSecond)
            && (10_000...15_000).contains(rightCrossingsPerSecond)
            && (0.75...5.0).contains(envelopeTransitionsPerSecond)
            && inboundDurationDelta >= elapsed * minimumRealtimeCoverage
            && inboundDurationDelta <= elapsed * maximumRealtimeCoverage
            && inboundEnergyDelta / elapsed >= minimumInboundEnergyPerSecond
            && inboundEnergyDelta <= inboundDurationDelta * 1.05
    }

    /// The deterministic challenge has two legitimate 500 ms level/frequency boundaries per
    /// second. A three-percent allowance covers those boundary callbacks plus one atomic-read
    /// skew, while persistent flattening or 10 ms phase resets remain orders of magnitude above it.
    static func waveformAnomalyRatesAreAcceptable(
        previous: PhysicalAudioPlayoutSnapshot,
        current: PhysicalAudioPlayoutSnapshot,
        maximumRatio: Double = 0.03
    ) -> Bool {
        guard maximumRatio >= 0, maximumRatio <= 1,
              current.callbackCount > previous.callbackCount,
              current.pcmShapeAnomalyCallbackCount
                >= previous.pcmShapeAnomalyCallbackCount,
              current.pcmBoundaryDiscontinuityCallbackCount
                >= previous.pcmBoundaryDiscontinuityCallbackCount else {
            return false
        }
        let callbackDelta = current.callbackCount - previous.callbackCount
        let permitted = max(1, floor(Double(callbackDelta) * maximumRatio))
        let shapeDelta = current.pcmShapeAnomalyCallbackCount
            - previous.pcmShapeAnomalyCallbackCount
        let boundaryDelta = current.pcmBoundaryDiscontinuityCallbackCount
            - previous.pcmBoundaryDiscontinuityCallbackCount
        return Double(shapeDelta) <= permitted && Double(boundaryDelta) <= permitted
    }
}

enum PhysicalContinuityWindowResult: Equatable {
    case waiting
    case satisfied
    case rejected
}

/// Sequence-level release oracle. The stable window starts on the first verified advancement—not
/// on the baseline read—so a two-second stall followed by one late callback cannot pass.
struct PhysicalAudioContinuityTracker {
    let requiredDuration: TimeInterval
    let maximumProgressGap: TimeInterval
    let expectedSessionGeneration: UUID?
    let minimumAdvancementObservations: Int

    private(set) var latestSnapshot: PhysicalAudioPlayoutSnapshot?
    private var progressOrigin: PhysicalAudioPlayoutSnapshot?
    private var progressStartedAt: TimeInterval?
    private var lastProgressAt: TimeInterval?
    private var advancementObservations = 0

    init(
        requiredDuration: TimeInterval,
        maximumProgressGap: TimeInterval,
        expectedSessionGeneration: UUID? = nil,
        minimumAdvancementObservations: Int = 3
    ) {
        self.requiredDuration = requiredDuration
        self.maximumProgressGap = maximumProgressGap
        self.expectedSessionGeneration = expectedSessionGeneration
        self.minimumAdvancementObservations = minimumAdvancementObservations
    }

    mutating func observe(
        _ snapshot: PhysicalAudioPlayoutSnapshot,
        at now: TimeInterval
    ) -> PhysicalContinuityWindowResult {
        guard expectedSessionGeneration.map({ $0 == snapshot.sessionGeneration }) != false,
              PhysicalAudioPlayoutEvaluator.hasValidStructure(snapshot),
              snapshot.fullQualityInvariantsHold,
              snapshot.failureCount == 0,
              snapshot.currentConsecutiveNearSilenceFrameCount == 0,
              snapshot.lastPeakMagnitude > 0,
              snapshot.lastCallbackMeanMagnitude > 0 else {
            return .rejected
        }
        guard let previous = latestSnapshot else {
            latestSnapshot = snapshot
            lastProgressAt = now
            return .waiting
        }
        guard previous.sessionGeneration == snapshot.sessionGeneration else { return .rejected }

        if snapshot == previous {
            if let lastProgressAt,
               now - lastProgressAt > maximumProgressGap {
                resetProgress(at: snapshot, now: now)
            }
            return .waiting
        }

        guard PhysicalAudioPlayoutEvaluator.evaluate(
            previous: previous,
            current: snapshot
        ) == .advancing,
        PhysicalAudioPlayoutEvaluator.waveformAnomalyRatesAreAcceptable(
            previous: previous,
            current: snapshot
        ) else {
            return .rejected
        }
        if let lastProgressAt,
           now - lastProgressAt > maximumProgressGap {
            resetProgress(at: snapshot, now: now)
            return .waiting
        }

        latestSnapshot = snapshot
        lastProgressAt = now
        if progressStartedAt == nil {
            progressStartedAt = now
            progressOrigin = snapshot
            advancementObservations = 1
            return .waiting
        }
        advancementObservations += 1
        guard let progressStartedAt,
              let progressOrigin else { return .waiting }
        let elapsed = now - progressStartedAt
        guard elapsed >= requiredDuration,
              advancementObservations >= minimumAdvancementObservations else {
            return .waiting
        }
        return PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
            previous: progressOrigin,
            current: snapshot,
            elapsed: elapsed
        ) ? .satisfied : .waiting
    }

    private mutating func resetProgress(
        at snapshot: PhysicalAudioPlayoutSnapshot,
        now: TimeInterval
    ) {
        latestSnapshot = snapshot
        progressOrigin = nil
        progressStartedAt = nil
        lastProgressAt = now
        advancementObservations = 0
    }
}

struct PhysicalVideoRenderSnapshot: Equatable {
    let rendererID: UUID
    let frameCount: UInt64
    let timestampNanoseconds: Int64
    let width: Int
    let height: Int
    let contentDigest: UInt64
    let contentSampleCount: UInt64
    let contentChangeCount: UInt64

    init?(accessibilityValue: String) {
        guard let fields = PhysicalOracleFields.parse(
            accessibilityValue,
            requiredKeys: [
                "v", "renderer", "frames", "timestampNs", "width", "height",
                "contentDigest", "contentSamples", "contentChanges",
            ]
        ), let renderer = fields["renderer"].flatMap(UUID.init(uuidString:)),
           let frames = fields["frames"].flatMap(UInt64.init),
           let timestamp = fields["timestampNs"].flatMap(Int64.init),
           let width = fields["width"].flatMap(Int.init),
           let height = fields["height"].flatMap(Int.init),
           let contentDigest = fields["contentDigest"].flatMap(UInt64.init),
           let contentSamples = fields["contentSamples"].flatMap(UInt64.init),
           let contentChanges = fields["contentChanges"].flatMap(UInt64.init) else {
            return nil
        }
        rendererID = renderer
        frameCount = frames
        timestampNanoseconds = timestamp
        self.width = width
        self.height = height
        self.contentDigest = contentDigest
        contentSampleCount = contentSamples
        contentChangeCount = contentChanges
    }
}

enum PhysicalVideoRenderDelta: Equatable {
    case advancing
    case rendererChanged
    case frameCounterRegressed
    case frameCounterStalled
    case timestampRegressed
    case timestampStalled
    case invalidDimensions
    case dimensionsChanged
    case invalidContentEvidence
    case contentSampleCounterRegressed
    case contentSampleCounterStalled
    case contentChangeCounterRegressed
    case contentChangeCounterImpossible
    case contentDigestChangeUnaccounted
    case contentUnchanged
}

enum PhysicalVideoRenderEvaluator {
    static func evaluate(
        previous: PhysicalVideoRenderSnapshot,
        current: PhysicalVideoRenderSnapshot
    ) -> PhysicalVideoRenderDelta {
        guard previous.rendererID == current.rendererID else { return .rendererChanged }
        guard previous.width >= 320, previous.height >= 180,
              current.width >= 320, current.height >= 180 else {
            return .invalidDimensions
        }
        guard previous.width == current.width,
              previous.height == current.height else { return .dimensionsChanged }
        guard contentEvidenceIsStructurallyValid(previous),
              contentEvidenceIsStructurallyValid(current) else {
            return .invalidContentEvidence
        }
        guard current.frameCount >= previous.frameCount else {
            return .frameCounterRegressed
        }
        guard current.timestampNanoseconds >= previous.timestampNanoseconds else {
            return .timestampRegressed
        }
        guard current.frameCount > previous.frameCount else { return .frameCounterStalled }
        guard current.timestampNanoseconds > previous.timestampNanoseconds else {
            return .timestampStalled
        }
        guard current.contentSampleCount >= previous.contentSampleCount else {
            return .contentSampleCounterRegressed
        }
        guard current.contentSampleCount > previous.contentSampleCount else {
            return .contentSampleCounterStalled
        }
        guard current.contentChangeCount >= previous.contentChangeCount else {
            return .contentChangeCounterRegressed
        }
        let sampleDelta = current.contentSampleCount - previous.contentSampleCount
        let changeDelta = current.contentChangeCount - previous.contentChangeCount
        let frameDelta = current.frameCount - previous.frameCount
        guard sampleDelta <= frameDelta else { return .contentChangeCounterImpossible }
        guard changeDelta <= sampleDelta else { return .contentChangeCounterImpossible }
        let digestChanged = current.contentDigest != previous.contentDigest
        if digestChanged, changeDelta == 0 {
            return .contentDigestChangeUnaccounted
        }
        // If the endpoint digest returned to its prior value, at least two sampled changes must
        // have occurred (A -> B -> A). One claimed change cannot produce equal endpoints.
        if !digestChanged, changeDelta == 1 {
            return .contentChangeCounterImpossible
        }
        guard changeDelta > 0 else { return .contentUnchanged }
        return .advancing
    }

    static func coversElapsedInterval(
        previous: PhysicalVideoRenderSnapshot,
        current: PhysicalVideoRenderSnapshot,
        elapsed: TimeInterval,
        minimumFramesPerSecond: Double = 12
    ) -> Bool {
        guard elapsed > 0,
              evaluate(previous: previous, current: current) == .advancing else {
            return false
        }
        let frameDelta = current.frameCount - previous.frameCount
        let timestampDelta = current.timestampNanoseconds - previous.timestampNanoseconds
        let contentSampleDelta = current.contentSampleCount - previous.contentSampleCount
        let contentChangeDelta = current.contentChangeCount - previous.contentChangeCount
        return Double(frameDelta) >= elapsed * minimumFramesPerSecond
            && Double(frameDelta) <= elapsed * 120
            && Double(timestampDelta) >= elapsed * 500_000_000
            && Double(timestampDelta) <= elapsed * 1_500_000_000
            && Double(contentSampleDelta) >= elapsed * 3
            && Double(contentChangeDelta) >= elapsed * 3
            && contentChangeDelta <= contentSampleDelta
    }

    static func contentEvidenceIsStructurallyValid(
        _ snapshot: PhysicalVideoRenderSnapshot
    ) -> Bool {
        snapshot.contentSampleCount > 0
            && snapshot.contentSampleCount <= snapshot.frameCount
            && snapshot.contentChangeCount < snapshot.contentSampleCount
    }
}

struct PhysicalVideoContinuityTracker {
    let requiredDuration: TimeInterval
    let maximumProgressGap: TimeInterval
    let minimumAdvancementObservations: Int

    private(set) var latestSnapshot: PhysicalVideoRenderSnapshot?
    private var progressOrigin: PhysicalVideoRenderSnapshot?
    private var progressStartedAt: TimeInterval?
    private var lastProgressAt: TimeInterval?
    private var advancementObservations = 0

    init(
        requiredDuration: TimeInterval,
        maximumProgressGap: TimeInterval,
        minimumAdvancementObservations: Int = 3
    ) {
        self.requiredDuration = requiredDuration
        self.maximumProgressGap = maximumProgressGap
        self.minimumAdvancementObservations = minimumAdvancementObservations
    }

    mutating func observe(
        _ snapshot: PhysicalVideoRenderSnapshot,
        at now: TimeInterval
    ) -> PhysicalContinuityWindowResult {
        guard snapshot.width >= 320, snapshot.height >= 180,
              PhysicalVideoRenderEvaluator.contentEvidenceIsStructurallyValid(snapshot) else {
            return .rejected
        }
        guard let previous = latestSnapshot else {
            latestSnapshot = snapshot
            lastProgressAt = now
            return .waiting
        }
        guard previous.rendererID == snapshot.rendererID else { return .rejected }
        if snapshot == previous {
            if let lastProgressAt,
               now - lastProgressAt > maximumProgressGap {
                resetProgress(at: snapshot, now: now)
            }
            return .waiting
        }
        let delta = PhysicalVideoRenderEvaluator.evaluate(
            previous: previous,
            current: snapshot
        )
        guard delta == .advancing || delta == .contentUnchanged else {
            return .rejected
        }
        latestSnapshot = snapshot
        if delta == .contentUnchanged {
            if let lastProgressAt,
               now - lastProgressAt > maximumProgressGap {
                resetProgress(at: snapshot, now: now)
            }
            return .waiting
        }
        if let lastProgressAt,
           now - lastProgressAt > maximumProgressGap {
            resetProgress(at: snapshot, now: now)
            return .waiting
        }
        lastProgressAt = now
        if progressStartedAt == nil {
            progressStartedAt = now
            progressOrigin = snapshot
            advancementObservations = 1
            return .waiting
        }
        advancementObservations += 1
        guard let progressStartedAt,
              let progressOrigin else { return .waiting }
        let elapsed = now - progressStartedAt
        guard elapsed >= requiredDuration,
              advancementObservations >= minimumAdvancementObservations else {
            return .waiting
        }
        return PhysicalVideoRenderEvaluator.coversElapsedInterval(
            previous: progressOrigin,
            current: snapshot,
            elapsed: elapsed
        ) ? .satisfied : .waiting
    }

    private mutating func resetProgress(
        at snapshot: PhysicalVideoRenderSnapshot,
        now: TimeInterval
    ) {
        latestSnapshot = snapshot
        progressOrigin = nil
        progressStartedAt = nil
        lastProgressAt = now
        advancementObservations = 0
    }
}

struct PhysicalScreenAcknowledgementSnapshot: Equatable {
    enum Command: String, Equatable {
        case show
        case hide
    }

    enum State: String, Equatable {
        case active
        case inactive
    }

    let sessionGeneration: UUID
    let requestID: UInt64
    let command: Command
    let state: State

    init?(accessibilityValue: String) {
        guard let fields = PhysicalOracleFields.parse(
            accessibilityValue,
            requiredKeys: ["v", "session", "request", "command", "state"]
        ), let session = fields["session"].flatMap(UUID.init(uuidString:)),
           let request = fields["request"].flatMap(UInt64.init),
           let command = fields["command"].flatMap(Command.init(rawValue:)),
           let state = fields["state"].flatMap(State.init(rawValue:)) else {
            return nil
        }
        sessionGeneration = session
        requestID = request
        self.command = command
        self.state = state
    }
}
