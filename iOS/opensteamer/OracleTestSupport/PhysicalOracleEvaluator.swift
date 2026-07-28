import Foundation

/// Strict parser for versioned, pipe-delimited accessibility oracle payloads.
/// Requiring the exact key set makes additions an intentional test-contract change and prevents a
/// partially parsed or duplicated field from being accepted as physical evidence.
private enum PhysicalOracleFields {
    static func parse(
        _ value: String,
        requiredKeys: Set<String>,
        expectedVersion: Int = 1
    ) -> [String: String]? {
        var fields: [String: String] = [:]
        for component in value.split(separator: "|", omittingEmptySubsequences: false) {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            let key = String(pair[0])
            guard !key.isEmpty, fields[key] == nil else { return nil }
            fields[key] = String(pair[1])
        }
        guard fields["v"] == String(expectedVersion),
              Set(fields.keys) == requiredKeys else {
            return nil
        }
        return fields
    }
}

/// Strict copy of the privacy-minimal raw-microphone oracle exposed through accessibility.
struct PhysicalRawMicrophoneSnapshot: Equatable {
    private static let schemaVersion = 2
    private static let maximumAccessibilityValueBytes = 1_024

    let applicationProcessIdentifier: Int32
    let sessionGeneration: UUID
    let windowGeneration: UUID
    let transportAuthorizationGeneration: UUID
    let audioPolicyGeneration: UUID
    let negotiationEpoch: UInt64
    let bindingGeneration: UInt64
    let trackGeneration: UInt64
    let microphonePolicyGeneration: UInt64
    let recordingGeneration: UInt64
    let approvedRecordingGeneration: UInt64
    let realtimeAdmissionCount: UInt64
    let deliveryCallbackCount: UInt64
    let deliveredFrameCount: UInt64
    let packetsSent: UInt64
    let bytesSent: UInt64
    let totalAudioEnergy: Double?
    let totalSamplesDuration: Double?
    let coherentSampleCount: UInt64

    init?(accessibilityValue: String) {
        guard accessibilityValue.utf8.count
                <= Self.maximumAccessibilityValueBytes,
              let fields = PhysicalOracleFields.parse(
                accessibilityValue,
                requiredKeys: [
                    "v", "pid", "session", "window", "transport",
                    "audioPolicy", "negotiation", "binding",
                    "track", "micPolicy", "recording", "approved",
                    "admissions", "callbacks", "frames", "packets",
                    "bytes", "energy", "duration", "samples",
                    "paired", "intent", "call", "transportHealthy",
                    "senderOwned", "trackEnabled", "raw", "topology",
                    "deviceOpen", "authorizationOpen", "senderScoped",
                ],
                expectedVersion: Self.schemaVersion
              ),
              fields["paired"] == "1",
              fields["intent"] == "1",
              fields["call"] == "0",
              fields["transportHealthy"] == "1",
              fields["senderOwned"] == "1",
              fields["trackEnabled"] == "1",
              fields["raw"] == "1",
              fields["topology"] == "1",
              fields["deviceOpen"] == "1",
              fields["authorizationOpen"] == "1",
              fields["senderScoped"] == "1",
              let processIdentifierText = fields["pid"],
              let processIdentifier = Int32(processIdentifierText),
              processIdentifier > 0,
              let session = fields["session"]
                .flatMap(UUID.init(uuidString:)),
              let window = fields["window"]
                .flatMap(UUID.init(uuidString:)),
              let transport = fields["transport"]
                .flatMap(UUID.init(uuidString:)),
              let audioPolicy = fields["audioPolicy"]
                .flatMap(UUID.init(uuidString:)) else {
            return nil
        }

        let unsignedKeys = [
            "negotiation", "binding", "track", "micPolicy",
            "recording", "approved", "admissions", "callbacks",
            "frames", "packets", "bytes", "samples",
        ]
        var unsigned: [String: UInt64] = [:]
        for key in unsignedKeys {
            guard let text = fields[key],
                  let value = UInt64(text) else {
                return nil
            }
            unsigned[key] = value
        }

        let energyText = fields["energy"]!
        let durationText = fields["duration"]!
        let energy: Double?
        let duration: Double?
        if energyText == "missing", durationText == "missing" {
            energy = nil
            duration = nil
        } else {
            guard energyText != "missing",
                  durationText != "missing",
                  let parsedEnergy = Double(energyText),
                  let parsedDuration = Double(durationText),
                  parsedEnergy.isFinite,
                  parsedDuration.isFinite,
                  parsedEnergy >= 0,
                  parsedDuration >= 0 else {
                return nil
            }
            energy = parsedEnergy
            duration = parsedDuration
        }

        applicationProcessIdentifier = processIdentifier
        sessionGeneration = session
        windowGeneration = window
        transportAuthorizationGeneration = transport
        audioPolicyGeneration = audioPolicy
        negotiationEpoch = unsigned["negotiation"]!
        bindingGeneration = unsigned["binding"]!
        trackGeneration = unsigned["track"]!
        microphonePolicyGeneration = unsigned["micPolicy"]!
        recordingGeneration = unsigned["recording"]!
        approvedRecordingGeneration = unsigned["approved"]!
        realtimeAdmissionCount = unsigned["admissions"]!
        deliveryCallbackCount = unsigned["callbacks"]!
        deliveredFrameCount = unsigned["frames"]!
        packetsSent = unsigned["packets"]!
        bytesSent = unsigned["bytes"]!
        totalAudioEnergy = energy
        totalSamplesDuration = duration
        coherentSampleCount = unsigned["samples"]!
        guard PhysicalRawMicrophoneEvaluator
                .hasValidStructure(self) else {
            return nil
        }
    }
}

enum PhysicalRawMicrophoneDelta: Equatable {
    case advancing
    case invalidStructure
    case sessionChanged
    case windowChanged
    case transportGenerationChanged
    case audioPolicyGenerationChanged
    case senderBindingChanged
    case invalidElapsed
    case counterRegressed
    case nativeCounterStalled
    case senderCounterStalled
    case insufficientDensity
    case counterLeap
}

private enum PhysicalRawMicrophoneRateAssessment: Equatable {
    case advancing
    case insufficientDensity
    case counterLeap
}

