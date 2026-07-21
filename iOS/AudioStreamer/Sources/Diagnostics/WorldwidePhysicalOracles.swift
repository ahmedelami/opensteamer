import AudioToolbox
import Foundation
import WebRTCTransport

/// Non-secret, machine-readable evidence exported through accessibility for the physical release
/// gate. These values deliberately contain only ephemeral session identity and monotonic RemoteIO
/// render-input counters from before iOS's final mixer/route/DAC/speaker output. Pairing material,
/// signaling credentials, and media never enter the accessibility tree.
struct WorldwideAudioPlayoutOracleSnapshot: Equatable, Sendable {
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
    let inboundAudioEnergy: Double?
    let inboundSamplesDuration: Double?
    let fullQualityInvariantsHold: Bool

    init(
        sessionGeneration: UUID,
        diagnostics: WebRTCIOSPlayoutDiagnostics,
        inboundAudio: WebRTCAudioStatistics? = nil
    ) {
        self.sessionGeneration = sessionGeneration
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
        [
            "v=1",
            "session=\(sessionGeneration.uuidString.lowercased())",
            "callbacks=\(callbackCount)",
            "frames=\(frameCount)",
            "failures=\(failureCount)",
            "pcmSamples=\(pcmSampleCount)",
            "pcmNonzero=\(pcmNonzeroSampleCount)",
            "pcmAbs=\(pcmAbsoluteSampleSum)",
            "pcmLeftAbs=\(pcmLeftAbsoluteSampleSum)",
            "pcmRightAbs=\(pcmRightAbsoluteSampleSum)",
            "pcmStereoDiffAbs=\(pcmStereoDifferenceAbsoluteSampleSum)",
            "pcmClipped=\(pcmClippedSampleCount)",
            "silenceCallbacks=\(explicitSilenceCallbackCount)",
            "gapViolations=\(callbackGapViolationCount)",
            "maxGapNs=\(maximumCallbackGapNanoseconds)",
            "nearSilenceCallbacks=\(nearSilenceCallbackCount)",
            "currentNearSilenceFrames=\(currentConsecutiveNearSilenceFrameCount)",
            "maxNearSilenceFrames=\(maximumConsecutiveNearSilenceFrameCount)",
            "leftCrossings=\(pcmLeftZeroCrossingCount)",
            "rightCrossings=\(pcmRightZeroCrossingCount)",
            "envelopeTransitions=\(pcmEnvelopeTransitionCount)",
            "shapeAnomalies=\(pcmShapeAnomalyCallbackCount)",
            "boundaryDiscontinuities=\(pcmBoundaryDiscontinuityCallbackCount)",
            "callbackMean=\(lastCallbackMeanMagnitude)",
            "rebuilds=\(recoveryRebuildCount)",
            "peak=\(lastPeakMagnitude)",
            "inboundEnergy=\(inboundAudioEnergy.map { String($0) } ?? "missing")",
            "inboundDuration=\(inboundSamplesDuration.map { String($0) } ?? "missing")",
            "fullQuality=\(fullQualityInvariantsHold ? 1 : 0)",
        ].joined(separator: "|")
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
        diagnostics.initialized
            && diagnostics.playoutInitialized
            && diagnostics.playing
            && diagnostics.sessionActive
            && diagnostics.ownsSessionActivation
            && diagnostics.remoteIOCreated
            && !diagnostics.inputBusEnabled
            && diagnostics.outputBusEnabled
            && !diagnostics.recoveryRequired
            && !diagnostics.explicitResumeRequired
            && diagnostics.categoryIsMediaPlayback
            && diagnostics.modeIsDefault
            && diagnostics.categoryOptionsAreEmpty
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
