import AudioToolbox
import Foundation
import WebRTCTransport

/// App-owned context surrounding one exact sender-scoped microphone statistics sample.
///
/// Object identities are retained only inside this fail-closed process-local evaluator. They never
/// enter accessibility and are discarded when the proof window resets.
struct WorldwideRawMicrophoneProofSample: Equatable {
    let sessionGeneration: UUID
    let peerIdentity: ObjectIdentifier
    let transportAuthorizationGeneration: UUID
    let audioPolicyGeneration: UUID
    let authorizationIdentity: ObjectIdentifier
    let authenticatedPairedSession: Bool
    let microphoneIntentIsCurrent: Bool
    let microphonePermissionGranted: Bool
    let callIsActive: Bool
    let transportIsHealthy: Bool
    let statistics: WebRTCIPhoneMicrophoneSenderStatistics
}

enum WorldwideRawMicrophoneRateAssessment: Equatable {
    case advancing
    case insufficientDensity
    case counterLeap
}

/// Shared production/physical density and upper-rate contract for exact raw microphone evidence.
///
/// The lower bounds are deliberately conservative relative to a live 48 kHz sender, but they are
/// high enough that one callback, frame, packet, or byte cannot certify a multi-second interval.
/// Energy magnitude is intentionally not bounded below because legitimate digital silence remains
/// valid microphone delivery; when WebRTC exposes audio totals, only sample-duration continuity is
/// required.
enum WorldwideRawMicrophoneRatePolicy {
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
    ) -> WorldwideRawMicrophoneRateAssessment {
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

enum WorldwideRawMicrophoneProofDelta: Equatable {
    case advancing
    case invalidContext
    case bindingChanged
    case invalidSenderState
    case timestampRegressed
    case counterRegressed
    case counterStalled
    case insufficientDensity
    case counterLeap
}

/// Exact native-input-to-sender-RTP proof. No receiver, BlackHole, default-device, or host-app
/// consumption claim is made here; those remain independent Phase B evidence.
enum WorldwideRawMicrophoneOracleEvaluator {
    static let maximumSampleInterval =
        WorldwideRawMicrophoneRatePolicy.maximumSampleInterval
    private static let maximumCounter = UInt64(Int64.max)
    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    static func hasValidState(
        _ sample: WorldwideRawMicrophoneProofSample
    ) -> Bool {
        let sender = sample.statistics.sender
        let containsRawCounterEvidence =
            sender.realtimeAdmissionCount > 0
                || sender.deliveryCallbackCount > 0
                || sender.deliveredFrameCount > 0
                || sample.statistics.packetsSent > 0
                || sample.statistics.bytesSent > 0
        guard sample.sessionGeneration != zeroUUID,
              sample.transportAuthorizationGeneration != zeroUUID,
              sample.audioPolicyGeneration != zeroUUID,
              sender.peerEpoch != zeroUUID,
              sample.authenticatedPairedSession,
              sample.microphoneIntentIsCurrent,
              sample.microphonePermissionGranted,
              !sample.callIsActive,
              sample.transportIsHealthy,
              sender.senderOwnsMID,
              sender.senderOwnsLocalTrack,
              !sender.transceiverIsStopped,
              sender.preferredDirectionIncludesSending,
              sender.currentDirectionIncludesSending,
              sender.trackIsEnabled,
              sender.rawProcessingIsLive,
              sender.transportIsHealthy,
              sender.authorizationIsCurrent,
              sender.authorizationIsValid,
              sender.senderIsAdmitted,
              sender.nativeDeviceIsOpen,
              sender.nativeDeviceGateIsOpen,
              sender.nativeAuthorizationGateIsOpen,
              sender.categoryIsPlayAndRecord,
              sender.modeIsDefault,
              sender.usesRemoteIO,
              sender.inputBusEnabled,
              sender.captureRouteIsBuiltInMicrophone,
              sender.captureRouteProofGeneration > 0,
              sender.outputBusEnabled,
              !sender.categoryOptionsAreEmpty,
              sender.categoryOptionsAreIPhoneMicrophoneRouting,
              sender.routeSharingPolicyIsDefault,
              sender.hasOutputRoute,
              sender.sampleRateIs48k,
              sender.ioBufferDurationIsBounded,
              sender.outputChannelCountIsStereo,
              !sender.recoveryRequired,
              !sender.explicitResumeRequired,
              !sender.hostedCallMode,
              sender.failureCode == 0,
              sender.lastLifecycleStatus == noErr,
              sender.bindingGeneration > 0,
              sender.negotiationEpoch > 0,
              sender.trackGeneration > 0,
              sender.microphonePolicyGeneration > 0,
              sender.recordingGeneration > 0,
              sender.recordingGeneration
                == sender.approvedRecordingGeneration,
              sender.realtimeAdmissionCount <= maximumCounter,
              sender.deliveryCallbackCount <= maximumCounter,
              sender.deliveredFrameCount <= maximumCounter,
              sender.deliveryCallbackCount
                <= sender.realtimeAdmissionCount,
              sender.deliveredFrameCount
                >= sender.deliveryCallbackCount,
              sample.statistics.packetsSent <= maximumCounter,
              sample.statistics.bytesSent <= maximumCounter,
              sample.statistics.bytesSent
                >= sample.statistics.packetsSent,
              sample.statistics.sourceReportWasLinked,
              containsRawCounterEvidence,
              sample.statistics.collectedAt
                .timeIntervalSinceReferenceDate.isFinite,
              audioTotalsAreValid(sample.statistics) else {
            return false
        }
        return true
    }

    static func evaluate(
        previous: WorldwideRawMicrophoneProofSample,
        current: WorldwideRawMicrophoneProofSample
    ) -> WorldwideRawMicrophoneProofDelta {
        guard hasValidState(previous),
              hasValidState(current) else {
            return .invalidSenderState
        }
        guard previous.sessionGeneration
                == current.sessionGeneration,
              previous.peerIdentity == current.peerIdentity,
              previous.authorizationIdentity
                == current.authorizationIdentity,
              previous.transportAuthorizationGeneration
                == current.transportAuthorizationGeneration,
              previous.audioPolicyGeneration
                == current.audioPolicyGeneration else {
            return .invalidContext
        }

        let previousSender = previous.statistics.sender
        let currentSender = current.statistics.sender
        guard previousSender.peerEpoch == currentSender.peerEpoch,
              previousSender.bindingGeneration
                == currentSender.bindingGeneration,
              previousSender.negotiationEpoch
                == currentSender.negotiationEpoch,
              previousSender.trackGeneration
                == currentSender.trackGeneration,
              previousSender.microphonePolicyGeneration
                == currentSender.microphonePolicyGeneration,
              previousSender.recordingGeneration
                == currentSender.recordingGeneration,
              previousSender.approvedRecordingGeneration
                == currentSender.approvedRecordingGeneration,
              previousSender.captureRouteProofGeneration
                == currentSender.captureRouteProofGeneration else {
            return .bindingChanged
        }

        let elapsed = current.statistics.collectedAt
            .timeIntervalSince(previous.statistics.collectedAt)
        guard elapsed.isFinite, elapsed > 0 else {
            return .timestampRegressed
        }

        let monotonic =
            currentSender.realtimeAdmissionCount
                >= previousSender.realtimeAdmissionCount
            && currentSender.deliveryCallbackCount
                >= previousSender.deliveryCallbackCount
            && currentSender.deliveredFrameCount
                >= previousSender.deliveredFrameCount
            && current.statistics.packetsSent
                >= previous.statistics.packetsSent
            && current.statistics.bytesSent
                >= previous.statistics.bytesSent
        guard monotonic,
              audioTotalsDidNotRegress(
                previous: previous.statistics,
                current: current.statistics
              ) else {
            return .counterRegressed
        }

        guard currentSender.realtimeAdmissionCount
                > previousSender.realtimeAdmissionCount,
              currentSender.deliveryCallbackCount
                > previousSender.deliveryCallbackCount,
              currentSender.deliveredFrameCount
                > previousSender.deliveredFrameCount,
              current.statistics.packetsSent
                > previous.statistics.packetsSent,
              current.statistics.bytesSent
                > previous.statistics.bytesSent,
              audioTotalsAdvancedWhenPresent(
                previous: previous.statistics,
                current: current.statistics
              ) else {
            return .counterStalled
        }

        let admissionDelta = currentSender.realtimeAdmissionCount
            - previousSender.realtimeAdmissionCount
        let callbackDelta = currentSender.deliveryCallbackCount
            - previousSender.deliveryCallbackCount
        let frameDelta = currentSender.deliveredFrameCount
            - previousSender.deliveredFrameCount
        let packetDelta = current.statistics.packetsSent
            - previous.statistics.packetsSent
        let byteDelta = current.statistics.bytesSent
            - previous.statistics.bytesSent

        guard let audioDeltas = audioTotalDeltas(
            previous: previous.statistics,
            current: current.statistics
        ) else {
            return .counterRegressed
        }

        switch WorldwideRawMicrophoneRatePolicy.assess(
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

    private static func audioTotalsAreValid(
        _ statistics: WebRTCIPhoneMicrophoneSenderStatistics
    ) -> Bool {
        switch (
            statistics.totalAudioEnergy,
            statistics.totalSamplesDuration
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

    private static func audioTotalsDidNotRegress(
        previous: WebRTCIPhoneMicrophoneSenderStatistics,
        current: WebRTCIPhoneMicrophoneSenderStatistics
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

    private static func audioTotalsAdvancedWhenPresent(
        previous: WebRTCIPhoneMicrophoneSenderStatistics,
        current: WebRTCIPhoneMicrophoneSenderStatistics
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

    private static func audioTotalDeltas(
        previous: WebRTCIPhoneMicrophoneSenderStatistics,
        current: WebRTCIPhoneMicrophoneSenderStatistics
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

/// Versioned privacy-minimal accessibility payload emitted only after two coherent exact samples.
struct WorldwideRawMicrophoneOracleSnapshot: Equatable, Sendable {
    static let schemaVersion = 3
    static let maximumAccessibilityValueBytes = 1_024

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
    let captureRouteIsBuiltInMicrophone: Bool
    let captureRouteProofGeneration: UInt64
    let realtimeAdmissionCount: UInt64
    let deliveryCallbackCount: UInt64
    let deliveredFrameCount: UInt64
    let packetsSent: UInt64
    let bytesSent: UInt64
    let totalAudioEnergy: Double?
    let totalSamplesDuration: Double?
    let coherentSampleCount: UInt64

    fileprivate init?(
        windowGeneration: UUID,
        coherentSampleCount: UInt64,
        current: WorldwideRawMicrophoneProofSample
    ) {
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        guard processIdentifier > 0,
              coherentSampleCount >= 2,
              coherentSampleCount <= UInt64(Int64.max),
              WorldwideRawMicrophoneOracleEvaluator
                .hasValidState(current) else {
            return nil
        }
        applicationProcessIdentifier = processIdentifier
        let sender = current.statistics.sender
        sessionGeneration = current.sessionGeneration
        self.windowGeneration = windowGeneration
        transportAuthorizationGeneration =
            current.transportAuthorizationGeneration
        audioPolicyGeneration = current.audioPolicyGeneration
        negotiationEpoch = sender.negotiationEpoch
        bindingGeneration = sender.bindingGeneration
        trackGeneration = sender.trackGeneration
        microphonePolicyGeneration =
            sender.microphonePolicyGeneration
        recordingGeneration = sender.recordingGeneration
        approvedRecordingGeneration =
            sender.approvedRecordingGeneration
        captureRouteIsBuiltInMicrophone =
            sender.captureRouteIsBuiltInMicrophone
        captureRouteProofGeneration =
            sender.captureRouteProofGeneration
        realtimeAdmissionCount = sender.realtimeAdmissionCount
        deliveryCallbackCount = sender.deliveryCallbackCount
        deliveredFrameCount = sender.deliveredFrameCount
        packetsSent = current.statistics.packetsSent
        bytesSent = current.statistics.bytesSent
        totalAudioEnergy = current.statistics.totalAudioEnergy
        totalSamplesDuration =
            current.statistics.totalSamplesDuration
        self.coherentSampleCount = coherentSampleCount
        guard accessibilityValue.utf8.count
                <= Self.maximumAccessibilityValueBytes else {
            return nil
        }
    }

    var accessibilityValue: String {
        let energyValue: String =
            totalAudioEnergy.map { String($0) } ?? "missing"
        let durationValue: String =
            totalSamplesDuration.map { String($0) } ?? "missing"
        var fields: [String] = []
        fields.reserveCapacity(32)
        fields.append("v=\(Self.schemaVersion)")
        fields.append("pid=\(applicationProcessIdentifier)")
        fields.append("session=\(sessionGeneration.uuidString.lowercased())")
        fields.append("window=\(windowGeneration.uuidString.lowercased())")
        fields.append("transport=\(transportAuthorizationGeneration.uuidString.lowercased())")
        fields.append("audioPolicy=\(audioPolicyGeneration.uuidString.lowercased())")
        fields.append("negotiation=\(negotiationEpoch)")
        fields.append("binding=\(bindingGeneration)")
        fields.append("track=\(trackGeneration)")
        fields.append("micPolicy=\(microphonePolicyGeneration)")
        fields.append("recording=\(recordingGeneration)")
        fields.append("approved=\(approvedRecordingGeneration)")
        fields.append("admissions=\(realtimeAdmissionCount)")
        fields.append("callbacks=\(deliveryCallbackCount)")
        fields.append("frames=\(deliveredFrameCount)")
        fields.append("packets=\(packetsSent)")
        fields.append("bytes=\(bytesSent)")
        fields.append("energy=\(energyValue)")
        fields.append("duration=\(durationValue)")
        fields.append("samples=\(coherentSampleCount)")
        fields.append("paired=1")
        fields.append("intent=1")
        fields.append("call=0")
        fields.append("transportHealthy=1")
        fields.append("senderOwned=1")
        fields.append("trackEnabled=1")
        fields.append("raw=1")
        fields.append("topology=1")
        fields.append("deviceOpen=1")
        fields.append("authorizationOpen=1")
        fields.append("senderScoped=1")
        fields.append("captureBuiltInMic=1")
        return fields.joined(separator: "|")
    }
}

enum WorldwideRawMicrophoneContinuityResult: Equatable {
    case waiting
    case satisfied(WorldwideRawMicrophoneOracleSnapshot)
    case rejected
}

struct WorldwideRawMicrophoneContinuityTracker {
    private var windowGeneration = UUID()
    private var previous: WorldwideRawMicrophoneProofSample?
    private var coherentSampleCount: UInt64 = 0

    mutating func observe(
        _ sample: WorldwideRawMicrophoneProofSample
    ) -> WorldwideRawMicrophoneContinuityResult {
        guard WorldwideRawMicrophoneOracleEvaluator
                .hasValidState(sample) else {
            reset()
            return .rejected
        }
        guard let previous else {
            self.previous = sample
            coherentSampleCount = 1
            return .waiting
        }
        let delta = WorldwideRawMicrophoneOracleEvaluator.evaluate(
            previous: previous,
            current: sample
        )
        if delta == .bindingChanged,
           Self.isExactCaptureRouteProofRotation(
               previous: previous,
               current: sample
           ) {
            // A route notification invalidates the old proof at ingress. The first sample from
            // the newly validated built-in route is therefore the baseline for a new window,
            // never evidence for the retired window and never discarded before rebasing.
            windowGeneration = UUID()
            self.previous = sample
            coherentSampleCount = 1
            return .waiting
        }
        guard delta == .advancing,
        coherentSampleCount < UInt64(Int64.max) else {
            reset()
            return .rejected
        }

        coherentSampleCount += 1
        self.previous = sample
        guard let snapshot = WorldwideRawMicrophoneOracleSnapshot(
            windowGeneration: windowGeneration,
            coherentSampleCount: coherentSampleCount,
            current: sample
        ) else {
            reset()
            return .rejected
        }
        return .satisfied(snapshot)
    }

    private static func isExactCaptureRouteProofRotation(
        previous: WorldwideRawMicrophoneProofSample,
        current: WorldwideRawMicrophoneProofSample
    ) -> Bool {
        let previousSender = previous.statistics.sender
        let currentSender = current.statistics.sender
        return previousSender.captureRouteProofGeneration
                != currentSender.captureRouteProofGeneration
            && previousSender.peerEpoch == currentSender.peerEpoch
            && previousSender.bindingGeneration
                == currentSender.bindingGeneration
            && previousSender.negotiationEpoch
                == currentSender.negotiationEpoch
            && previousSender.trackGeneration
                == currentSender.trackGeneration
            && previousSender.microphonePolicyGeneration
                == currentSender.microphonePolicyGeneration
            && previousSender.recordingGeneration
                == currentSender.recordingGeneration
            && previousSender.approvedRecordingGeneration
                == currentSender.approvedRecordingGeneration
    }

    mutating func reset() {
        windowGeneration = UUID()
        previous = nil
        coherentSampleCount = 0
    }
}

/// Non-secret, machine-readable evidence exported through accessibility for the physical release
/// gate. These values deliberately contain only ephemeral session identity and monotonic RemoteIO
/// render-input counters from before iOS's final mixer/route/DAC/speaker output. Pairing material,
/// signaling credentials, and media never enter the accessibility tree.
struct WorldwideAudioPlayoutOracleSnapshot: Equatable, Sendable {
    static let schemaVersion = 2

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
    let inboundAudioEnergy: Double?
    let inboundSamplesDuration: Double?
    let fullQualityInvariantsHold: Bool

    init(
        sessionGeneration: UUID,
        audioPolicyGeneration: UUID,
        diagnostics: WebRTCIOSPlayoutDiagnostics,
        inboundAudio: WebRTCAudioStatistics? = nil
    ) {
        self.sessionGeneration = sessionGeneration
        self.audioPolicyGeneration = audioPolicyGeneration
        callbackCount = diagnostics.playoutCallbackCount
        frameCount = diagnostics.playoutFrameCount
        failureCount = diagnostics.playoutFailureCount
        pcmSampleCount = diagnostics.playoutPCMSampleCount
        pcmNonzeroSampleCount = diagnostics.playoutPCMNonzeroSampleCount
        pcmAbsoluteSampleSum = diagnostics.playoutPCMAbsoluteSampleSum
        pcmLeftAbsoluteSampleSum = diagnostics.playoutPCMLeftAbsoluteSampleSum
        pcmRightAbsoluteSampleSum = diagnostics.playoutPCMRightAbsoluteSampleSum
        pcmStereoDifferenceAbsoluteSampleSum =
            diagnostics.playoutPCMStereoDifferenceAbsoluteSampleSum
        pcmClippedSampleCount = diagnostics.playoutPCMClippedSampleCount
        explicitSilenceCallbackCount = diagnostics.playoutExplicitSilenceCallbackCount
        callbackGapViolationCount = diagnostics.playoutCallbackGapViolationCount
        maximumCallbackGapNanoseconds = diagnostics.playoutMaximumCallbackGapNanoseconds
        nearSilenceCallbackCount = diagnostics.playoutNearSilenceCallbackCount
        currentConsecutiveNearSilenceFrameCount =
            diagnostics.playoutCurrentConsecutiveNearSilenceFrameCount
        maximumConsecutiveNearSilenceFrameCount =
            diagnostics.playoutMaximumConsecutiveNearSilenceFrameCount
        pcmLeftZeroCrossingCount = diagnostics.playoutPCMLeftZeroCrossingCount
        pcmRightZeroCrossingCount = diagnostics.playoutPCMRightZeroCrossingCount
        pcmEnvelopeTransitionCount = diagnostics.playoutPCMEnvelopeTransitionCount
        pcmShapeAnomalyCallbackCount = diagnostics.playoutPCMShapeAnomalyCallbackCount
        pcmBoundaryDiscontinuityCallbackCount =
            diagnostics.playoutPCMBoundaryDiscontinuityCallbackCount
        lastCallbackMeanMagnitude = diagnostics.playoutLastCallbackMeanMagnitude
        recoveryRebuildCount = diagnostics.recoveryRebuildCount
        lastPeakMagnitude = diagnostics.lastPlayoutPeakMagnitude
        inboundAudioEnergy = inboundAudio?.totalAudioEnergy
        inboundSamplesDuration = inboundAudio?.totalSamplesDuration
        fullQualityInvariantsHold = Self.fullQualityInvariantsHold(diagnostics)
    }

    init(
        sessionGeneration: UUID,
        audioPolicyGeneration: UUID,
        callbackCount: UInt64,
        frameCount: UInt64,
        failureCount: UInt64,
        pcmSampleCount: UInt64 = 0,
        pcmNonzeroSampleCount: UInt64 = 0,
        pcmAbsoluteSampleSum: UInt64 = 0,
        pcmLeftAbsoluteSampleSum: UInt64 = 0,
        pcmRightAbsoluteSampleSum: UInt64 = 0,
        pcmStereoDifferenceAbsoluteSampleSum: UInt64 = 0,
        pcmClippedSampleCount: UInt64 = 0,
        explicitSilenceCallbackCount: UInt64 = 0,
        callbackGapViolationCount: UInt64 = 0,
        maximumCallbackGapNanoseconds: UInt64 = 0,
        nearSilenceCallbackCount: UInt64 = 0,
        currentConsecutiveNearSilenceFrameCount: UInt64 = 0,
        maximumConsecutiveNearSilenceFrameCount: UInt64 = 0,
        pcmLeftZeroCrossingCount: UInt64 = 0,
        pcmRightZeroCrossingCount: UInt64 = 0,
        pcmEnvelopeTransitionCount: UInt64 = 0,
        pcmShapeAnomalyCallbackCount: UInt64 = 0,
        pcmBoundaryDiscontinuityCallbackCount: UInt64 = 0,
        lastCallbackMeanMagnitude: UInt32 = 0,
        recoveryRebuildCount: UInt64 = 0,
        lastPeakMagnitude: UInt32 = 0,
        inboundAudioEnergy: Double? = nil,
        inboundSamplesDuration: Double? = nil,
        fullQualityInvariantsHold: Bool
    ) {
        self.sessionGeneration = sessionGeneration
        self.audioPolicyGeneration = audioPolicyGeneration
        self.callbackCount = callbackCount
        self.frameCount = frameCount
        self.failureCount = failureCount
        self.pcmSampleCount = pcmSampleCount
        self.pcmNonzeroSampleCount = pcmNonzeroSampleCount
        self.pcmAbsoluteSampleSum = pcmAbsoluteSampleSum
        self.pcmLeftAbsoluteSampleSum = pcmLeftAbsoluteSampleSum
        self.pcmRightAbsoluteSampleSum = pcmRightAbsoluteSampleSum
        self.pcmStereoDifferenceAbsoluteSampleSum =
            pcmStereoDifferenceAbsoluteSampleSum
        self.pcmClippedSampleCount = pcmClippedSampleCount
        self.explicitSilenceCallbackCount = explicitSilenceCallbackCount
        self.callbackGapViolationCount = callbackGapViolationCount
        self.maximumCallbackGapNanoseconds = maximumCallbackGapNanoseconds
        self.nearSilenceCallbackCount = nearSilenceCallbackCount
        self.currentConsecutiveNearSilenceFrameCount =
            currentConsecutiveNearSilenceFrameCount
        self.maximumConsecutiveNearSilenceFrameCount =
            maximumConsecutiveNearSilenceFrameCount
        self.pcmLeftZeroCrossingCount = pcmLeftZeroCrossingCount
        self.pcmRightZeroCrossingCount = pcmRightZeroCrossingCount
        self.pcmEnvelopeTransitionCount = pcmEnvelopeTransitionCount
        self.pcmShapeAnomalyCallbackCount = pcmShapeAnomalyCallbackCount
        self.pcmBoundaryDiscontinuityCallbackCount =
            pcmBoundaryDiscontinuityCallbackCount
        self.lastCallbackMeanMagnitude = lastCallbackMeanMagnitude
        self.recoveryRebuildCount = recoveryRebuildCount
        self.lastPeakMagnitude = lastPeakMagnitude
        self.inboundAudioEnergy = inboundAudioEnergy
        self.inboundSamplesDuration = inboundSamplesDuration
        self.fullQualityInvariantsHold = fullQualityInvariantsHold
    }

    var accessibilityValue: String {
        let inboundEnergyValue: String =
            inboundAudioEnergy.map { String($0) } ?? "missing"
        let inboundDurationValue: String =
            inboundSamplesDuration.map { String($0) } ?? "missing"
        var fields: [String] = []
        fields.reserveCapacity(30)
        fields.append("v=\(Self.schemaVersion)")
        fields.append("session=\(sessionGeneration.uuidString.lowercased())")
        fields.append("audioPolicy=\(audioPolicyGeneration.uuidString.lowercased())")
        fields.append("callbacks=\(callbackCount)")
        fields.append("frames=\(frameCount)")
        fields.append("failures=\(failureCount)")
        fields.append("pcmSamples=\(pcmSampleCount)")
        fields.append("pcmNonzero=\(pcmNonzeroSampleCount)")
        fields.append("pcmAbs=\(pcmAbsoluteSampleSum)")
        fields.append("pcmLeftAbs=\(pcmLeftAbsoluteSampleSum)")
        fields.append("pcmRightAbs=\(pcmRightAbsoluteSampleSum)")
        fields.append("pcmStereoDiffAbs=\(pcmStereoDifferenceAbsoluteSampleSum)")
        fields.append("pcmClipped=\(pcmClippedSampleCount)")
        fields.append("silenceCallbacks=\(explicitSilenceCallbackCount)")
        fields.append("gapViolations=\(callbackGapViolationCount)")
        fields.append("maxGapNs=\(maximumCallbackGapNanoseconds)")
        fields.append("nearSilenceCallbacks=\(nearSilenceCallbackCount)")
        fields.append("currentNearSilenceFrames=\(currentConsecutiveNearSilenceFrameCount)")
        fields.append("maxNearSilenceFrames=\(maximumConsecutiveNearSilenceFrameCount)")
        fields.append("leftCrossings=\(pcmLeftZeroCrossingCount)")
        fields.append("rightCrossings=\(pcmRightZeroCrossingCount)")
        fields.append("envelopeTransitions=\(pcmEnvelopeTransitionCount)")
        fields.append("shapeAnomalies=\(pcmShapeAnomalyCallbackCount)")
        fields.append("boundaryDiscontinuities=\(pcmBoundaryDiscontinuityCallbackCount)")
        fields.append("callbackMean=\(lastCallbackMeanMagnitude)")
        fields.append("rebuilds=\(recoveryRebuildCount)")
        fields.append("peak=\(lastPeakMagnitude)")
        fields.append("inboundEnergy=\(inboundEnergyValue)")
        fields.append("inboundDuration=\(inboundDurationValue)")
        fields.append("fullQuality=\(fullQualityInvariantsHold ? 1 : 0)")
        return fields.joined(separator: "|")
    }

    static func fullQualityInvariantsHold(
        _ diagnostics: WebRTCIOSPlayoutDiagnostics
    ) -> Bool {
        routeInvariantsHold(diagnostics)
            && diagnostics.playoutFailureCount == 0
    }

    /// Route/configuration proof used by the recoverable runtime state machine. A prior render
    /// failure may be accepted there only through that state machine's captured failure floor; the
    /// stricter physical release snapshot above still requires a zero lifetime failure count.
    static func routeInvariantsHold(
        _ diagnostics: WebRTCIOSPlayoutDiagnostics
    ) -> Bool {
        let categoryMatchesInputPolicy: Bool
        let categoryOptionsMatchInputPolicy: Bool
        if diagnostics.inputBusEnabled {
            categoryMatchesInputPolicy =
                !diagnostics.categoryIsMediaPlayback
                && diagnostics.categoryIsMediaPlayAndRecord
            categoryOptionsMatchInputPolicy =
                !diagnostics.categoryOptionsAreEmpty
                && diagnostics.categoryOptionsAreIPhoneMicrophoneRouting
                && !diagnostics.categoryOptionsAreMixWithOthers
        } else {
            categoryMatchesInputPolicy =
                diagnostics.categoryIsMediaPlayback
                && !diagnostics.categoryIsMediaPlayAndRecord
            categoryOptionsMatchInputPolicy =
                diagnostics.categoryOptionsAreEmpty
                && !diagnostics.categoryOptionsAreIPhoneMicrophoneRouting
                && !diagnostics.categoryOptionsAreMixWithOthers
        }

        return diagnostics.initialized
            && diagnostics.playoutInitialized
            && diagnostics.playing
            && diagnostics.sessionActive
            && diagnostics.ownsSessionActivation
            && diagnostics.remoteIOCreated
            && diagnostics.outputBusEnabled
            && !diagnostics.recoveryRequired
            && !diagnostics.explicitResumeRequired
            && categoryMatchesInputPolicy
            && diagnostics.modeIsDefault
            && categoryOptionsMatchInputPolicy
            && diagnostics.routeSharingPolicyIsDefault
            && abs(diagnostics.sampleRate - 48_000) < 1
            && diagnostics.outputIOBufferDuration > 0
            && diagnostics.outputIOBufferDuration <= 0.020
            && diagnostics.outputChannelCount == 2
            && diagnostics.audioUnitSubType == kAudioUnitSubType_RemoteIO
            && diagnostics.failureCode == 0
            && diagnostics.lastLifecycleStatus == noErr
            && diagnostics.lastPlayoutStatus == noErr
            && diagnostics.unexpectedRecordingRequestCount == 0
            && diagnostics.lastPlayoutFrameCount > 0
    }
}

/// Privacy-minimal hosted-call playout evidence for the physical release gate.
///
/// The counters are RemoteIO render-input observations from before iOS's final mixer, route
/// processing, DAC, and speaker. They do not claim final speaker audibility. Pairing material,
/// signaling credentials, device identity, and media never enter this snapshot.
struct WorldwideHostedCallPlayoutOracleSnapshot: Equatable, Sendable {
    let sessionGeneration: UUID
    let policyID: UUID
    let origin: WebRTCIOSHostedCallPlayoutOrigin
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
    let inboundBytes: UInt64?
    let inboundPackets: UInt64?
    let inboundJitterBufferEmittedCount: UInt64?
    let inboundTotalSamplesReceived: UInt64?
    let inboundAudioEnergy: Double?
    let inboundSamplesDuration: Double?
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

    init?(
        sessionGeneration: UUID,
        policyID: UUID,
        origin authorizationOrigin: WebRTCIOSHostedCallPlayoutOrigin,
        audioPolicyGeneration: UUID,
        authorizationPolicyID: UUID,
        authorizationGeneration: UInt64,
        authorizationIsValid: Bool,
        authorizationIsRecoveryPending: Bool,
        diagnostics: WebRTCIOSPlayoutDiagnostics,
        inboundAudio: WebRTCAudioStatistics,
        connectedCallKitSnapshot: Bool
    ) {
        guard let nativeOrigin = diagnostics.hostedCallOrigin,
              nativeOrigin == authorizationOrigin else {
            return nil
        }

        self.sessionGeneration = sessionGeneration
        self.policyID = policyID
        origin = nativeOrigin
        self.audioPolicyGeneration = audioPolicyGeneration
        systemAudioGeneration = diagnostics.systemAudioGeneration
        self.authorizationGeneration = authorizationGeneration
        nativeAuthorizationGeneration = diagnostics.hostedCallAuthorizationGeneration
        callbackCount = diagnostics.playoutCallbackCount
        frameCount = diagnostics.playoutFrameCount
        failureCount = diagnostics.playoutFailureCount
        pcmNonzeroSampleCount = diagnostics.playoutPCMNonzeroSampleCount
        pcmAbsoluteSampleSum = diagnostics.playoutPCMAbsoluteSampleSum
        unexpectedRecordingRequestCount = diagnostics.unexpectedRecordingRequestCount
        inboundBytes = inboundAudio.bytes
        inboundPackets = inboundAudio.packets
        inboundJitterBufferEmittedCount = inboundAudio.jitterBufferEmittedCount
        inboundTotalSamplesReceived = inboundAudio.totalSamplesReceived
        if let value = inboundAudio.totalAudioEnergy, value.isFinite {
            inboundAudioEnergy = value
        } else {
            inboundAudioEnergy = nil
        }
        if let value = inboundAudio.totalSamplesDuration, value.isFinite {
            inboundSamplesDuration = value
        } else {
            inboundSamplesDuration = nil
        }
        outputBusEnabled = diagnostics.outputBusEnabled
        inputBusEnabled = diagnostics.inputBusEnabled
        categoryIsMediaPlayback = diagnostics.categoryIsMediaPlayback
        modeIsDefault = diagnostics.modeIsDefault
        categoryOptionsAreMixWithOthers = diagnostics.categoryOptionsAreMixWithOthers
        remoteIOCreated = diagnostics.remoteIOCreated
        audioUnitIsRemoteIO = diagnostics.audioUnitSubType == kAudioUnitSubType_RemoteIO
        activeSessionOwnership = diagnostics.sessionActive && diagnostics.ownsSessionActivation
        hostedCallMode = diagnostics.hostedCallMode
        self.authorizationIsValid = authorizationIsValid
        authorizationIsConsumed = !authorizationIsRecoveryPending
        nativeAuthorizationIsValid = diagnostics.hostedCallAuthorizationValid
        nativeAuthorizationIsConsumed = !diagnostics.hostedCallRecoveryPending
        authorizationPolicyMatches = authorizationPolicyID == policyID
        authorizationGenerationMatches =
            authorizationGeneration != 0
            && systemAudioGeneration == authorizationGeneration
            && nativeAuthorizationGeneration == authorizationGeneration
        self.connectedCallKitSnapshot = connectedCallKitSnapshot
    }

    var accessibilityValue: String {
        let inboundBytesValue: String =
            inboundBytes.map { String($0) } ?? "missing"
        let inboundPacketsValue: String =
            inboundPackets.map { String($0) } ?? "missing"
        let inboundJitterEmittedValue: String =
            inboundJitterBufferEmittedCount.map { String($0) } ?? "missing"
        let inboundSamplesValue: String =
            inboundTotalSamplesReceived.map { String($0) } ?? "missing"
        let inboundEnergyValue: String =
            inboundAudioEnergy.map { String($0) } ?? "missing"
        let inboundDurationValue: String =
            inboundSamplesDuration.map { String($0) } ?? "missing"
        var fields: [String] = []
        fields.reserveCapacity(36)
        fields.append("v=2")
        fields.append("origin=\(origin.rawValue)")
        fields.append("session=\(sessionGeneration.uuidString.lowercased())")
        fields.append("policy=\(policyID.uuidString.lowercased())")
        fields.append("audioPolicy=\(audioPolicyGeneration.uuidString.lowercased())")
        fields.append("systemAudioGeneration=\(systemAudioGeneration)")
        fields.append("authorizationGeneration=\(authorizationGeneration)")
        fields.append("nativeAuthorizationGeneration=\(nativeAuthorizationGeneration)")
        fields.append("callbacks=\(callbackCount)")
        fields.append("frames=\(frameCount)")
        fields.append("failures=\(failureCount)")
        fields.append("pcmNonzero=\(pcmNonzeroSampleCount)")
        fields.append("pcmAbs=\(pcmAbsoluteSampleSum)")
        fields.append("recordRequests=\(unexpectedRecordingRequestCount)")
        fields.append("inboundBytes=\(inboundBytesValue)")
        fields.append("inboundPackets=\(inboundPacketsValue)")
        fields.append("inboundJitterEmitted=\(inboundJitterEmittedValue)")
        fields.append("inboundSamples=\(inboundSamplesValue)")
        fields.append("inboundEnergy=\(inboundEnergyValue)")
        fields.append("inboundDuration=\(inboundDurationValue)")
        fields.append("output=\(outputBusEnabled ? 1 : 0)")
        fields.append("input=\(inputBusEnabled ? 1 : 0)")
        fields.append("playback=\(categoryIsMediaPlayback ? 1 : 0)")
        fields.append("defaultMode=\(modeIsDefault ? 1 : 0)")
        fields.append("mixWithOthers=\(categoryOptionsAreMixWithOthers ? 1 : 0)")
        fields.append("remoteIOCreated=\(remoteIOCreated ? 1 : 0)")
        fields.append("remoteIOSubtype=\(audioUnitIsRemoteIO ? 1 : 0)")
        fields.append("activeOwnership=\(activeSessionOwnership ? 1 : 0)")
        fields.append("hostedMode=\(hostedCallMode ? 1 : 0)")
        fields.append("authorizationValid=\(authorizationIsValid ? 1 : 0)")
        fields.append("authorizationConsumed=\(authorizationIsConsumed ? 1 : 0)")
        fields.append("nativeAuthorizationValid=\(nativeAuthorizationIsValid ? 1 : 0)")
        fields.append("nativeAuthorizationConsumed=\(nativeAuthorizationIsConsumed ? 1 : 0)")
        fields.append("authorizationPolicyMatches=\(authorizationPolicyMatches ? 1 : 0)")
        fields.append(
            "authorizationGenerationMatches=\(authorizationGenerationMatches ? 1 : 0)"
        )
        fields.append("callKitConnected=\(connectedCallKitSnapshot ? 1 : 0)")
        return fields.joined(separator: "|")
    }
}

/// Accessibility-safe proof that the Mac acknowledged a specific show/hide request for the active
/// session generation. It carries no screen pixels, device identity, or signaling material.
struct WorldwideScreenAcknowledgementOracleSnapshot: Equatable, Sendable {
    enum Command: String, Equatable, Sendable {
        case show
        case hide
    }

    enum State: String, Equatable, Sendable {
        case active
        case inactive
    }

    let sessionGeneration: UUID
    let requestID: UInt64
    let command: Command
    let state: State

    var accessibilityValue: String {
        [
            "v=1",
            "session=\(sessionGeneration.uuidString.lowercased())",
            "request=\(requestID)",
            "command=\(command.rawValue)",
            "state=\(state.rawValue)",
        ].joined(separator: "|")
    }

}

/// Monotonic evidence derived from frames that reached the iPhone renderer.
/// The rolling digest/change counters let a physical UI test reject a static or frozen image
/// without exporting the underlying pixels through accessibility.
struct WorldwideVideoRenderOracleSnapshot: Equatable, Sendable {
    let rendererID: UUID
    let frameCount: UInt64
    let timestampNanoseconds: Int64
    let width: Int
    let height: Int
    let contentDigest: UInt64
    let contentSampleCount: UInt64
    let contentChangeCount: UInt64

    init(
        rendererID: UUID,
        observation: WebRTCVideoRenderObservation
    ) {
        self.rendererID = rendererID
        frameCount = observation.frameCount
        timestampNanoseconds = observation.timestampNanoseconds
        width = observation.width
        height = observation.height
        contentDigest = observation.contentDigest
        contentSampleCount = observation.contentSampleCount
        contentChangeCount = observation.contentChangeCount
    }

    init(
        rendererID: UUID,
        frameCount: UInt64,
        timestampNanoseconds: Int64,
        width: Int,
        height: Int,
        contentDigest: UInt64 = 0,
        contentSampleCount: UInt64 = 0,
        contentChangeCount: UInt64 = 0
    ) {
        self.rendererID = rendererID
        self.frameCount = frameCount
        self.timestampNanoseconds = timestampNanoseconds
        self.width = width
        self.height = height
        self.contentDigest = contentDigest
        self.contentSampleCount = contentSampleCount
        self.contentChangeCount = contentChangeCount
    }

    var accessibilityValue: String {
        [
            "v=1",
            "renderer=\(rendererID.uuidString.lowercased())",
            "frames=\(frameCount)",
            "timestampNs=\(timestampNanoseconds)",
            "width=\(width)",
            "height=\(height)",
            "contentDigest=\(contentDigest)",
            "contentSamples=\(contentSampleCount)",
            "contentChanges=\(contentChangeCount)",
        ].joined(separator: "|")
    }
}