/// Physical-consumer-owned density and upper-rate contract for exact raw microphone evidence.
///
/// The lower bounds are deliberately conservative relative to a live 48 kHz sender, but they are
/// high enough that one callback, frame, packet, or byte cannot certify a multi-second interval.
/// Energy magnitude is intentionally not bounded below because legitimate digital silence remains
/// valid microphone delivery; when audio totals are present, only sample-duration continuity is
/// required.
private enum PhysicalRawMicrophoneRatePolicy {
    static let maximumSampleInterval: TimeInterval = 2.5

    static let minimumRealtimeAdmissionRate = 50.0
    static let minimumDeliveryCallbackRate = 50.0
    static let minimumDeliveredFrameRate = 24_000.0
    static let minimumExactSenderPacketRate = 20.0
    static let minimumExactSenderByteRate = 2_000.0
    static let minimumAudioDurationCoverage = 0.50

    static let maximumRealtimeAdmissionRate = 400.0
    static let maximumDeliveryCallbackRate = 400.0
    static let maximumDeliveredFrameRate = 72_000.0
    static let maximumExactSenderPacketRate = 500.0
    static let maximumExactSenderByteRate = 2_000_000.0
    static let maximumAudioDurationCoverage = 1.50

    static let admissionUpperTolerance = 4.0
    static let callbackUpperTolerance = 4.0
    static let frameUpperTolerance = 960.0
    static let packetUpperTolerance = 4.0
    static let byteUpperTolerance = 4_096.0
    static let audioDurationUpperTolerance = 0.050

    static func assess(
        elapsed: TimeInterval,
        admissionDelta: UInt64,
        callbackDelta: UInt64,
        frameDelta: UInt64,
        packetDelta: UInt64,
        byteDelta: UInt64,
        audioEnergyDelta: Double?,
        audioDurationDelta: Double?
    ) -> PhysicalRawMicrophoneRateAssessment {
        guard elapsed.isFinite,
              elapsed > 0,
              elapsed <= maximumSampleInterval,
              callbackDelta <= admissionDelta,
              frameDelta >= callbackDelta,
              byteDelta >= packetDelta else {
            return .counterLeap
        }

        guard Double(admissionDelta)
                <= elapsed * maximumRealtimeAdmissionRate
                    + admissionUpperTolerance,
              Double(callbackDelta)
                <= elapsed * maximumDeliveryCallbackRate
                    + callbackUpperTolerance,
              Double(frameDelta)
                <= elapsed * maximumDeliveredFrameRate
                    + frameUpperTolerance,
              Double(packetDelta)
                <= elapsed * maximumExactSenderPacketRate
                    + packetUpperTolerance,
              Double(byteDelta)
                <= elapsed * maximumExactSenderByteRate
                    + byteUpperTolerance,
              audioTotalsAreWithinUpperBounds(
                elapsed: elapsed,
                energyDelta: audioEnergyDelta,
                durationDelta: audioDurationDelta
              ) else {
            return .counterLeap
        }

        guard Double(admissionDelta)
                >= elapsed * minimumRealtimeAdmissionRate,
              Double(callbackDelta)
                >= elapsed * minimumDeliveryCallbackRate,
              Double(frameDelta)
                >= elapsed * minimumDeliveredFrameRate,
              Double(packetDelta)
                >= elapsed * minimumExactSenderPacketRate,
              Double(byteDelta)
                >= elapsed * minimumExactSenderByteRate,
              audioDurationHasMinimumCoverage(
                elapsed: elapsed,
                energyDelta: audioEnergyDelta,
                durationDelta: audioDurationDelta
              ) else {
            return .insufficientDensity
        }

        return .advancing
    }

    private static func audioTotalsAreWithinUpperBounds(
        elapsed: TimeInterval,
        energyDelta: Double?,
        durationDelta: Double?
    ) -> Bool {
        switch (energyDelta, durationDelta) {
        case (nil, nil):
            return true
        case let (.some(energy), .some(duration)):
            return energy.isFinite
                && duration.isFinite
                && energy >= 0
                && duration > 0
                && duration
                    <= elapsed * maximumAudioDurationCoverage
                        + audioDurationUpperTolerance
                && energy <= duration * 1.05
        default:
            return false
        }
    }

    private static func audioDurationHasMinimumCoverage(
        elapsed: TimeInterval,
        energyDelta: Double?,
        durationDelta: Double?
    ) -> Bool {
        switch (energyDelta, durationDelta) {
        case (nil, nil):
            return true
        case let (.some(energy), .some(duration)):
            return energy.isFinite
                && duration.isFinite
                && energy >= 0
                && duration >= elapsed * minimumAudioDurationCoverage
        default:
            return false
        }
    }
}

enum PhysicalRawMicrophoneEvaluator {
    private static let maximumCounter = UInt64(Int64.max)
    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    static func hasValidStructure(
        _ snapshot: PhysicalRawMicrophoneSnapshot
    ) -> Bool {
        let containsRawCounterEvidence =
            snapshot.realtimeAdmissionCount > 0
                || snapshot.deliveryCallbackCount > 0
                || snapshot.deliveredFrameCount > 0
                || snapshot.packetsSent > 0
                || snapshot.bytesSent > 0
        guard snapshot.sessionGeneration != zeroUUID,
              snapshot.windowGeneration != zeroUUID,
              snapshot.transportAuthorizationGeneration != zeroUUID,
              snapshot.audioPolicyGeneration != zeroUUID,
              snapshot.negotiationEpoch > 0,
              snapshot.bindingGeneration > 0,
              snapshot.trackGeneration > 0,
              snapshot.microphonePolicyGeneration > 0,
              snapshot.recordingGeneration > 0,
              snapshot.recordingGeneration
                == snapshot.approvedRecordingGeneration,
              snapshot.coherentSampleCount >= 2,
              snapshot.coherentSampleCount <= maximumCounter,
              snapshot.realtimeAdmissionCount <= maximumCounter,
              snapshot.deliveryCallbackCount <= maximumCounter,
              snapshot.deliveredFrameCount <= maximumCounter,
              snapshot.packetsSent <= maximumCounter,
              snapshot.bytesSent <= maximumCounter,
              snapshot.deliveryCallbackCount
                <= snapshot.realtimeAdmissionCount,
              snapshot.deliveredFrameCount
                >= snapshot.deliveryCallbackCount,
              containsRawCounterEvidence,
              snapshot.bytesSent >= snapshot.packetsSent else {
            return false
        }
        switch (
            snapshot.totalAudioEnergy,
            snapshot.totalSamplesDuration
        ) {
        case (nil, nil):
            return true
        case let (.some(energy), .some(duration)):
            return energy.isFinite
                && duration.isFinite
                && energy >= 0
                && duration >= 0
                && energy <= duration * 1.05
        default:
            return false
        }
    }

    static func evaluate(
        previous: PhysicalRawMicrophoneSnapshot,
        current: PhysicalRawMicrophoneSnapshot,
        elapsed: TimeInterval
    ) -> PhysicalRawMicrophoneDelta {
        guard hasValidStructure(previous),
              hasValidStructure(current) else {
            return .invalidStructure
        }
        guard previous.sessionGeneration
                == current.sessionGeneration else {
            return .sessionChanged
        }
        guard previous.windowGeneration
                == current.windowGeneration else {
            return .windowChanged
        }
        guard previous.transportAuthorizationGeneration
                == current.transportAuthorizationGeneration else {
            return .transportGenerationChanged
        }
        guard previous.audioPolicyGeneration
                == current.audioPolicyGeneration else {
            return .audioPolicyGenerationChanged
        }
        guard previous.negotiationEpoch == current.negotiationEpoch,
              previous.bindingGeneration == current.bindingGeneration,
              previous.trackGeneration == current.trackGeneration,
              previous.microphonePolicyGeneration
                == current.microphonePolicyGeneration,
              previous.recordingGeneration
                == current.recordingGeneration,
              previous.approvedRecordingGeneration
                == current.approvedRecordingGeneration else {
            return .senderBindingChanged
        }

        guard elapsed.isFinite, elapsed > 0 else {
            return .invalidElapsed
        }

        let monotonic =
            current.realtimeAdmissionCount
                >= previous.realtimeAdmissionCount
            && current.deliveryCallbackCount
                >= previous.deliveryCallbackCount
            && current.deliveredFrameCount
                >= previous.deliveredFrameCount
            && current.packetsSent >= previous.packetsSent
            && current.bytesSent >= previous.bytesSent
            && current.coherentSampleCount
                >= previous.coherentSampleCount
        guard monotonic,
              optionalTotalsDidNotRegress(
                previous: previous,
                current: current
              ) else {
            return .counterRegressed
        }
        guard current.realtimeAdmissionCount
                > previous.realtimeAdmissionCount,
              current.deliveryCallbackCount
                > previous.deliveryCallbackCount,
              current.deliveredFrameCount
                > previous.deliveredFrameCount else {
            return .nativeCounterStalled
        }
        guard current.packetsSent > previous.packetsSent,
              current.bytesSent > previous.bytesSent,
              current.coherentSampleCount
                > previous.coherentSampleCount,
              optionalTotalsHaveDurationProgress(
                previous: previous,
                current: current
              ) else {
            return .senderCounterStalled
        }

        let admissionDelta = current.realtimeAdmissionCount
            - previous.realtimeAdmissionCount
        let callbackDelta = current.deliveryCallbackCount
            - previous.deliveryCallbackCount
        let frameDelta = current.deliveredFrameCount
            - previous.deliveredFrameCount
        let packetDelta = current.packetsSent - previous.packetsSent
        let byteDelta = current.bytesSent - previous.bytesSent
        guard let audioDeltas = optionalAudioTotalDeltas(
            previous: previous,
            current: current
        ) else {
            return .counterRegressed
        }

        switch PhysicalRawMicrophoneRatePolicy.assess(
            elapsed: elapsed,
            admissionDelta: admissionDelta,
            callbackDelta: callbackDelta,
            frameDelta: frameDelta,
            packetDelta: packetDelta,
            byteDelta: byteDelta,
            audioEnergyDelta: audioDeltas.energy,
            audioDurationDelta: audioDeltas.duration
        ) {
        case .advancing:
            return .advancing
        case .insufficientDensity:
            return .insufficientDensity
        case .counterLeap:
            return .counterLeap
        }
    }

    static func coversElapsedInterval(
        previous: PhysicalRawMicrophoneSnapshot,
        current: PhysicalRawMicrophoneSnapshot,
        elapsed: TimeInterval
    ) -> Bool {
        evaluate(
            previous: previous,
            current: current,
            elapsed: elapsed
        ) == .advancing
    }

    private static func optionalTotalsDidNotRegress(
        previous: PhysicalRawMicrophoneSnapshot,
        current: PhysicalRawMicrophoneSnapshot
    ) -> Bool {
        switch (
            previous.totalAudioEnergy,
            previous.totalSamplesDuration,
            current.totalAudioEnergy,
            current.totalSamplesDuration
        ) {
        case (nil, nil, nil, nil):
            return true
        case let (
            .some(previousEnergy),
            .some(previousDuration),
            .some(currentEnergy),
            .some(currentDuration)
        ):
            return currentEnergy >= previousEnergy
                && currentDuration >= previousDuration
        default:
            return false
        }
    }

    private static func optionalTotalsHaveDurationProgress(
        previous: PhysicalRawMicrophoneSnapshot,
        current: PhysicalRawMicrophoneSnapshot
    ) -> Bool {
        switch (
            previous.totalAudioEnergy,
            previous.totalSamplesDuration,
            current.totalAudioEnergy,
            current.totalSamplesDuration
        ) {
        case (nil, nil, nil, nil):
            return true
        case let (
            .some(previousEnergy),
            .some(previousDuration),
            .some(currentEnergy),
            .some(currentDuration)
        ):
            return currentEnergy >= previousEnergy
                && currentDuration > previousDuration
        default:
            return false
        }
    }

    private static func optionalAudioTotalDeltas(
        previous: PhysicalRawMicrophoneSnapshot,
        current: PhysicalRawMicrophoneSnapshot
    ) -> (energy: Double?, duration: Double?)? {
        switch (
            previous.totalAudioEnergy,
            previous.totalSamplesDuration,
            current.totalAudioEnergy,
            current.totalSamplesDuration
        ) {
        case (nil, nil, nil, nil):
            return (energy: nil, duration: nil)
        case let (
            .some(previousEnergy),
            .some(previousDuration),
            .some(currentEnergy),
            .some(currentDuration)
        ):
            return (
                energy: currentEnergy - previousEnergy,
                duration: currentDuration - previousDuration
            )
        default:
            return nil
        }
    }
}

/// Typed copy of the non-secret audio evidence exposed by the production app's accessibility tree.
/// All counters are lifetime cumulative within `sessionGeneration`; evaluators compare snapshots
/// instead of interpreting any single counter as proof of audible continuity.
struct PhysicalAudioPlayoutSnapshot: Equatable {
    private static let schemaVersion = 2

    let sessionGeneration: UUID
    let audioPolicyGeneration: UUID
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
                "v", "session", "audioPolicy", "callbacks", "frames",
                "failures", "pcmSamples",
                "pcmNonzero", "pcmAbs", "pcmLeftAbs", "pcmRightAbs",
                "pcmStereoDiffAbs", "pcmClipped", "silenceCallbacks",
                "gapViolations", "maxGapNs", "nearSilenceCallbacks",
                "currentNearSilenceFrames", "maxNearSilenceFrames",
                "leftCrossings", "rightCrossings", "envelopeTransitions",
                "shapeAnomalies", "boundaryDiscontinuities", "callbackMean",
                "rebuilds", "peak",
                "inboundEnergy", "inboundDuration", "fullQuality",
            ],
            expectedVersion: Self.schemaVersion
        ), let sessionText = fields["session"],
           let session = Self.parseCanonicalNonzeroUUID(sessionText),
           let audioPolicyText = fields["audioPolicy"],
           let audioPolicy =
                Self.parseCanonicalNonzeroUUID(audioPolicyText),
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
        audioPolicyGeneration = audioPolicy
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

    private static func parseCanonicalNonzeroUUID(
        _ value: String
    ) -> UUID? {
        let zeroUUID = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        )
        guard let parsed = UUID(uuidString: value),
              parsed != zeroUUID,
              parsed.uuidString.lowercased() == value else {
            return nil
        }
        return parsed
    }
}

/// First failed invariant, or successful advancement, between two audio oracle snapshots.
enum PhysicalAudioPlayoutDelta: Equatable {
    case advancing
    case invalidPCMStructure
    case invalidInboundStructure
    case sessionChanged
    case audioPolicyChanged
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

/// Deterministic structural, monotonicity, waveform, and real-time-coverage checks for physical
/// audio evidence. These checks operate on text/counters and never require a subjective listener.
enum PhysicalAudioPlayoutEvaluator {
    /// RemoteIO is configured for 10 ms callbacks. A 25 ms boundary tolerates one late callback
    /// while making two-or-more missed callback intervals machine-visible.
    static let maximumPermittedCallbackGapNanoseconds: UInt64 = 25_000_000

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    static func hasValidStructure(_ snapshot: PhysicalAudioPlayoutSnapshot) -> Bool {
        guard snapshot.sessionGeneration != zeroUUID,
              snapshot.audioPolicyGeneration != zeroUUID,
              snapshot.pcmNonzeroSampleCount <= snapshot.pcmSampleCount,
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
        guard previous.audioPolicyGeneration
                == current.audioPolicyGeneration else {
            return .audioPolicyChanged
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
        guard elapsed.isFinite, elapsed > 0,
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

/// Progress state returned by both audio and video continuity windows.
enum PhysicalContinuityWindowResult: Equatable {
    case waiting
    case satisfied
    case rejected
}

/// Stable physical-observation window for the versioned exact raw-microphone accessibility oracle.
struct PhysicalRawMicrophoneContinuityTracker {
    let requiredDuration: TimeInterval
    let maximumProgressGap: TimeInterval
    let expectedSessionGeneration: UUID?
    let expectedWindowGeneration: UUID?
    let minimumAdvancementObservations: Int

    private(set) var latestSnapshot:
        PhysicalRawMicrophoneSnapshot?
    private(set) var accumulatedValidDuration: TimeInterval = 0
    private(set) var advancementObservationCount = 0
    private var lastObservedAt: TimeInterval?

    init(
        requiredDuration: TimeInterval,
        maximumProgressGap: TimeInterval,
        expectedSessionGeneration: UUID? = nil,
        expectedWindowGeneration: UUID? = nil,
        minimumAdvancementObservations: Int = 2
    ) {
        self.requiredDuration = requiredDuration
        self.maximumProgressGap = maximumProgressGap
        self.expectedSessionGeneration =
            expectedSessionGeneration
        self.expectedWindowGeneration =
            expectedWindowGeneration
        self.minimumAdvancementObservations =
            minimumAdvancementObservations
    }

    mutating func observe(
        _ snapshot: PhysicalRawMicrophoneSnapshot,
        at now: TimeInterval
    ) -> PhysicalContinuityWindowResult {
        guard requiredDuration.isFinite,
              requiredDuration > 0,
              maximumProgressGap.isFinite,
              maximumProgressGap > 0,
              maximumProgressGap
                <= PhysicalRawMicrophoneRatePolicy.maximumSampleInterval,
              minimumAdvancementObservations > 0,
              now.isFinite,
              expectedSessionGeneration.map({
                $0 == snapshot.sessionGeneration
              }) != false,
              expectedWindowGeneration.map({
                $0 == snapshot.windowGeneration
              }) != false,
              PhysicalRawMicrophoneEvaluator
                .hasValidStructure(snapshot) else {
            reset()
            return .rejected
        }

        guard let previous = latestSnapshot,
              let lastObservedAt else {
            latestSnapshot = snapshot
            self.lastObservedAt = now
            return .waiting
        }

        guard now > lastObservedAt else {
            reset()
            return .rejected
        }

        let elapsed = now - lastObservedAt
        guard elapsed <= maximumProgressGap else {
            reset()
            return .rejected
        }

        guard PhysicalRawMicrophoneEvaluator.evaluate(
            previous: previous,
            current: snapshot,
            elapsed: elapsed
        ) == .advancing else {
            reset()
            return .rejected
        }

        guard advancementObservationCount < Int.max else {
            reset()
            return .rejected
        }

        let accumulated = accumulatedValidDuration + elapsed
        guard accumulated.isFinite else {
            reset()
            return .rejected
        }

        latestSnapshot = snapshot
        self.lastObservedAt = now
        accumulatedValidDuration = accumulated
        advancementObservationCount += 1

        guard accumulatedValidDuration >= requiredDuration,
              advancementObservationCount
                >= minimumAdvancementObservations else {
            return .waiting
        }

        return .satisfied
    }

    mutating func reset() {
        latestSnapshot = nil
        accumulatedValidDuration = 0
        advancementObservationCount = 0
        lastObservedAt = nil
    }
}

/// Sequence-level release oracle. The stable window starts on the first verified advancement—not
/// on the baseline read—so a two-second stall followed by one late callback cannot pass.
struct PhysicalAudioContinuityTracker {
    let requiredDuration: TimeInterval
    let maximumProgressGap: TimeInterval
    let expectedSessionGeneration: UUID?
    let expectedAudioPolicyGeneration: UUID?
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
        expectedAudioPolicyGeneration: UUID? = nil,
        minimumAdvancementObservations: Int = 3
    ) {
        self.requiredDuration = requiredDuration
        self.maximumProgressGap = maximumProgressGap
        self.expectedSessionGeneration = expectedSessionGeneration
        self.expectedAudioPolicyGeneration = expectedAudioPolicyGeneration
        self.minimumAdvancementObservations = minimumAdvancementObservations
    }

    mutating func observe(
        _ snapshot: PhysicalAudioPlayoutSnapshot,
        at now: TimeInterval
    ) -> PhysicalContinuityWindowResult {
        guard requiredDuration.isFinite,
              requiredDuration > 0,
              maximumProgressGap.isFinite,
              maximumProgressGap > 0,
              minimumAdvancementObservations > 0,
              now.isFinite,
              expectedSessionGeneration.map({ $0 == snapshot.sessionGeneration }) != false,
              expectedAudioPolicyGeneration
                .map({ $0 == snapshot.audioPolicyGeneration }) != false,
              PhysicalAudioPlayoutEvaluator.hasValidStructure(snapshot),
              snapshot.fullQualityInvariantsHold,
              snapshot.failureCount == 0,
              snapshot.currentConsecutiveNearSilenceFrameCount == 0,
              snapshot.lastPeakMagnitude > 0,
              snapshot.lastCallbackMeanMagnitude > 0 else {
            reset()
            return .rejected
        }
        guard let previous = latestSnapshot else {
            latestSnapshot = snapshot
            lastProgressAt = now
            return .waiting
        }
        guard previous.sessionGeneration == snapshot.sessionGeneration,
              previous.audioPolicyGeneration
                == snapshot.audioPolicyGeneration else {
            reset()
            return .rejected
        }

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
            reset()
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

    mutating func reset() {
        latestSnapshot = nil
        progressOrigin = nil
        progressStartedAt = nil
        lastProgressAt = nil
        advancementObservations = 0
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

enum PhysicalHostedCallPlayoutOrigin: String, Equatable {
    case interruption
    case startupConnectedCall = "startup-connected-call"
}

/// Typed, privacy-minimal evidence exposed only after hosted-call readiness.
/// It proves advancing inbound RTP/statistics and pre-system-output RemoteIO render-input data;
/// it does not prove the final iOS mixer, route, DAC, speaker, or acoustic audibility.
struct PhysicalHostedCallPlayoutSnapshot: Equatable {
    let sessionGeneration: UUID
    let policyID: UUID
    let origin: PhysicalHostedCallPlayoutOrigin
    let audioPolicyGeneration: UUID
    let systemAudioGeneration: UInt64
    let authorizationGeneration: UInt64
    let nativeAuthorizationGeneration: UInt64
    let callbackCount: UInt64
    let frameCount: UInt64
    let failureCount: UInt64
    let pcmNonzeroSampleCount: UInt64
    let pcmAbsoluteSampleSum: UInt64
    let unexpectedRecordingRequestCount: UInt64
    let inboundBytes: UInt64
    let inboundPackets: UInt64
    let inboundJitterBufferEmittedCount: UInt64
    let inboundTotalSamplesReceived: UInt64
    let inboundAudioEnergy: Double
    let inboundSamplesDuration: Double
    let outputBusEnabled: Bool
    let inputBusEnabled: Bool
    let categoryIsMediaPlayback: Bool
    let modeIsDefault: Bool
    let categoryOptionsAreMixWithOthers: Bool
    let remoteIOCreated: Bool
    let audioUnitIsRemoteIO: Bool
    let activeSessionOwnership: Bool
    let hostedCallMode: Bool
    let authorizationIsValid: Bool
    let authorizationIsConsumed: Bool
    let nativeAuthorizationIsValid: Bool
    let nativeAuthorizationIsConsumed: Bool
    let authorizationPolicyMatches: Bool
    let authorizationGenerationMatches: Bool
    let connectedCallKitSnapshot: Bool

    init?(accessibilityValue: String) {
        guard let fields = PhysicalOracleFields.parse(
            accessibilityValue,
            requiredKeys: [
                "v", "origin", "session", "policy", "audioPolicy",
                "systemAudioGeneration", "authorizationGeneration",
                "nativeAuthorizationGeneration", "callbacks", "frames", "failures",
                "pcmNonzero", "pcmAbs", "recordRequests", "inboundBytes",
                "inboundPackets", "inboundJitterEmitted", "inboundSamples",
                "inboundEnergy", "inboundDuration", "output", "input", "playback",
                "defaultMode", "mixWithOthers", "remoteIOCreated", "remoteIOSubtype",
                "activeOwnership", "hostedMode", "authorizationValid",
                "authorizationConsumed", "nativeAuthorizationValid",
                "nativeAuthorizationConsumed", "authorizationPolicyMatches",
                "authorizationGenerationMatches", "callKitConnected",
            ],
            expectedVersion: 2
        ), let originText = fields["origin"],
           let parsedOrigin = PhysicalHostedCallPlayoutOrigin(rawValue: originText),
           let sessionText = fields["session"],
           let session = Self.parseUUID(sessionText),
           let policyText = fields["policy"],
           let policy = Self.parseUUID(policyText),
           let audioPolicyText = fields["audioPolicy"],
           let audioPolicy = Self.parseUUID(audioPolicyText) else {
            return nil
        }

        let unsignedKeys = [
            "systemAudioGeneration", "authorizationGeneration",
            "nativeAuthorizationGeneration", "callbacks", "frames", "failures",
            "pcmNonzero", "pcmAbs", "recordRequests", "inboundBytes",
            "inboundPackets", "inboundJitterEmitted", "inboundSamples",
        ]
        var unsigned: [String: UInt64] = [:]
        for key in unsignedKeys {
            guard let text = fields[key], let value = Self.parseUInt64(text) else {
                return nil
            }
            unsigned[key] = value
        }
        guard unsigned["systemAudioGeneration"]! > 0,
              unsigned["authorizationGeneration"]! > 0,
              unsigned["nativeAuthorizationGeneration"]! > 0 else {
            return nil
        }

        var doubles: [String: Double] = [:]
        for key in ["inboundEnergy", "inboundDuration"] {
            guard let text = fields[key],
                  let value = Self.parseNonnegativeFiniteDouble(text) else {
                return nil
            }
            doubles[key] = value
        }

        let booleanKeys = [
            "output", "input", "playback", "defaultMode", "mixWithOthers",
            "remoteIOCreated", "remoteIOSubtype", "activeOwnership", "hostedMode",
            "authorizationValid", "authorizationConsumed",
            "nativeAuthorizationValid", "nativeAuthorizationConsumed",
            "authorizationPolicyMatches", "authorizationGenerationMatches",
            "callKitConnected",
        ]
        var booleans: [String: Bool] = [:]
        for key in booleanKeys {
            guard let text = fields[key], let value = Self.parseBoolean(text) else {
                return nil
            }
            booleans[key] = value
        }

        sessionGeneration = session
        policyID = policy
        origin = parsedOrigin
        audioPolicyGeneration = audioPolicy
        systemAudioGeneration = unsigned["systemAudioGeneration"]!
        authorizationGeneration = unsigned["authorizationGeneration"]!
        nativeAuthorizationGeneration = unsigned["nativeAuthorizationGeneration"]!
        callbackCount = unsigned["callbacks"]!
        frameCount = unsigned["frames"]!
        failureCount = unsigned["failures"]!
        pcmNonzeroSampleCount = unsigned["pcmNonzero"]!
        pcmAbsoluteSampleSum = unsigned["pcmAbs"]!
        unexpectedRecordingRequestCount = unsigned["recordRequests"]!
        inboundBytes = unsigned["inboundBytes"]!
        inboundPackets = unsigned["inboundPackets"]!
        inboundJitterBufferEmittedCount = unsigned["inboundJitterEmitted"]!
        inboundTotalSamplesReceived = unsigned["inboundSamples"]!
        inboundAudioEnergy = doubles["inboundEnergy"]!
        inboundSamplesDuration = doubles["inboundDuration"]!
        outputBusEnabled = booleans["output"]!
        inputBusEnabled = booleans["input"]!
        categoryIsMediaPlayback = booleans["playback"]!
        modeIsDefault = booleans["defaultMode"]!
        categoryOptionsAreMixWithOthers = booleans["mixWithOthers"]!
        remoteIOCreated = booleans["remoteIOCreated"]!
        audioUnitIsRemoteIO = booleans["remoteIOSubtype"]!
        activeSessionOwnership = booleans["activeOwnership"]!
        hostedCallMode = booleans["hostedMode"]!
        authorizationIsValid = booleans["authorizationValid"]!
        authorizationIsConsumed = booleans["authorizationConsumed"]!
        nativeAuthorizationIsValid = booleans["nativeAuthorizationValid"]!
        nativeAuthorizationIsConsumed = booleans["nativeAuthorizationConsumed"]!
        authorizationPolicyMatches = booleans["authorizationPolicyMatches"]!
        authorizationGenerationMatches = booleans["authorizationGenerationMatches"]!
        connectedCallKitSnapshot = booleans["callKitConnected"]!
    }

    private static func parseUUID(_ value: String) -> UUID? {
        guard let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value else {
            return nil
        }
        return uuid
    }

    private static func parseUInt64(_ value: String) -> UInt64? {
        guard let parsed = UInt64(value), String(parsed) == value else { return nil }
        return parsed
    }

    private static func parseNonnegativeFiniteDouble(_ value: String) -> Double? {
        guard !value.hasPrefix("+"), !value.hasPrefix("-"),
              value.trimmingCharacters(in: .whitespacesAndNewlines) == value,
              let parsed = Double(value), parsed.isFinite, parsed >= 0,
              String(parsed) == value else {
            return nil
        }
        return parsed
    }

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value {
        case "0": return false
        case "1": return true
        default: return nil
        }
    }
}

/// First failed invariant, identity check, or counter check between hosted-call snapshots.
enum PhysicalHostedCallPlayoutDelta: Equatable {
    case advancing
    case invalidStructure
    case hostedInvariantMissing
    case sessionChanged
    case policyChanged
    case audioPolicyChanged
    case originChanged
    case generationChanged
    case failureCounterRegressed
    case failureCounterChanged
    case renderFailurePresent
    case recordingRequestCounterRegressed
    case recordingRequestCounterChanged
    case recordingRequestPresent
    case callbackCounterRegressed
    case frameCounterRegressed
    case pcmCounterRegressed
    case inboundCounterRegressed
    case callbackCounterStalled
    case frameCounterStalled
    case pcmContentStalled
    case inboundContentStalled
}

/// Deterministic hosted-call checks for pre-system-output render-input and inbound RTP evidence.
enum PhysicalHostedCallPlayoutEvaluator {
    static func hasValidStructure(_ snapshot: PhysicalHostedCallPlayoutSnapshot) -> Bool {
        hasValidCounterStructure(snapshot) && hostedCallInvariantsHold(snapshot)
    }

    static func evaluate(
        previous: PhysicalHostedCallPlayoutSnapshot,
        current: PhysicalHostedCallPlayoutSnapshot
    ) -> PhysicalHostedCallPlayoutDelta {
        guard hasValidCounterStructure(previous),
              hasValidCounterStructure(current) else {
            return .invalidStructure
        }
        guard hostedCallInvariantsHold(previous),
              hostedCallInvariantsHold(current) else {
            return .hostedInvariantMissing
        }
        guard previous.sessionGeneration == current.sessionGeneration else {
            return .sessionChanged
        }
        guard previous.policyID == current.policyID else { return .policyChanged }
        guard previous.audioPolicyGeneration == current.audioPolicyGeneration else {
            return .audioPolicyChanged
        }
        guard previous.origin == current.origin else {
            return .originChanged
        }
        guard previous.systemAudioGeneration == current.systemAudioGeneration,
              previous.authorizationGeneration == current.authorizationGeneration,
              previous.nativeAuthorizationGeneration
                == current.nativeAuthorizationGeneration else {
            return .generationChanged
        }
        guard current.failureCount >= previous.failureCount else {
            return .failureCounterRegressed
        }
        guard current.failureCount == previous.failureCount else {
            return .failureCounterChanged
        }
        guard previous.failureCount == 0 else { return .renderFailurePresent }
        guard current.unexpectedRecordingRequestCount
                >= previous.unexpectedRecordingRequestCount else {
            return .recordingRequestCounterRegressed
        }
        guard current.unexpectedRecordingRequestCount
                == previous.unexpectedRecordingRequestCount else {
            return .recordingRequestCounterChanged
        }
        guard previous.unexpectedRecordingRequestCount == 0 else {
            return .recordingRequestPresent
        }
        guard current.callbackCount >= previous.callbackCount else {
            return .callbackCounterRegressed
        }
        guard current.frameCount >= previous.frameCount else {
            return .frameCounterRegressed
        }
        guard current.pcmNonzeroSampleCount >= previous.pcmNonzeroSampleCount,
              current.pcmAbsoluteSampleSum >= previous.pcmAbsoluteSampleSum else {
            return .pcmCounterRegressed
        }
        guard current.inboundBytes >= previous.inboundBytes,
              current.inboundPackets >= previous.inboundPackets,
              current.inboundJitterBufferEmittedCount
                >= previous.inboundJitterBufferEmittedCount,
              current.inboundTotalSamplesReceived
                >= previous.inboundTotalSamplesReceived,
              current.inboundAudioEnergy >= previous.inboundAudioEnergy,
              current.inboundSamplesDuration >= previous.inboundSamplesDuration else {
            return .inboundCounterRegressed
        }
        guard current.callbackCount > previous.callbackCount else {
            return .callbackCounterStalled
        }
        guard current.frameCount > previous.frameCount else {
            return .frameCounterStalled
        }
        guard current.pcmNonzeroSampleCount > previous.pcmNonzeroSampleCount,
              current.pcmAbsoluteSampleSum > previous.pcmAbsoluteSampleSum else {
            return .pcmContentStalled
        }
        guard current.inboundBytes > previous.inboundBytes,
              current.inboundPackets > previous.inboundPackets,
              current.inboundJitterBufferEmittedCount
                > previous.inboundJitterBufferEmittedCount,
              current.inboundTotalSamplesReceived
                > previous.inboundTotalSamplesReceived,
              current.inboundAudioEnergy > previous.inboundAudioEnergy,
              current.inboundSamplesDuration > previous.inboundSamplesDuration else {
            return .inboundContentStalled
        }
        return .advancing
    }

    static func coversElapsedInterval(
        previous: PhysicalHostedCallPlayoutSnapshot,
        current: PhysicalHostedCallPlayoutSnapshot,
        elapsed: TimeInterval,
        minimumRealtimeCoverage: Double = 0.70,
        maximumRealtimeCoverage: Double = 1.35,
        minimumNonzeroSampleRatio: Double = 0.90,
        minimumMeanMagnitude: Double = 256,
        minimumInboundEnergyPerSecond: Double = 0.000_01
    ) -> Bool {
        guard elapsed.isFinite, elapsed > 0,
              minimumRealtimeCoverage > 0, minimumRealtimeCoverage <= 1,
              maximumRealtimeCoverage >= 1,
              minimumRealtimeCoverage < maximumRealtimeCoverage,
              minimumNonzeroSampleRatio > 0, minimumNonzeroSampleRatio <= 1,
              minimumMeanMagnitude > 0, minimumInboundEnergyPerSecond >= 0,
              evaluate(previous: previous, current: current) == .advancing else {
            return false
        }

        let callbackDelta = current.callbackCount - previous.callbackCount
        let frameDelta = current.frameCount - previous.frameCount
        let pcmNonzeroDelta = current.pcmNonzeroSampleCount
            - previous.pcmNonzeroSampleCount
        let pcmAbsoluteDelta = current.pcmAbsoluteSampleSum
            - previous.pcmAbsoluteSampleSum
        let inboundBytesDelta = current.inboundBytes - previous.inboundBytes
        let inboundPacketsDelta = current.inboundPackets - previous.inboundPackets
        let inboundSamplesDelta = current.inboundTotalSamplesReceived
            - previous.inboundTotalSamplesReceived
        let inboundDurationDelta = current.inboundSamplesDuration
            - previous.inboundSamplesDuration
        let inboundEnergyDelta = current.inboundAudioEnergy - previous.inboundAudioEnergy
        let callbackCoverage = Double(callbackDelta) / (elapsed * 100)
        let frameCoverage = Double(frameDelta) / (elapsed * 48_000)
        let nonzeroRatio = Double(pcmNonzeroDelta)
            / max(1, Double(frameDelta) * 2)
        let meanMagnitude = Double(pcmAbsoluteDelta) / max(1, Double(pcmNonzeroDelta))
        let inboundSampleCoverage = Double(inboundSamplesDelta) / (elapsed * 48_000)
        let inboundDurationCoverage = inboundDurationDelta / elapsed

        return (minimumRealtimeCoverage...maximumRealtimeCoverage).contains(callbackCoverage)
            && (minimumRealtimeCoverage...maximumRealtimeCoverage).contains(frameCoverage)
            && nonzeroRatio >= minimumNonzeroSampleRatio
            && nonzeroRatio <= 1.05
            && pcmAbsoluteDelta >= pcmNonzeroDelta
            && meanMagnitude >= minimumMeanMagnitude
            && meanMagnitude <= 32_768
            && inboundBytesDelta >= inboundPacketsDelta
            && (minimumRealtimeCoverage...maximumRealtimeCoverage)
                .contains(inboundSampleCoverage)
            && (minimumRealtimeCoverage...maximumRealtimeCoverage)
                .contains(inboundDurationCoverage)
            && inboundEnergyDelta / elapsed >= minimumInboundEnergyPerSecond
            && inboundEnergyDelta <= inboundDurationDelta * 1.05
    }

    private static func hasValidCounterStructure(
        _ snapshot: PhysicalHostedCallPlayoutSnapshot
    ) -> Bool {
        let doubledFrames = snapshot.frameCount.multipliedReportingOverflow(by: 2)
        let maximumInboundEnergy = snapshot.inboundSamplesDuration * 1.05
        return !doubledFrames.overflow
            && snapshot.systemAudioGeneration > 0
            && snapshot.systemAudioGeneration == snapshot.authorizationGeneration
            && snapshot.authorizationGeneration == snapshot.nativeAuthorizationGeneration
            && snapshot.pcmNonzeroSampleCount <= doubledFrames.partialValue
            && snapshot.pcmAbsoluteSampleSum >= snapshot.pcmNonzeroSampleCount
            && maximumInboundEnergy.isFinite
            && snapshot.inboundAudioEnergy <= maximumInboundEnergy
    }

    private static func hostedCallInvariantsHold(
        _ snapshot: PhysicalHostedCallPlayoutSnapshot
    ) -> Bool {
        snapshot.outputBusEnabled
            && !snapshot.inputBusEnabled
            && snapshot.categoryIsMediaPlayback
            && snapshot.modeIsDefault
            && snapshot.categoryOptionsAreMixWithOthers
            && snapshot.remoteIOCreated
            && snapshot.audioUnitIsRemoteIO
            && snapshot.activeSessionOwnership
            && snapshot.hostedCallMode
            && snapshot.authorizationIsValid
            && snapshot.authorizationIsConsumed
            && snapshot.nativeAuthorizationIsValid
            && snapshot.nativeAuthorizationIsConsumed
            && snapshot.authorizationPolicyMatches
            && snapshot.authorizationGenerationMatches
            && snapshot.connectedCallKitSnapshot
    }
}

/// Sequence-level hosted-call oracle. The window starts on the first verified advancement and
/// requires several bounded, real-time observations rather than one label or one counter jump.
struct PhysicalHostedCallPlayoutContinuityTracker {
    let requiredDuration: TimeInterval
    let maximumProgressGap: TimeInterval
    let expectedSessionGeneration: UUID?
    let expectedPolicyID: UUID?
    let expectedOrigin: PhysicalHostedCallPlayoutOrigin?
    let expectedAudioPolicyGeneration: UUID?
    let expectedAuthorizationGeneration: UInt64?
    let minimumAdvancementObservations: Int

    private(set) var latestSnapshot: PhysicalHostedCallPlayoutSnapshot?
    private var progressOrigin: PhysicalHostedCallPlayoutSnapshot?
    private var progressStartedAt: TimeInterval?
    private var lastProgressAt: TimeInterval?
    private var advancementObservations = 0

    init(
        requiredDuration: TimeInterval,
        maximumProgressGap: TimeInterval,
        expectedSessionGeneration: UUID? = nil,
        expectedPolicyID: UUID? = nil,
        expectedOrigin: PhysicalHostedCallPlayoutOrigin? = nil,
        expectedAudioPolicyGeneration: UUID? = nil,
        expectedAuthorizationGeneration: UInt64? = nil,
        minimumAdvancementObservations: Int = 3
    ) {
        self.requiredDuration = requiredDuration
        self.maximumProgressGap = maximumProgressGap
        self.expectedSessionGeneration = expectedSessionGeneration
        self.expectedPolicyID = expectedPolicyID
        self.expectedOrigin = expectedOrigin
        self.expectedAudioPolicyGeneration = expectedAudioPolicyGeneration
        self.expectedAuthorizationGeneration = expectedAuthorizationGeneration
        self.minimumAdvancementObservations = minimumAdvancementObservations
    }

    mutating func observe(
        _ snapshot: PhysicalHostedCallPlayoutSnapshot,
        at now: TimeInterval
    ) -> PhysicalContinuityWindowResult {
        guard requiredDuration > 0, maximumProgressGap > 0,
              minimumAdvancementObservations >= 2, now.isFinite,
              expectedSessionGeneration.map({ $0 == snapshot.sessionGeneration }) != false,
              expectedPolicyID.map({ $0 == snapshot.policyID }) != false,
              expectedOrigin.map({ $0 == snapshot.origin }) != false,
              expectedAudioPolicyGeneration
                .map({ $0 == snapshot.audioPolicyGeneration }) != false,
              expectedAuthorizationGeneration
                .map({ $0 == snapshot.authorizationGeneration }) != false,
              PhysicalHostedCallPlayoutEvaluator.hasValidStructure(snapshot),
              snapshot.failureCount == 0,
              snapshot.unexpectedRecordingRequestCount == 0 else {
            return .rejected
        }

        guard let previous = latestSnapshot else {
            latestSnapshot = snapshot
            lastProgressAt = now
            return .waiting
        }
        guard lastProgressAt.map({ now >= $0 }) != false else { return .rejected }

        if snapshot == previous {
            if let lastProgressAt, now - lastProgressAt > maximumProgressGap {
                resetProgress(at: snapshot, now: now)
            }
            return .waiting
        }

        guard PhysicalHostedCallPlayoutEvaluator.evaluate(
            previous: previous,
            current: snapshot
        ) == .advancing else {
            return .rejected
        }

        if let lastProgressAt, now - lastProgressAt > maximumProgressGap {
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
        guard let progressStartedAt, let progressOrigin else { return .waiting }
        let elapsed = now - progressStartedAt
        guard elapsed >= requiredDuration,
              advancementObservations >= minimumAdvancementObservations else {
            return .waiting
        }

        return PhysicalHostedCallPlayoutEvaluator.coversElapsedInterval(
            previous: progressOrigin,
            current: snapshot,
            elapsed: elapsed
        ) ? .satisfied : .waiting
    }

    private mutating func resetProgress(
        at snapshot: PhysicalHostedCallPlayoutSnapshot,
        now: TimeInterval
    ) {
        latestSnapshot = snapshot
        progressOrigin = nil
        progressStartedAt = nil
        lastProgressAt = now
        advancementObservations = 0
    }
}

/// Typed renderer evidence parsed from the production accessibility oracle.
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

/// First failed invariant, or successful advancement, between two rendered-video snapshots.
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

/// Validates that decoded frames, timestamps, and sampled content all advance at plausible rates.
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

/// Sequence-level video oracle that requires sustained decoded-content advancement.
/// Static frames may advance transport counters but cannot satisfy the content-change window.
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

/// Typed proof that the active Mac session acknowledged a show or hide command.
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
