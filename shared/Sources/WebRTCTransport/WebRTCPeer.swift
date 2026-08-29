@preconcurrency import LiveKitWebRTC
#if os(macOS)
import MacWebRTCAudioDeviceShim
#elseif os(iOS)
import AudioToolbox
import IOSWebRTCAudioDeviceShim
#endif
import Foundation
import RemoteSessionCore

/// The non-sensitive portion of an input request needed after its one network delivery.
///
/// Do not add the action or encoded request here: committed text may contain credentials.
struct WebRTCInputRequestBinding: Equatable, Sendable {
    let id: UInt64
    let screenRequestID: UInt64
    let inputSessionID: UUID

    init(_ request: WebRTCInputRequest) {
        id = request.id
        screenRequestID = request.screenRequestID
        inputSessionID = request.inputSessionID
    }
}

#if DEBUG
/// Sender encoding limits observed after applying the product's high-fidelity Opus policy.
struct WebRTCAudioSenderEncodingParameters: Equatable, Sendable {
    let maximumBitrateBps: Int?
    let minimumBitrateBps: Int?
}

/// Requested and native activation state for one audio-processing component.
struct WebRTCAudioProcessingComponentSnapshot: Equatable, Sendable {
    let requestedEnabled: Bool?
    let softwareActive: Bool
    let platformActive: Bool
}

/// Proof that call-oriented processing remains disabled for system-audio transport.
struct WebRTCAudioProcessingSnapshot: Equatable, Sendable {
    let hasAudioProcessingModule: Bool
    let echoCancellation: WebRTCAudioProcessingComponentSnapshot
    let noiseSuppression: WebRTCAudioProcessingComponentSnapshot
    let autoGainControl: WebRTCAudioProcessingComponentSnapshot
    let highPassFilter: WebRTCAudioProcessingComponentSnapshot
}

struct WebRTCIPhoneMicrophoneSenderSnapshot: Equatable, Sendable {
    let bindingNegotiationEpoch: UInt64?
    let currentNegotiationEpoch: UInt64
    let senderOwnsLocalTrack: Bool
    let rawProcessingRequestCount: Int
    let rawProcessingWasEverRequestedWithoutCurrentSender: Bool
    let rawProcessingAppliedResultCount: Int
    let rawProcessingStoredResultCount: Int
    let lastRawProcessingResultCodeRawValue: Int?
    let trackIsEnabled: Bool
    let nativeRecordingGeneration: UInt64?
    let nativeApprovedRecordingGeneration: UInt64?
    let nativeDeliveryCallbackCount: UInt64?
    let nativeDeliveredFrameCount: UInt64?
}
#endif

enum WebRTCNativeWrapperIdentity {
    static func isSemanticallyEqual(
        _ lhs: AnyObject?,
        _ rhs: AnyObject?
    ) -> Bool {
        guard let lhs = lhs as? NSObject,
              let rhs = rhs as? NSObject else {
            return false
        }
        return lhs.isEqual(rhs) && rhs.isEqual(lhs)
    }
}

/// Acquires the system-audio authorization before the causal-evidence authorization everywhere.
/// Native inactivity uses the same order while revoking an evidence token, preventing an ABBA
/// deadlock between a final evidence send and synchronous fail-close revocation.
enum WebRTCMacHostedCallEvidenceAuthorizationOrder {
    static func withValidAuthorizations<Result>(
        audioAuthorization: WebRTCAudioAuthorization,
        evidenceAuthorization:
            WebRTCMacHostedCallEvidenceAuthorization,
        expectedCallEpochNonce: UUID,
        afterAudioAuthorizationAcquired: () -> Void = {},
        operation: () throws -> Result
    ) throws -> Result {
        try audioAuthorization.withValidAuthorization {
            afterAudioAuthorizationAcquired()
            return try evidenceAuthorization.withValidAuthorization {
                guard evidenceAuthorization.callEpochNonce
                        == expectedCallEpochNonce else {
                    throw WebRTCTransportError.transportNotHealthy
                }
                return try operation()
            }
        }
    }
}

enum WebRTCIPhoneMicrophoneTransceiverAdmission {
    static func directionIncludesSending(
        _ direction: LKRTCRtpTransceiverDirection
    ) -> Bool {
        switch direction {
        case .sendRecv, .sendOnly:
            return true
        case .recvOnly, .inactive, .stopped:
            return false
        @unknown default:
            return false
        }
    }

    static func directionIncludesReceiving(
        _ direction: LKRTCRtpTransceiverDirection
    ) -> Bool {
        switch direction {
        case .sendRecv, .recvOnly:
            return true
        case .sendOnly, .inactive, .stopped:
            return false
        @unknown default:
            return false
        }
    }

    static func permitsConfiguredSending(
        isStopped: Bool,
        preferredDirection: LKRTCRtpTransceiverDirection
    ) -> Bool {
        !isStopped && directionIncludesSending(preferredDirection)
    }

    static func permitsNegotiatedSending(
        isStopped: Bool,
        preferredDirection: LKRTCRtpTransceiverDirection,
        currentDirection: LKRTCRtpTransceiverDirection?
    ) -> Bool {
        permitsConfiguredSending(
            isStopped: isStopped,
            preferredDirection: preferredDirection
        ) && currentDirection.map {
            directionIncludesSending($0)
        } == true
    }
}

enum WebRTCIPhoneMicrophoneNativeOwnership {
    static func isCurrent(
        bindingTransceiver: AnyObject,
        currentTransceiver: AnyObject,
        bindingSender: AnyObject,
        currentSender: AnyObject,
        bindingTrack: AnyObject,
        currentTrack: AnyObject,
        bindingMID: String,
        currentMID: String?,
        bindingSenderID: String,
        currentSenderID: String,
        bindingTrackID: String,
        currentTrackID: String
    ) -> Bool {
        !bindingMID.isEmpty
            && !bindingSenderID.isEmpty
            && !bindingTrackID.isEmpty
            && currentMID == bindingMID
            && currentSenderID == bindingSenderID
            && currentTrackID == bindingTrackID
            && WebRTCNativeWrapperIdentity.isSemanticallyEqual(
                bindingTransceiver,
                currentTransceiver
            )
            && WebRTCNativeWrapperIdentity.isSemanticallyEqual(
                bindingSender,
                currentSender
            )
            && WebRTCNativeWrapperIdentity.isSemanticallyEqual(
                bindingTrack,
                currentTrack
            )
    }
}

private struct WebRTCIPhoneMicrophoneSenderBinding {
    let generation: UInt64
    let negotiationEpoch: UInt64
    let trackGeneration: UInt64
    let mid: String
    let transceiver: LKRTCRtpTransceiver
    let senderID: String
    let sender: LKRTCRtpSender
    let localTrackID: String
    let localTrack: LKRTCAudioTrack
}

struct WebRTCIPhoneMicrophoneSenderStatisticsValidation: Equatable {
    let peerEpoch: UUID
    let bindingGeneration: UInt64
    let negotiationEpoch: UInt64
    let trackGeneration: UInt64
    let microphonePolicyGeneration: UInt64
    let recordingGeneration: UInt64
    let approvedRecordingGeneration: UInt64
    let captureRouteProofGeneration: UInt64
    let authorizationIdentity: ObjectIdentifier
    let senderID: String
    let localTrackID: String
    let mid: String
}

struct WebRTCIPhoneMicrophoneSenderStatisticsBaseline: Equatable {
    let validation: WebRTCIPhoneMicrophoneSenderStatisticsValidation
    let outboundRTPRecordIDs: [String]
    let statistics: WebRTCIPhoneMicrophoneSenderStatistics
}

struct WebRTCIPhoneMicrophoneSenderStatisticsSamplingResult: Equatable {
    let statistics: WebRTCIPhoneMicrophoneSenderStatistics?
    let baseline: WebRTCIPhoneMicrophoneSenderStatisticsBaseline
    let requiresAdvancingEvidence: Bool
}

enum WebRTCIPhoneMicrophoneSenderStatisticsSampler {
    private static let maximumCounter = UInt64(Int64.max)
    private static let maximumReportAge: TimeInterval = 5
    private static let maximumFutureSkew: TimeInterval = 0.250

    static func evaluate(
        parsed: WebRTCIPhoneMicrophoneOutboundStatistics?,
        captured: WebRTCIPhoneMicrophoneSenderStatisticsValidation,
        current: WebRTCIPhoneMicrophoneSenderStatisticsValidation?,
        diagnostics: WebRTCIPhoneMicrophoneSenderDiagnostics?,
        callbackCompletedAt: Date,
        currentTime: Date,
        previousBaseline:
            WebRTCIPhoneMicrophoneSenderStatisticsBaseline? = nil,
        requiresAdvancingEvidence: Bool = false
    ) -> WebRTCIPhoneMicrophoneSenderStatisticsSamplingResult? {
        guard let parsed,
              let current,
              let diagnostics,
              let collectedAt = reportDate(
                timestampMicroseconds:
                    parsed.reportTimestampMicroseconds,
                callbackCompletedAt: callbackCompletedAt,
                currentTime: currentTime
              ),
              captured == current,
              !current.senderID.isEmpty,
              !current.localTrackID.isEmpty,
              !current.mid.isEmpty,
              !requiresAdvancingEvidence || previousBaseline != nil,
              diagnostics.peerEpoch == current.peerEpoch,
              diagnostics.bindingGeneration == current.bindingGeneration,
              diagnostics.negotiationEpoch == current.negotiationEpoch,
              diagnostics.trackGeneration == current.trackGeneration,
              diagnostics.microphonePolicyGeneration
                == current.microphonePolicyGeneration,
              diagnostics.recordingGeneration
                == current.recordingGeneration,
              diagnostics.approvedRecordingGeneration
                == current.approvedRecordingGeneration,
              diagnostics.captureRouteProofGeneration
                == current.captureRouteProofGeneration,
              diagnostics.captureRouteProofGeneration > 0,
              diagnostics.senderOwnsMID,
              diagnostics.senderOwnsLocalTrack,
              !diagnostics.transceiverIsStopped,
              diagnostics.preferredDirectionIncludesSending,
              diagnostics.currentDirectionIncludesSending,
              diagnostics.trackIsEnabled,
              diagnostics.rawProcessingIsLive,
              diagnostics.transportIsHealthy,
              diagnostics.authorizationIsCurrent,
              diagnostics.authorizationIsValid,
              diagnostics.senderIsAdmitted,
              diagnostics.nativeDeviceIsOpen,
              diagnostics.nativeDeviceGateIsOpen,
              diagnostics.nativeAuthorizationGateIsOpen,
              diagnostics.categoryIsPlayAndRecord,
              diagnostics.modeIsDefault,
              diagnostics.usesRemoteIO,
              diagnostics.inputBusEnabled,
              diagnostics.captureRouteIsBuiltInMicrophone,
              diagnostics.outputBusEnabled,
              !diagnostics.categoryOptionsAreEmpty,
              diagnostics.categoryOptionsAreIPhoneMicrophoneRouting,
              diagnostics.routeSharingPolicyIsDefault,
              diagnostics.hasOutputRoute,
              diagnostics.sampleRateIs48k,
              diagnostics.ioBufferDurationIsBounded,
              diagnostics.outputChannelCountIsStereo,
              !diagnostics.recoveryRequired,
              !diagnostics.explicitResumeRequired,
              !diagnostics.hostedCallMode,
              diagnostics.failureCode == 0,
              diagnostics.lastLifecycleStatus == 0,
              diagnostics.bindingGeneration > 0,
              diagnostics.trackGeneration > 0,
              diagnostics.microphonePolicyGeneration > 0,
              diagnostics.recordingGeneration > 0,
              diagnostics.recordingGeneration
                == diagnostics.approvedRecordingGeneration,
              diagnostics.realtimeAdmissionCount <= maximumCounter,
              diagnostics.deliveryCallbackCount <= maximumCounter,
              diagnostics.deliveredFrameCount <= maximumCounter,
              diagnostics.deliveryCallbackCount
                <= diagnostics.realtimeAdmissionCount,
              diagnostics.deliveredFrameCount
                >= diagnostics.deliveryCallbackCount,
              !parsed.outboundRTPRecordIDs.isEmpty,
              parsed.outboundRTPRecordIDs.allSatisfy({ !$0.isEmpty }),
              Set(parsed.outboundRTPRecordIDs).count
                == parsed.outboundRTPRecordIDs.count,
              parsed.packetsSent <= maximumCounter,
              parsed.bytesSent <= maximumCounter,
              parsed.bytesSent >= parsed.packetsSent,
              audioTotalsAreValid(
                energy: parsed.totalAudioEnergy,
                duration: parsed.totalSamplesDuration
              ) else {
            return nil
        }

        let statistics = WebRTCIPhoneMicrophoneSenderStatistics(
            collectedAt: collectedAt,
            sender: diagnostics,
            packetsSent: parsed.packetsSent,
            bytesSent: parsed.bytesSent,
            totalAudioEnergy: parsed.totalAudioEnergy,
            totalSamplesDuration: parsed.totalSamplesDuration,
            sourceReportWasLinked: parsed.sourceReportWasLinked
        )
        let baseline = WebRTCIPhoneMicrophoneSenderStatisticsBaseline(
            validation: current,
            outboundRTPRecordIDs:
                parsed.outboundRTPRecordIDs.sorted(),
            statistics: statistics
        )

        guard let previousBaseline else {
            return WebRTCIPhoneMicrophoneSenderStatisticsSamplingResult(
                statistics: statistics,
                baseline: baseline,
                requiresAdvancingEvidence: false
            )
        }

        if previousBaseline.validation
            .captureRouteProofGeneration
            != current.captureRouteProofGeneration {
            return WebRTCIPhoneMicrophoneSenderStatisticsSamplingResult(
                statistics: nil,
                baseline: baseline,
                requiresAdvancingEvidence: true
            )
        }

        let previous = previousBaseline.statistics
        guard previousBaseline.validation == current,
              previous.sender.peerEpoch == diagnostics.peerEpoch,
              previous.sender.bindingGeneration
                == diagnostics.bindingGeneration,
              previous.sender.negotiationEpoch
                == diagnostics.negotiationEpoch,
              previous.sender.trackGeneration
                == diagnostics.trackGeneration,
              previous.sender.microphonePolicyGeneration
                == diagnostics.microphonePolicyGeneration,
              previous.sender.recordingGeneration
                == diagnostics.recordingGeneration,
              previous.sender.approvedRecordingGeneration
                == diagnostics.approvedRecordingGeneration,
              previous.sender.captureRouteProofGeneration
                == diagnostics.captureRouteProofGeneration,
              previous.collectedAt <= collectedAt,
              diagnostics.realtimeAdmissionCount
                >= previous.sender.realtimeAdmissionCount,
              diagnostics.deliveryCallbackCount
                >= previous.sender.deliveryCallbackCount,
              diagnostics.deliveredFrameCount
                >= previous.sender.deliveredFrameCount else {
            return nil
        }

        let resetOccurred =
            previousBaseline.outboundRTPRecordIDs
                != baseline.outboundRTPRecordIDs
            || previous.sourceReportWasLinked
                != statistics.sourceReportWasLinked
            || parsed.packetsSent < previous.packetsSent
            || parsed.bytesSent < previous.bytesSent
            || audioTotalsReset(
                previousEnergy: previous.totalAudioEnergy,
                previousDuration: previous.totalSamplesDuration,
                currentEnergy: parsed.totalAudioEnergy,
                currentDuration: parsed.totalSamplesDuration
            )

        if resetOccurred {
            return WebRTCIPhoneMicrophoneSenderStatisticsSamplingResult(
                statistics: nil,
                baseline: baseline,
                requiresAdvancingEvidence: true
            )
        }

        let didAdvance =
            parsed.packetsSent > previous.packetsSent
            || parsed.bytesSent > previous.bytesSent
            || audioTotalsDidAdvance(
                previousEnergy: previous.totalAudioEnergy,
                previousDuration: previous.totalSamplesDuration,
                currentEnergy: parsed.totalAudioEnergy,
                currentDuration: parsed.totalSamplesDuration
            )
        if requiresAdvancingEvidence && !didAdvance {
            return WebRTCIPhoneMicrophoneSenderStatisticsSamplingResult(
                statistics: nil,
                baseline: baseline,
                requiresAdvancingEvidence: true
            )
        }

        return WebRTCIPhoneMicrophoneSenderStatisticsSamplingResult(
            statistics: statistics,
            baseline: baseline,
            requiresAdvancingEvidence: false
        )
    }

    private static func reportDate(
        timestampMicroseconds: Double,
        callbackCompletedAt: Date,
        currentTime: Date
    ) -> Date? {
        guard timestampMicroseconds.isFinite,
              timestampMicroseconds > 0,
              callbackCompletedAt.timeIntervalSince1970.isFinite,
              currentTime.timeIntervalSince1970.isFinite else {
            return nil
        }

        let reportSeconds = timestampMicroseconds / 1_000_000
        guard reportSeconds.isFinite else { return nil }
        let reportDate = Date(timeIntervalSince1970: reportSeconds)
        let callbackDelay =
            currentTime.timeIntervalSince(callbackCompletedAt)
        let callbackAge =
            callbackCompletedAt.timeIntervalSince(reportDate)
        let currentAge = currentTime.timeIntervalSince(reportDate)

        guard callbackDelay >= 0,
              callbackDelay <= maximumReportAge,
              callbackAge >= -maximumFutureSkew,
              callbackAge <= maximumReportAge,
              currentAge >= -maximumFutureSkew,
              currentAge <= maximumReportAge else {
            return nil
        }
        return reportDate
    }

    private static func audioTotalsAreValid(
        energy: Double?,
        duration: Double?
    ) -> Bool {
        switch (energy, duration) {
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

    private static func audioTotalsReset(
        previousEnergy: Double?,
        previousDuration: Double?,
        currentEnergy: Double?,
        currentDuration: Double?
    ) -> Bool {
        switch (
            previousEnergy,
            previousDuration,
            currentEnergy,
            currentDuration
        ) {
        case (nil, nil, nil, nil),
             (nil, nil, .some, .some):
            return false
        case let (
            .some(previousEnergy),
            .some(previousDuration),
            .some(currentEnergy),
            .some(currentDuration)
        ):
            return currentEnergy < previousEnergy
                || currentDuration < previousDuration
        case (.some, .some, nil, nil):
            return true
        default:
            return true
        }
    }

    private static func audioTotalsDidAdvance(
        previousEnergy: Double?,
        previousDuration: Double?,
        currentEnergy: Double?,
        currentDuration: Double?
    ) -> Bool {
        switch (
            previousEnergy,
            previousDuration,
            currentEnergy,
            currentDuration
        ) {
        case (nil, nil, nil, nil),
             (.some, .some, nil, nil):
            return false
        case let (nil, nil, .some(energy), .some(duration)):
            return energy > 0 || duration > 0
        case let (
            .some(previousEnergy),
            .some(previousDuration),
            .some(currentEnergy),
            .some(currentDuration)
        ):
            return currentEnergy > previousEnergy
                || currentDuration > previousDuration
        default:
            return false
        }
    }
}

private struct WebRTCIPhoneMicrophoneSenderStatisticsCapture {
    let sender: LKRTCRtpSender
    let validation: WebRTCIPhoneMicrophoneSenderStatisticsValidation
}

private struct WebRTCIPhoneMicrophoneSenderStatisticsReportCapture: Sendable {
    let parsed: WebRTCIPhoneMicrophoneOutboundStatistics?
    let callbackCompletedAt: Date
}

/// Bridges native callbacks without allowing a lost callback to suspend an actor forever.
/// Callback and deadline may race on unrelated queues, so the continuation is claimed under one
/// lock and always resumed outside that lock.
enum WebRTCBoundedCallback {
    static func value<Value: Sendable>(
        timeout: Duration,
        register: (@escaping @Sendable (Value) -> Void) -> Void
    ) async -> Value? {
        precondition(timeout > .zero)
        return await withCheckedContinuation { continuation in
            let resolver = WebRTCOneShotContinuation<Value?>(
                continuation
            )
            register { value in
                resolver.resolve(value)
            }
            Task.detached {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                resolver.resolve(nil)
            }
        }
    }
}

private final class WebRTCOneShotContinuation<Value: Sendable>:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resolve(_ value: Value) {
        let claimed = lock.withLock {
            let claimed = continuation
            continuation = nil
            return claimed
        }
        claimed?.resume(returning: value)
    }
}

struct WebRTCIPhoneMicrophoneReceiverStatisticsValidation: Equatable, Sendable {
    let peerEpoch: UUID
    let negotiationEpoch: UInt64
    let receiverID: String
    let remoteTrackID: String
    let mid: String
}

enum WebRTCIPhoneMicrophoneReceiverStatisticsSampler {
    static func evaluate(
        parsed: WebRTCIPhoneMicrophoneInboundStatistics?,
        captured: WebRTCIPhoneMicrophoneReceiverStatisticsValidation,
        current: WebRTCIPhoneMicrophoneReceiverStatisticsValidation?,
        nativeOwnershipIsCurrent: Bool
    ) -> WebRTCAudioStatistics? {
        guard let parsed,
              let current,
              nativeOwnershipIsCurrent,
              captured == current,
              !current.receiverID.isEmpty,
              !current.remoteTrackID.isEmpty,
              !current.mid.isEmpty else {
            return nil
        }
        return parsed.statistics
    }
}

private struct WebRTCIPhoneMicrophoneReceiverStatisticsCapture {
    let transceiver: LKRTCRtpTransceiver
    let receiver: LKRTCRtpReceiver
    let receiverTrack: LKRTCAudioTrack
    let remoteTrack: WebRTCRemoteAudioTrack
    let validation: WebRTCIPhoneMicrophoneReceiverStatisticsValidation
}

#if os(iOS)
public enum WebRTCIOSPlayoutRecoveryTerminalOutcome: Equatable, Sendable {
    case pending
    case accepted
    case rejected
    case revoked

    fileprivate init(
        native: ASIOSStereoPlayoutRecoveryTerminalOutcome
    ) {
        switch native {
        case .pending:
            self = .pending
        case .accepted:
            self = .accepted
        case .rejected:
            self = .rejected
        case .revoked:
            self = .revoked
        @unknown default:
            self = .rejected
        }
    }
}

/// Revocable ownership for one explicit native RemoteIO recovery attempt.
///
/// The Objective-C gate is linearizable: revocation shares the lock held across the final native
/// rebuild, so an ADM block queued by a retired peer cannot reactivate audio for a newer session.
public final class WebRTCIOSPlayoutRecoveryAuthorization: @unchecked Sendable {
    fileprivate let native = ASIOSStereoPlayoutRecoveryAuthorization()

    public init() {}

    public var isValid: Bool { native.isValid }
    public var generation: UInt64 { native.generation }
    public var terminalGeneration: UInt64 {
        native.terminalGeneration
    }
    public var terminalOutcome:
        WebRTCIOSPlayoutRecoveryTerminalOutcome {
        WebRTCIOSPlayoutRecoveryTerminalOutcome(
            native: native.terminalOutcome
        )
    }

    /// A terminal generation is the publication fence: after it matches this authorization,
    /// the immutable outcome can be consumed without treating rejection/revocation as success.
    public var hasAcceptedTerminalOutcome: Bool {
        terminalGeneration == generation
            && terminalOutcome == .accepted
    }

    public func revoke() {
        native.revoke()
    }

    #if DEBUG
    @discardableResult
    public func performIfValidForTesting(_ operation: () -> Void) -> Bool {
        native.performIfValid(operation)
    }

    @discardableResult
    public func rejectIfValidForTesting() -> Bool {
        native.debugRejectIfValidForTesting()
    }
    #endif
}

/// Exact source of one hosted-call output-only policy.
public enum WebRTCIOSHostedCallPlayoutOrigin: String, Sendable {
    case interruption = "interruption"
    case startupConnectedCall = "startup-connected-call"

    fileprivate init?(native: ASIOSHostedCallPlayoutOrigin) {
        switch native {
        case .interruption:
            self = .interruption
        case .startupConnectedCall:
            self = .startupConnectedCall
        case .unspecified:
            return nil
        @unknown default:
            return nil
        }
    }

    fileprivate var native: ASIOSHostedCallPlayoutOrigin {
        switch self {
        case .interruption:
            return .interruption
        case .startupConnectedCall:
            return .startupConnectedCall
        }
    }
}

/// Persistent, revocable ownership for one connected hosted-call playout policy.
///
/// The native authorization carries the policy identity, exact origin, and one unconsumed native
/// claim. Revocation shares the native operation lock, so replacing the peer, ending the call, or
/// retiring the audio-policy generation fences an already-queued ADM operation synchronously.
public final class WebRTCIOSHostedCallPlayoutAuthorization: @unchecked Sendable {
    fileprivate let native: ASIOSHostedCallPlayoutAuthorization
    public let policyID: UUID
    public let origin: WebRTCIOSHostedCallPlayoutOrigin

    public init(
        policyID: UUID,
        origin: WebRTCIOSHostedCallPlayoutOrigin
    ) {
        self.policyID = policyID
        self.origin = origin
        native = ASIOSHostedCallPlayoutAuthorization(
            policyIdentifier: policyID,
            origin: origin.native
        )
    }

    public var isValid: Bool { native.isValid }
    public var isRecoveryPending: Bool { native.isRecoveryPending }
    public var systemAudioGeneration: UInt64 { native.systemAudioGeneration }

    public func revoke() {
        native.revoke()
    }

    #if DEBUG
    @discardableResult
    public func performRecoveryIfValidForTesting(_ operation: () -> Void) -> Bool {
        native.performRecoveryIfValid(forTesting: operation)
    }

    @discardableResult
    public func performRecoveryIfValidForTesting(
        systemAudioGeneration: UInt64,
        revocationHandler: @escaping @Sendable () -> Void,
        _ operation: () -> Void = {}
    ) -> Bool {
        native.performRecoveryIfValidForTesting(
            systemAudioGeneration: systemAudioGeneration,
            revocationHandler: revocationHandler,
            operation: operation
        )
    }
    #endif
}

/// Revocable ownership for the current user-authorized iPhone microphone path.
public final class WebRTCIOSMicrophoneAuthorization: @unchecked Sendable {
    fileprivate let native = ASIOSMicrophoneAuthorization()

    public init() {}

    public var isValid: Bool { native.isValid }

    public var recordingGeneration: UInt64 {
        native.microphoneRecordingGeneration
    }

    public func revoke() {
        native.revoke()
    }

    #if DEBUG
    public func debugBeginRealtimeAdmissionForTesting() -> Bool {
        native.debugBeginRealtimeAdmissionForTesting()
    }

    public func debugEndRealtimeAdmissionForTesting() {
        native.debugEndRealtimeAdmissionForTesting()
    }

    public func waitForRealtimeGateClosureForTesting() {
        native.waitForRealtimeGateClosureForTesting()
    }

    public func debugSetRecordingGenerationForTesting(
        _ recordingGeneration: UInt64
    ) {
        native.debugSetMicrophoneRecordingGenerationForTesting(recordingGeneration)
    }

    @discardableResult
    public func performIfValidForTesting(_ operation: () -> Void) -> Bool {
        native.performIfValid(forTesting: operation)
    }
    #endif
}

/// Exact terminal states for one lifecycle-owned output-only microphone operation.
public enum WebRTCIOSOutputOnlyMicrophoneTokenState: String, Equatable, Sendable {
    case armed
    case executing
    case succeeded
    case failed
    case revoked
}

/// The exact AVAudioSession category and mode authorized by one output-only token.
public struct WebRTCIOSOutputOnlyMicrophoneTarget: Equatable, Sendable {
    public let category: String
    public let mode: String

    public init(category: String, mode: String) {
        self.category = category
        self.mode = mode
    }
}

/// One-shot ownership of a native output-only microphone policy write.
///
/// Claiming transitions to `executing` while holding the token lock, then releases that lock
/// before invoking the native operation. A synchronous category callback can therefore inspect
/// `executing` without deadlocking. Revocation can win only while the token remains `armed`.
public final class WebRTCIOSOutputOnlyMicrophoneToken: @unchecked Sendable {
    public let tokenID: UUID
    public let operationID: UUID
    public let ownerEpoch: UUID
    public let lifecycleGeneration: UInt64
    public let target: WebRTCIOSOutputOnlyMicrophoneTarget

    private let lock = NSLock()
    private var stateStorage: WebRTCIOSOutputOnlyMicrophoneTokenState = .armed

    public init(
        tokenID: UUID = UUID(),
        operationID: UUID = UUID(),
        ownerEpoch: UUID,
        lifecycleGeneration: UInt64,
        target: WebRTCIOSOutputOnlyMicrophoneTarget
    ) {
        self.tokenID = tokenID
        self.operationID = operationID
        self.ownerEpoch = ownerEpoch
        self.lifecycleGeneration = lifecycleGeneration
        self.target = target
    }

    public var state: WebRTCIOSOutputOnlyMicrophoneTokenState {
        lock.withLock { stateStorage }
    }

    /// Revokes only an operation that has not entered its native claim.
    @discardableResult
    public func revoke() -> Bool {
        lock.withLock {
            guard stateStorage == .armed else { return false }
            stateStorage = .revoked
            return true
        }
    }

    /// Performs the sole native write authorized by this token.
    ///
    /// No token lock is held while `operation` runs.
    @discardableResult
    public func performOnce(_ operation: () -> Bool) -> Bool {
        lock.lock()
        guard stateStorage == .armed else {
            lock.unlock()
            return false
        }
        stateStorage = .executing
        lock.unlock()

        let nativeResult = operation()
        lock.withLock {
            precondition(stateStorage == .executing)
            stateStorage = nativeResult ? .succeeded : .failed
        }
        return nativeResult
    }
}

/// Thread-safe coordination shared by the peer actor and its MainActor suspension handler.
public final class WebRTCIOSMicrophoneRetirementContext: @unchecked Sendable {
    public let retirementID: UUID
    public let startSequence: UInt64
    public let retiringAuthorizationIdentity: ObjectIdentifier?

    private let lock = NSLock()
    private var selectedTokenStorage: WebRTCIOSOutputOnlyMicrophoneToken?
    private var executingTokenStorage: WebRTCIOSOutputOnlyMicrophoneToken?

    public init(
        retirementID: UUID = UUID(),
        startSequence: UInt64,
        retiringAuthorizationIdentity: ObjectIdentifier?
    ) {
        self.retirementID = retirementID
        self.startSequence = startSequence
        self.retiringAuthorizationIdentity = retiringAuthorizationIdentity
    }

    public var selectedToken: WebRTCIOSOutputOnlyMicrophoneToken? {
        lock.withLock { selectedTokenStorage }
    }

    public var executingToken: WebRTCIOSOutputOnlyMicrophoneToken? {
        lock.withLock { executingTokenStorage }
    }

    /// First selection wins. The handler and a reentrant public disable use this same slot.
    @discardableResult
    public func selectToken(
        _ token: WebRTCIOSOutputOnlyMicrophoneToken
    ) -> WebRTCIOSOutputOnlyMicrophoneToken {
        lock.withLock {
            if let selectedTokenStorage {
                return selectedTokenStorage
            }
            selectedTokenStorage = token
            return token
        }
    }

    /// Releases a selected token only after revocation won while it was still armed.
    @discardableResult
    public func clearSelectedTokenIfRevoked(
        _ token: WebRTCIOSOutputOnlyMicrophoneToken
    ) -> Bool {
        guard token.state == .revoked else { return false }
        return lock.withLock {
            guard selectedTokenStorage === token,
                  executingTokenStorage == nil else {
                return false
            }
            selectedTokenStorage = nil
            return true
        }
    }

    fileprivate func recordExecutingToken(
        _ token: WebRTCIOSOutputOnlyMicrophoneToken
    ) -> Bool {
        lock.withLock {
            if let selectedTokenStorage,
               selectedTokenStorage !== token {
                return false
            }
            if let executingTokenStorage,
               executingTokenStorage !== token {
                return false
            }
            selectedTokenStorage = token
            executingTokenStorage = token
            return true
        }
    }
}

public enum WebRTCIOSMicrophonePolicyAttemptKind: String, Equatable, Sendable {
    case enable
    case outputOnlyDisable
}

public enum WebRTCIOSMicrophonePolicyAttemptOrigin: String, Equatable, Sendable {
    case publicRequest
    case transportSuspension
    case terminalCleanup
}

/// Completion evidence for the most recent native microphone-policy attempt.
public struct WebRTCIOSMicrophonePolicyCompletionStamp: Equatable, Sendable {
    public let sequence: UInt64
    public let kind: WebRTCIOSMicrophonePolicyAttemptKind
    public let origin: WebRTCIOSMicrophonePolicyAttemptOrigin
    public let retirementID: UUID?
    public let retiredAuthorizationIdentity: ObjectIdentifier?
    public let tokenID: UUID?
    public let nativeResult: Bool

    public init(
        sequence: UInt64,
        kind: WebRTCIOSMicrophonePolicyAttemptKind,
        origin: WebRTCIOSMicrophonePolicyAttemptOrigin,
        retirementID: UUID?,
        retiredAuthorizationIdentity: ObjectIdentifier?,
        tokenID: UUID?,
        nativeResult: Bool
    ) {
        self.sequence = sequence
        self.kind = kind
        self.origin = origin
        self.retirementID = retirementID
        self.retiredAuthorizationIdentity = retiredAuthorizationIdentity
        self.tokenID = tokenID
        self.nativeResult = nativeResult
    }
}

#if os(iOS)
private struct WebRTCIOSMicrophoneNativeStageResult {
    let recordingGeneration: UInt64
    let failureReason: WebRTCIOSMicrophoneStageFailureReason?
}

private extension WebRTCIOSMicrophoneStageFailureReason {
    init(native: ASIOSMicrophoneStageFailureReason) {
        switch native {
        case .none:
            self = .unknown
        case .delegateUnavailable:
            self = .delegateUnavailable
        case .deviceNotInitialized:
            self = .deviceNotInitialized
        case .playoutNotReady:
            self = .playoutNotReady
        case .nativeRecoveryRequired:
            self = .nativeRecoveryRequired
        case .topologyRebuildFailed:
            self = .topologyRebuildFailed
        case .topologyStillNotStaged:
            self = .topologyStillNotStaged
        case .hostedCall:
            self = .hostedCall
        case .interrupted:
            self = .interrupted
        case .explicitResumeRequired:
            self = .explicitResumeRequired
        case .authorizationInvalid:
            self = .authorizationInvalid
        case .recordingGenerationBindFailed:
            self = .recordingGenerationBindFailed
        @unknown default:
            self = .unknown
        }
    }
}
#endif

/// Deterministic policy state used by race tests without depending on AVAudioSession hardware.
public struct WebRTCIOSMicrophonePolicySnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let sequence: UInt64
    public let activeAuthorizationIdentity: ObjectIdentifier?
    public let nativeTeardownAuthorizationIdentity: ObjectIdentifier?
    public let trackIsEnabled: Bool
    public let nativeTeardownPending: Bool
    public let completionStamp: WebRTCIOSMicrophonePolicyCompletionStamp?
    public let retirementID: UUID?

    public init(
        generation: UInt64,
        sequence: UInt64,
        activeAuthorizationIdentity: ObjectIdentifier?,
        nativeTeardownAuthorizationIdentity: ObjectIdentifier?,
        trackIsEnabled: Bool,
        nativeTeardownPending: Bool,
        completionStamp: WebRTCIOSMicrophonePolicyCompletionStamp?,
        retirementID: UUID?
    ) {
        self.generation = generation
        self.sequence = sequence
        self.activeAuthorizationIdentity = activeAuthorizationIdentity
        self.nativeTeardownAuthorizationIdentity =
            nativeTeardownAuthorizationIdentity
        self.trackIsEnabled = trackIsEnabled
        self.nativeTeardownPending = nativeTeardownPending
        self.completionStamp = completionStamp
        self.retirementID = retirementID
    }
}

#if DEBUG
/// Lock-free callback and waveform evidence exposed by the test-only iOS publication harness.
public struct WebRTCIOSPlayoutPublicationTestSnapshot: Equatable, Sendable {
    public let callbackCount: UInt64
    public let frameCount: UInt64
    public let failureCount: UInt64
    public let pcmSampleCount: UInt64
    public let pcmNonzeroSampleCount: UInt64
    public let pcmAbsoluteSampleSum: UInt64
    public let pcmLeftAbsoluteSampleSum: UInt64
    public let pcmRightAbsoluteSampleSum: UInt64
    public let pcmStereoDifferenceAbsoluteSampleSum: UInt64
    public let pcmClippedSampleCount: UInt64
    public let explicitSilenceCallbackCount: UInt64
    public let callbackGapViolationCount: UInt64
    public let maximumCallbackGapNanoseconds: UInt64
    public let nearSilenceCallbackCount: UInt64
    public let currentConsecutiveNearSilenceFrameCount: UInt64
    public let maximumConsecutiveNearSilenceFrameCount: UInt64
    public let pcmLeftZeroCrossingCount: UInt64
    public let pcmRightZeroCrossingCount: UInt64
    public let pcmEnvelopeTransitionCount: UInt64
    public let pcmShapeAnomalyCallbackCount: UInt64
    public let pcmBoundaryDiscontinuityCallbackCount: UInt64
    public let lastCallbackMeanMagnitude: UInt32
    public let lastFrameCount: UInt32
    public let lastPeakMagnitude: UInt32
    public let lastStatus: Int32
}

/// Invokes production iOS callback-observation primitives without creating audio hardware.
public final class WebRTCIOSPlayoutPublicationTestHarness: @unchecked Sendable {
    private let native = ASIOSStereoPlayoutPublicationTestHarness()

    public init() {}

    public var prePublicationSnapshot: WebRTCIOSPlayoutPublicationTestSnapshot {
        makeSnapshot(native.prePublicationSnapshot)
    }

    public var snapshot: WebRTCIOSPlayoutPublicationTestSnapshot {
        makeSnapshot(native.snapshot)
    }

    public func publishCallback(frameCount: UInt32, status: Int32) {
        native.publishCallback(withFrameCount: frameCount, status: status)
    }

    public func analyzePCM16(samples: [Int16], outputIsSilence: Bool = false) {
        let data = samples.withUnsafeBytes { Data($0) }
        native.analyzePCM16Samples(data, outputIsSilence: outputIsSilence)
    }

    public func recordSuccessfulCallback(atMonotonicTimeNanoseconds nanoseconds: UInt64) {
        native.recordSuccessfulCallback(atMonotonicTimeNanoseconds: nanoseconds)
    }

    public func markRecoveryBoundary() {
        native.markRecoveryBoundary()
    }

    private func makeSnapshot(
        _ value: ASIOSStereoPlayoutPublicationSnapshot
    ) -> WebRTCIOSPlayoutPublicationTestSnapshot {
        WebRTCIOSPlayoutPublicationTestSnapshot(
            callbackCount: value.callbackCount,
            frameCount: value.frameCount,
            failureCount: value.failureCount,
            pcmSampleCount: value.pcmSampleCount,
            pcmNonzeroSampleCount: value.pcmNonzeroSampleCount,
            pcmAbsoluteSampleSum: value.pcmAbsoluteSampleSum,
            pcmLeftAbsoluteSampleSum: value.pcmLeftAbsoluteSampleSum,
            pcmRightAbsoluteSampleSum: value.pcmRightAbsoluteSampleSum,
            pcmStereoDifferenceAbsoluteSampleSum:
                value.pcmStereoDifferenceAbsoluteSampleSum,
            pcmClippedSampleCount: value.pcmClippedSampleCount,
            explicitSilenceCallbackCount: value.explicitSilenceCallbackCount,
            callbackGapViolationCount: value.callbackGapViolationCount,
            maximumCallbackGapNanoseconds: value.maximumCallbackGapNanoseconds,
            nearSilenceCallbackCount: value.nearSilenceCallbackCount,
            currentConsecutiveNearSilenceFrameCount:
                value.currentConsecutiveNearSilenceFrameCount,
            maximumConsecutiveNearSilenceFrameCount:
                value.maximumConsecutiveNearSilenceFrameCount,
            pcmLeftZeroCrossingCount: value.pcmLeftZeroCrossingCount,
            pcmRightZeroCrossingCount: value.pcmRightZeroCrossingCount,
            pcmEnvelopeTransitionCount: value.pcmEnvelopeTransitionCount,
            pcmShapeAnomalyCallbackCount: value.pcmShapeAnomalyCallbackCount,
            pcmBoundaryDiscontinuityCallbackCount:
                value.pcmBoundaryDiscontinuityCallbackCount,
            lastCallbackMeanMagnitude: value.lastCallbackMeanMagnitude,
            lastFrameCount: value.lastFrameCount,
            lastPeakMagnitude: value.lastPeakMagnitude,
            lastStatus: value.lastStatus
        )
    }
}

/// Lifecycle counters exposed by the test-only queued-recovery harness.
public struct WebRTCIOSPlayoutRecoveryTestDiagnostics: Equatable, Sendable {
    public let failureCode: Int
    public let lastLifecycleStatus: Int32
    public let requestCount: UInt64
    public let authorizationRejectionCount: UInt64
    public let rebuildCount: UInt64
    public let unexpectedRecordingRequestCount: UInt64
    public let playoutCallbackCount: UInt64
    public let playoutFrameCount: UInt64
    public let playoutFailureCount: UInt64
    public let lastPlayoutFrameCount: UInt32
    public let lastPlayoutStatus: Int32
    public let microphoneDeviceGateClosedAndDrained: Bool
    public let microphoneAuthorizationGatePublished: Bool
    public let microphoneRecordingGeneration: UInt64
    public let approvedMicrophoneRecordingGeneration: UInt64
    public let categoryIsMediaPlayAndRecord: Bool
    public let modeIsDefault: Bool
    public let microphoneRealtimeAdmissionCount: UInt64
    public let microphoneDeliveryCallbackCount: UInt64
    public let microphoneDeliveredFrameCount: UInt64
    public let sessionActive: Bool
    public let remoteIOCreated: Bool
    public let inputBusEnabled: Bool
    public let captureRouteIsBuiltInMicrophone: Bool
    public let captureRouteProofGeneration: UInt64
    public let outputBusEnabled: Bool
    public let recoveryRequired: Bool
    public let explicitResumeRequired: Bool
    public let categoryOptionsAreEmpty: Bool
    public let categoryOptionsAreIPhoneMicrophoneRouting: Bool
    public let routeSharingPolicyIsDefault: Bool
    public let categoryOptionsAreMixWithOthers: Bool
    public let hasOutputRoute: Bool
    public let hostedCallMode: Bool
    public let hostedCallAuthorizationValid: Bool
    public let hostedCallRecoveryPending: Bool
    public let hostedCallOrigin: WebRTCIOSHostedCallPlayoutOrigin?
    public let systemAudioGeneration: UInt64
    public let hostedCallAuthorizationGeneration: UInt64
}

public enum WebRTCIOSExpectedRouteChangeDisposition: Sendable {
    case unrelated
    case consume
    case rejectTransaction

    fileprivate init(native: ASIOSExpectedRouteChangeDisposition) {
        switch native {
        case .unrelated:
            self = .unrelated
        case .consume:
            self = .consume
        case .rejectTransaction:
            self = .rejectTransaction
        @unknown default:
            self = .unrelated
        }
    }
}

public enum WebRTCIOSExpectedRouteChangeTestScenario: Int, Sendable {
    case pendingActivation
    case pendingBound
    case pendingCategory
    case pendingOverride
    case pendingWrongPreviousRoute
    case pendingWrongGeneration
    case pendingWrongOwnership
    case convergedDuplicate
    case convergedChangedRoute
    case convergedRecoveryRequired
    case convergedExpired
    case pendingCoalescedSkippedIntermediate
    case pendingExpired
    case pendingSequenceNotAdvanced
    case pendingWrongSystemGeneration
    case pendingWrongPolicy
    case pendingMissingFingerprint
    case convergedWrongOwnership
    case convergedInactive
    case convergedOutputMissing
    case convergedChannelMismatch
    case convergedTargetMismatch
    case convergedPreferredMismatch
    case convergedWrongSystemGeneration
    case convergedWrongGeneration
    case convergedPreviousUnseen
    case convergedExplicitResumeRequired
    case preparedExact
    case preparedChangedRoute
    case startingChangedRoute
    case startingWrongOwnership
    case startingRecoveryRequired
    case startingOldDeviceUnavailable
    case startingCategory
    case startingChannelMismatch
    case startingCoalescedExactRoute
    case startingOutputChanged
    case startingInactive
    case startingWrongGeneration
    case startingWrongSystemGeneration
    case startingTargetMismatch
    case startingPreferredMismatch
    case startingExplicitResumeRequired
    case pendingOutputChanged
    case convergedStartSettlementCoalescedExactRoute
    case convergedStartSettlementExpired

    fileprivate var native: ASIOSExpectedRouteChangeTestScenario {
        switch self {
        case .pendingActivation:
            return .pendingActivation
        case .pendingBound:
            return .pendingBound
        case .pendingCategory:
            return .pendingCategory
        case .pendingOverride:
            return .pendingOverride
        case .pendingWrongPreviousRoute:
            return .pendingWrongPreviousRoute
        case .pendingWrongGeneration:
            return .pendingWrongGeneration
        case .pendingWrongOwnership:
            return .pendingWrongOwnership
        case .convergedDuplicate:
            return .convergedDuplicate
        case .convergedChangedRoute:
            return .convergedChangedRoute
        case .convergedRecoveryRequired:
            return .convergedRecoveryRequired
        case .convergedExpired:
            return .convergedExpired
        case .pendingCoalescedSkippedIntermediate:
            return .pendingCoalescedSkippedIntermediate
        case .pendingExpired:
            return .pendingExpired
        case .pendingSequenceNotAdvanced:
            return .pendingSequenceNotAdvanced
        case .pendingWrongSystemGeneration:
            return .pendingWrongSystemGeneration
        case .pendingWrongPolicy:
            return .pendingWrongPolicy
        case .pendingMissingFingerprint:
            return .pendingMissingFingerprint
        case .convergedWrongOwnership:
            return .convergedWrongOwnership
        case .convergedInactive:
            return .convergedInactive
        case .convergedOutputMissing:
            return .convergedOutputMissing
        case .convergedChannelMismatch:
            return .convergedChannelMismatch
        case .convergedTargetMismatch:
            return .convergedTargetMismatch
        case .convergedPreferredMismatch:
            return .convergedPreferredMismatch
        case .convergedWrongSystemGeneration:
            return .convergedWrongSystemGeneration
        case .convergedWrongGeneration:
            return .convergedWrongGeneration
        case .convergedPreviousUnseen:
            return .convergedPreviousUnseen
        case .convergedExplicitResumeRequired:
            return .convergedExplicitResumeRequired
        case .preparedExact:
            return .preparedExact
        case .preparedChangedRoute:
            return .preparedChangedRoute
        case .startingChangedRoute:
            return .startingChangedRoute
        case .startingWrongOwnership:
            return .startingWrongOwnership
        case .startingRecoveryRequired:
            return .startingRecoveryRequired
        case .startingOldDeviceUnavailable:
            return .startingOldDeviceUnavailable
        case .startingCategory:
            return .startingCategory
        case .startingChannelMismatch:
            return .startingChannelMismatch
        case .startingCoalescedExactRoute:
            return .startingCoalescedExactRoute
        case .startingOutputChanged:
            return .startingOutputChanged
        case .startingInactive:
            return .startingInactive
        case .startingWrongGeneration:
            return .startingWrongGeneration
        case .startingWrongSystemGeneration:
            return .startingWrongSystemGeneration
        case .startingTargetMismatch:
            return .startingTargetMismatch
        case .startingPreferredMismatch:
            return .startingPreferredMismatch
        case .startingExplicitResumeRequired:
            return .startingExplicitResumeRequired
        case .pendingOutputChanged:
            return .pendingOutputChanged
        case .convergedStartSettlementCoalescedExactRoute:
            return .convergedStartSettlementCoalescedExactRoute
        case .convergedStartSettlementExpired:
            return .convergedStartSettlementExpired
        }
    }
}

public enum WebRTCIOSExpectedCategoryObservationTestScenario: Int, Sendable {
    case microphoneExact
    case outputOnlyExact
    case untracked
    case wrongOptions
    case wrongMode
    case wrongSharingPolicy
    case wrongConfigurationGeneration
    case wrongSystemAudioGeneration
    case sequenceNotAdvanced
    case expired

    fileprivate var native: ASIOSExpectedCategoryObservationTestScenario {
        switch self {
        case .microphoneExact:
            return .microphoneExact
        case .outputOnlyExact:
            return .outputOnlyExact
        case .untracked:
            return .untracked
        case .wrongOptions:
            return .wrongOptions
        case .wrongMode:
            return .wrongMode
        case .wrongSharingPolicy:
            return .wrongSharingPolicy
        case .wrongConfigurationGeneration:
            return .wrongConfigurationGeneration
        case .wrongSystemAudioGeneration:
            return .wrongSystemAudioGeneration
        case .sequenceNotAdvanced:
            return .sequenceNotAdvanced
        case .expired:
            return .expired
        }
    }
}

/// Drives the real native recovery gate and records the production configuration-operation inputs
/// deterministically without claiming that Simulator created a hardware RemoteIO instance.
public final class WebRTCIOSPlayoutRecoveryTestHarness: @unchecked Sendable {
    private let native = ASIOSStereoPlayoutRecoveryTestHarness()

    public init() {}

    public var queuedOperationCount: Int { Int(native.queuedOperationCount) }
    public var configurationOperationCount: Int {
        Int(native.configurationOperationCount)
    }
    public var lastChannelPreferenceOperations: [String] {
        native.lastChannelPreferenceOperations
    }
    public var lastConfiguredCategory: String? {
        native.lastConfiguredCategory
    }
    public var lastConfiguredMode: String? {
        native.lastConfiguredMode
    }
    public var lastConfiguredRouteSharingPolicy: Int {
        Int(native.lastConfiguredRouteSharingPolicy)
    }
    public var lastConfiguredCategoryOptions: UInt {
        UInt(native.lastConfiguredCategoryOptions)
    }
    public var lastConfiguredInputBusEnabled: Bool {
        native.lastConfiguredInputBusEnabled
    }
    public var lastConfiguredOutputBusEnabled: Bool {
        native.lastConfiguredOutputBusEnabled
    }
    public var lastConfiguredOutputStreamFormat: AudioStreamBasicDescription {
        native.lastConfiguredOutputStreamFormat
    }
    public var hostedCallPolicyID: UUID? {
        native.hostedCallPolicyIdentifier.map { $0 as UUID }
    }

    public var diagnostics: WebRTCIOSPlayoutRecoveryTestDiagnostics {
        let value = native.diagnostics
        return WebRTCIOSPlayoutRecoveryTestDiagnostics(
            failureCode: Int(value.failureCode.rawValue),
            lastLifecycleStatus: value.lastLifecycleStatus,
            requestCount: value.recoveryRequestCount,
            authorizationRejectionCount: value.recoveryAuthorizationRejectionCount,
            rebuildCount: value.recoveryRebuildCount,
            unexpectedRecordingRequestCount:
                value.unexpectedRecordingRequestCount,
            playoutCallbackCount: value.playoutCallbackCount,
            playoutFrameCount: value.playoutFrameCount,
            playoutFailureCount: value.playoutFailureCount,
            lastPlayoutFrameCount: value.lastPlayoutFrameCount,
            lastPlayoutStatus: value.lastPlayoutStatus,
            microphoneDeviceGateClosedAndDrained:
                value.microphoneDeviceGateClosedAndDrained,
            microphoneAuthorizationGatePublished:
                value.microphoneAuthorizationGatePublished,
            microphoneRecordingGeneration:
                value.microphoneRecordingGeneration,
            approvedMicrophoneRecordingGeneration:
                value.approvedMicrophoneRecordingGeneration,
            categoryIsMediaPlayAndRecord:
                value.categoryIsMediaPlayAndRecord,
            modeIsDefault: value.modeIsDefault,
            microphoneRealtimeAdmissionCount:
                value.microphoneRealtimeAdmissionCount,
            microphoneDeliveryCallbackCount:
                value.microphoneDeliveryCallbackCount,
            microphoneDeliveredFrameCount:
                value.microphoneDeliveredFrameCount,
            sessionActive: value.sessionActive,
            remoteIOCreated: value.remoteIOCreated,
            inputBusEnabled: value.inputBusEnabled,
            captureRouteIsBuiltInMicrophone:
                value.captureRouteIsBuiltInMicrophone,
            captureRouteProofGeneration:
                value.captureRouteProofGeneration,
            outputBusEnabled: value.outputBusEnabled,
            recoveryRequired: value.recoveryRequired,
            explicitResumeRequired: value.explicitResumeRequired,
            categoryOptionsAreEmpty: value.categoryOptionsAreEmpty,
            categoryOptionsAreIPhoneMicrophoneRouting:
                value.categoryOptionsAreIPhoneMicrophoneRouting,
            routeSharingPolicyIsDefault: value.routeSharingPolicyIsDefault,
            categoryOptionsAreMixWithOthers:
                value.categoryOptionsAreMixWithOthers,
            hasOutputRoute: value.hasOutputRoute,
            hostedCallMode: value.hostedCallMode,
            hostedCallAuthorizationValid:
                value.hostedCallAuthorizationValid,
            hostedCallRecoveryPending:
                value.hostedCallRecoveryPending,
            hostedCallOrigin:
                WebRTCIOSHostedCallPlayoutOrigin(
                    native: value.hostedCallOrigin
                ),
            systemAudioGeneration: value.systemAudioGeneration,
            hostedCallAuthorizationGeneration:
                value.hostedCallAuthorizationGeneration
        )
    }

    public func debugInstallMicrophoneAuthorizationForTesting(
        _ authorization: WebRTCIOSMicrophoneAuthorization?
    ) {
        native.debugInstallMicrophoneAuthorization(
            forTesting: authorization?.native
        )
    }

    @discardableResult
    public func setMicrophoneAuthorizationForTesting(
        _ authorization: WebRTCIOSMicrophoneAuthorization?
    ) -> Bool {
        native.setMicrophoneAuthorizationForTesting(authorization?.native)
    }

    public func debugPublishCurrentMicrophoneAuthorizationForTesting() -> Bool {
        native.debugPublishCurrentMicrophoneAuthorizationForTesting()
    }

    public func debugBeginRealtimeAdmissionForTesting() -> Bool {
        native.debugBeginRealtimeAdmissionForTesting()
    }

    public func debugEndRealtimeAdmissionForTesting() {
        native.debugEndRealtimeAdmissionForTesting()
    }

    public func debugCloseAndFenceRealtimeGateForTesting() {
        native.debugCloseAndFenceRealtimeGateForTesting()
    }

    public func waitForRealtimeGateClosureForTesting() {
        native.waitForRealtimeGateClosureForTesting()
    }

    public func debugTerminateForTesting() -> Bool {
        native.debugTerminateForTesting()
    }

    public func debugApplyActiveChannelPreferencesForTesting(
        sessionActive: Bool,
        maximumInputChannels: Int,
        maximumOutputChannels: Int,
        microphoneEnabled: Bool
    ) -> Bool {
        native.debugApplyActiveChannelPreferencesForTesting(
            sessionActive: sessionActive,
            maximumInputChannels: maximumInputChannels,
            maximumOutputChannels: maximumOutputChannels,
            microphoneEnabled: microphoneEnabled
        )
    }

    public func debugClassifyExpectedRouteChangeForTesting(
        _ scenario: WebRTCIOSExpectedRouteChangeTestScenario
    ) -> WebRTCIOSExpectedRouteChangeDisposition {
        WebRTCIOSExpectedRouteChangeDisposition(
            native: native.debugClassifyExpectedRouteChangeForTesting(
                scenario.native
            )
        )
    }

    public func debugExpectedCategoryObservationIsAbsorbedForTesting(
        _ scenario: WebRTCIOSExpectedCategoryObservationTestScenario
    ) -> Bool {
        native.debugExpectedCategoryObservationIsAbsorbedForTesting(
            scenario.native
        )
    }

    public func debugDriveRetiredExpectedCategoryObservationForTesting(
        exactPolicy: Bool
    ) -> Bool {
        native.debugDriveRetiredExpectedCategoryObservationForTesting(
            exactPolicy: exactPolicy
        )
    }

    public func debugRemoteIOStartSettlementAcceptsDelayedObservationForTesting()
        -> Bool
    {
        native.debugRemoteIOStartSettlementAcceptsDelayedObservationForTesting()
    }

    public func debugSupersededRouteObservationIsSuppressedForTesting(
        oldDeviceUnavailable: Bool
    ) -> Bool {
        native.debugSupersededRouteObservationIsSuppressedForTesting(
            oldDeviceUnavailable: oldDeviceUnavailable
        )
    }

    public func debugRetiredSystemGenerationRouteObservationIsSuppressedForTesting(
        oldDeviceUnavailable: Bool
    ) -> Bool {
        native
            .debugRetiredSystemGenerationRouteObservationIsSuppressedForTesting(
                oldDeviceUnavailable: oldDeviceUnavailable
            )
    }

    public func debugRecordedConsumedRouteClosureSchedulesFreshResolutionForTesting()
        -> Bool
    {
        native
            .debugRecordedConsumedRouteClosureSchedulesFreshResolutionForTesting()
    }

    public func debugRecordedConsumedRouteClosureUsesFreshRouteForTesting()
        -> Bool
    {
        native.debugRecordedConsumedRouteClosureUsesFreshRouteForTesting()
    }

    public func debugNotificationSequenceChangeBlocksFreshRouteReopenForTesting()
        -> Bool
    {
        native
            .debugNotificationSequenceChangeBlocksFreshRouteReopenForTesting()
    }

    public func debugRunningUnpublishedAudioUnitStopInvariantHoldsForTesting()
        -> Bool
    {
        native.debugRunningUnpublishedAudioUnitStopInvariantHoldsForTesting()
    }

    public func debugRouteEvidenceOwnsMicrophonePublicationClosureForTesting(
        recordedClosure: Bool,
        inFlightCount: UInt
    ) -> Bool {
        native
            .debugRouteEvidenceOwnsMicrophonePublicationClosureForTesting(
                recordedClosure: recordedClosure,
                inFlightCount: inFlightCount
            )
    }

    public func debugTrackedCategoryObservationOwnsRouteClosureForTesting()
        -> Bool
    {
        native.debugTrackedCategoryObservationOwnsRouteClosureForTesting()
    }

    public func debugUntrackedCategoryObservationAvoidsUnownedRouteClosureForTesting()
        -> Bool
    {
        native
            .debugUntrackedCategoryObservationAvoidsUnownedRouteClosureForTesting()
    }

    public func debugConsumedPublicationQueuesRecordedRouteClosureResolutionForTesting()
        -> Bool
    {
        native
            .debugConsumedPublicationQueuesRecordedRouteClosureResolutionForTesting()
    }

    public func debugFinalMicrophonePublicationRejectsDelayedRouteIngressForTesting()
        -> Bool
    {
        native
            .debugFinalMicrophonePublicationRejectsDelayedRouteIngressForTesting()
    }

    public func debugRouteLockedOwnershipSnapshotComparatorForTesting()
        -> Bool
    {
        native.debugRouteLockedOwnershipSnapshotComparatorForTesting()
    }

    public func debugImmutableRouteRejectionSnapshotSurvivesLaterRouteForTesting()
        -> Bool
    {
        native
            .debugImmutableRouteRejectionSnapshotSurvivesLaterRouteForTesting()
    }

    public func debugClearRetiresInFlightExpectedRouteObservationForTesting()
        -> Bool
    {
        native
            .debugClearRetiresInFlightExpectedRouteObservationForTesting()
    }

    public func debugOldQueuedRouteObservationCannotMutateRearmedTransactionForTesting()
        -> Bool
    {
        native
            .debugOldQueuedRouteObservationCannotMutateRearmedTransactionForTesting()
    }

    public func debugStructuredRouteTransactionFailureSnapshotForTesting()
        -> String
    {
        native.debugStructuredRouteTransactionFailureSnapshotForTesting()
    }

    public func publishCallback(frameCount: UInt32, status: Int32) {
        native.publishCallback(withFrameCount: frameCount, status: status)
    }

    public func queueRecovery(
        authorization: WebRTCIOSPlayoutRecoveryAuthorization
    ) {
        native.queueRecovery(authorization: authorization.native)
    }

    public func queueHostedCallRecovery(
        authorization: WebRTCIOSHostedCallPlayoutAuthorization
    ) {
        native.queueHostedCallRecovery(authorization: authorization.native)
    }

    @discardableResult
    public func armStartupConnectedCallPlayout(
        authorization: WebRTCIOSHostedCallPlayoutAuthorization
    ) -> Bool {
        native.armStartupConnectedCallPlayout(
            authorization: authorization.native
        )
    }

    @discardableResult
    public func debugStartPlayoutForTesting() -> Bool {
        native.debugStartPlayoutForTesting()
    }

    public func debugMarkInterruptedFailClosedForTesting() {
        native.debugMarkInterruptedFailClosedForTesting()
    }

    public func debugMarkInterruptionEndedFailClosedForTesting() {
        native.debugMarkInterruptionEndedFailClosedForTesting()
    }

    public func debugMarkHealthyPlayoutForTesting() {
        native.debugMarkHealthyPlayoutForTesting()
    }

    public func debugMarkRouteLossForTesting() {
        native.debugMarkRouteLossForTesting()
    }

    public func debugAttemptFailureOverwriteForTesting() {
        native.debugAttemptFailureOverwriteForTesting()
    }

    public func debugAdvanceSystemAudioGenerationForTesting() {
        native.debugAdvanceSystemAudioGenerationForTesting()
    }

    public func debugSetOutputRouteAvailableForTesting(_ available: Bool) {
        native.debugSetOutputRouteAvailable(forTesting: available)
    }

    public func debugSetCaptureRouteBuiltInMicrophoneForTesting(
        _ isBuiltIn: Bool
    ) {
        native.debugSetCaptureRouteBuiltInMicrophone(
            forTesting: isBuiltIn
        )
    }

    public func debugFailNextHostedCallActivationForTesting() {
        native.debugFailNextHostedCallActivationForTesting()
    }

    @discardableResult
    public func runNextQueuedOperation() -> Bool {
        native.runNextQueuedOperation()
    }
}
#endif

/// Runtime proof that iOS is using one app-owned conditional-duplex RemoteIO media path rather
/// than WebRTC's call-oriented default audio device or a duplicate application renderer.
public struct WebRTCIOSPlayoutDiagnostics: Sendable {
    public let initialized: Bool
    public let playoutInitialized: Bool
    public let playing: Bool
    public let sessionActive: Bool
    public let ownsSessionActivation: Bool
    public let remoteIOCreated: Bool
    public let inputBusEnabled: Bool
    public let captureRouteIsBuiltInMicrophone: Bool
    public let captureRouteProofGeneration: UInt64
    public let outputBusEnabled: Bool
    public let recoveryRequired: Bool
    public let explicitResumeRequired: Bool
    public let categoryIsMediaPlayback: Bool
    public let categoryIsMediaPlayAndRecord: Bool
    public let modeIsDefault: Bool
    public let categoryOptionsAreEmpty: Bool
    public let categoryOptionsAreIPhoneMicrophoneRouting: Bool
    public let categoryOptionsAreMixWithOthers: Bool
    public let routeSharingPolicyIsDefault: Bool
    public let hasOutputRoute: Bool
    public let hostedCallMode: Bool
    public let hostedCallAuthorizationValid: Bool
    public let hostedCallRecoveryPending: Bool
    public let hostedCallOrigin: WebRTCIOSHostedCallPlayoutOrigin?
    public let systemAudioGeneration: UInt64
    public let hostedCallAuthorizationGeneration: UInt64
    public let sampleRate: Double
    public let outputIOBufferDuration: TimeInterval
    public let outputChannelCount: Int
    public let audioUnitSubType: UInt32
    public let failureCode: Int
    public let lastLifecycleStatus: Int32
    public let failureMessage: String?
    public let playoutCallbackCount: UInt64
    public let playoutFrameCount: UInt64
    public let playoutFailureCount: UInt64
    public let playoutPCMSampleCount: UInt64
    public let playoutPCMNonzeroSampleCount: UInt64
    public let playoutPCMAbsoluteSampleSum: UInt64
    public let playoutPCMLeftAbsoluteSampleSum: UInt64
    public let playoutPCMRightAbsoluteSampleSum: UInt64
    public let playoutPCMStereoDifferenceAbsoluteSampleSum: UInt64
    public let playoutPCMClippedSampleCount: UInt64
    public let playoutExplicitSilenceCallbackCount: UInt64
    public let playoutCallbackGapViolationCount: UInt64
    public let playoutMaximumCallbackGapNanoseconds: UInt64
    public let playoutNearSilenceCallbackCount: UInt64
    public let playoutCurrentConsecutiveNearSilenceFrameCount: UInt64
    public let playoutMaximumConsecutiveNearSilenceFrameCount: UInt64
    public let playoutPCMLeftZeroCrossingCount: UInt64
    public let playoutPCMRightZeroCrossingCount: UInt64
    public let playoutPCMEnvelopeTransitionCount: UInt64
    public let playoutPCMShapeAnomalyCallbackCount: UInt64
    public let playoutPCMBoundaryDiscontinuityCallbackCount: UInt64
    public let playoutLastCallbackMeanMagnitude: UInt32
    public let unexpectedRecordingRequestCount: UInt64
    public let recoveryRequestCount: UInt64
    public let recoveryAuthorizationRejectionCount: UInt64
    public let recoveryRebuildCount: UInt64
    public let lastPlayoutFrameCount: UInt32
    public let lastPlayoutPeakMagnitude: UInt32
    public let lastPlayoutStatus: Int32

    public init(
        initialized: Bool,
        playoutInitialized: Bool,
        playing: Bool,
        sessionActive: Bool,
        ownsSessionActivation: Bool,
        remoteIOCreated: Bool,
        inputBusEnabled: Bool,
        captureRouteIsBuiltInMicrophone: Bool = false,
        captureRouteProofGeneration: UInt64 = 0,
        outputBusEnabled: Bool,
        recoveryRequired: Bool,
        explicitResumeRequired: Bool,
        categoryIsMediaPlayback: Bool,
        categoryIsMediaPlayAndRecord: Bool = false,
        modeIsDefault: Bool,
        categoryOptionsAreEmpty: Bool,
        categoryOptionsAreIPhoneMicrophoneRouting: Bool = false,
        categoryOptionsAreMixWithOthers: Bool = false,
        routeSharingPolicyIsDefault: Bool,
        hasOutputRoute: Bool = true,
        hostedCallMode: Bool = false,
        hostedCallAuthorizationValid: Bool = false,
        hostedCallRecoveryPending: Bool = false,
        hostedCallOrigin: WebRTCIOSHostedCallPlayoutOrigin? = nil,
        systemAudioGeneration: UInt64 = 0,
        hostedCallAuthorizationGeneration: UInt64 = 0,
        sampleRate: Double,
        outputIOBufferDuration: TimeInterval,
        outputChannelCount: Int,
        audioUnitSubType: UInt32,
        failureCode: Int,
        lastLifecycleStatus: Int32,
        failureMessage: String?,
        playoutCallbackCount: UInt64,
        playoutFrameCount: UInt64,
        playoutFailureCount: UInt64,
        playoutPCMSampleCount: UInt64,
        playoutPCMNonzeroSampleCount: UInt64,
        playoutPCMAbsoluteSampleSum: UInt64,
        playoutPCMLeftAbsoluteSampleSum: UInt64,
        playoutPCMRightAbsoluteSampleSum: UInt64,
        playoutPCMStereoDifferenceAbsoluteSampleSum: UInt64,
        playoutPCMClippedSampleCount: UInt64,
        playoutExplicitSilenceCallbackCount: UInt64,
        unexpectedRecordingRequestCount: UInt64,
        recoveryRequestCount: UInt64,
        recoveryAuthorizationRejectionCount: UInt64,
        recoveryRebuildCount: UInt64,
        lastPlayoutFrameCount: UInt32,
        lastPlayoutPeakMagnitude: UInt32,
        lastPlayoutStatus: Int32,
        playoutCallbackGapViolationCount: UInt64 = 0,
        playoutMaximumCallbackGapNanoseconds: UInt64 = 0,
        playoutNearSilenceCallbackCount: UInt64 = 0,
        playoutCurrentConsecutiveNearSilenceFrameCount: UInt64 = 0,
        playoutMaximumConsecutiveNearSilenceFrameCount: UInt64 = 0,
        playoutPCMLeftZeroCrossingCount: UInt64 = 0,
        playoutPCMRightZeroCrossingCount: UInt64 = 0,
        playoutPCMEnvelopeTransitionCount: UInt64 = 0,
        playoutPCMShapeAnomalyCallbackCount: UInt64 = 0,
        playoutPCMBoundaryDiscontinuityCallbackCount: UInt64 = 0,
        playoutLastCallbackMeanMagnitude: UInt32 = 0
    ) {
        self.initialized = initialized
        self.playoutInitialized = playoutInitialized
        self.playing = playing
        self.sessionActive = sessionActive
        self.ownsSessionActivation = ownsSessionActivation
        self.remoteIOCreated = remoteIOCreated
        self.inputBusEnabled = inputBusEnabled
        self.captureRouteIsBuiltInMicrophone =
            captureRouteIsBuiltInMicrophone
        self.captureRouteProofGeneration =
            captureRouteProofGeneration
        self.outputBusEnabled = outputBusEnabled
        self.recoveryRequired = recoveryRequired
        self.explicitResumeRequired = explicitResumeRequired
        self.categoryIsMediaPlayback = categoryIsMediaPlayback
        self.categoryIsMediaPlayAndRecord = categoryIsMediaPlayAndRecord
        self.modeIsDefault = modeIsDefault
        self.categoryOptionsAreEmpty = categoryOptionsAreEmpty
        self.categoryOptionsAreIPhoneMicrophoneRouting =
            categoryOptionsAreIPhoneMicrophoneRouting
        self.categoryOptionsAreMixWithOthers = categoryOptionsAreMixWithOthers
        self.routeSharingPolicyIsDefault = routeSharingPolicyIsDefault
        self.hasOutputRoute = hasOutputRoute
        self.hostedCallMode = hostedCallMode
        self.hostedCallAuthorizationValid = hostedCallAuthorizationValid
        self.hostedCallRecoveryPending = hostedCallRecoveryPending
        self.hostedCallOrigin = hostedCallOrigin
        self.systemAudioGeneration = systemAudioGeneration
        self.hostedCallAuthorizationGeneration =
            hostedCallAuthorizationGeneration
        self.sampleRate = sampleRate
        self.outputIOBufferDuration = outputIOBufferDuration
        self.outputChannelCount = outputChannelCount
        self.audioUnitSubType = audioUnitSubType
        self.failureCode = failureCode
        self.lastLifecycleStatus = lastLifecycleStatus
        self.failureMessage = failureMessage
        self.playoutCallbackCount = playoutCallbackCount
        self.playoutFrameCount = playoutFrameCount
        self.playoutFailureCount = playoutFailureCount
        self.playoutPCMSampleCount = playoutPCMSampleCount
        self.playoutPCMNonzeroSampleCount = playoutPCMNonzeroSampleCount
        self.playoutPCMAbsoluteSampleSum = playoutPCMAbsoluteSampleSum
        self.playoutPCMLeftAbsoluteSampleSum = playoutPCMLeftAbsoluteSampleSum
        self.playoutPCMRightAbsoluteSampleSum = playoutPCMRightAbsoluteSampleSum
        self.playoutPCMStereoDifferenceAbsoluteSampleSum =
            playoutPCMStereoDifferenceAbsoluteSampleSum
        self.playoutPCMClippedSampleCount = playoutPCMClippedSampleCount
        self.playoutExplicitSilenceCallbackCount = playoutExplicitSilenceCallbackCount
        self.unexpectedRecordingRequestCount = unexpectedRecordingRequestCount
        self.recoveryRequestCount = recoveryRequestCount
        self.recoveryAuthorizationRejectionCount = recoveryAuthorizationRejectionCount
        self.recoveryRebuildCount = recoveryRebuildCount
        self.lastPlayoutFrameCount = lastPlayoutFrameCount
        self.lastPlayoutPeakMagnitude = lastPlayoutPeakMagnitude
        self.lastPlayoutStatus = lastPlayoutStatus
        self.playoutCallbackGapViolationCount = playoutCallbackGapViolationCount
        self.playoutMaximumCallbackGapNanoseconds = playoutMaximumCallbackGapNanoseconds
        self.playoutNearSilenceCallbackCount = playoutNearSilenceCallbackCount
        self.playoutCurrentConsecutiveNearSilenceFrameCount =
            playoutCurrentConsecutiveNearSilenceFrameCount
        self.playoutMaximumConsecutiveNearSilenceFrameCount =
            playoutMaximumConsecutiveNearSilenceFrameCount
        self.playoutPCMLeftZeroCrossingCount = playoutPCMLeftZeroCrossingCount
        self.playoutPCMRightZeroCrossingCount = playoutPCMRightZeroCrossingCount
        self.playoutPCMEnvelopeTransitionCount = playoutPCMEnvelopeTransitionCount
        self.playoutPCMShapeAnomalyCallbackCount =
            playoutPCMShapeAnomalyCallbackCount
        self.playoutPCMBoundaryDiscontinuityCallbackCount =
            playoutPCMBoundaryDiscontinuityCallbackCount
        self.playoutLastCallbackMeanMagnitude = playoutLastCallbackMeanMagnitude
    }
}

/// Preserves the exact native audio-session failure at the microphone-admission boundary.
///
/// The native device rolls back immediately after a failed duplex rebuild. Capturing this
/// snapshot before the higher-level cleanup runs is therefore the only reliable way to
/// distinguish a session preference failure from an active-route or RemoteIO failure.
enum WebRTCIOSMicrophoneAdmissionDiagnostics {
    static func failureDescription(
        _ diagnostics: WebRTCIOSPlayoutDiagnostics?
    ) -> String {
        let prefix =
            "The current iPhone route could not stage the authorized microphone topology."
        guard let diagnostics else {
            return prefix + " Native diagnostics were unavailable."
        }

        let nativeMessage = diagnostics.failureMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayMessage = nativeMessage.flatMap { message in
            message.isEmpty ? nil : message
        } ?? "none"
        let category: String
        if diagnostics.categoryIsMediaPlayAndRecord {
            category = "playAndRecord"
        } else if diagnostics.categoryIsMediaPlayback {
            category = "playback"
        } else {
            category = "other"
        }
        let options: String
        if diagnostics.categoryOptionsAreEmpty {
            options = "empty"
        } else if diagnostics.categoryOptionsAreIPhoneMicrophoneRouting {
            options = "iPhoneMicRouting"
        } else if diagnostics.categoryOptionsAreMixWithOthers {
            options = "mixWithOthers"
        } else {
            options = "other"
        }
        let route = diagnostics.hasOutputRoute ? "present" : "missing"

        return prefix
            + " Native failure: code=\(diagnostics.failureCode), "
            + "status=\(diagnostics.lastLifecycleStatus), "
            + "message=\(displayMessage). "
            + "Snapshot: category=\(category), modeDefault=\(diagnostics.modeIsDefault), "
            + "options=\(options), route=\(route), "
            + "rate=\(diagnostics.sampleRate), buffer=\(diagnostics.outputIOBufferDuration), "
            + "outputChannels=\(diagnostics.outputChannelCount), "
            + "sessionActive=\(diagnostics.sessionActive), "
            + "ownsActivation=\(diagnostics.ownsSessionActivation), "
            + "remoteIO=\(diagnostics.remoteIOCreated), "
            + "inputBus=\(diagnostics.inputBusEnabled), "
            + "outputBus=\(diagnostics.outputBusEnabled), "
            + "recoveryRequired=\(diagnostics.recoveryRequired), "
            + "explicitResumeRequired=\(diagnostics.explicitResumeRequired)."
    }
}
#endif

/// Platform policy for creating the local iPhone-microphone sender track.
///
/// iOS viewers always own the track. DEBUG macOS viewers may opt into the headless
/// audio test path. Release macOS structurally excludes track creation and reports false.
enum WebRTCIPhoneMicrophoneTrackCreationPolicy {
    static func shouldCreate(
        role: RemotePeerRole,
        useHeadlessMacViewerAudioForTesting: Bool = false
    ) -> Bool {
        #if os(iOS)
        role == .viewer
        #elseif DEBUG && os(macOS)
        role == .viewer && useHeadlessMacViewerAudioForTesting
        #else
        false
        #endif
    }
}

/// Owns one role-specific native WebRTC connection and its ordered control/input state machines.
///
/// Actor isolation serializes signaling epochs, candidate generations, replay histories, and
/// media authorization gates. Native callbacks cross through `WebRTCDelegateProxy` as values.
public actor WebRTCPeer {
    private static let controlHistoryLimit = 256
    private static let inputHistoryLimit = 256
    private static let maximumPendingRemoteCandidateCount = 256
    private static let maximumCandidateBytes = 8_192
    private static let maximumCandidateMIDBytes = 128
    private static let maximumCandidateUsernameFragmentBytes = 256
    #if os(iOS)
    private static let iPhoneMicrophoneOutputOnlyTarget =
        WebRTCIOSOutputOnlyMicrophoneTarget(
            category: "AVAudioSessionCategoryPlayback",
            mode: "AVAudioSessionModeDefault"
        )
    #endif

    #if DEBUG && os(macOS)
    @TaskLocal private static var useHeadlessMacViewerAudioForTesting = false
    #endif

    public nonisolated let events: AsyncStream<WebRTCTransportEvent>
    public nonisolated let externalAudioCapturer: MacExternalAudioCapturer?
    public nonisolated let externalVideoCapturer: MacExternalVideoCapturer?
    #if os(macOS)
    public nonisolated let macDecodedAudioSource: WebRTCMacDecodedAudioSource?
    #endif

    private let role: RemotePeerRole
    private let eventContinuation: AsyncStream<WebRTCTransportEvent>.Continuation
    private let factory: LKRTCPeerConnectionFactory
    private let peerConnection: LKRTCPeerConnection
    private let delegateProxy: WebRTCDelegateProxy
    private let localAudioTrack: LKRTCAudioTrack?
    private let localVideoTrack: LKRTCVideoTrack?
    private let localIPhoneMicrophoneTrack: LKRTCAudioTrack?
    private let iPhoneMicrophoneReceiverID: String?
    private let iPhoneMicrophonePeerEpoch = UUID()
    private var iPhoneMicrophoneSenderBindingGeneration: UInt64 = 0
    private var iPhoneMicrophoneTrackGeneration: UInt64 = 0
    private var iPhoneMicrophoneSenderBinding: WebRTCIPhoneMicrophoneSenderBinding?
    private var lastIPhoneMicrophoneSenderStatistics:
        WebRTCIPhoneMicrophoneSenderStatistics?
    private var iPhoneMicrophoneSenderStatisticsBaseline:
        WebRTCIPhoneMicrophoneSenderStatisticsBaseline?
    private var iPhoneMicrophoneSenderStatisticsRequiresAdvancingEvidence = false
    private var lastIPhoneMicrophoneRawProcessingResult:
        (negotiationEpoch: UInt64, codeRawValue: Int)?
    #if DEBUG
    private var debugIPhoneMicrophoneRawProcessingRequestCount = 0
    private var debugIPhoneMicrophoneRawProcessingWasEverRequestedWithoutCurrentSender = false
    private var debugIPhoneMicrophoneRawProcessingAppliedResultCount = 0
    private var debugIPhoneMicrophoneRawProcessingStoredResultCount = 0
    private var debugIPhoneMicrophoneAudioProcessingStateOverride:
        WebRTCAudioProcessingSnapshot?
    #endif
    private let mediaConstraints: LKRTCMediaConstraints
    #if os(macOS)
    // The native custom-ADM factory is expected to retain its device, but keeping ownership
    // explicit also supports the DEBUG headless viewer used by hardware-independent codec tests.
    private let macStereoAudioDevice: ASMacStereoAudioDevice?
    #endif
    #if os(iOS)
    private let iOSStereoPlayoutAudioDevice: ASIOSStereoPlayoutAudioDevice?
    private let iPhoneMicrophoneTerminalCleanupOwnerEpoch = UUID()
    private var iPhoneMicrophoneTerminalCleanupHasStarted = false
    private var activeIPhoneMicrophoneAuthorization: WebRTCIOSMicrophoneAuthorization?
    private var iPhoneMicrophoneNativeTeardownPending = false
    private var iPhoneMicrophoneNativeTeardownAuthorizationIdentity:
        ObjectIdentifier?
    private var iPhoneMicrophoneNativeRecordingGeneration: UInt64 = 0
    private var iPhoneMicrophonePolicyGeneration: UInt64 = 0
    private var iPhoneMicrophonePolicySequence: UInt64 = 0
    private var latestIPhoneMicrophonePolicyCompletionStamp:
        WebRTCIOSMicrophonePolicyCompletionStamp?
    private var iPhoneMicrophoneRetirementContext:
        WebRTCIOSMicrophoneRetirementContext?
    private var iPhoneMicrophoneTransportSuspensionHandler:
        (@Sendable @MainActor (
            WebRTCIOSMicrophoneRetirementContext
        ) async -> WebRTCIOSOutputOnlyMicrophoneToken?)?
    #if DEBUG
    private var debugIPhoneMicrophonePolicyApplier:
        (@Sendable (Bool) -> Bool)?
    private var debugIPhoneMicrophoneStageFailureDiagnostics:
        WebRTCIOSPlayoutDiagnostics?
    private var debugIPhoneMicrophoneStageFailureReason:
        WebRTCIOSMicrophoneStageFailureReason?
    #endif
    #endif

    private var delegateEventTask: Task<Void, Never>?
    private var statisticsTask: Task<Void, Never>?
    // Trickle candidates can beat SDP through signaling; native WebRTC rejects them until SDP lands.
    private var pendingRemoteCandidates: [RemoteICECandidate] = []
    private var pendingLocalCandidates: [RemoteICECandidate] = []
    private var remoteDescriptionIsSet = false
    private var localDescriptionIsAnnounced = false
    private var negotiationEpoch: UInt64 = 0
    private var outstandingLocalOfferEpoch: UInt64?
    private var applyingRemoteAnswerEpoch: UInt64?
    private var applyingRemoteOfferEpoch: UInt64?
    private var localICEUsernameFragmentMap: ICEUsernameFragmentMap?
    private var remoteICEUsernameFragmentMap: ICEUsernameFragmentMap?
    private var requiresCandidateUsernameFragment = false
    private var hasStarted = false
    private var isClosed = false
    private var currentRemoteAudioTrack: WebRTCRemoteAudioTrack?
    private var currentRemoteVideoTrack: WebRTCRemoteVideoTrack?
    private var activeSystemAudioAuthorization: WebRTCAudioAuthorization?
    private var pendingSystemAudioAuthorization: WebRTCAudioAuthorization?
    private var systemAudioAdmissionEpoch: UInt64 = 0
    private var currentRoute: WebRTCICERouteDiagnostics?
    private var nextControlRequestID: UInt64 = 1
    private var highestSentControlRequestID: UInt64?
    private var sentControlRequests: [UInt64: WebRTCControlRequest] = [:]
    private var sentControlRequestOrder: [UInt64] = []
    private var receivedControlAcknowledgements: [UInt64: WebRTCControlAcknowledgement] = [:]
    private var highestReceivedControlRequestID: UInt64?
    private var receivedControlRequests: [UInt64: WebRTCControlRequest] = [:]
    private var receivedControlRequestOrder: [UInt64] = []
    private var sentControlAcknowledgements: [UInt64: WebRTCControlAcknowledgement] = [:]
    // Remote input is an independent ordered lane. It never shares IDs or replay state with
    // screen lifecycle control, and is usable only while the exact Active capability is current.
    private var activeHostInputCapability: WebRTCInputCapability?
    private var activeViewerInputCapability: WebRTCInputCapability?
    private var activeHostInputAuthorization: WebRTCInputAuthorization?
    private var activeViewerInputAuthorization: WebRTCInputAuthorization?
    private var nextInputRequestID: UInt64 = 1
    private var highestReceivedInputRequestID: UInt64?
    // Request histories deliberately retain only authorization-binding metadata. In particular,
    // committed text (which may be a password) must not survive the native send/event-delivery
    // window merely to support feedback correlation or duplicate suppression.
    private var sentInputRequests: [UInt64: WebRTCInputRequestBinding] = [:]
    private var sentInputRequestOrder: [UInt64] = []
    private var receivedInputFeedback: [UInt64: WebRTCInputFeedback] = [:]
    private var receivedInputRequests: [UInt64: WebRTCInputRequestBinding] = [:]
    private var receivedInputRequestOrder: [UInt64] = []
    private var sentInputFeedback: [UInt64: WebRTCInputFeedback] = [:]
    // The viewer advertises support in its current SDP answer before the host can use the strict
    // v2 evidence message. Received evidence is sequence-checked within this peer lifetime.
    private var macHostedCallEvidenceIsNegotiated = false
    private var nextMacHostedCallEvidenceSequence: UInt64 = 1
    private var currentSentMacHostedCallChallenge:
        WebRTCMacHostedCallChallenge?
    private var highestReceivedMacHostedCallChallenge:
        WebRTCMacHostedCallChallenge?
    private var currentReceivedMacHostedCallChallenge:
        WebRTCMacHostedCallChallenge?
    private var sentMacHostedCallObservationAuthorization:
        WebRTCAudioAuthorization?
    private var sentMacHostedCallObservationChallenge:
        WebRTCMacHostedCallChallenge?
    private var highestSentMacHostedCallObservationSequence: UInt64 = 0
    private var highestReceivedMacHostedCallEvidenceSequence: UInt64?
    private var currentReceivedMacHostedCallEvidence:
        WebRTCMacHostedCallEvidence?

    /// Builds the native factory, role-appropriate audio device, media tracks, and control lane.
    public init(configuration: WebRTCTransportConfiguration) throws {
        guard WebRTCRuntime.isInitialized else {
            throw WebRTCTransportError.nativeFailure("WebRTC SSL initialization failed.")
        }
        if configuration.icePolicy == .relayOnly,
           !configuration.iceServers.contains(where: Self.containsTURNServer) {
            throw WebRTCTransportError.relayPolicyRequiresTURN
        }

        let eventPair = AsyncStream<WebRTCTransportEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        events = eventPair.stream
        eventContinuation = eventPair.continuation
        role = configuration.role

        let encoderFactory = LKRTCDefaultVideoEncoderFactory()
        if let h264 = LKRTCDefaultVideoEncoderFactory.supportedCodecs().first(where: {
            ($0.name as String).caseInsensitiveCompare(kLKRTCVideoCodecH264Name as String) == .orderedSame
        }) {
            encoderFactory.preferredCodec = h264
        }
        let decoderFactory = LKRTCDefaultVideoDecoderFactory()
        let nativeFactory: LKRTCPeerConnectionFactory
        #if os(macOS)
        let stereoAudioDevice: ASMacStereoAudioDevice?
        if configuration.role == .host {
            var preflightError: NSError?
            guard ASMacWebRTCAudioDevicePreflight(&preflightError) else {
                throw WebRTCTransportError.nativeFailure(
                    preflightError?.localizedDescription
                        ?? "The pinned custom stereo audio-device ABI is unavailable."
                )
            }
            let device = ASMacStereoAudioDevice()
            var factoryError: NSError?
            guard let customFactory = ASCreateMacStereoPeerConnectionFactory(
                encoderFactory,
                decoderFactory,
                device,
                &factoryError
            ) else {
                throw WebRTCTransportError.nativeFailure(
                    factoryError?.localizedDescription
                        ?? "The input-only stereo WebRTC factory could not be created."
                )
            }
            stereoAudioDevice = device
            nativeFactory = customFactory
        } else {
            #if DEBUG
            if Self.useHeadlessMacViewerAudioForTesting {
                var preflightError: NSError?
                guard ASMacWebRTCAudioDevicePreflight(&preflightError) else {
                    throw WebRTCTransportError.nativeFailure(
                        preflightError?.localizedDescription
                            ?? "The headless test audio device is unavailable."
                    )
                }
                let device = ASMacStereoAudioDevice()
                var factoryError: NSError?
                guard let customFactory = ASCreateMacStereoPeerConnectionFactory(
                    encoderFactory,
                    decoderFactory,
                    device,
                    &factoryError
                ) else {
                    throw WebRTCTransportError.nativeFailure(
                        factoryError?.localizedDescription
                            ?? "The headless test WebRTC factory could not be created."
                    )
                }
                stereoAudioDevice = device
                nativeFactory = customFactory
            } else {
                stereoAudioDevice = nil
                nativeFactory = LKRTCPeerConnectionFactory(
                    audioDeviceModuleType: .audioEngine,
                    bypassVoiceProcessing: true,
                    encoderFactory: encoderFactory,
                    decoderFactory: decoderFactory,
                    audioProcessingModule: nil
                )
            }
            #else
            stereoAudioDevice = nil
            nativeFactory = LKRTCPeerConnectionFactory(
                audioDeviceModuleType: .audioEngine,
                bypassVoiceProcessing: true,
                encoderFactory: encoderFactory,
                decoderFactory: decoderFactory,
                audioProcessingModule: nil
            )
            #endif
        }
        #elseif os(iOS)
        let stereoPlayoutDevice: ASIOSStereoPlayoutAudioDevice?
        if configuration.role == .viewer {
            let device = ASIOSStereoPlayoutAudioDevice()
            stereoPlayoutDevice = device
            nativeFactory = LKRTCPeerConnectionFactory(
                encoderFactory: encoderFactory,
                decoderFactory: decoderFactory,
                audioDevice: device
            )
        } else {
            stereoPlayoutDevice = nil
            nativeFactory = LKRTCPeerConnectionFactory(
                audioDeviceModuleType: .audioEngine,
                bypassVoiceProcessing: true,
                encoderFactory: encoderFactory,
                decoderFactory: decoderFactory,
                audioProcessingModule: nil
            )
        }
        iOSStereoPlayoutAudioDevice = stereoPlayoutDevice
        #else
        nativeFactory = LKRTCPeerConnectionFactory(
            audioDeviceModuleType: .audioEngine,
            bypassVoiceProcessing: true,
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory,
            audioProcessingModule: nil
        )
        #endif
        factory = nativeFactory
        #if os(macOS)
        macStereoAudioDevice = stereoAudioDevice
        macDecodedAudioSource = stereoAudioDevice.map {
            WebRTCMacDecodedAudioSource(device: $0)
        }
        #endif

        #if !os(macOS)
        if configuration.role == .host {
            let audioDeviceModule = nativeFactory.audioDeviceModule
            guard audioDeviceModule.setPlatformVoiceProcessingAllowed(false) == 0,
                  audioDeviceModule.setManualRenderingMode(true) == 0,
                  audioDeviceModule.isManualRenderingMode else {
                throw WebRTCTransportError.audioTrackCreationFailed
            }
        }
        #endif

        let nativeConfiguration = LKRTCConfiguration()
        nativeConfiguration.iceServers = configuration.iceServers.map {
            LKRTCIceServer(
                urlStrings: $0.urls,
                username: $0.username,
                credential: $0.credential
            )
        }
        nativeConfiguration.sdpSemantics = .unifiedPlan
        nativeConfiguration.iceTransportPolicy = configuration.icePolicy == .relayOnly ? .relay : .all
        nativeConfiguration.bundlePolicy = .maxBundle
        nativeConfiguration.rtcpMuxPolicy = .require
        nativeConfiguration.continualGatheringPolicy = .gatherContinually
        nativeConfiguration.tcpCandidatePolicy = .enabled
        nativeConfiguration.candidateNetworkPolicy = .all
        nativeConfiguration.disableIPV6OnWiFi = false
        nativeConfiguration.disableLinkLocalNetworks = false
        nativeConfiguration.enableIceGatheringOnAnyAddressPorts = true
        nativeConfiguration.enableDscp = true
        nativeConfiguration.iceCandidatePoolSize = 2

        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        mediaConstraints = constraints
        let proxy = WebRTCDelegateProxy()
        delegateProxy = proxy
        guard let nativePeer = nativeFactory.peerConnection(
            with: nativeConfiguration,
            constraints: constraints,
            delegate: proxy
        ) else {
            throw WebRTCTransportError.peerConnectionCreationFailed
        }
        peerConnection = nativePeer

        #if os(iOS)
        if WebRTCIPhoneMicrophoneTrackCreationPolicy.shouldCreate(
            role: configuration.role
        ) {
            let source = nativeFactory.audioSource(with: nil)
            let track = nativeFactory.audioTrack(
                with: source,
                trackId: WebRTCAudioTrackIdentifiers.iPhoneMicrophone
            )
            track.isEnabled = false
            localIPhoneMicrophoneTrack = track
        } else {
            localIPhoneMicrophoneTrack = nil
        }
        #elseif DEBUG && os(macOS)
        if WebRTCIPhoneMicrophoneTrackCreationPolicy.shouldCreate(
            role: configuration.role,
            useHeadlessMacViewerAudioForTesting:
                Self.useHeadlessMacViewerAudioForTesting
        ) {
            let source = nativeFactory.audioSource(with: nil)
            let track = nativeFactory.audioTrack(
                with: source,
                trackId: WebRTCAudioTrackIdentifiers.iPhoneMicrophone
            )
            track.isEnabled = false
            localIPhoneMicrophoneTrack = track
        } else {
            localIPhoneMicrophoneTrack = nil
        }
        #else
        localIPhoneMicrophoneTrack = nil
        #endif

        var configuredIPhoneMicrophoneReceiverID: String?
        if configuration.role == .host {
            #if os(macOS)
            guard let stereoAudioDevice,
                  let audioCapturer = MacExternalAudioCapturer(
                      stereoAudioDevice: stereoAudioDevice
                  ) else {
                throw WebRTCTransportError.audioTrackCreationFailed
            }
            #else
            let audioCapturer = MacExternalAudioCapturer(
                audioDeviceModule: nativeFactory.audioDeviceModule
            )
            #endif
            let audioSource = nativeFactory.audioSource(with: nil)
            let audioTrack = nativeFactory.audioTrack(
                with: audioSource,
                trackId: "system-audio"
            )
            audioTrack.isEnabled = false
            let audioTransceiverConfiguration = LKRTCRtpTransceiverInit()
            audioTransceiverConfiguration.direction = .sendOnly
            audioTransceiverConfiguration.streamIds = ["audio-stream"]
            guard let audioTransceiver = nativePeer.addTransceiver(
                with: audioTrack,
                init: audioTransceiverConfiguration
            ) else {
                throw WebRTCTransportError.audioTrackCreationFailed
            }
            // Apply raw processing only after the track is attached to its sender. Before that,
            // WebRTC merely stores the request on the source; adding the sender subsequently
            // installs communication defaults (AEC/NS/AGC/HPF) on the shared voice engine.
            guard audioTrack.setAudioProcessingOptions(.raw()).isSuccess else {
                throw WebRTCTransportError.audioTrackCreationFailed
            }
            try Self.preferOpus(
                on: audioTransceiver,
                capabilities: nativeFactory.rtpSenderCapabilities(
                    forKind: kLKRTCMediaStreamTrackKindAudio
                )
            )
            try Self.applyHighFidelityAudioSenderParameters(
                to: audioTransceiver.sender
            )
            localAudioTrack = audioTrack
            externalAudioCapturer = audioCapturer

            let microphoneReceiverConfiguration = LKRTCRtpTransceiverInit()
            microphoneReceiverConfiguration.direction = .recvOnly
            microphoneReceiverConfiguration.streamIds = [
                WebRTCAudioTrackIdentifiers.iPhoneMicrophoneStream
            ]
            guard let microphoneReceiver = nativePeer.addTransceiver(
                of: .audio,
                init: microphoneReceiverConfiguration
            ) else {
                throw WebRTCTransportError.audioTrackCreationFailed
            }
            let receiverID = microphoneReceiver.receiver.receiverId as String
            guard !receiverID.isEmpty else {
                throw WebRTCTransportError.nativeFailure(
                    "The dedicated iPhone microphone receiver did not expose an identity."
                )
            }
            configuredIPhoneMicrophoneReceiverID = receiverID
            try Self.preferOpus(
                on: microphoneReceiver,
                capabilities: nativeFactory.rtpReceiverCapabilities(
                    forKind: kLKRTCMediaStreamTrackKindAudio
                )
            )

            let videoSource = nativeFactory.videoSource(forScreenCast: true)
            let videoTrack = nativeFactory.videoTrack(
                with: videoSource,
                trackId: "screen-video"
            )
            videoTrack.isEnabled = false
            let videoTransceiverConfiguration = LKRTCRtpTransceiverInit()
            videoTransceiverConfiguration.direction = .sendOnly
            videoTransceiverConfiguration.streamIds = ["screen-stream"]
            guard let videoTransceiver = nativePeer.addTransceiver(
                with: videoTrack,
                init: videoTransceiverConfiguration
            ) else {
                throw WebRTCTransportError.videoTrackCreationFailed
            }
            try Self.preferH264(
                on: videoTransceiver,
                capabilities: nativeFactory.rtpSenderCapabilities(
                    forKind: kLKRTCMediaStreamTrackKindVideo
                )
            )
            localVideoTrack = videoTrack
            externalVideoCapturer = MacExternalVideoCapturer(source: videoSource)

            let dataChannelConfiguration = LKRTCDataChannelConfiguration()
            dataChannelConfiguration.isOrdered = true
            dataChannelConfiguration.maxPacketLifeTime = -1
            dataChannelConfiguration.maxRetransmits = -1
            dataChannelConfiguration.isNegotiated = false
            dataChannelConfiguration.`protocol` = WebRTCWireConstants.controlProtocol
            guard let dataChannel = nativePeer.dataChannel(
                forLabel: WebRTCWireConstants.controlChannelLabel,
                configuration: dataChannelConfiguration
            ) else {
                throw WebRTCTransportError.dataChannelCreationFailed
            }
            proxy.installDataChannel(dataChannel)
        } else {
            localAudioTrack = nil
            externalAudioCapturer = nil
            localVideoTrack = nil
            externalVideoCapturer = nil
        }
        iPhoneMicrophoneReceiverID = configuredIPhoneMicrophoneReceiverID

        if let maximumVideoBitrate = configuration.maximumVideoBitrate {
            _ = nativePeer.setBweMinBitrateBps(
                nil,
                currentBitrateBps: nil,
                maxBitrateBps: NSNumber(value: maximumVideoBitrate)
            )
        }
    }

    deinit {
        statisticsTask?.cancel()
        delegateEventTask?.cancel()
        delegateProxy.close()
        peerConnection.close()
        eventContinuation.finish()
    }

    /// Starts event processing and, for the host role, emits the initial offer.
    public func start() async throws {
        try ensureOpen()
        guard role == .host else { throw WebRTCTransportError.invalidRole }
        guard !hasStarted else { throw WebRTCTransportError.alreadyStarted }
        guard outstandingLocalOfferEpoch == nil,
              applyingRemoteAnswerEpoch == nil,
              applyingRemoteOfferEpoch == nil,
              peerConnection.signalingState == .stable else {
            throw WebRTCTransportError.unexpectedSignal
        }
        ensureDelegateEventLoop()

        let offerEpoch = nextNegotiationEpoch()
        resetMacHostedCallEvidenceNegotiation()
        outstandingLocalOfferEpoch = offerEpoch
        hasStarted = true
        localDescriptionIsAnnounced = false
        remoteDescriptionIsSet = false
        localICEUsernameFragmentMap = nil
        remoteICEUsernameFragmentMap = nil
        requiresCandidateUsernameFragment = false
        pendingLocalCandidates.removeAll(keepingCapacity: true)
        do {
            let sdp = try await createAndSetLocalOffer()
            try ensureOpen()
            guard outstandingLocalOfferEpoch == offerEpoch else {
                throw WebRTCTransportError.unexpectedSignal
            }
            let payload = RemoteSignalPayload.offer(sdp: sdp)
            try announceLocalDescription(payload)
        } catch {
            if outstandingLocalOfferEpoch == offerEpoch,
               peerConnection.signalingState == .stable {
                outstandingLocalOfferEpoch = nil
            }
            hasStarted = false
            throw error
        }
    }

    /// Applies one already-authenticated rendezvous payload to the native connection.
    public func receive(_ payload: RemoteSignalPayload) async throws {
        try ensureOpen()
        ensureDelegateEventLoop()

        switch payload {
        case .offer(let sdp):
            guard role == .viewer,
                  outstandingLocalOfferEpoch == nil,
                  applyingRemoteAnswerEpoch == nil,
                  applyingRemoteOfferEpoch == nil,
                  peerConnection.signalingState == .stable else {
                throw WebRTCTransportError.unexpectedSignal
            }

            let isRestartOffer = hasStarted
            let offerEpoch = nextNegotiationEpoch()
            resetMacHostedCallEvidenceNegotiation()
            applyingRemoteOfferEpoch = offerEpoch
            defer {
                if applyingRemoteOfferEpoch == offerEpoch {
                    applyingRemoteOfferEpoch = nil
                }
            }

            // This generation boundary must be installed before the first await. Otherwise a
            // candidate callback can announce or apply an answer-era candidate against old SDP.
            localDescriptionIsAnnounced = false
            remoteDescriptionIsSet = false
            localICEUsernameFragmentMap = nil
            remoteICEUsernameFragmentMap = nil
            pendingLocalCandidates.removeAll(keepingCapacity: true)
            invalidateIPhoneMicrophoneSenderBinding()
            if isRestartOffer {
                requiresCandidateUsernameFragment = true
                pendingRemoteCandidates.removeAll(keepingCapacity: true)
                invalidateCurrentRoute()
                await failCloseScreenMedia()
            }

            try await setRemoteDescription(sdp: sdp, type: .offer)
            try ensureOpen()
            guard applyingRemoteOfferEpoch == offerEpoch else {
                throw WebRTCTransportError.unexpectedSignal
            }
            try installRemoteICEUsernameFragments(from: sdp)
            remoteDescriptionIsSet = true
            try configureIPhoneMicrophoneSender(remoteOfferSDP: sdp)
            try await flushRemoteCandidates(expectedEpoch: offerEpoch)
            try ensureOpen()
            guard applyingRemoteOfferEpoch == offerEpoch else {
                throw WebRTCTransportError.unexpectedSignal
            }
            try preferOpusOnAudioTransceivers()
            try preferH264OnVideoTransceivers()
            let answerSDP = try await createAndSetLocalAnswer(remoteOfferSDP: sdp)
            try ensureOpen()
            guard applyingRemoteOfferEpoch == offerEpoch else {
                throw WebRTCTransportError.unexpectedSignal
            }
            hasStarted = true
            macHostedCallEvidenceIsNegotiated =
                MacHostedCallEvidenceSDP.peerSupportsEvidence(in: sdp)
                && MacHostedCallEvidenceSDP.peerSupportsEvidence(
                    in: answerSDP
                )
            // `outboundSignal(.answer)` is the ordered post-capability event consumed by the
            // viewer. The application may retry its current challenge only after forwarding this
            // answer; the peer-side transport/capability check remains authoritative.
            try announceLocalDescription(.answer(sdp: answerSDP))

        case .answer(let sdp):
            guard role == .host,
                  hasStarted,
                  localDescriptionIsAnnounced,
                  let offerEpoch = outstandingLocalOfferEpoch,
                  applyingRemoteAnswerEpoch == nil,
                  applyingRemoteOfferEpoch == nil,
                  peerConnection.signalingState == .haveLocalOffer else {
                throw WebRTCTransportError.unexpectedSignal
            }

            applyingRemoteAnswerEpoch = offerEpoch
            defer {
                if applyingRemoteAnswerEpoch == offerEpoch {
                    applyingRemoteAnswerEpoch = nil
                }
            }

            try await setRemoteDescription(sdp: sdp, type: .answer)
            try ensureOpen()
            guard outstandingLocalOfferEpoch == offerEpoch,
                  applyingRemoteAnswerEpoch == offerEpoch else {
                throw WebRTCTransportError.unexpectedSignal
            }
            // A disabled sender stores this request. `enableSystemAudioIfTransportHealthy` applies
            // and verifies it after transport health is proven and immediately before PCM flows.
            try requestRawSystemAudioProcessing()
            macHostedCallEvidenceIsNegotiated =
                MacHostedCallEvidenceSDP.peerSupportsEvidence(in: sdp)
            try installRemoteICEUsernameFragments(from: sdp)
            remoteDescriptionIsSet = true
            try await flushRemoteCandidates(expectedEpoch: offerEpoch)
            try ensureOpen()
            guard outstandingLocalOfferEpoch == offerEpoch,
                  applyingRemoteAnswerEpoch == offerEpoch else {
                throw WebRTCTransportError.unexpectedSignal
            }
            outstandingLocalOfferEpoch = nil

        case .candidate(let candidate):
            guard Self.isValidCandidateEnvelope(candidate) else {
                throw WebRTCTransportError.invalidICECandidate
            }
            if remoteDescriptionIsSet {
                guard let candidate = currentRemoteCandidate(candidate) else { return }
                let expectedEpoch = negotiationEpoch
                _ = try await addRemoteCandidate(candidate, expectedEpoch: expectedEpoch)
            } else {
                try enqueuePendingRemoteCandidate(candidate)
            }

        case .control(let command):
            // Retained only for legacy encrypted-signaling compatibility. It never enables video;
            // the worldwide path must complete the v2 data-channel request/ack handshake.
            emit(.controlReceived(command))

        case .identity(let identity):
            emit(.identityReceived(identity))

        case .iceRestartRequest:
            // Application services authenticate, deduplicate, and direction-check this request.
            // Feeding it into the media peer would bypass those lifecycle guards.
            throw WebRTCTransportError.unexpectedSignal

        case .end(let reason):
            emit(.ended(reason))
            closeTransport()
        }
    }

    public func handle(_ payload: RemoteSignalPayload) async throws {
        try await receive(payload)
    }

    /// Begins a fresh ICE generation while retaining the authenticated signaling session.
    public func restartICE() async throws {
        try ensureOpen()
        guard role == .host, hasStarted else { throw WebRTCTransportError.invalidRole }
        guard outstandingLocalOfferEpoch == nil,
              applyingRemoteAnswerEpoch == nil,
              applyingRemoteOfferEpoch == nil,
              peerConnection.signalingState == .stable else {
            throw WebRTCTransportError.iceRestartAlreadyInProgress
        }
        ensureDelegateEventLoop()

        let offerEpoch = nextNegotiationEpoch()
        resetMacHostedCallEvidenceNegotiation()
        outstandingLocalOfferEpoch = offerEpoch
        localDescriptionIsAnnounced = false
        remoteDescriptionIsSet = false
        localICEUsernameFragmentMap = nil
        remoteICEUsernameFragmentMap = nil
        requiresCandidateUsernameFragment = true
        pendingLocalCandidates.removeAll(keepingCapacity: true)
        pendingRemoteCandidates.removeAll(keepingCapacity: true)
        suspendSystemAudioForTransportUncertainty()
        invalidateCurrentRoute()
        await failCloseScreenMedia()
        peerConnection.restartIce()
        do {
            let sdp = try await createAndSetLocalOffer()
            try ensureOpen()
            guard outstandingLocalOfferEpoch == offerEpoch else {
                throw WebRTCTransportError.unexpectedSignal
            }
            try announceLocalDescription(.offer(sdp: sdp))
            // The generation remains outstanding until its answer and candidates are applied.
        } catch {
            if outstandingLocalOfferEpoch == offerEpoch,
               peerConnection.signalingState == .stable {
                outstandingLocalOfferEpoch = nil
            }
            throw error
        }
    }

    /// Sends a v2 command from the viewer and returns the identifier its acknowledgement must match.
    @discardableResult
    public func requestControl(_ command: RemoteControlCommand) throws -> UInt64 {
        try ensureOpen()
        guard role == .viewer else { throw WebRTCTransportError.invalidRole }
        ensureDelegateEventLoop()
        guard nextControlRequestID < UInt64.max else {
            throw WebRTCTransportError.controlRequestIDExhausted
        }
        guard prepareSentControlHistoryForNewRequest() else {
            throw WebRTCTransportError.dataChannelBackpressured
        }

        let request = WebRTCControlRequest(id: nextControlRequestID, command: command)
        let data = try JSONEncoder().encode(ControlChannelMessage.command(request))

        if command == .showScreen || command == .hideScreen {
            // Starting any visibility transition makes the old input generation stale locally.
            // Revoke before the native send so a failed Hide/Show cannot leave input authorized.
            // Privacy is monotone: a fresh Show/Active ACK is required to restore input.
            replaceViewerInputSession(capability: nil, authorization: nil)
        }

        try delegateProxy.sendControlData(data)

        nextControlRequestID += 1
        highestSentControlRequestID = request.id
        sentControlRequests[request.id] = request
        sentControlRequestOrder.append(request.id)
        return request.id
    }

    @discardableResult
    public func setScreenVisible(_ isVisible: Bool) throws -> UInt64 {
        try requestControl(isVisible ? .showScreen : .hideScreen)
    }

    /// Confirms that the host application has actually completed `id` and reached `state`.
    /// A Show/Active transition additionally requires the revocable healthy-transport API.
    public func acknowledgeControlRequest(id: UInt64, state: WebRTCScreenState) throws {
        try acknowledgeControlRequest(
            id: id,
            state: state,
            permitsScreenTrackEnable: false,
            inputCapability: nil,
            inputAuthorization: nil
        )
    }

    private func acknowledgeControlRequest(
        id: UInt64,
        state: WebRTCScreenState,
        permitsScreenTrackEnable: Bool,
        inputCapability: WebRTCInputCapability?,
        inputAuthorization: WebRTCInputAuthorization?
    ) throws {
        try ensureOpen()
        guard role == .host else { throw WebRTCTransportError.invalidRole }
        ensureDelegateEventLoop()
        guard let request = receivedControlRequests[id] else {
            if let highestReceivedControlRequestID, id < highestReceivedControlRequestID {
                throw WebRTCTransportError.staleControlRequest(id)
            }
            throw WebRTCTransportError.unknownControlRequest(id)
        }
        guard id == highestReceivedControlRequestID else {
            throw WebRTCTransportError.staleControlRequest(id)
        }

        let enablesScreenTrack = state == .active && request.command == .showScreen
        guard !enablesScreenTrack || permitsScreenTrackEnable else {
            throw WebRTCTransportError.controlAuthorizationRequired
        }
        guard inputCapability == nil || (
            enablesScreenTrack
                && inputCapability?.isValid == true
                && inputCapability?.screenRequestID == id
        ) else {
            throw WebRTCTransportError.invalidInputCapability
        }
        guard (inputCapability == nil) == (inputAuthorization == nil) else {
            throw WebRTCTransportError.invalidInputCapability
        }

        let acknowledgement = WebRTCControlAcknowledgement(
            id: id,
            state: state,
            inputCapability: inputCapability
        )
        if let existing = sentControlAcknowledgements[id], existing != acknowledgement {
            throw WebRTCTransportError.conflictingControlAcknowledgement(id)
        }
        if sentControlAcknowledgements[id] != nil,
           inputCapability != nil,
           (inputCapability != activeHostInputCapability
                || inputAuthorization !== activeHostInputAuthorization) {
            throw WebRTCTransportError.invalidInputCapability
        }

        let data = try JSONEncoder().encode(ControlChannelMessage.acknowledgement(acknowledgement))
        if state == .inactive {
            localVideoTrack?.isEnabled = false
            // Input is revoked synchronously even if the Inactive ACK cannot be delivered.
            replaceHostInputSession(capability: nil, authorization: nil)
        } else if enablesScreenTrack,
                  (activeHostInputCapability != inputCapability
                    || activeHostInputAuthorization !== inputAuthorization) {
            // Never retain an older generation while a replacement Active ACK is in flight.
            replaceHostInputSession(capability: nil, authorization: nil)
        }
        if enablesScreenTrack, let inputAuthorization {
            // Install at the native callback boundary before sending the capability. A native
            // disconnect that races the ACK then revokes this exact token synchronously, before
            // either the peer actor or host service can drain stale events.
            guard delegateProxy.installInputAuthorization(inputAuthorization) else {
                inputAuthorization.revoke()
                throw WebRTCTransportError.transportNotHealthy
            }
        }
        do {
            if let inputAuthorization {
                try inputAuthorization.withValidAuthorization {
                    try delegateProxy.sendControlData(data)
                }
            } else {
                try delegateProxy.sendControlData(data)
            }
            sentControlAcknowledgements[id] = acknowledgement
            if enablesScreenTrack {
                replaceHostInputSession(
                    capability: inputCapability,
                    authorization: inputAuthorization
                )
                guard !delegateProxy.didFailEventDelivery(),
                      inputAuthorization.map({
                          delegateProxy.hasHealthyInstalledInputAuthorization($0)
                      }) != false else {
                    throw WebRTCTransportError.transportClosed
                }
                // Media may become visible only after the Active acknowledgement has been
                // accepted by the ordered control channel and its input gate was retained.
                localVideoTrack?.isEnabled = true
            } else if state == .inactive {
                replaceHostInputSession(capability: nil, authorization: nil)
            }
        } catch {
            // An Active acknowledgement is not true if it cannot reach the viewer.
            if enablesScreenTrack {
                localVideoTrack?.isEnabled = false
                replaceHostInputSession(capability: nil, authorization: nil)
                inputAuthorization?.revoke()
            }
            throw error
        }
    }

    /// Atomically validates the native connection, ICE, signaling-generation, and data-channel
    /// state in this actor before sending an acknowledgement. Host code uses this for the active
    /// capture transition and for the post-restart Inactive proof so a separate snapshot cannot
    /// become stale while waiting to enter the peer actor.
    public func acknowledgeControlRequestIfTransportHealthy(
        id: UInt64,
        state: WebRTCScreenState,
        authorization: WebRTCControlAuthorization,
        inputCapability: WebRTCInputCapability? = nil,
        inputAuthorization: WebRTCInputAuthorization? = nil,
        finalAuthorizationCheck: @Sendable () -> Bool = { true }
    ) throws {
        try authorization.withValidAuthorization {
            guard finalAuthorizationCheck() else {
                throw WebRTCTransportError.controlAuthorizationRevoked
            }
            guard isTransportHealthyForCapture() else {
                throw WebRTCTransportError.transportNotHealthy
            }
            try acknowledgeControlRequest(
                id: id,
                state: state,
                permitsScreenTrackEnable: true,
                inputCapability: inputCapability,
                inputAuthorization: inputAuthorization
            )
        }
    }

    /// The only Active acknowledgement path used by the Mac capture service. Revocation and the
    /// stable native-health check are serialized by `authorization`, while the actor serializes
    /// the track enable and data-channel send.
    public func acknowledgeActiveControlRequestIfTransportHealthy(
        id: UInt64,
        authorization: WebRTCControlAuthorization,
        inputCapability: WebRTCInputCapability? = nil,
        inputAuthorization: WebRTCInputAuthorization? = nil,
        finalAuthorizationCheck: @Sendable () -> Bool = { true }
    ) throws {
        try acknowledgeControlRequestIfTransportHealthy(
            id: id,
            state: .active,
            authorization: authorization,
            inputCapability: inputCapability,
            inputAuthorization: inputAuthorization,
            finalAuthorizationCheck: finalAuthorizationCheck
        )
    }

    /// Sends one input operation using the capability from the most recent Show/Active ACK.
    /// Input IDs are monotonic independently of screen-control request IDs.
    @discardableResult
    public func requestInput(
        _ action: WebRTCInputAction,
        viewerVideoSize: WebRTCInputVideoSize? = nil
    ) throws -> UInt64 {
        guard let activeViewerInputCapability,
              let activeViewerInputAuthorization else {
            throw WebRTCTransportError.inputUnavailable
        }
        return try requestInput(
            action,
            viewerVideoSize: viewerVideoSize,
            capability: activeViewerInputCapability,
            authorization: activeViewerInputAuthorization
        )
    }

    /// Explicit-capability spelling lets UI code reject a stale task captured before a new
    /// Show/Active generation. The supplied capability must still equal the peer's current one.
    @discardableResult
    public func requestInput(
        _ action: WebRTCInputAction,
        viewerVideoSize: WebRTCInputVideoSize? = nil,
        capability: WebRTCInputCapability
    ) throws -> UInt64 {
        guard let activeViewerInputAuthorization else {
            throw WebRTCTransportError.inputUnavailable
        }
        return try requestInput(
            action,
            viewerVideoSize: viewerVideoSize,
            capability: capability,
            authorization: activeViewerInputAuthorization
        )
    }

    /// The explicit authorization closes the gap between UI cancellation and the final native
    /// data-channel send. Revocation waits for an in-progress send, or wins before it starts.
    @discardableResult
    public func requestInput(
        _ action: WebRTCInputAction,
        viewerVideoSize: WebRTCInputVideoSize? = nil,
        capability: WebRTCInputCapability,
        authorization: WebRTCInputAuthorization
    ) throws -> UInt64 {
        try ensureOpen()
        guard role == .viewer else { throw WebRTCTransportError.invalidRole }
        ensureDelegateEventLoop()
        guard capability.isValid,
              capability == activeViewerInputCapability,
              authorization === activeViewerInputAuthorization else {
            throw WebRTCTransportError.inputUnavailable
        }
        guard action.isValid,
              Self.inputCapability(capability, permits: action) else {
            throw WebRTCTransportError.invalidInputRequest
        }
        guard nextInputRequestID < UInt64.max else {
            throw WebRTCTransportError.inputRequestIDExhausted
        }

        guard prepareSentInputHistoryForNewRequest() else {
            failCloseInput("Remote-input send backlog exceeded its safe bound.")
            throw WebRTCTransportError.dataChannelBackpressured
        }

        let request = WebRTCInputRequest(
            id: nextInputRequestID,
            screenRequestID: capability.screenRequestID,
            inputSessionID: capability.inputSessionID,
            action: action,
            viewerVideoSize: viewerVideoSize
        )
        guard request.isValid else {
            throw WebRTCTransportError.invalidInputRequest
        }
        let data = try JSONEncoder().encode(ControlChannelMessage.input(request))
        guard data.count <= capability.maxMessageBytes else {
            throw WebRTCTransportError.invalidInputRequest
        }
        try authorization.withValidAuthorization {
            guard capability == activeViewerInputCapability,
                  authorization === activeViewerInputAuthorization else {
                throw WebRTCTransportError.inputUnavailable
            }
            try delegateProxy.sendControlData(data)
            nextInputRequestID += 1
            sentInputRequests[request.id] = WebRTCInputRequestBinding(request)
            sentInputRequestOrder.append(request.id)
        }
        return request.id
    }

    @discardableResult
    public func sendInput(
        _ action: WebRTCInputAction,
        viewerVideoSize: WebRTCInputVideoSize? = nil
    ) throws -> UInt64 {
        try requestInput(action, viewerVideoSize: viewerVideoSize)
    }

    @discardableResult
    public func sendInput(
        _ action: WebRTCInputAction,
        viewerVideoSize: WebRTCInputVideoSize? = nil,
        capability: WebRTCInputCapability
    ) throws -> UInt64 {
        try requestInput(
            action,
            viewerVideoSize: viewerVideoSize,
            capability: capability
        )
    }

    @discardableResult
    public func sendInput(
        _ action: WebRTCInputAction,
        viewerVideoSize: WebRTCInputVideoSize? = nil,
        capability: WebRTCInputCapability,
        authorization: WebRTCInputAuthorization
    ) throws -> UInt64 {
        try requestInput(
            action,
            viewerVideoSize: viewerVideoSize,
            capability: capability,
            authorization: authorization
        )
    }

    /// Completes a received request. The transport constructs all binding identifiers from the
    /// retained request, preventing application code from accidentally acknowledging another
    /// input or screen generation.
    public func sendInputFeedback(
        for id: UInt64,
        result: WebRTCInputFeedbackResult,
        rejectionReason: WebRTCInputRejectionReason? = nil,
        focus: WebRTCInputFocus = .none
    ) throws {
        try ensureOpen()
        guard role == .host else { throw WebRTCTransportError.invalidRole }
        ensureDelegateEventLoop()
        guard let request = receivedInputRequests[id] else {
            if let highestReceivedInputRequestID, id <= highestReceivedInputRequestID {
                throw WebRTCTransportError.staleInputRequest(id)
            }
            throw WebRTCTransportError.unknownInputRequest(id)
        }
        guard let capability = activeHostInputCapability,
              request.screenRequestID == capability.screenRequestID,
              request.inputSessionID == capability.inputSessionID else {
            throw WebRTCTransportError.inputUnavailable
        }

        let feedback = WebRTCInputFeedback(
            id: request.id,
            screenRequestID: request.screenRequestID,
            inputSessionID: request.inputSessionID,
            result: result,
            rejectionReason: rejectionReason,
            focus: focus
        )
        guard feedback.isValid else { throw WebRTCTransportError.invalidInputRequest }
        if let existing = sentInputFeedback[id], existing != feedback {
            throw WebRTCTransportError.conflictingInputFeedback(id)
        }

        let data = try JSONEncoder().encode(ControlChannelMessage.inputFeedback(feedback))
        guard data.count <= capability.maxMessageBytes else {
            throw WebRTCTransportError.invalidInputRequest
        }
        try delegateProxy.sendControlData(data)
        sentInputFeedback[id] = feedback
    }

    public func currentInputCapability() -> WebRTCInputCapability? {
        role == .host ? activeHostInputCapability : activeViewerInputCapability
    }

#if DEBUG
    #if os(macOS)
    nonisolated static func makeHeadlessViewerForTesting(
        configuration: WebRTCTransportConfiguration
    ) throws -> WebRTCPeer {
        try $useHeadlessMacViewerAudioForTesting.withValue(true) {
            try WebRTCPeer(configuration: configuration)
        }
    }

    func pullHeadlessMacViewerAudioForTesting(frameCount: Int = 480) -> Bool {
        guard role == .viewer,
              frameCount > 0,
              let macStereoAudioDevice else {
            return false
        }
        return macStereoAudioDevice.pullHeadlessPlayoutFrames(UInt(frameCount))
    }

    var iPhoneMicrophoneReceiverIDForTesting: String? {
        role == .host ? iPhoneMicrophoneReceiverID : nil
    }

    /// Bypasses proxy deduplication so peer-level exact receiver classification can be tested.
    func consumeIPhoneMicrophoneReceiverCallbackForTesting(
        receiverID: String
    ) async -> Bool {
        guard let receiverTrack =
                iPhoneMicrophoneNativeReceiverTrackForTesting() else {
            return false
        }
        await consume(
            .remoteAudioTrack(
                WebRTCNativeRemoteAudioReceiverTrack(
                    receiverTrack.track,
                    receiverID: receiverID
                )
            )
        )
        return true
    }

    /// Replays the genuine receiver callback through the proxy's receiver-ID dedupe boundary.
    func replayIPhoneMicrophoneReceiverCallbackForTesting() -> Bool {
        guard let receiverTrack =
                iPhoneMicrophoneNativeReceiverTrackForTesting() else {
            return false
        }
        return delegateProxy.receiveRemoteAudioTrackForTesting(
            receiverTrack.track,
            receiverID: receiverTrack.receiverID
        )
    }

    /// Returns a fresh public wrapper for the same receiver without making it peer-current.
    func makeStaleIPhoneMicrophoneTrackForTesting()
        -> WebRTCRemoteAudioTrack? {
        guard let receiverTrack =
                iPhoneMicrophoneNativeReceiverTrackForTesting() else {
            return nil
        }
        return WebRTCRemoteAudioTrack(
            WebRTCNativeRemoteAudioReceiverTrack(
                receiverTrack.track,
                receiverID: receiverTrack.receiverID
            ),
            logicalLane: .iPhoneMicrophone
        )
    }

    private func iPhoneMicrophoneNativeReceiverTrackForTesting()
        -> (receiverID: String, track: LKRTCAudioTrack)? {
        guard role == .host,
              let receiverID = iPhoneMicrophoneReceiverID,
              let transceiver = peerConnection.transceivers.first(where: {
                  $0.mediaType == .audio
                      && ($0.receiver.receiverId as String) == receiverID
              }),
              let track = transceiver.receiver.track as? LKRTCAudioTrack else {
            return nil
        }
        return (receiverID, track)
    }
    #endif

    func installHostInputSessionForTesting(
        capability: WebRTCInputCapability,
        authorization: WebRTCInputAuthorization
    ) throws {
        try ensureOpen()
        guard role == .host, capability.isValid else {
            throw WebRTCTransportError.invalidInputCapability
        }
        delegateProxy.markNativeTransportHealthyForTesting()
        replaceHostInputSession(capability: capability, authorization: authorization)
    }

    func receiveInputRequestForTesting(_ request: WebRTCInputRequest) -> Bool {
        receiveInputRequest(request)
        return receivedInputRequests[request.id] != nil
    }

    func installViewerInputSessionForTesting(
        capability: WebRTCInputCapability,
        authorization: WebRTCInputAuthorization
    ) throws {
        try ensureOpen()
        guard role == .viewer, capability.isValid else {
            throw WebRTCTransportError.invalidInputCapability
        }
        // Test-only native health makes the authorization genuinely live while leaving the
        // data-channel object absent, so tests can exercise synchronous revocation on send loss.
        delegateProxy.markNativeTransportHealthyForTesting()
        replaceViewerInputSession(capability: capability, authorization: authorization)
    }

    func emitPublicEventForTesting() {
        emit(.diagnosticFailure("event-buffer-test"))
    }

    func receiveControlAcknowledgementForTesting(
        request: WebRTCControlRequest,
        acknowledgement: WebRTCControlAcknowledgement
    ) throws {
        try ensureOpen()
        guard role == .viewer,
              request.id == acknowledgement.id else {
            throw WebRTCTransportError.invalidRole
        }
        highestSentControlRequestID = request.id
        sentControlRequests[request.id] = request
        sentControlRequestOrder.append(request.id)
        receiveControlAcknowledgement(acknowledgement)
    }

    var isClosedForTesting: Bool {
        isClosed
    }

    var isSystemAudioEnabledForTesting: Bool {
        localAudioTrack?.isEnabled == true
            && activeSystemAudioAuthorization?.isValid == true
    }

    func audioSenderEncodingParametersForTesting() -> [WebRTCAudioSenderEncodingParameters] {
        peerConnection.transceivers
            .filter { $0.mediaType == .audio && $0.sender.track != nil }
            .flatMap { transceiver in
                transceiver.sender.parameters.encodings.map { encoding in
                    WebRTCAudioSenderEncodingParameters(
                        maximumBitrateBps: encoding.maxBitrateBps?.intValue,
                        minimumBitrateBps: encoding.minBitrateBps?.intValue
                    )
                }
            }
    }

    func audioProcessingStateForTesting() -> WebRTCAudioProcessingSnapshot {
        let state = factory.audioProcessingState
        return WebRTCAudioProcessingSnapshot(
            hasAudioProcessingModule: state.hasAudioProcessingModule,
            echoCancellation: Self.audioProcessingComponentSnapshot(
                state.echoCancellation
            ),
            noiseSuppression: Self.audioProcessingComponentSnapshot(
                state.noiseSuppression
            ),
            autoGainControl: Self.audioProcessingComponentSnapshot(
                state.autoGainControl
            ),
            highPassFilter: Self.audioProcessingComponentSnapshot(
                state.highPassFilter
            )
        )
    }

    private static func audioProcessingComponentSnapshot(
        _ state: LKRTCAudioProcessingComponentState
    ) -> WebRTCAudioProcessingComponentSnapshot {
        WebRTCAudioProcessingComponentSnapshot(
            requestedEnabled: state.requested?.isEnabled,
            softwareActive: state.isSoftwareActive,
            platformActive: state.isPlatformActive
        )
    }

    func iPhoneMicrophoneSenderStateForTesting()
        -> WebRTCIPhoneMicrophoneSenderSnapshot {
        let nativeRecordingGeneration: UInt64?
        let nativeApprovedRecordingGeneration: UInt64?
        let nativeDeliveryCallbackCount: UInt64?
        let nativeDeliveredFrameCount: UInt64?
        #if os(macOS)
        let nativeDiagnostics = macStereoAudioDevice?.diagnostics
        nativeRecordingGeneration =
            nativeDiagnostics?.recordingGeneration
        nativeApprovedRecordingGeneration =
            nativeDiagnostics?.approvedRecordingGeneration
        nativeDeliveryCallbackCount =
            nativeDiagnostics?.deliveryCallbackCount
        nativeDeliveredFrameCount =
            nativeDiagnostics?.deliveredFrameCount
        #elseif os(iOS)
        let nativeDiagnostics = iOSStereoPlayoutAudioDevice?.diagnostics
        nativeRecordingGeneration =
            nativeDiagnostics?.microphoneRecordingGeneration
        nativeApprovedRecordingGeneration =
            nativeDiagnostics?.approvedMicrophoneRecordingGeneration
        nativeDeliveryCallbackCount =
            nativeDiagnostics?.microphoneDeliveryCallbackCount
        nativeDeliveredFrameCount =
            nativeDiagnostics?.microphoneDeliveredFrameCount
        #else
        nativeRecordingGeneration = nil
        nativeApprovedRecordingGeneration = nil
        nativeDeliveryCallbackCount = nil
        nativeDeliveredFrameCount = nil
        #endif

        let lastRawProcessingResultCodeRawValue: Int?
        if let result = lastIPhoneMicrophoneRawProcessingResult,
           result.negotiationEpoch == negotiationEpoch {
            lastRawProcessingResultCodeRawValue = result.codeRawValue
        } else {
            lastRawProcessingResultCodeRawValue = nil
        }

        return WebRTCIPhoneMicrophoneSenderSnapshot(
            bindingNegotiationEpoch:
                iPhoneMicrophoneSenderBinding?.negotiationEpoch,
            currentNegotiationEpoch: negotiationEpoch,
            senderOwnsLocalTrack: iPhoneMicrophoneSenderOwnsLocalTrack(
                expectedNegotiationEpoch: negotiationEpoch
            ),
            rawProcessingRequestCount:
                debugIPhoneMicrophoneRawProcessingRequestCount,
            rawProcessingWasEverRequestedWithoutCurrentSender:
                debugIPhoneMicrophoneRawProcessingWasEverRequestedWithoutCurrentSender,
            rawProcessingAppliedResultCount:
                debugIPhoneMicrophoneRawProcessingAppliedResultCount,
            rawProcessingStoredResultCount:
                debugIPhoneMicrophoneRawProcessingStoredResultCount,
            lastRawProcessingResultCodeRawValue:
                lastRawProcessingResultCodeRawValue,
            trackIsEnabled: localIPhoneMicrophoneTrack?.isEnabled == true,
            nativeRecordingGeneration: nativeRecordingGeneration,
            nativeApprovedRecordingGeneration:
                nativeApprovedRecordingGeneration,
            nativeDeliveryCallbackCount: nativeDeliveryCallbackCount,
            nativeDeliveredFrameCount: nativeDeliveredFrameCount
        )
    }

    func debugSetIPhoneMicrophoneAudioProcessingStateForTesting(
        _ state: WebRTCAudioProcessingSnapshot?
    ) {
        debugIPhoneMicrophoneAudioProcessingStateOverride = state
    }

    func debugEnableIPhoneMicrophoneTrackAfterRawProcessingForTesting(
        maximumAttempts: Int = 20,
        rawProcessingMaximumAttempts: Int? = 20
    ) async throws -> WebRTCAudioProcessingSnapshot {
        #if os(macOS)
        try ensureOpen()
        guard role == .viewer,
              let track = localIPhoneMicrophoneTrack,
              let macStereoAudioDevice else {
            throw WebRTCTransportError.invalidRole
        }

        let expectedNegotiationEpoch = negotiationEpoch
        track.isEnabled = false
        macStereoAudioDevice.revokeRecordingAdmission()
        let baseline = macStereoAudioDevice.diagnostics
        do {
            guard iPhoneMicrophoneSenderOwnsLocalTrack(
                expectedNegotiationEpoch: expectedNegotiationEpoch
            ) else {
                throw WebRTCTransportError.transportNotHealthy
            }

            // The headless custom ADM has no source producer. Activating this exact
            // sender can therefore drive Stored options into the live voice engine
            // while the native recording generation still admits zero source PCM.
            track.isEnabled = true
            try await awaitRawIPhoneMicrophoneProcessing(
                expectedNegotiationEpoch: expectedNegotiationEpoch,
                requiresHealthyTransport: false,
                maximumAttempts: rawProcessingMaximumAttempts
            )
            let recordingGeneration =
                try await awaitHeadlessMacIPhoneMicrophoneRecordingGeneration(
                    expectedNegotiationEpoch: expectedNegotiationEpoch,
                    baselineDeliveryCallbackCount:
                        baseline.deliveryCallbackCount,
                    baselineDeliveredFrameCount:
                        baseline.deliveredFrameCount,
                    maximumAttempts: maximumAttempts
                )
            guard negotiationEpoch == expectedNegotiationEpoch,
                  iPhoneMicrophoneSenderOwnsLocalTrack(
                      expectedNegotiationEpoch: expectedNegotiationEpoch
                  ),
                  track.isEnabled,
                  rawIPhoneMicrophoneProcessingIsLive() else {
                throw WebRTCTransportError.transportNotHealthy
            }

            let staged = macStereoAudioDevice.diagnostics
            guard staged.recordingGeneration == recordingGeneration,
                  staged.approvedRecordingGeneration == 0,
                  staged.deliveryCallbackCount
                    == baseline.deliveryCallbackCount,
                  staged.deliveredFrameCount
                    == baseline.deliveredFrameCount,
                  macStereoAudioDevice.approveRecordingGeneration(
                    recordingGeneration
                  ) else {
                throw WebRTCTransportError.nativeFailure(
                    "The exact headless microphone recording generation could not be approved."
                )
            }

            let approved = macStereoAudioDevice.diagnostics
            guard approved.recordingGeneration == recordingGeneration,
                  approved.approvedRecordingGeneration
                    == recordingGeneration else {
                throw WebRTCTransportError.nativeFailure(
                    "The headless microphone recording-generation approval changed."
                )
            }

            let processingState =
                debugIPhoneMicrophoneAudioProcessingStateOverride
                    ?? audioProcessingStateForTesting()
            return processingState
        } catch {
            track.isEnabled = false
            macStereoAudioDevice.revokeRecordingAdmission()
            throw error
        }
        #else
        throw WebRTCTransportError.invalidRole
        #endif
    }

    func debugDisableIPhoneMicrophoneTrackForTesting() {
        localIPhoneMicrophoneTrack?.isEnabled = false
        #if os(macOS)
        macStereoAudioDevice?.revokeRecordingAdmission()
        #endif
    }

    func debugMakeIPhoneMicrophoneSenderBindingStaleForTesting() {
        guard let binding = iPhoneMicrophoneSenderBinding else { return }
        iPhoneMicrophoneSenderBinding = WebRTCIPhoneMicrophoneSenderBinding(
            generation: binding.generation,
            negotiationEpoch: binding.negotiationEpoch &- 1,
            trackGeneration: binding.trackGeneration,
            mid: binding.mid,
            transceiver: binding.transceiver,
            senderID: binding.senderID,
            sender: binding.sender,
            localTrackID: binding.localTrackID,
            localTrack: binding.localTrack
        )
        resetIPhoneMicrophoneSenderStatisticsContinuity()
        localIPhoneMicrophoneTrack?.isEnabled = false
    }

    func debugClearIPhoneMicrophoneSenderBindingForTesting() {
        iPhoneMicrophoneSenderBinding = nil
        resetIPhoneMicrophoneSenderStatisticsContinuity()
        localIPhoneMicrophoneTrack?.isEnabled = false
    }

    var isLocalIPhoneMicrophoneTrackEnabledForTesting: Bool {
        localIPhoneMicrophoneTrack?.isEnabled == true
    }
#endif

    /// Immediately disables screen media after an application-owned authorization changes.
    /// It deliberately preserves ordered request history: a newer recovery Hide may already be
    /// queued while the host crosses actors. Native failure/restart boundaries use the stronger
    /// `failCloseScreenMedia()` reset from within this actor's event order.
    public func suspendScreenMediaForTransportUncertainty() {
        localVideoTrack?.isEnabled = false
        invalidateInputSession(reason: "Screen media authorization became uncertain.")
    }

    /// Enables host system audio only while the same actor turn can prove the native transport
    /// and ordered control lane are healthy. Audio has a separate authorization from screen
    /// visibility so Hide can disable video without interrupting background listening.
    public func enableSystemAudioIfTransportHealthy(
        authorization: WebRTCAudioAuthorization
    ) async throws {
        try ensureOpen()
        guard role == .host,
              let localAudioTrack,
              let externalAudioCapturer else {
            throw WebRTCTransportError.invalidRole
        }

        if let existingAuthorization = activeSystemAudioAuthorization,
           existingAuthorization !== authorization {
            suspendSystemAudioForTransportUncertainty()
        }
        try authorization.withValidAuthorization {}
        systemAudioAdmissionEpoch &+= 1
        let admissionEpoch = systemAudioAdmissionEpoch
        activeSystemAudioAuthorization = nil
        pendingSystemAudioAuthorization = authorization
        externalAudioCapturer.setEnabled(false)
        localAudioTrack.isEnabled = true

        do {
            guard isTransportHealthyForCapture() else {
                throw WebRTCTransportError.transportNotHealthy
            }
            try await awaitRawSystemAudioProcessing(
                admissionEpoch: admissionEpoch,
                authorization: authorization
            )
            try authorization.withValidAuthorization {
                guard systemAudioAdmissionEpoch == admissionEpoch,
                      pendingSystemAudioAuthorization === authorization,
                      isTransportHealthyForCapture(),
                      localAudioTrack.isEnabled else {
                    throw WebRTCTransportError.transportNotHealthy
                }
                guard externalAudioCapturer.approveCurrentRecordingGeneration() else {
                    throw WebRTCTransportError.nativeFailure(
                        "The current WebRTC recording generation is unavailable for admission."
                    )
                }
                // No source PCM is admitted until both the active voice engine and exact native
                // StartRecording generation have passed their fail-closed gates.
                externalAudioCapturer.setEnabled(true)
                pendingSystemAudioAuthorization = nil
                activeSystemAudioAuthorization = authorization
            }
        } catch {
            if systemAudioAdmissionEpoch == admissionEpoch {
                pendingSystemAudioAuthorization = nil
                localAudioTrack.isEnabled = false
                externalAudioCapturer.setEnabled(false)
                externalAudioCapturer.reset()
            }
            throw error
        }
    }

    /// Fail-closes system audio and drops buffered PCM at every transport/recovery uncertainty
    /// boundary. Re-enabling always requires a fresh authorization and a new health proof.
    public func suspendSystemAudioForTransportUncertainty() {
        let authorization = activeSystemAudioAuthorization
        let pendingAuthorization = pendingSystemAudioAuthorization
        systemAudioAdmissionEpoch &+= 1
        activeSystemAudioAuthorization = nil
        pendingSystemAudioAuthorization = nil
        localAudioTrack?.isEnabled = false
        externalAudioCapturer?.setEnabled(false)
        externalAudioCapturer?.reset()
        resetSentMacHostedCallObservationState()
        authorization?.revoke()
        if pendingAuthorization !== authorization {
            pendingAuthorization?.revoke()
        }
    }

    /// Sends one privacy-minimal challenge from the viewer after its local CallKit epoch rotated.
    /// Bidirectional SDP negotiation prevents this evidence kind from reaching an older host.
    public func requestMacHostedCallEvidenceIfTransportHealthy(
        challenge: WebRTCMacHostedCallChallenge
    ) throws {
        try ensureOpen()
        guard role == .viewer,
              challenge.isValid,
              macHostedCallEvidenceIsNegotiated,
              isTransportHealthyForMedia() else {
            throw WebRTCTransportError.transportNotHealthy
        }
        if let current = currentSentMacHostedCallChallenge {
            guard challenge.sequence > current.sequence
                    || challenge == current else {
                throw WebRTCTransportError.transportNotHealthy
            }
        }

        let data = try JSONEncoder().encode(
            ControlChannelMessage.macHostedCallChallenge(challenge)
        )
        try delegateProxy.sendControlData(data)
        currentSentMacHostedCallChallenge = challenge
        invalidateReceivedMacHostedCallEvidence()
    }

    /// Sends one fresh Mac-hosted FaceTime evidence heartbeat under the exact live system-audio
    /// authorization and the exact challenge sampled by the native Core Audio source.
    public func updateMacHostedCallEvidenceIfTransportHealthy(
        state: WebRTCMacHostedCallEvidence.State,
        challenge: WebRTCMacHostedCallChallenge,
        nativeObservationSequence: UInt64,
        authorization: WebRTCAudioAuthorization,
        evidenceAuthorization:
            WebRTCMacHostedCallEvidenceAuthorization
    ) throws {
        try ensureOpen()
        guard role == .host else {
            throw WebRTCTransportError.invalidRole
        }
        try WebRTCMacHostedCallEvidenceAuthorizationOrder
            .withValidAuthorizations(
                audioAuthorization: authorization,
                evidenceAuthorization: evidenceAuthorization,
                expectedCallEpochNonce: challenge.callEpochNonce
            ) {
                guard activeSystemAudioAuthorization === authorization,
                      localAudioTrack?.isEnabled == true,
                      macHostedCallEvidenceIsNegotiated,
                      challenge.isValid,
                      currentReceivedMacHostedCallChallenge == challenge,
                      isTransportHealthyForCapture(),
                      nextMacHostedCallEvidenceSequence < UInt64.max else {
                    throw WebRTCTransportError.transportNotHealthy
                }

                let bindingMatches =
                    sentMacHostedCallObservationAuthorization === authorization
                    && sentMacHostedCallObservationChallenge == challenge
                guard WebRTCMacHostedCallObservationSendPolicy.admits(
                    observationSequence: nativeObservationSequence,
                    highestSentSequence:
                        highestSentMacHostedCallObservationSequence,
                    bindingMatches: bindingMatches
                ) else {
                    throw WebRTCTransportError.transportNotHealthy
                }

                let evidence = WebRTCMacHostedCallEvidence(
                    sequence: nextMacHostedCallEvidenceSequence,
                    challengeSequence: challenge.sequence,
                    challengeNonce: challenge.nonce,
                    callEpochNonce: challenge.callEpochNonce,
                    state: state
                )
                let data = try JSONEncoder().encode(
                    ControlChannelMessage.macHostedCallEvidence(evidence)
                )
                try delegateProxy.sendControlData(data)
                sentMacHostedCallObservationAuthorization =
                    authorization
                sentMacHostedCallObservationChallenge = challenge
                highestSentMacHostedCallObservationSequence =
                    nativeObservationSequence
                nextMacHostedCallEvidenceSequence &+= 1
            }
    }

    #if os(macOS)
    /// Opens host-side playout for the exact current iPhone microphone track only after a fresh,
    /// actor-serialized native transport-health proof.
    ///
    /// This method deliberately contains no suspension point. Native fail-close callbacks and this
    /// admission therefore serialize through the peer actor without a stale application snapshot.
    public func enableRemoteIPhoneMicrophonePlaybackIfTransportHealthy(
        _ track: WebRTCRemoteAudioTrack
    ) throws {
        guard !isClosed else {
            track.setEnabled(false)
            throw WebRTCTransportError.transportClosed
        }
        guard role == .host else {
            track.setEnabled(false)
            throw WebRTCTransportError.invalidRole
        }
        guard let receiverID = iPhoneMicrophoneReceiverID,
              track.logicalLane == .iPhoneMicrophone,
              track.receiverID == receiverID,
              currentRemoteAudioTrack === track else {
            track.setEnabled(false)
            throw WebRTCTransportError.transportNotHealthy
        }
        guard isTransportHealthyForCapture() else {
            track.setEnabled(false)
            throw WebRTCTransportError.transportNotHealthy
        }
        track.setEnabled(true)
    }
    #endif

    #if os(iOS)
    /// Installs the synchronous MainActor acknowledgement used by recoverable peer uncertainty.
    /// The handler must cancel stale category ownership and arm playback/default before returning.
    public func installIPhoneMicrophoneTransportSuspensionHandler(
        _ handler: @escaping @Sendable @MainActor (
            WebRTCIOSMicrophoneRetirementContext
        ) async -> WebRTCIOSOutputOnlyMicrophoneToken?
    ) {
        guard role == .viewer else { return }
        iPhoneMicrophoneTransportSuspensionHandler = handler
    }

    /// Opens the current viewer microphone only while the exact authorization and
    /// transport generation remain healthy.
    public func enableIPhoneMicrophone(
        authorization: WebRTCIOSMicrophoneAuthorization
    ) async throws {
        try await enableIPhoneMicrophone(
            authorization: authorization,
            requiresHealthyTransport: true,
            requiresRawNegotiatedSenderProof: true
        )
    }

    private func enableIPhoneMicrophone(
        authorization: WebRTCIOSMicrophoneAuthorization,
        requiresHealthyTransport: Bool,
        requiresRawNegotiatedSenderProof: Bool
    ) async throws {
        try ensureOpen()
        guard role == .viewer,
              let track = localIPhoneMicrophoneTrack,
              let device = iOSStereoPlayoutAudioDevice,
              authorization.isValid else {
            throw WebRTCTransportError.audioAuthorizationRevoked
        }
        guard !requiresHealthyTransport || isTransportHealthyForMedia() else {
            throw WebRTCTransportError.transportNotHealthy
        }

        guard requiresRawNegotiatedSenderProof else {
            #if DEBUG
            try enableIPhoneMicrophoneWithoutRawNegotiatedSenderProofForTesting(
                authorization: authorization,
                requiresHealthyTransport: requiresHealthyTransport
            )
            return
            #else
            throw WebRTCTransportError.nativeFailure(
                "Release microphone admission cannot bypass negotiated raw-processing proof."
            )
            #endif
        }

        let previousAuthorization = activeIPhoneMicrophoneAuthorization
        let previousAuthorizationIdentity = previousAuthorization.map {
            ObjectIdentifier($0)
        }
        let authorizationIdentity = ObjectIdentifier(authorization)
        let policyGeneration = advanceIPhoneMicrophonePolicyGeneration()
        track.isEnabled = false
        activeIPhoneMicrophoneAuthorization = nil
        iPhoneMicrophoneNativeRecordingGeneration = 0
        iPhoneMicrophoneNativeTeardownPending = true
        iPhoneMicrophoneNativeTeardownAuthorizationIdentity =
            authorizationIdentity

        do {
            let stageResult =
                performIPhoneMicrophoneStageAttempt(
                    authorization,
                    origin: .publicRequest,
                    retiredAuthorizationIdentity:
                        previousAuthorizationIdentity
                )
            if previousAuthorization !== authorization {
                previousAuthorization?.revoke()
            }

            let recordingGeneration =
                stageResult.recordingGeneration
            guard recordingGeneration != 0 else {
                let description =
                    WebRTCIOSMicrophoneAdmissionDiagnostics
                        .failureDescription(
                            iPhoneMicrophoneAdmissionFailureDiagnostics()
                        )
                guard let reason = stageResult.failureReason else {
                    throw WebRTCTransportError.nativeFailure(
                        description
                    )
                }
                throw WebRTCTransportError
                    .iPhoneMicrophoneStageFailed(
                        reason: reason,
                        message: description
                    )
            }

            activeIPhoneMicrophoneAuthorization = authorization
            iPhoneMicrophoneNativeRecordingGeneration =
                recordingGeneration

            let stagedDiagnostics = device.diagnostics
            guard iPhoneMicrophoneNativeStageIsCurrent(
                authorization: authorization,
                recordingGeneration: recordingGeneration,
                baselineRealtimeAdmissionCount:
                    stagedDiagnostics.microphoneRealtimeAdmissionCount,
                baselineDeliveryCallbackCount:
                    stagedDiagnostics.microphoneDeliveryCallbackCount,
                baselineDeliveredFrameCount:
                    stagedDiagnostics.microphoneDeliveredFrameCount
            ) else {
                throw WebRTCTransportError.nativeFailure(
                    "The iPhone microphone topology was not staged with PCM publication closed."
                )
            }

            let admissionNegotiationEpoch = negotiationEpoch
            guard iPhoneMicrophoneSenderOwnsLocalTrack(
                expectedNegotiationEpoch: admissionNegotiationEpoch
            ) else {
                throw WebRTCTransportError.transportNotHealthy
            }

            // The physical input topology is now final, but both native
            // publication gates remain closed. Only the exact sender is made
            // active so its Stored request can reach the live voice engine.
            track.isEnabled = true
            try await awaitRawIPhoneMicrophoneProcessing(
                expectedNegotiationEpoch: admissionNegotiationEpoch,
                requiresHealthyTransport: requiresHealthyTransport
            )

            guard authorization.isValid else {
                throw WebRTCTransportError.audioAuthorizationRevoked
            }
            guard iPhoneMicrophonePolicyGeneration == policyGeneration,
                  activeIPhoneMicrophoneAuthorization === authorization,
                  iPhoneMicrophoneNativeRecordingGeneration
                    == recordingGeneration,
                  !requiresHealthyTransport || isTransportHealthyForMedia(),
                  negotiationEpoch == admissionNegotiationEpoch,
                  iPhoneMicrophoneSenderOwnsLocalTrack(
                    expectedNegotiationEpoch: admissionNegotiationEpoch
                  ),
                  track.isEnabled else {
                throw WebRTCTransportError.transportNotHealthy
            }

            guard iPhoneMicrophoneNativeStageIsCurrent(
                authorization: authorization,
                recordingGeneration: recordingGeneration,
                baselineRealtimeAdmissionCount:
                    stagedDiagnostics.microphoneRealtimeAdmissionCount,
                baselineDeliveryCallbackCount:
                    stagedDiagnostics.microphoneDeliveryCallbackCount,
                baselineDeliveredFrameCount:
                    stagedDiagnostics.microphoneDeliveredFrameCount
            ) else {
                throw WebRTCTransportError.nativeFailure(
                    "The staged iPhone microphone generation changed before raw-processing proof."
                )
            }

            guard rawIPhoneMicrophoneProcessingIsLive() else {
                throw WebRTCTransportError.nativeFailure(
                    "WebRTC call-oriented processing became active before microphone admission: "
                        + rawIPhoneMicrophoneProcessingDiagnostic()
                )
            }

            guard device.approveStagedMicrophoneAuthorization(
                authorization.native,
                recordingGeneration: recordingGeneration
            ) else {
                throw WebRTCTransportError.nativeFailure(
                    "The exact staged iPhone microphone generation could not be approved."
                )
            }

            guard iPhoneMicrophonePolicyGeneration == policyGeneration,
                  activeIPhoneMicrophoneAuthorization === authorization,
                  authorization.isValid,
                  negotiationEpoch == admissionNegotiationEpoch,
                  iPhoneMicrophoneSenderOwnsLocalTrack(
                    expectedNegotiationEpoch: admissionNegotiationEpoch
                  ),
                  !requiresHealthyTransport || isTransportHealthyForMedia(),
                  rawIPhoneMicrophoneProcessingIsLive(),
                  iPhoneMicrophoneNativeApprovalIsCurrent(
                    authorization: authorization,
                    recordingGeneration: recordingGeneration
                  ) else {
                throw WebRTCTransportError.transportNotHealthy
            }

            iPhoneMicrophoneNativeTeardownPending = false
            iPhoneMicrophoneNativeTeardownAuthorizationIdentity = nil
        } catch {
            rollbackFailedIPhoneMicrophoneAdmission(
                authorization: authorization,
                authorizationIdentity: authorizationIdentity,
                policyGeneration: policyGeneration
            )
            throw error
        }
    }

    #if DEBUG
    private func enableIPhoneMicrophoneWithoutRawNegotiatedSenderProofForTesting(
        authorization: WebRTCIOSMicrophoneAuthorization,
        requiresHealthyTransport: Bool
    ) throws {
        guard let track = localIPhoneMicrophoneTrack else {
            throw WebRTCTransportError.invalidRole
        }

        let previousAuthorization = activeIPhoneMicrophoneAuthorization
        let previousAuthorizationIdentity = previousAuthorization.map {
            ObjectIdentifier($0)
        }
        let authorizationIdentity = ObjectIdentifier(authorization)
        let policyGeneration = advanceIPhoneMicrophonePolicyGeneration()

        track.isEnabled = false
        activeIPhoneMicrophoneAuthorization = nil
        iPhoneMicrophoneNativeRecordingGeneration = 0
        iPhoneMicrophoneNativeTeardownPending = true
        iPhoneMicrophoneNativeTeardownAuthorizationIdentity =
            authorizationIdentity

        let applied = performIPhoneMicrophonePolicyAttempt(
            authorization,
            kind: .enable,
            origin: .publicRequest,
            retirementID: nil,
            retiredAuthorizationIdentity:
                previousAuthorizationIdentity,
            tokenID: nil
        )
        if previousAuthorization !== authorization {
            previousAuthorization?.revoke()
        }

        guard applied else {
            rollbackFailedIPhoneMicrophoneAdmission(
                authorization: authorization,
                authorizationIdentity: authorizationIdentity,
                policyGeneration: policyGeneration
            )
            throw WebRTCTransportError.nativeFailure(
                "The DEBUG microphone policy seam rejected the enable operation."
            )
        }

        activeIPhoneMicrophoneAuthorization = authorization
        iPhoneMicrophoneNativeRecordingGeneration =
            authorization.recordingGeneration
        guard authorization.isValid,
              iPhoneMicrophonePolicyGeneration == policyGeneration,
              activeIPhoneMicrophoneAuthorization === authorization,
              !requiresHealthyTransport || isTransportHealthyForMedia() else {
            rollbackFailedIPhoneMicrophoneAdmission(
                authorization: authorization,
                authorizationIdentity: authorizationIdentity,
                policyGeneration: policyGeneration
            )
            throw WebRTCTransportError.transportNotHealthy
        }

        iPhoneMicrophoneNativeTeardownPending = false
        iPhoneMicrophoneNativeTeardownAuthorizationIdentity = nil
        track.isEnabled = true
    }
    #endif

    private func rollbackFailedIPhoneMicrophoneAdmission(
        authorization: WebRTCIOSMicrophoneAuthorization,
        authorizationIdentity: ObjectIdentifier,
        policyGeneration: UInt64
    ) {
        guard iPhoneMicrophonePolicyGeneration == policyGeneration,
              iPhoneMicrophoneNativeTeardownAuthorizationIdentity
                == authorizationIdentity,
              activeIPhoneMicrophoneAuthorization == nil
                || activeIPhoneMicrophoneAuthorization === authorization else {
            return
        }

        localIPhoneMicrophoneTrack?.isEnabled = false
        activeIPhoneMicrophoneAuthorization = nil
        iPhoneMicrophoneNativeRecordingGeneration = 0
        authorization.revoke()
        iPhoneMicrophoneNativeTeardownPending = true

        // Failed admission may close only peer-owned publication gates. Restoring the native
        // output-only policy remains pending until an application-owned token is consumed.
        iPhoneMicrophoneNativeTeardownAuthorizationIdentity =
            authorizationIdentity
    }

    /// A stale disable may revoke its own authorization, but cannot close a newer
    /// microphone generation installed on this peer.
    @discardableResult
    public func disableIPhoneMicrophone(
        authorization: WebRTCIOSMicrophoneAuthorization? = nil,
        outputOnlyToken: WebRTCIOSOutputOnlyMicrophoneToken? = nil
    ) -> Bool {
        guard role == .viewer else {
            authorization?.revoke()
            return false
        }
        if let authorization,
           let activeIPhoneMicrophoneAuthorization,
           activeIPhoneMicrophoneAuthorization !== authorization {
            authorization.revoke()
            return false
        }

        let requestedAuthorizationIdentity = authorization.map {
            ObjectIdentifier($0)
        }
        let activeAuthorization = activeIPhoneMicrophoneAuthorization
        let retirementContext = matchingIPhoneMicrophoneRetirementContext(
            requestedAuthorizationIdentity: requestedAuthorizationIdentity,
            activeAuthorization: activeAuthorization
        )

        if activeAuthorization == nil, let authorization {
            let identity = ObjectIdentifier(authorization)
            let matchesPendingTeardown =
                iPhoneMicrophoneNativeTeardownPending
                    && iPhoneMicrophoneNativeTeardownAuthorizationIdentity
                        == identity
            let matchesRetirement =
                retirementContext?.retiringAuthorizationIdentity == identity
            let matchesCompletedOutputOnly =
                iPhoneMicrophoneOutputOnlyWasAlreadyReached(
                    requestedAuthorizationIdentity: identity
                )
            guard matchesPendingTeardown
                    || matchesRetirement
                    || matchesCompletedOutputOnly else {
                authorization.revoke()
                return false
            }
        }

        if iPhoneMicrophoneOutputOnlyWasAlreadyReached(
            requestedAuthorizationIdentity: requestedAuthorizationIdentity
        ) {
            authorization?.revoke()
            return true
        }

        guard let outputOnlyToken else {
            authorization?.revoke()
            return false
        }

        let retiring = activeIPhoneMicrophoneAuthorization ?? authorization
        let retiringAuthorizationIdentity =
            retirementContext?.retiringAuthorizationIdentity
                ?? retiring.map { ObjectIdentifier($0) }
                ?? iPhoneMicrophoneNativeTeardownAuthorizationIdentity

        return performIPhoneMicrophoneOutputOnlyDisable(
            retiringAuthorization: retiring,
            retiringAuthorizationIdentity: retiringAuthorizationIdentity,
            token: outputOnlyToken,
            origin: .publicRequest,
            retirementContext: retirementContext
        )
    }

    @discardableResult
    private func advanceIPhoneMicrophonePolicyGeneration() -> UInt64 {
        resetIPhoneMicrophoneSenderStatisticsContinuity()
        iPhoneMicrophonePolicyGeneration &+= 1
        if iPhoneMicrophonePolicyGeneration == 0 {
            iPhoneMicrophonePolicyGeneration = 1
        }
        return iPhoneMicrophonePolicyGeneration
    }

    @discardableResult
    private func advanceIPhoneMicrophonePolicySequence() -> UInt64 {
        iPhoneMicrophonePolicySequence &+= 1
        if iPhoneMicrophonePolicySequence == 0 {
            iPhoneMicrophonePolicySequence = 1
        }
        return iPhoneMicrophonePolicySequence
    }

    private func matchingIPhoneMicrophoneRetirementContext(
        requestedAuthorizationIdentity: ObjectIdentifier?,
        activeAuthorization: WebRTCIOSMicrophoneAuthorization?
    ) -> WebRTCIOSMicrophoneRetirementContext? {
        guard activeAuthorization == nil,
              let iPhoneMicrophoneRetirementContext else {
            return nil
        }
        if let requestedAuthorizationIdentity {
            return iPhoneMicrophoneRetirementContext
                .retiringAuthorizationIdentity == requestedAuthorizationIdentity
                ? iPhoneMicrophoneRetirementContext
                : nil
        }
        guard iPhoneMicrophoneNativeTeardownPending else { return nil }
        return iPhoneMicrophoneRetirementContext
    }

    private func iPhoneMicrophoneOutputOnlyWasAlreadyReached(
        requestedAuthorizationIdentity: ObjectIdentifier?
    ) -> Bool {
        guard activeIPhoneMicrophoneAuthorization == nil,
              localIPhoneMicrophoneTrack?.isEnabled != true,
              !iPhoneMicrophoneNativeTeardownPending,
              let latestIPhoneMicrophonePolicyCompletionStamp,
              latestIPhoneMicrophonePolicyCompletionStamp.kind
                == .outputOnlyDisable,
              latestIPhoneMicrophonePolicyCompletionStamp.nativeResult else {
            return false
        }
        if let requestedAuthorizationIdentity {
            return latestIPhoneMicrophonePolicyCompletionStamp
                .retiredAuthorizationIdentity
                == requestedAuthorizationIdentity
        }
        return true
    }

    private func performIPhoneMicrophoneOutputOnlyDisable(
        retiringAuthorization: WebRTCIOSMicrophoneAuthorization?,
        retiringAuthorizationIdentity: ObjectIdentifier?,
        token: WebRTCIOSOutputOnlyMicrophoneToken,
        origin: WebRTCIOSMicrophonePolicyAttemptOrigin,
        retirementContext: WebRTCIOSMicrophoneRetirementContext?
    ) -> Bool {
        if let retirementContext {
            let selectedToken = retirementContext.selectToken(token)
            guard selectedToken === token else { return false }
        }

        var didClaimNativeWrite = false
        let nativeResult = token.performOnce {
            if let retirementContext,
               !retirementContext.recordExecutingToken(token) {
                return false
            }

            if let currentAuthorization =
                activeIPhoneMicrophoneAuthorization {
                guard let retiringAuthorization,
                      currentAuthorization === retiringAuthorization else {
                    return false
                }
            }

            didClaimNativeWrite = true
            _ = advanceIPhoneMicrophonePolicyGeneration()
            retiringAuthorization?.revoke()
            activeIPhoneMicrophoneAuthorization = nil
            localIPhoneMicrophoneTrack?.isEnabled = false
            iPhoneMicrophoneNativeRecordingGeneration = 0
            iPhoneMicrophoneNativeTeardownPending = true
            iPhoneMicrophoneNativeTeardownAuthorizationIdentity =
                retiringAuthorizationIdentity

            let applied = performIPhoneMicrophonePolicyAttempt(
                nil,
                kind: .outputOnlyDisable,
                origin: origin,
                retirementID: retirementContext?.retirementID,
                retiredAuthorizationIdentity:
                    retiringAuthorizationIdentity,
                tokenID: token.tokenID
            )
            iPhoneMicrophoneNativeTeardownPending = !applied
            iPhoneMicrophoneNativeTeardownAuthorizationIdentity =
                applied ? nil : retiringAuthorizationIdentity
            return applied
        }
        return didClaimNativeWrite && nativeResult
    }

    private func performIPhoneMicrophoneStageAttempt(
        _ authorization: WebRTCIOSMicrophoneAuthorization,
        origin: WebRTCIOSMicrophonePolicyAttemptOrigin,
        retiredAuthorizationIdentity: ObjectIdentifier?
    ) -> WebRTCIOSMicrophoneNativeStageResult {
        let sequence = advanceIPhoneMicrophonePolicySequence()
        let result =
            stageNativeIPhoneMicrophonePolicy(authorization)
        latestIPhoneMicrophonePolicyCompletionStamp =
            WebRTCIOSMicrophonePolicyCompletionStamp(
                sequence: sequence,
                kind: .enable,
                origin: origin,
                retirementID: nil,
                retiredAuthorizationIdentity:
                    retiredAuthorizationIdentity,
                tokenID: nil,
                nativeResult: result.recordingGeneration != 0
            )
        return result
    }

    private func performIPhoneMicrophonePolicyAttempt(
        _ authorization: WebRTCIOSMicrophoneAuthorization?,
        kind: WebRTCIOSMicrophonePolicyAttemptKind,
        origin: WebRTCIOSMicrophonePolicyAttemptOrigin,
        retirementID: UUID?,
        retiredAuthorizationIdentity: ObjectIdentifier?,
        tokenID: UUID?
    ) -> Bool {
        let sequence = advanceIPhoneMicrophonePolicySequence()
        let nativeResult = applyNativeIPhoneMicrophonePolicy(authorization)
        latestIPhoneMicrophonePolicyCompletionStamp =
            WebRTCIOSMicrophonePolicyCompletionStamp(
                sequence: sequence,
                kind: kind,
                origin: origin,
                retirementID: retirementID,
                retiredAuthorizationIdentity:
                    retiredAuthorizationIdentity,
                tokenID: tokenID,
                nativeResult: nativeResult
            )
        return nativeResult
    }

    private func stageNativeIPhoneMicrophonePolicy(
        _ authorization: WebRTCIOSMicrophoneAuthorization
    ) -> WebRTCIOSMicrophoneNativeStageResult {
        #if DEBUG
        if debugIPhoneMicrophoneStageFailureDiagnostics != nil {
            authorization.revoke()
            return WebRTCIOSMicrophoneNativeStageResult(
                recordingGeneration: 0,
                failureReason:
                    debugIPhoneMicrophoneStageFailureReason
            )
        }
        #endif
        guard let device = iOSStereoPlayoutAudioDevice else {
            authorization.revoke()
            return WebRTCIOSMicrophoneNativeStageResult(
                recordingGeneration: 0,
                failureReason: .deviceUnavailable
            )
        }
        let recordingGeneration =
            device.stageMicrophoneAuthorization(authorization.native)
        return WebRTCIOSMicrophoneNativeStageResult(
            recordingGeneration: recordingGeneration,
            failureReason: recordingGeneration == 0
                ? WebRTCIOSMicrophoneStageFailureReason(
                    native:
                        authorization.native
                            .microphoneStageFailureReason
                )
                : nil
        )
    }

    private func iPhoneMicrophoneAdmissionFailureDiagnostics()
        -> WebRTCIOSPlayoutDiagnostics?
    {
        #if DEBUG
        if let diagnostics = debugIPhoneMicrophoneStageFailureDiagnostics {
            debugIPhoneMicrophoneStageFailureDiagnostics = nil
            debugIPhoneMicrophoneStageFailureReason = nil
            return diagnostics
        }
        #endif
        return iOSPlayoutDiagnostics()
    }

    private func applyNativeIPhoneMicrophonePolicy(
        _ authorization: WebRTCIOSMicrophoneAuthorization?
    ) -> Bool {
        #if DEBUG
        if let debugIPhoneMicrophonePolicyApplier {
            return debugIPhoneMicrophonePolicyApplier(authorization != nil)
        }
        #endif
        guard let device = iOSStereoPlayoutAudioDevice else {
            authorization?.revoke()
            return false
        }
        return device.setMicrophoneAuthorization(authorization?.native)
    }
    #endif

    public func remoteAudioTrack() -> WebRTCRemoteAudioTrack? {
        currentRemoteAudioTrack
    }

    public func remoteVideoTrack() -> WebRTCRemoteVideoTrack? {
        currentRemoteVideoTrack
    }

    #if os(iOS)
    public func iOSPlayoutDiagnostics() -> WebRTCIOSPlayoutDiagnostics? {
        guard let device = iOSStereoPlayoutAudioDevice else { return nil }
        let value = device.diagnostics
        return WebRTCIOSPlayoutDiagnostics(
            initialized: value.initialized,
            playoutInitialized: value.playoutInitialized,
            playing: value.playing,
            sessionActive: value.sessionActive,
            ownsSessionActivation: value.ownsSessionActivation,
            remoteIOCreated: value.remoteIOCreated,
            inputBusEnabled: value.inputBusEnabled,
            captureRouteIsBuiltInMicrophone:
                value.captureRouteIsBuiltInMicrophone,
            captureRouteProofGeneration:
                value.captureRouteProofGeneration,
            outputBusEnabled: value.outputBusEnabled,
            recoveryRequired: value.recoveryRequired,
            explicitResumeRequired: value.explicitResumeRequired,
            categoryIsMediaPlayback: value.categoryIsMediaPlayback,
            categoryIsMediaPlayAndRecord: value.categoryIsMediaPlayAndRecord,
            modeIsDefault: value.modeIsDefault,
            categoryOptionsAreEmpty: value.categoryOptionsAreEmpty,
            categoryOptionsAreIPhoneMicrophoneRouting:
                value.categoryOptionsAreIPhoneMicrophoneRouting,
            categoryOptionsAreMixWithOthers:
                value.categoryOptionsAreMixWithOthers,
            routeSharingPolicyIsDefault: value.routeSharingPolicyIsDefault,
            hasOutputRoute: value.hasOutputRoute,
            hostedCallMode: value.hostedCallMode,
            hostedCallAuthorizationValid:
                value.hostedCallAuthorizationValid,
            hostedCallRecoveryPending:
                value.hostedCallRecoveryPending,
            hostedCallOrigin:
                WebRTCIOSHostedCallPlayoutOrigin(
                    native: value.hostedCallOrigin
                ),
            systemAudioGeneration: value.systemAudioGeneration,
            hostedCallAuthorizationGeneration:
                value.hostedCallAuthorizationGeneration,
            sampleRate: value.sampleRate,
            outputIOBufferDuration: value.outputIOBufferDuration,
            outputChannelCount: value.outputChannelCount,
            audioUnitSubType: value.audioUnitSubType,
            failureCode: value.failureCode.rawValue,
            lastLifecycleStatus: value.lastLifecycleStatus,
            failureMessage: device.lastLifecycleFailureMessage,
            playoutCallbackCount: value.playoutCallbackCount,
            playoutFrameCount: value.playoutFrameCount,
            playoutFailureCount: value.playoutFailureCount,
            playoutPCMSampleCount: value.playoutPCMSampleCount,
            playoutPCMNonzeroSampleCount: value.playoutPCMNonzeroSampleCount,
            playoutPCMAbsoluteSampleSum: value.playoutPCMAbsoluteSampleSum,
            playoutPCMLeftAbsoluteSampleSum: value.playoutPCMLeftAbsoluteSampleSum,
            playoutPCMRightAbsoluteSampleSum: value.playoutPCMRightAbsoluteSampleSum,
            playoutPCMStereoDifferenceAbsoluteSampleSum:
                value.playoutPCMStereoDifferenceAbsoluteSampleSum,
            playoutPCMClippedSampleCount: value.playoutPCMClippedSampleCount,
            playoutExplicitSilenceCallbackCount:
                value.playoutExplicitSilenceCallbackCount,
            unexpectedRecordingRequestCount: value.unexpectedRecordingRequestCount,
            recoveryRequestCount: value.recoveryRequestCount,
            recoveryAuthorizationRejectionCount:
                value.recoveryAuthorizationRejectionCount,
            recoveryRebuildCount: value.recoveryRebuildCount,
            lastPlayoutFrameCount: value.lastPlayoutFrameCount,
            lastPlayoutPeakMagnitude: value.lastPlayoutPeakMagnitude,
            lastPlayoutStatus: value.lastPlayoutStatus,
            playoutCallbackGapViolationCount:
                value.playoutCallbackGapViolationCount,
            playoutMaximumCallbackGapNanoseconds:
                value.playoutMaximumCallbackGapNanoseconds,
            playoutNearSilenceCallbackCount:
                value.playoutNearSilenceCallbackCount,
            playoutCurrentConsecutiveNearSilenceFrameCount:
                value.playoutCurrentConsecutiveNearSilenceFrameCount,
            playoutMaximumConsecutiveNearSilenceFrameCount:
                value.playoutMaximumConsecutiveNearSilenceFrameCount,
            playoutPCMLeftZeroCrossingCount:
                value.playoutPCMLeftZeroCrossingCount,
            playoutPCMRightZeroCrossingCount:
                value.playoutPCMRightZeroCrossingCount,
            playoutPCMEnvelopeTransitionCount:
                value.playoutPCMEnvelopeTransitionCount,
            playoutPCMShapeAnomalyCallbackCount:
                value.playoutPCMShapeAnomalyCallbackCount,
            playoutPCMBoundaryDiscontinuityCallbackCount:
                value.playoutPCMBoundaryDiscontinuityCallbackCount,
            playoutLastCallbackMeanMagnitude:
                value.playoutLastCallbackMeanMagnitude
        )
    }

    public func requestIOSPlayoutRecovery(
        authorization: WebRTCIOSPlayoutRecoveryAuthorization
    ) {
        guard !isClosed, authorization.isValid else { return }
        iOSStereoPlayoutAudioDevice?.requestPlayoutRecovery(
            authorization: authorization.native
        )
    }

    public func requestIOSHostedCallPlayoutRecovery(
        authorization: WebRTCIOSHostedCallPlayoutAuthorization
    ) {
        guard !isClosed,
              authorization.origin == .interruption,
              authorization.isValid,
              authorization.isRecoveryPending else { return }
        iOSStereoPlayoutAudioDevice?.requestHostedCallPlayoutRecovery(
            authorization: authorization.native
        )
    }

    public func armIOSStartupConnectedCallPlayout(
        authorization: WebRTCIOSHostedCallPlayoutAuthorization
    ) -> Bool {
        guard !isClosed,
              authorization.origin == .startupConnectedCall,
              authorization.isValid else {
            return false
        }
        return iOSStereoPlayoutAudioDevice?
            .armStartupConnectedCallPlayout(
                authorization: authorization.native
            ) ?? false
    }
    #endif

    /// A fresh native snapshot used in addition to application-owned recovery gates before the
    /// host enables capture. It is deliberately not the ICE-restart success oracle: libwebrtc can
    /// keep these states connected while a restart is being negotiated.
    public func isTransportHealthyForCapture() -> Bool {
        role == .host && isTransportHealthyForMedia()
    }

    private func isTransportHealthyForMedia() -> Bool {
        guard hasStarted,
              !isClosed,
              localDescriptionIsAnnounced,
              remoteDescriptionIsSet,
              outstandingLocalOfferEpoch == nil,
              applyingRemoteAnswerEpoch == nil,
              applyingRemoteOfferEpoch == nil,
              peerConnection.signalingState == .stable,
              peerConnection.connectionState == .connected,
              delegateProxy.isControlChannelOpen() else {
            return false
        }
        return peerConnection.iceConnectionState == .connected
            || peerConnection.iceConnectionState == .completed
    }

    /// Collects and privacy-reduces one native WebRTC statistics report.
    public func statisticsSnapshot() async -> WebRTCStatisticsSnapshot {
        await collectStatistics(publishEvent: false)
    }

    private func collectStatistics(
        publishEvent: Bool
    ) async -> WebRTCStatisticsSnapshot {
        let nativeSnapshot = await withCheckedContinuation {
            (continuation: CheckedContinuation<WebRTCStatisticsSnapshot, Never>) in
            let resolver = WebRTCOneShotContinuation(continuation)
            peerConnection.statistics { report in
                resolver.resolve(WebRTCStatisticsParser.parse(report))
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(1))
                resolver.resolve(WebRTCStatisticsSnapshot())
            }
        }

        // The host has more than one audio transceiver. Never let the whole-peer parser's
        // array-order selection become microphone-health evidence: replace it with a report
        // requested from, and revalidated against, the exact dedicated native receiver.
        let receiverReport: (
            capture: WebRTCIPhoneMicrophoneReceiverStatisticsCapture,
            parsed: WebRTCIPhoneMicrophoneInboundStatistics?
        )?
        if role == .host,
           let capture =
            currentIPhoneMicrophoneReceiverStatisticsCapture() {
            let parsed = await withCheckedContinuation {
                (
                    continuation:
                        CheckedContinuation<
                            WebRTCIPhoneMicrophoneInboundStatistics?,
                            Never
                        >
                ) in
                let resolver = WebRTCOneShotContinuation(continuation)
                peerConnection.statistics(for: capture.receiver) { report in
                    resolver.resolve(
                        WebRTCStatisticsParser
                            .parseIPhoneMicrophoneReceiver(
                                report,
                                expectedTrackID:
                                    capture.validation.remoteTrackID,
                                expectedMID: capture.validation.mid
                            )
                    )
                }
                Task.detached {
                    try? await Task.sleep(for: .seconds(1))
                    resolver.resolve(nil)
                }
            }
            receiverReport = (capture, parsed)
        } else {
            receiverReport = nil
        }

        let inboundAudio: WebRTCAudioStatistics?
        if role != .host {
            inboundAudio = nativeSnapshot.inboundAudio
        } else if let receiverReport,
                  let current =
                    currentIPhoneMicrophoneReceiverStatisticsCapture() {
            let captured = receiverReport.capture
            let nativeOwnershipIsCurrent =
                captured.remoteTrack === current.remoteTrack
                && WebRTCNativeWrapperIdentity.isSemanticallyEqual(
                    captured.transceiver,
                    current.transceiver
                )
                && WebRTCNativeWrapperIdentity.isSemanticallyEqual(
                    captured.receiver,
                    current.receiver
                )
                && WebRTCNativeWrapperIdentity.isSemanticallyEqual(
                    captured.receiverTrack,
                    current.receiverTrack
                )
            inboundAudio =
                WebRTCIPhoneMicrophoneReceiverStatisticsSampler
                    .evaluate(
                        parsed: receiverReport.parsed,
                        captured: captured.validation,
                        current: current.validation,
                        nativeOwnershipIsCurrent:
                            nativeOwnershipIsCurrent
                    )
        } else {
            inboundAudio = nil
        }

        let snapshot: WebRTCStatisticsSnapshot
        if nativeSnapshot.route != nil || currentRoute == nil {
            snapshot = replacingInboundAudio(
                in: nativeSnapshot,
                with: inboundAudio
            )
        } else {
            snapshot = WebRTCStatisticsSnapshot(
                collectedAt: nativeSnapshot.collectedAt,
                route: currentRoute,
                currentRoundTripTime: nativeSnapshot.currentRoundTripTime,
                availableOutgoingBitrate: nativeSnapshot.availableOutgoingBitrate,
                jitter: nativeSnapshot.jitter,
                outboundVideo: nativeSnapshot.outboundVideo,
                inboundVideo: nativeSnapshot.inboundVideo,
                audioSource: nativeSnapshot.audioSource,
                outboundAudio: nativeSnapshot.outboundAudio,
                inboundAudio: inboundAudio,
                remoteInboundAudio: nativeSnapshot.remoteInboundAudio
            )
        }
        if publishEvent, !isClosed {
            // No suspension is permitted between exact-receiver revalidation and this yield.
            publishStatistics(snapshot)
        }
        return snapshot
    }

    private func replacingInboundAudio(
        in snapshot: WebRTCStatisticsSnapshot,
        with inboundAudio: WebRTCAudioStatistics?
    ) -> WebRTCStatisticsSnapshot {
        WebRTCStatisticsSnapshot(
            collectedAt: snapshot.collectedAt,
            route: snapshot.route,
            currentRoundTripTime: snapshot.currentRoundTripTime,
            availableOutgoingBitrate: snapshot.availableOutgoingBitrate,
            jitter: snapshot.jitter,
            outboundVideo: snapshot.outboundVideo,
            inboundVideo: snapshot.inboundVideo,
            audioSource: snapshot.audioSource,
            outboundAudio: snapshot.outboundAudio,
            inboundAudio: inboundAudio,
            remoteInboundAudio: snapshot.remoteInboundAudio
        )
    }

    private func currentIPhoneMicrophoneReceiverStatisticsCapture()
        -> WebRTCIPhoneMicrophoneReceiverStatisticsCapture? {
        guard !isClosed,
              role == .host,
              let expectedReceiverID = iPhoneMicrophoneReceiverID,
              !expectedReceiverID.isEmpty,
              let remoteTrack = currentRemoteAudioTrack,
              remoteTrack.logicalLane == .iPhoneMicrophone,
              remoteTrack.receiverID == expectedReceiverID,
              !remoteTrack.nativeTrackID.isEmpty else {
            return nil
        }

        let matches = peerConnection.transceivers.filter { transceiver in
            transceiver.mediaType == .audio
                && (transceiver.receiver.receiverId as String)
                    == expectedReceiverID
        }
        guard matches.count == 1,
              let transceiver = matches.first,
              !transceiver.isStopped,
              WebRTCIPhoneMicrophoneTransceiverAdmission
                .directionIncludesReceiving(transceiver.direction),
              let currentDirection =
                Self.iPhoneMicrophoneCurrentDirection(transceiver),
              WebRTCIPhoneMicrophoneTransceiverAdmission
                .directionIncludesReceiving(currentDirection),
              let mid = transceiver.mid as String?,
              !mid.isEmpty else {
            return nil
        }

        let receiver = transceiver.receiver
        let receiverID = receiver.receiverId as String
        guard receiverID == expectedReceiverID,
              let receiverTrack = receiver.track as? LKRTCAudioTrack,
              (receiverTrack.trackId as String)
                == remoteTrack.nativeTrackID else {
            return nil
        }

        return WebRTCIPhoneMicrophoneReceiverStatisticsCapture(
            transceiver: transceiver,
            receiver: receiver,
            receiverTrack: receiverTrack,
            remoteTrack: remoteTrack,
            validation:
                WebRTCIPhoneMicrophoneReceiverStatisticsValidation(
                    peerEpoch: iPhoneMicrophonePeerEpoch,
                    negotiationEpoch: negotiationEpoch,
                    receiverID: receiverID,
                    remoteTrackID: remoteTrack.nativeTrackID,
                    mid: mid
                )
        )
    }

    #if os(iOS)
    /// Current release-safe state for the exact negotiated iPhone microphone sender.
    public func iPhoneMicrophoneSenderState()
        -> WebRTCIPhoneMicrophoneSenderDiagnostics? {
        guard role == .viewer,
              let binding = iPhoneMicrophoneSenderBinding,
              let device = iOSStereoPlayoutAudioDevice else {
            return nil
        }
        let transceiver =
            currentIPhoneMicrophoneSenderTransceiver(for: binding)
        return makeIPhoneMicrophoneSenderDiagnostics(
            binding: binding,
            transceiver: transceiver,
            native: device.diagnostics
        )
    }

    /// Requests sender-specific native statistics for the exact captured microphone sender, then
    /// rejects the result unless every peer, binding, sender, track, policy, authorization, and
    /// native recording generation remains current after the asynchronous callback.
    public func iPhoneMicrophoneSenderStatistics()
        async -> WebRTCIPhoneMicrophoneSenderStatistics? {
        guard let captured =
            currentIPhoneMicrophoneSenderStatisticsCapture() else {
            return nil
        }

        let reportCapture: WebRTCIPhoneMicrophoneSenderStatisticsReportCapture? =
            await withCheckedContinuation { continuation in
                let resolver = WebRTCOneShotContinuation(
                    continuation
                )
                peerConnection.statistics(for: captured.sender) { report in
                    let parsed =
                        WebRTCStatisticsParser.parseIPhoneMicrophoneSender(
                            report,
                            expectedSenderID:
                                captured.validation.senderID,
                            expectedTrackID:
                                captured.validation.localTrackID,
                            expectedMID:
                                captured.validation.mid
                        )
                    resolver.resolve(
                        WebRTCIPhoneMicrophoneSenderStatisticsReportCapture(
                            parsed: parsed,
                            callbackCompletedAt: Date()
                        )
                    )
                }
                Task.detached {
                    try? await Task.sleep(for: .seconds(1))
                    resolver.resolve(nil)
                }
            }
        guard let reportCapture else {
            return nil
        }

        let currentTime = Date()
        guard let current =
            currentIPhoneMicrophoneSenderStatisticsCapture() else {
            return nil
        }
        guard let samplingResult =
            WebRTCIPhoneMicrophoneSenderStatisticsSampler.evaluate(
                parsed: reportCapture.parsed,
                captured: captured.validation,
                current: current.validation,
                diagnostics: iPhoneMicrophoneSenderState(),
                callbackCompletedAt:
                    reportCapture.callbackCompletedAt,
                currentTime: currentTime,
                previousBaseline:
                    iPhoneMicrophoneSenderStatisticsBaseline,
                requiresAdvancingEvidence:
                    iPhoneMicrophoneSenderStatisticsRequiresAdvancingEvidence
            ) else {
            return nil
        }

        iPhoneMicrophoneSenderStatisticsBaseline =
            samplingResult.baseline
        iPhoneMicrophoneSenderStatisticsRequiresAdvancingEvidence =
            samplingResult.requiresAdvancingEvidence
        lastIPhoneMicrophoneSenderStatistics =
            samplingResult.statistics
        return samplingResult.statistics
    }

    private func makeIPhoneMicrophoneSenderDiagnostics(
        binding: WebRTCIPhoneMicrophoneSenderBinding,
        transceiver: LKRTCRtpTransceiver?,
        native: ASIOSStereoPlayoutDiagnostics
    ) -> WebRTCIPhoneMicrophoneSenderDiagnostics {
        let currentTrack = localIPhoneMicrophoneTrack
        let currentSender = transceiver?.sender
        let senderTrack = currentSender?.track
        let currentTrackID = currentTrack.map { $0.trackId as String }
        let bindingGenerationIsCurrent =
            binding.negotiationEpoch == negotiationEpoch
            && binding.generation > 0
            && binding.trackGeneration > 0
        let nativeOwnershipIsCurrent: Bool
        if let transceiver,
           let currentSender,
           let currentTrack,
           let currentTrackID {
            nativeOwnershipIsCurrent =
                WebRTCIPhoneMicrophoneNativeOwnership.isCurrent(
                    bindingTransceiver: binding.transceiver,
                    currentTransceiver: transceiver,
                    bindingSender: binding.sender,
                    currentSender: currentSender,
                    bindingTrack: binding.localTrack,
                    currentTrack: currentTrack,
                    bindingMID: binding.mid,
                    currentMID: transceiver.mid as String?,
                    bindingSenderID: binding.senderID,
                    currentSenderID:
                        currentSender.senderId as String,
                    bindingTrackID: binding.localTrackID,
                    currentTrackID: currentTrackID
                )
        } else {
            nativeOwnershipIsCurrent = false
        }
        let senderOwnsMID =
            bindingGenerationIsCurrent && nativeOwnershipIsCurrent
        let senderOwnsLocalTrack =
            senderOwnsMID
            && senderTrack.map { senderTrack in
                WebRTCNativeWrapperIdentity.isSemanticallyEqual(
                    senderTrack,
                    currentTrack
                )
                    && (senderTrack.trackId as String)
                        == binding.localTrackID
            } == true
        let transceiverIsStopped = transceiver?.isStopped ?? true
        let preferredDirectionIncludesSending = transceiver.map {
            WebRTCIPhoneMicrophoneTransceiverAdmission
                .directionIncludesSending($0.direction)
        } ?? false
        let currentDirectionIncludesSending = transceiver.flatMap {
            Self.iPhoneMicrophoneCurrentDirection($0)
        }.map {
            WebRTCIPhoneMicrophoneTransceiverAdmission
                .directionIncludesSending($0)
        } ?? false
        let trackIsEnabled = currentTrack?.isEnabled == true
        let rawProcessingIsLive =
            senderOwnsLocalTrack
            && rawIPhoneMicrophoneProcessingIsLive()
        let transportIsHealthy = isTransportHealthyForMedia()
        let authorization = activeIPhoneMicrophoneAuthorization
        let recordingGeneration = native.microphoneRecordingGeneration
        let approvedRecordingGeneration =
            native.approvedMicrophoneRecordingGeneration
        let authorizationIsCurrent = authorization.map {
            iPhoneMicrophoneNativeRecordingGeneration
                == recordingGeneration
                && $0.recordingGeneration == recordingGeneration
        } ?? false
        let authorizationIsValid = authorization?.isValid == true
        let usesRemoteIO =
            native.audioUnitSubType == kAudioUnitSubType_RemoteIO
        let sampleRateIs48k =
            native.sampleRate.isFinite
            && abs(native.sampleRate - 48_000) < 1
        let ioBufferDurationIsBounded =
            native.outputIOBufferDuration.isFinite
            && native.outputIOBufferDuration > 0
            && native.outputIOBufferDuration <= 0.020
        let outputChannelCountIsStereo =
            native.outputChannelCount == 2
        let nativeDeviceIsOpen =
            native.initialized
            && native.playoutInitialized
            && native.playing
            && native.sessionActive
            && native.ownsSessionActivation
            && native.remoteIOCreated
            && native.hasOutputRoute
            && usesRemoteIO
            && native.failureCode.rawValue == 0
            && native.lastLifecycleStatus == noErr
        let nativeDeviceGateIsOpen =
            !native.microphoneDeviceGateClosedAndDrained
        let nativeAuthorizationGateIsOpen =
            native.microphoneAuthorizationGatePublished
        let generationMatches =
            recordingGeneration > 0
            && recordingGeneration == approvedRecordingGeneration
            && authorizationIsCurrent
        let senderIsAdmitted =
            senderOwnsMID
            && senderOwnsLocalTrack
            && !transceiverIsStopped
            && preferredDirectionIncludesSending
            && currentDirectionIncludesSending
            && trackIsEnabled
            && rawProcessingIsLive
            && transportIsHealthy
            && authorizationIsCurrent
            && authorizationIsValid
            && nativeDeviceIsOpen
            && nativeDeviceGateIsOpen
            && nativeAuthorizationGateIsOpen
            && native.categoryIsMediaPlayAndRecord
            && native.modeIsDefault
            && native.inputBusEnabled
            && native.captureRouteIsBuiltInMicrophone
            && native.captureRouteProofGeneration > 0
            && native.outputBusEnabled
            && !native.categoryOptionsAreEmpty
            && native.categoryOptionsAreIPhoneMicrophoneRouting
            && native.routeSharingPolicyIsDefault
            && sampleRateIs48k
            && ioBufferDurationIsBounded
            && outputChannelCountIsStereo
            && !native.recoveryRequired
            && !native.explicitResumeRequired
            && !native.hostedCallMode
            && generationMatches
            && iPhoneMicrophonePolicyGeneration > 0

        return WebRTCIPhoneMicrophoneSenderDiagnostics(
            peerEpoch: iPhoneMicrophonePeerEpoch,
            bindingGeneration: binding.generation,
            negotiationEpoch: binding.negotiationEpoch,
            trackGeneration: binding.trackGeneration,
            microphonePolicyGeneration:
                iPhoneMicrophonePolicyGeneration,
            senderOwnsMID: senderOwnsMID,
            senderOwnsLocalTrack: senderOwnsLocalTrack,
            transceiverIsStopped: transceiverIsStopped,
            preferredDirectionIncludesSending:
                preferredDirectionIncludesSending,
            currentDirectionIncludesSending: currentDirectionIncludesSending,
            trackIsEnabled: trackIsEnabled,
            rawProcessingIsLive: rawProcessingIsLive,
            transportIsHealthy: transportIsHealthy,
            authorizationIsCurrent: authorizationIsCurrent,
            authorizationIsValid: authorizationIsValid,
            senderIsAdmitted: senderIsAdmitted,
            nativeDeviceIsOpen: nativeDeviceIsOpen,
            nativeDeviceGateIsOpen: nativeDeviceGateIsOpen,
            nativeAuthorizationGateIsOpen:
                nativeAuthorizationGateIsOpen,
            categoryIsPlayAndRecord:
                native.categoryIsMediaPlayAndRecord,
            modeIsDefault: native.modeIsDefault,
            usesRemoteIO: usesRemoteIO,
            inputBusEnabled: native.inputBusEnabled,
            captureRouteIsBuiltInMicrophone:
                native.captureRouteIsBuiltInMicrophone,
            captureRouteProofGeneration:
                native.captureRouteProofGeneration,
            outputBusEnabled: native.outputBusEnabled,
            categoryOptionsAreEmpty:
                native.categoryOptionsAreEmpty,
            categoryOptionsAreIPhoneMicrophoneRouting:
                native.categoryOptionsAreIPhoneMicrophoneRouting,
            routeSharingPolicyIsDefault:
                native.routeSharingPolicyIsDefault,
            hasOutputRoute: native.hasOutputRoute,
            sampleRateIs48k: sampleRateIs48k,
            ioBufferDurationIsBounded:
                ioBufferDurationIsBounded,
            outputChannelCountIsStereo:
                outputChannelCountIsStereo,
            recoveryRequired: native.recoveryRequired,
            explicitResumeRequired: native.explicitResumeRequired,
            hostedCallMode: native.hostedCallMode,
            failureCode: Int(native.failureCode.rawValue),
            lastLifecycleStatus: native.lastLifecycleStatus,
            recordingGeneration: recordingGeneration,
            approvedRecordingGeneration:
                approvedRecordingGeneration,
            realtimeAdmissionCount:
                native.microphoneRealtimeAdmissionCount,
            deliveryCallbackCount:
                native.microphoneDeliveryCallbackCount,
            deliveredFrameCount:
                native.microphoneDeliveredFrameCount
        )
    }

    private func currentIPhoneMicrophoneSenderStatisticsCapture()
        -> WebRTCIPhoneMicrophoneSenderStatisticsCapture? {
        guard let diagnostics = iPhoneMicrophoneSenderState(),
              diagnostics.senderIsAdmitted,
              let binding = iPhoneMicrophoneSenderBinding,
              binding.negotiationEpoch == negotiationEpoch,
              binding.generation
                == diagnostics.bindingGeneration,
              binding.trackGeneration
                == diagnostics.trackGeneration,
              let track = localIPhoneMicrophoneTrack,
              (track.trackId as String) == binding.localTrackID,
              WebRTCNativeWrapperIdentity.isSemanticallyEqual(
                binding.localTrack,
                track
              ),
              iPhoneMicrophoneSenderOwnsLocalTrack(
                expectedNegotiationEpoch: binding.negotiationEpoch,
                requiresCurrentDirection: true
              ),
              let transceiver =
                currentIPhoneMicrophoneSenderTransceiver(
                    for: binding
                ),
              let authorization =
                activeIPhoneMicrophoneAuthorization,
              authorization.isValid,
              authorization.recordingGeneration > 0,
              authorization.recordingGeneration
                == diagnostics.recordingGeneration,
              diagnostics.recordingGeneration
                == diagnostics.approvedRecordingGeneration else {
            return nil
        }

        let sender = transceiver.sender
        guard WebRTCNativeWrapperIdentity.isSemanticallyEqual(
            binding.sender,
            sender
        ), (sender.senderId as String) == binding.senderID else {
            return nil
        }

        return WebRTCIPhoneMicrophoneSenderStatisticsCapture(
            sender: sender,
            validation:
                WebRTCIPhoneMicrophoneSenderStatisticsValidation(
                    peerEpoch: iPhoneMicrophonePeerEpoch,
                    bindingGeneration: binding.generation,
                    negotiationEpoch: binding.negotiationEpoch,
                    trackGeneration: binding.trackGeneration,
                    microphonePolicyGeneration:
                        iPhoneMicrophonePolicyGeneration,
                    recordingGeneration:
                        diagnostics.recordingGeneration,
                    approvedRecordingGeneration:
                        diagnostics.approvedRecordingGeneration,
                    captureRouteProofGeneration:
                        diagnostics.captureRouteProofGeneration,
                    authorizationIdentity:
                        ObjectIdentifier(authorization),
                    senderID: binding.senderID,
                    localTrackID: binding.localTrackID,
                    mid: binding.mid
                )
        )
    }
    #endif

    /// Starts bounded periodic statistics events; only one sampler may run at a time.
    public func startStatistics(interval: Duration = .seconds(1)) throws {
        try ensureOpen()
        guard interval > .zero else {
            throw WebRTCTransportError.nativeFailure("The statistics interval must be positive.")
        }
        guard statisticsTask == nil else { return }
        statisticsTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self else { return }
                await self.collectAndPublishStatistics()
            }
        }
    }

    /// Collects, revalidates, and enqueues one statistics event in one actor invocation. Once the
    /// receiver-scoped callback has been revalidated, there is no suspension before the event is
    /// yielded. The public event stream's FIFO ordering therefore prevents the host service from
    /// applying positive media evidence to a later remote-track publication.
    private func collectAndPublishStatistics() async {
        guard !isClosed else { return }
        _ = await collectStatistics(publishEvent: true)
    }

    /// Revokes every media/input gate and idempotently releases the native peer.
    public func close(reason: RemoteSessionEndReason = .normal) {
        guard !isClosed else { return }
        ensureDelegateEventLoop()
        emit(.outboundSignal(.end(reason)))
        emit(.ended(reason))
        closeTransport()
    }

    private func ensureDelegateEventLoop() {
        guard delegateEventTask == nil else { return }
        let nativeEvents = delegateProxy.events
        delegateEventTask = Task { [weak self] in
            for await event in nativeEvents {
                guard let self else { return }
                await self.consume(event)
            }
            guard !Task.isCancelled, let self else { return }
            await self.nativeEventStreamTerminatedUnexpectedly()
        }
    }

    private func consume(_ event: NativePeerEvent) async {
        guard !isClosed else { return }
        guard !delegateProxy.didFailEventDelivery() else {
            failClosedForEventDeliveryLoss("Native WebRTC event backlog overflowed.")
            return
        }
        switch event {
        case .localCandidate(let candidate):
            if localDescriptionIsAnnounced {
                guard let candidate = currentLocalCandidate(candidate) else { return }
                emit(.outboundSignal(.candidate(candidate)))
            } else {
                pendingLocalCandidates.append(candidate)
            }
        case .peerState(let state):
            if state != .connected {
                resetMacHostedCallEvidenceTransportState()
                await failCloseScreenMedia()
            }
            emit(.peerStateChanged(state))
        case .iceState(let state):
            if state != .connected && state != .completed {
                resetMacHostedCallEvidenceTransportState()
                await failCloseScreenMedia()
            }
            emit(.iceStateChanged(state))
        case .gatheringState(let state):
            emit(.iceGatheringStateChanged(state))
        case .dataChannelState(let state):
            if state != .open {
                resetMacHostedCallEvidenceTransportState()
                await failCloseScreenMedia()
            }
            emit(.dataChannelStateChanged(state))
        case .dataChannelMessage(let data):
            receiveControlChannelData(data)
        case .remoteAudioTrack(let receivedTrack):
            guard !receivedTrack.receiverID.isEmpty else {
                receivedTrack.setEnabled(false)
                emit(
                    .diagnosticFailure(
                        "Rejected a remote audio receiver without an identity."
                    )
                )
                return
            }

            let logicalLane: WebRTCRemoteAudioLane
            if role == .host {
                guard let expectedReceiverID = iPhoneMicrophoneReceiverID,
                      receivedTrack.receiverID == expectedReceiverID else {
                    receivedTrack.setEnabled(false)
                    emit(
                        .diagnosticFailure(
                            "Rejected remote audio receiver "
                                + "\(receivedTrack.receiverID) outside the dedicated "
                                + "iPhone microphone lane."
                        )
                    )
                    return
                }
                logicalLane = .iPhoneMicrophone
            } else {
                // Viewer-side system audio retains its existing strict native sender-track check.
                guard receivedTrack.nativeTrackID
                        == WebRTCAudioTrackIdentifiers.systemAudio else {
                    receivedTrack.setEnabled(false)
                    emit(
                        .diagnosticFailure(
                            "Rejected unexpected remote system-audio track "
                                + "\(receivedTrack.nativeTrackID)."
                        )
                    )
                    return
                }
                logicalLane = .systemAudio
            }

            // Reading receiver.track may produce a fresh wrapper. Preserve the current gate and
            // dedupe exclusively by the receiver's stable native identity.
            if let currentRemoteAudioTrack,
               currentRemoteAudioTrack.receiverID == receivedTrack.receiverID {
                receivedTrack.setEnabled(currentRemoteAudioTrack.isEnabled)
                return
            }

            // Native receive tracks start enabled. Both the iPhone playback owner and Mac
            // BlackHole sink must explicitly reopen their current-generation gate.
            currentRemoteAudioTrack?.setEnabled(false)
            receivedTrack.setEnabled(false)
            let track = WebRTCRemoteAudioTrack(
                receivedTrack,
                logicalLane: logicalLane
            )
            currentRemoteAudioTrack = track
            emit(.remoteAudioTrack(track))
        case .remoteVideoTrack(let track):
            currentRemoteVideoTrack = track
            emit(.remoteVideoTrack(track))
        case .route(let route):
            currentRoute = route
            emit(.routeChanged(route))
        case .iceCandidateError(let error):
            emit(.iceCandidateError(error))
        case .negotiationNeeded:
            emit(.negotiationNeeded)
        case .failure(let message):
            if message.contains("control-channel") {
                invalidateInputSession(reason: message)
            }
            emit(.diagnosticFailure(message))
        }
    }

    private func nativeEventStreamTerminatedUnexpectedly() {
        guard !isClosed else { return }
        failClosedForEventDeliveryLoss("Native WebRTC event stream terminated unexpectedly.")
    }

    @discardableResult
    private func emit(_ event: WebRTCTransportEvent) -> Bool {
        guard !isClosed else { return false }
        switch eventContinuation.yield(event) {
        case .enqueued:
            return true
        case .dropped:
            failClosedForEventDeliveryLoss("Public WebRTC event backlog overflowed.")
            return false
        case .terminated:
            failClosedForEventDeliveryLoss("Public WebRTC event stream terminated unexpectedly.")
            return false
        @unknown default:
            failClosedForEventDeliveryLoss("Public WebRTC event delivery failed.")
            return false
        }
    }

    /// No diagnostic event can be trusted after an event-stream loss. Revoke the shared input
    /// gate first, then synchronously close native media and finish the stream.
    private func failClosedForEventDeliveryLoss(_ reason: String) {
        guard !isClosed else { return }
        resetMacHostedCallEvidenceTransportState()
        suspendSystemAudioForTransportUncertainty()
        forceIPhoneMicrophoneNativeTeardown()
        #if os(iOS)
        iPhoneMicrophoneTransportSuspensionHandler = nil
        #endif
        disableRemoteAudioPlayback()
        isClosed = true
        localVideoTrack?.isEnabled = false
        let hostAuthorization = activeHostInputAuthorization
        let viewerAuthorization = activeViewerInputAuthorization
        activeHostInputCapability = nil
        activeViewerInputCapability = nil
        activeHostInputAuthorization = nil
        activeViewerInputAuthorization = nil
        resetInputHistories()
        hostAuthorization?.revoke()
        if viewerAuthorization !== hostAuthorization { viewerAuthorization?.revoke() }
        statisticsTask?.cancel()
        statisticsTask = nil
        delegateEventTask?.cancel()
        delegateEventTask = nil
        negotiationEpoch &+= 1
        outstandingLocalOfferEpoch = nil
        applyingRemoteAnswerEpoch = nil
        applyingRemoteOfferEpoch = nil
        localICEUsernameFragmentMap = nil
        remoteICEUsernameFragmentMap = nil
        requiresCandidateUsernameFragment = false
        pendingLocalCandidates.removeAll(keepingCapacity: false)
        pendingRemoteCandidates.removeAll(keepingCapacity: false)
        delegateProxy.close()
        peerConnection.close()
        eventContinuation.finish()
        _ = reason // Retain a debugger-visible reason without attempting another lossy event.
    }

    private func announceLocalDescription(_ payload: RemoteSignalPayload) throws {
        switch payload {
        case .offer(let sdp), .answer(let sdp):
            guard let mapping = ICEUsernameFragmentParser.mapping(
                inSessionDescription: sdp
            ), !mapping.declaredFragments.isEmpty else {
                throw WebRTCTransportError.invalidSessionDescription
            }
            localICEUsernameFragmentMap = mapping
        default:
            throw WebRTCTransportError.unexpectedSignal
        }
        emit(.outboundSignal(payload))
        localDescriptionIsAnnounced = true
        for candidate in pendingLocalCandidates {
            guard let candidate = currentLocalCandidate(candidate) else { continue }
            emit(.outboundSignal(.candidate(candidate)))
        }
        pendingLocalCandidates.removeAll(keepingCapacity: true)
    }

    private func receiveControlChannelData(_ data: Data) {
        do {
            let message = try JSONDecoder().decode(ControlChannelMessage.self, from: data)
            switch message {
            case .command(let request):
                receiveControlRequest(request)
            case .acknowledgement(let acknowledgement):
                receiveControlAcknowledgement(acknowledgement)
            case .input(let request):
                receiveInputRequest(request)
            case .inputFeedback(let feedback):
                receiveInputFeedback(feedback)
            case .macHostedCallChallenge(let challenge):
                receiveMacHostedCallChallenge(challenge)
            case .macHostedCallEvidence(let evidence):
                receiveMacHostedCallEvidence(evidence)
            }
        } catch {
            invalidateInputSession(reason: "Invalid control-channel message.")
            resetMacHostedCallEvidenceTransportState()
            emit(.diagnosticFailure("Invalid control-channel message."))
        }
    }

    private func receiveMacHostedCallChallenge(
        _ challenge: WebRTCMacHostedCallChallenge
    ) {
        guard role == .host,
              macHostedCallEvidenceIsNegotiated,
              challenge.isValid else {
            resetMacHostedCallEvidenceTransportState()
            emit(.diagnosticFailure("Unexpected Mac-hosted call challenge."))
            return
        }

        if let highest = highestReceivedMacHostedCallChallenge {
            if challenge == highest {
                let isFreshTransportRebind =
                    currentReceivedMacHostedCallChallenge == nil
                currentReceivedMacHostedCallChallenge = challenge
                if isFreshTransportRebind {
                    emit(.macHostedCallChallengeReceived(challenge))
                }
                return
            }
            guard challenge.sequence > highest.sequence else {
                resetMacHostedCallEvidenceTransportState()
                emit(.diagnosticFailure("Stale Mac-hosted call challenge."))
                return
            }
        }

        highestReceivedMacHostedCallChallenge = challenge
        currentReceivedMacHostedCallChallenge = challenge
        emit(.macHostedCallChallengeReceived(challenge))
    }

    private func receiveMacHostedCallEvidence(
        _ evidence: WebRTCMacHostedCallEvidence
    ) {
        guard role == .viewer,
              macHostedCallEvidenceIsNegotiated,
              let challenge = currentSentMacHostedCallChallenge,
              evidence.matches(challenge) else {
            invalidateReceivedMacHostedCallEvidence()
            emit(.diagnosticFailure("Unexpected Mac-hosted call evidence."))
            return
        }

        if let highest = highestReceivedMacHostedCallEvidenceSequence {
            if evidence.sequence == highest,
               evidence == currentReceivedMacHostedCallEvidence {
                return
            }
            guard evidence.sequence > highest else {
                invalidateReceivedMacHostedCallEvidence()
                emit(.diagnosticFailure("Stale Mac-hosted call evidence."))
                return
            }
        }

        highestReceivedMacHostedCallEvidenceSequence = evidence.sequence
        currentReceivedMacHostedCallEvidence = evidence
        emit(.macHostedCallEvidenceChanged(evidence))
    }

    private func invalidateReceivedMacHostedCallEvidence() {
        guard currentReceivedMacHostedCallEvidence != nil else { return }
        currentReceivedMacHostedCallEvidence = nil
        emit(.macHostedCallEvidenceChanged(nil))
    }

    private func resetMacHostedCallEvidenceNegotiation() {
        macHostedCallEvidenceIsNegotiated = false
        highestReceivedMacHostedCallChallenge = nil
        currentReceivedMacHostedCallChallenge = nil
        currentSentMacHostedCallChallenge = nil
        highestReceivedMacHostedCallEvidenceSequence = nil
        resetSentMacHostedCallObservationState()
        invalidateReceivedMacHostedCallEvidence()
    }

    private func resetMacHostedCallEvidenceTransportState() {
        currentReceivedMacHostedCallChallenge = nil
        currentSentMacHostedCallChallenge = nil
        resetSentMacHostedCallObservationState()
        invalidateReceivedMacHostedCallEvidence()
    }

    private func resetSentMacHostedCallObservationState() {
        sentMacHostedCallObservationAuthorization = nil
        sentMacHostedCallObservationChallenge = nil
        highestSentMacHostedCallObservationSequence = 0
    }

    private func receiveControlRequest(_ request: WebRTCControlRequest) {
        guard role == .host, request.id > 0 else {
            emit(.diagnosticFailure("Unexpected control request."))
            return
        }

        if let existing = receivedControlRequests[request.id] {
            guard existing == request else {
                emit(.diagnosticFailure("Conflicting duplicate control request."))
                return
            }
            // An ordered reliable channel should not duplicate messages, but replaying an already
            // completed acknowledgement is safe and does not repeat application work.
            if let acknowledgement = sentControlAcknowledgements[request.id] {
                do {
                    let data = try JSONEncoder().encode(
                        ControlChannelMessage.acknowledgement(acknowledgement)
                    )
                    try delegateProxy.sendControlData(data)
                } catch {
                    emit(.diagnosticFailure("Could not replay control acknowledgement."))
                }
            }
            return
        }

        if let highestReceivedControlRequestID, request.id <= highestReceivedControlRequestID {
            emit(.diagnosticFailure("Stale control request ignored."))
            return
        }

        if request.command == .showScreen || request.command == .hideScreen {
            // Revoke before the application event is yielded so queued media or input cannot race
            // a newer screen generation through lagging service state. A fresh Show/Active ACK is
            // the only path that may re-enable the host video track.
            localVideoTrack?.isEnabled = false
            replaceHostInputSession(capability: nil, authorization: nil)
        }

        guard prepareReceivedControlHistoryForNewRequest() else {
            emit(.diagnosticFailure("Control request backlog exceeded its safe bound."))
            closeTransport()
            return
        }

        highestReceivedControlRequestID = request.id
        receivedControlRequests[request.id] = request
        receivedControlRequestOrder.append(request.id)
        emit(.controlRequestReceived(request))
    }

    private func receiveControlAcknowledgement(_ acknowledgement: WebRTCControlAcknowledgement) {
        guard role == .viewer,
              let request = sentControlRequests[acknowledgement.id],
              request.id == acknowledgement.id else {
            emit(.diagnosticFailure("Unknown control acknowledgement ignored."))
            return
        }
        guard acknowledgement.id == highestSentControlRequestID else {
            emit(.diagnosticFailure("Stale control acknowledgement ignored."))
            return
        }
        if let existing = receivedControlAcknowledgements[acknowledgement.id] {
            if existing != acknowledgement {
                emit(.diagnosticFailure("Conflicting control acknowledgement ignored."))
            }
            return
        }

        // A Hide may only be confirmed by the host reaching Inactive. Treat Active-for-Hide as
        // terminal instead of exposing it to a UI timeout: the host may still be capturing, so
        // closing the peer is the only fail-closed response available on this channel.
        guard request.command != .hideScreen || acknowledgement.state == .inactive else {
            emit(.diagnosticFailure("Host did not reach Inactive after Hide."))
            closeTransport()
            return
        }

        let isActiveShow = acknowledgement.state == .active
            && request.command == .showScreen
        guard acknowledgement.inputCapability == nil || (
            isActiveShow
                && acknowledgement.inputCapability?.isValid == true
                && acknowledgement.inputCapability?.screenRequestID == request.id
        ) else {
            invalidateInputSession(reason: "Invalid input capability in control acknowledgement.")
            emit(.diagnosticFailure("Invalid input capability ignored."))
            return
        }

        receivedControlAcknowledgements[acknowledgement.id] = acknowledgement
        let inputAuthorization: WebRTCInputAuthorization?
        if isActiveShow, let capability = acknowledgement.inputCapability {
            let authorization = WebRTCInputAuthorization()
            replaceViewerInputSession(
                capability: capability,
                authorization: authorization
            )
            inputAuthorization = authorization
        } else if acknowledgement.state == .inactive {
            replaceViewerInputSession(capability: nil, authorization: nil)
            inputAuthorization = nil
        } else {
            inputAuthorization = nil
        }
        emit(
            .controlAcknowledgementReceived(
                acknowledgement,
                inputAuthorization: inputAuthorization
            )
        )
    }

    private func receiveInputRequest(_ request: WebRTCInputRequest) {
        guard role == .host,
              request.isValid,
              let capability = activeHostInputCapability,
              let authorization = activeHostInputAuthorization,
              authorization.isValid,
              request.screenRequestID == capability.screenRequestID,
              request.inputSessionID == capability.inputSessionID,
              Self.inputCapability(capability, permits: request.action) else {
            failCloseInput("Unexpected, unsupported, or unbound remote-input request.")
            return
        }

        let binding = WebRTCInputRequestBinding(request)
        if let existing = receivedInputRequests[request.id] {
            guard existing == binding else {
                failCloseInput("Conflicting duplicate remote-input binding.")
                return
            }
            // Never yield an ID twice. The payload is intentionally not retained: a duplicate
            // with the same authenticated session binding is treated as an idempotent retry,
            // regardless of payload, and can therefore never repeat irreversible OS work. If
            // application work already completed, replay only its immutable feedback; otherwise
            // wait for the original completion.
            if let feedback = sentInputFeedback[request.id] {
                do {
                    let data = try JSONEncoder().encode(
                        ControlChannelMessage.inputFeedback(feedback)
                    )
                    try delegateProxy.sendControlData(data)
                } catch {
                    failCloseInput("Could not replay remote-input feedback.")
                }
            }
            return
        }

        if let highestReceivedInputRequestID, request.id <= highestReceivedInputRequestID {
            failCloseInput("Stale remote-input request rejected.")
            return
        }

        guard prepareReceivedInputHistoryForNewRequest() else {
            failCloseInput("Remote-input receive backlog exceeded its safe bound.")
            return
        }

        highestReceivedInputRequestID = request.id
        receivedInputRequests[request.id] = binding
        receivedInputRequestOrder.append(request.id)
        emit(.inputRequestReceived(request, authorization: authorization))
    }

    private static func inputCapability(
        _ capability: WebRTCInputCapability,
        permits action: WebRTCInputAction
    ) -> Bool {
        switch action {
        case .primaryDrag:
            capability.supportsPrimaryDrag
        case .tap, .insertText, .backspace, .returnKey:
            true
        }
    }

    private func receiveInputFeedback(_ feedback: WebRTCInputFeedback) {
        guard role == .viewer,
              feedback.isValid,
              let capability = activeViewerInputCapability,
              let request = sentInputRequests[feedback.id],
              feedback.screenRequestID == capability.screenRequestID,
              feedback.inputSessionID == capability.inputSessionID,
              feedback.screenRequestID == request.screenRequestID,
              feedback.inputSessionID == request.inputSessionID else {
            failCloseInput("Unknown, stale, or unbound remote-input feedback.")
            return
        }

        if let existing = receivedInputFeedback[feedback.id] {
            if existing != feedback {
                failCloseInput("Conflicting remote-input feedback.")
            }
            return
        }

        receivedInputFeedback[feedback.id] = feedback
        emit(.inputFeedbackReceived(feedback))
    }

    private func failCloseScreenMedia() async {
        suspendSystemAudioForTransportUncertainty()
        disableRemoteAudioPlayback()
        localVideoTrack?.isEnabled = false
        // Clear the peer-owned capability before lifecycle state events can reach application
        // actors. This closes the window where their health booleans still describe the old route.
        invalidateInputSession(reason: "WebRTC transport became uncertain.")
        guard await suspendIPhoneMicrophoneForTransportUncertainty() else {
            return
        }
        // A prior active acknowledgement cannot be replayed after connectivity was lost. The
        // viewer must issue a new, higher request ID after the control channel is usable again.
        receivedControlRequests.removeAll(keepingCapacity: true)
        receivedControlRequestOrder.removeAll(keepingCapacity: true)
        sentControlAcknowledgements.removeAll(keepingCapacity: true)
    }

    private func replaceHostInputSession(
        capability: WebRTCInputCapability?,
        authorization: WebRTCInputAuthorization?
    ) {
        precondition((capability == nil) == (authorization == nil))
        guard activeHostInputCapability != capability
                || activeHostInputAuthorization !== authorization
                || activeViewerInputCapability != nil
                || activeViewerInputAuthorization != nil else { return }
        let oldHostAuthorization = activeHostInputAuthorization
        let oldViewerAuthorization = activeViewerInputAuthorization
        activeHostInputCapability = capability
        activeHostInputAuthorization = authorization
        activeViewerInputCapability = nil
        activeViewerInputAuthorization = nil
        delegateProxy.installInputAuthorization(authorization)
        resetInputHistories()
        if oldHostAuthorization !== authorization { oldHostAuthorization?.revoke() }
        oldViewerAuthorization?.revoke()
    }

    private func replaceViewerInputSession(
        capability: WebRTCInputCapability?,
        authorization: WebRTCInputAuthorization?
    ) {
        precondition((capability == nil) == (authorization == nil))
        guard activeViewerInputCapability != capability
                || activeViewerInputAuthorization !== authorization
                || activeHostInputCapability != nil
                || activeHostInputAuthorization != nil else { return }
        let oldHostAuthorization = activeHostInputAuthorization
        let oldViewerAuthorization = activeViewerInputAuthorization
        activeViewerInputCapability = capability
        activeViewerInputAuthorization = authorization
        activeHostInputCapability = nil
        activeHostInputAuthorization = nil
        delegateProxy.installInputAuthorization(authorization)
        resetInputHistories()
        oldHostAuthorization?.revoke()
        if oldViewerAuthorization !== authorization { oldViewerAuthorization?.revoke() }
    }

    private func invalidateInputSession(reason: String) {
        let hadCapability = activeHostInputCapability != nil || activeViewerInputCapability != nil
        let hostAuthorization = activeHostInputAuthorization
        let viewerAuthorization = activeViewerInputAuthorization
        activeHostInputCapability = nil
        activeViewerInputCapability = nil
        activeHostInputAuthorization = nil
        activeViewerInputAuthorization = nil
        delegateProxy.installInputAuthorization(nil)
        resetInputHistories()
        hostAuthorization?.revoke()
        if viewerAuthorization !== hostAuthorization { viewerAuthorization?.revoke() }
        if hadCapability {
            emit(.inputSessionInvalidated(reason))
        }
    }

    private func failCloseInput(_ reason: String) {
        invalidateInputSession(reason: reason)
        emit(.diagnosticFailure(reason))
    }

    private func resetInputHistories() {
        highestReceivedInputRequestID = nil
        sentInputRequests.removeAll(keepingCapacity: true)
        sentInputRequestOrder.removeAll(keepingCapacity: true)
        receivedInputFeedback.removeAll(keepingCapacity: true)
        receivedInputRequests.removeAll(keepingCapacity: true)
        receivedInputRequestOrder.removeAll(keepingCapacity: true)
        sentInputFeedback.removeAll(keepingCapacity: true)
    }

    private func prepareSentControlHistoryForNewRequest() -> Bool {
        while sentControlRequestOrder.count >= Self.controlHistoryLimit {
            guard let index = sentControlRequestOrder.firstIndex(where: {
                receivedControlAcknowledgements[$0] != nil
            }) else {
                return false
            }
            let id = sentControlRequestOrder.remove(at: index)
            sentControlRequests.removeValue(forKey: id)
            receivedControlAcknowledgements.removeValue(forKey: id)
        }
        return true
    }

    private func prepareReceivedControlHistoryForNewRequest() -> Bool {
        while receivedControlRequestOrder.count >= Self.controlHistoryLimit {
            guard let index = receivedControlRequestOrder.firstIndex(where: {
                sentControlAcknowledgements[$0] != nil
            }) else {
                return false
            }
            let id = receivedControlRequestOrder.remove(at: index)
            receivedControlRequests.removeValue(forKey: id)
            sentControlAcknowledgements.removeValue(forKey: id)
        }
        return true
    }

    private func prepareSentInputHistoryForNewRequest() -> Bool {
        while sentInputRequestOrder.count >= Self.inputHistoryLimit {
            guard let index = sentInputRequestOrder.firstIndex(where: {
                receivedInputFeedback[$0] != nil
            }) else {
                return false
            }
            let id = sentInputRequestOrder.remove(at: index)
            sentInputRequests.removeValue(forKey: id)
            receivedInputFeedback.removeValue(forKey: id)
        }
        return true
    }

    private func prepareReceivedInputHistoryForNewRequest() -> Bool {
        while receivedInputRequestOrder.count >= Self.inputHistoryLimit {
            guard let index = receivedInputRequestOrder.firstIndex(where: {
                sentInputFeedback[$0] != nil
            }) else {
                return false
            }
            let id = receivedInputRequestOrder.remove(at: index)
            receivedInputRequests.removeValue(forKey: id)
            sentInputFeedback.removeValue(forKey: id)
        }
        return true
    }

    private func publishStatistics(_ snapshot: WebRTCStatisticsSnapshot) {
        if let route = snapshot.route, route != currentRoute {
            currentRoute = route
            emit(.routeChanged(route))
        }
        emit(.statistics(snapshot))
    }

    private func nextNegotiationEpoch() -> UInt64 {
        negotiationEpoch &+= 1
        return negotiationEpoch
    }

    private func nextIPhoneMicrophoneSenderBindingGeneration()
        -> UInt64 {
        iPhoneMicrophoneSenderBindingGeneration &+= 1
        if iPhoneMicrophoneSenderBindingGeneration == 0 {
            iPhoneMicrophoneSenderBindingGeneration = 1
        }
        return iPhoneMicrophoneSenderBindingGeneration
    }

    private func nextIPhoneMicrophoneTrackGeneration() -> UInt64 {
        iPhoneMicrophoneTrackGeneration &+= 1
        if iPhoneMicrophoneTrackGeneration == 0 {
            iPhoneMicrophoneTrackGeneration = 1
        }
        return iPhoneMicrophoneTrackGeneration
    }

    private func resetIPhoneMicrophoneSenderStatisticsContinuity() {
        lastIPhoneMicrophoneSenderStatistics = nil
        iPhoneMicrophoneSenderStatisticsBaseline = nil
        iPhoneMicrophoneSenderStatisticsRequiresAdvancingEvidence = false
    }

    private func invalidateIPhoneMicrophoneSenderBinding() {
        iPhoneMicrophoneSenderBinding = nil
        resetIPhoneMicrophoneSenderStatisticsContinuity()
        lastIPhoneMicrophoneRawProcessingResult = nil
        localIPhoneMicrophoneTrack?.isEnabled = false
        #if os(iOS)
        iPhoneMicrophoneNativeRecordingGeneration = 0
        #endif
    }

    private func invalidateCurrentRoute() {
        currentRoute = nil
        emit(
            .routeChanged(WebRTCICERouteDiagnostics(kind: .unknown))
        )
    }

    private func createAndSetLocalOffer() async throws -> String {
        try applyHighFidelityAudioSenderParameters()
        let sdp = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String, any Error>) in
            peerConnection.offer(for: mediaConstraints) { [peerConnection] description, error in
                guard let description else {
                    continuation.resume(
                        throwing: Self.nativeError(error, fallback: .invalidSessionDescription)
                    )
                    return
                }
                let productDescription = Self.applyingProductOpusOfferPolicy(
                    to: description
                )
                let localDescription = LKRTCSessionDescription(
                    type: productDescription.type,
                    sdp: MacHostedCallEvidenceSDP.advertisingHostSupport(
                        in: productDescription.sdp as String
                    )
                )
                peerConnection.setLocalDescription(localDescription) { error in
                    if let error {
                        continuation.resume(throwing: WebRTCTransportError.nativeFailure(error.localizedDescription))
                    } else {
                        continuation.resume(returning: localDescription.sdp as String)
                    }
                }
            }
        }
        try requestRawSystemAudioProcessing()
        return sdp
    }

    private func createAndSetLocalAnswer(remoteOfferSDP: String) async throws -> String {
        try applyHighFidelityAudioSenderParameters()
        let expectedNegotiationEpoch = negotiationEpoch
        let answerSDP = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String, any Error>) in
            peerConnection.answer(for: mediaConstraints) { [peerConnection] description, error in
                guard let description else {
                    continuation.resume(
                        throwing: Self.nativeError(error, fallback: .invalidSessionDescription)
                    )
                    return
                }
                let productDescription = Self.applyingProductOpusAnswerPolicy(
                    to: description,
                    remoteOfferSDP: remoteOfferSDP
                )
                let localDescription = LKRTCSessionDescription(
                    type: productDescription.type,
                    sdp: MacHostedCallEvidenceSDP.advertisingViewerSupport(
                        in: productDescription.sdp as String,
                        remoteOfferSDP: remoteOfferSDP
                    )
                )
                peerConnection.setLocalDescription(localDescription) { error in
                    if let error {
                        continuation.resume(throwing: WebRTCTransportError.nativeFailure(error.localizedDescription))
                    } else {
                        continuation.resume(returning: localDescription.sdp as String)
                    }
                }
            }
        }
        try reapplyRawIPhoneMicrophoneProcessing(
            expectedNegotiationEpoch: expectedNegotiationEpoch
        )
        return answerSDP
    }

    private static func applyingProductOpusOfferPolicy(
        to description: LKRTCSessionDescription
    ) -> LKRTCSessionDescription {
        let nativeSDP = description.sdp as String
        let systemAudioMID = IPhoneMicrophoneSDP.systemAudioMID(
            inHostOffer: nativeSDP
        )
        let highFidelitySDP = systemAudioMID.map {
            OpusStereoSDP.applyingHighFidelityPolicy(
                to: nativeSDP,
                mediaMID: $0
            )
        } ?? nativeSDP
        let microphoneMID = IPhoneMicrophoneSDP.microphoneMID(
            inHostOffer: highFidelitySDP
        )
        return LKRTCSessionDescription(
            type: description.type,
            sdp: IPhoneMicrophoneSDP.applyingMonoPolicy(
                to: highFidelitySDP,
                microphoneMID: microphoneMID
            )
        )
    }

    private static func applyingProductOpusAnswerPolicy(
        to description: LKRTCSessionDescription,
        remoteOfferSDP: String
    ) -> LKRTCSessionDescription {
        let nativeSDP = description.sdp as String
        let systemAudioMID = IPhoneMicrophoneSDP.systemAudioMID(
            inHostOffer: remoteOfferSDP
        )
        let highFidelitySDP = systemAudioMID.map {
            OpusStereoSDP.applyingHighFidelityAnswerPolicy(
                to: nativeSDP,
                remoteOffer: remoteOfferSDP,
                mediaMID: $0
            )
        } ?? nativeSDP
        return LKRTCSessionDescription(
            type: description.type,
            sdp: IPhoneMicrophoneSDP.applyingMonoPolicy(
                to: highFidelitySDP,
                microphoneMID: IPhoneMicrophoneSDP.microphoneMID(
                    inHostOffer: remoteOfferSDP
                )
            )
        )
    }

    private func configureIPhoneMicrophoneSender(
        remoteOfferSDP: String
    ) throws {
        guard role == .viewer,
              let track = localIPhoneMicrophoneTrack else {
            return
        }
        track.isEnabled = false
        iPhoneMicrophoneSenderBinding = nil
        resetIPhoneMicrophoneSenderStatisticsContinuity()
        guard let microphoneMID = IPhoneMicrophoneSDP.microphoneMID(
            inHostOffer: remoteOfferSDP
        ) else {
            return
        }
        let matchingTransceivers = peerConnection.transceivers.filter {
            $0.mediaType == .audio
                && ($0.mid as String?) == microphoneMID
        }
        guard matchingTransceivers.count == 1,
              let transceiver = matchingTransceivers.first else {
            throw WebRTCTransportError.invalidSessionDescription
        }

        let sender = transceiver.sender
        sender.track = track
        sender.streamIds = [
            WebRTCAudioTrackIdentifiers.iPhoneMicrophoneStream
        ]
        var directionError: NSError?
        transceiver.setDirection(.sendOnly, error: &directionError)
        if let directionError {
            throw WebRTCTransportError.nativeFailure(
                directionError.localizedDescription
            )
        }
        guard WebRTCIPhoneMicrophoneTransceiverAdmission
                .permitsConfiguredSending(
                    isStopped: transceiver.isStopped,
                    preferredDirection: transceiver.direction
                ) else {
            throw WebRTCTransportError.nativeFailure(
                "The negotiated iPhone microphone transceiver cannot send."
            )
        }

        let senderID = sender.senderId as String
        let localTrackID = track.trackId as String
        guard !senderID.isEmpty,
              localTrackID
                == WebRTCAudioTrackIdentifiers.iPhoneMicrophone,
              let senderTrack = sender.track,
              WebRTCNativeWrapperIdentity.isSemanticallyEqual(
                senderTrack,
                track
              ),
              (senderTrack.trackId as String) == localTrackID else {
            throw WebRTCTransportError.nativeFailure(
                "The negotiated iPhone microphone sender does not own "
                    + "the exact local microphone track."
            )
        }
        let bindingGeneration =
            nextIPhoneMicrophoneSenderBindingGeneration()
        let trackGeneration =
            nextIPhoneMicrophoneTrackGeneration()
        let binding = WebRTCIPhoneMicrophoneSenderBinding(
            generation: bindingGeneration,
            negotiationEpoch: negotiationEpoch,
            trackGeneration: trackGeneration,
            mid: microphoneMID,
            transceiver: transceiver,
            senderID: senderID,
            sender: sender,
            localTrackID: localTrackID,
            localTrack: track
        )
        iPhoneMicrophoneSenderBinding = binding
        do {
            try requestRawIPhoneMicrophoneProcessing(
                expectedNegotiationEpoch: negotiationEpoch,
                requiresCurrentDirection: false
            )
        } catch {
            iPhoneMicrophoneSenderBinding = nil
            resetIPhoneMicrophoneSenderStatisticsContinuity()
            throw error
        }
    }

    private func setRemoteDescription(sdp: String, type: LKRTCSdpType) async throws {
        guard !sdp.isEmpty else { throw WebRTCTransportError.invalidSessionDescription }
        let description = LKRTCSessionDescription(type: type, sdp: sdp)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: WebRTCTransportError.nativeFailure(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func installRemoteICEUsernameFragments(from sdp: String) throws {
        guard let mapping = ICEUsernameFragmentParser.mapping(
            inSessionDescription: sdp
        ), !mapping.declaredFragments.isEmpty else {
            throw WebRTCTransportError.invalidSessionDescription
        }
        remoteICEUsernameFragmentMap = mapping
    }

    private func currentLocalCandidate(
        _ candidate: RemoteICECandidate
    ) -> RemoteICECandidate? {
        guard let localICEUsernameFragmentMap else { return nil }
        return ICECandidateUsernameFragmentValidator.validatedCandidate(
            candidate,
            against: localICEUsernameFragmentMap,
            requiresExplicitFragment: requiresCandidateUsernameFragment
        )
    }

    private func currentRemoteCandidate(
        _ candidate: RemoteICECandidate
    ) -> RemoteICECandidate? {
        guard let remoteICEUsernameFragmentMap else { return nil }
        return ICECandidateUsernameFragmentValidator.validatedCandidate(
            candidate,
            against: remoteICEUsernameFragmentMap,
            requiresExplicitFragment: requiresCandidateUsernameFragment
        )
    }

    private func enqueuePendingRemoteCandidate(
        _ candidate: RemoteICECandidate
    ) throws {
        guard pendingRemoteCandidates.count < Self.maximumPendingRemoteCandidateCount else {
            closeTransport()
            throw WebRTCTransportError.pendingRemoteCandidateLimitExceeded(
                Self.maximumPendingRemoteCandidateCount
            )
        }
        pendingRemoteCandidates.append(candidate)
    }

    private static func isValidCandidateEnvelope(_ candidate: RemoteICECandidate) -> Bool {
        !candidate.sdp.isEmpty
            && candidate.sdp.utf8.count <= maximumCandidateBytes
            && candidate.sdpMid.map {
                !$0.isEmpty && $0.utf8.count <= maximumCandidateMIDBytes
                    && !$0.contains(where: \.isWhitespace)
            } != false
            && candidate.sdpMLineIndex.map { $0 >= 0 && $0 <= 65_535 } != false
            && (candidate.sdpMid != nil || candidate.sdpMLineIndex != nil)
            && candidate.usernameFragment.map {
                !$0.isEmpty
                    && $0.utf8.count <= maximumCandidateUsernameFragmentBytes
                    && !$0.contains(where: \.isWhitespace)
            } != false
    }

    /// Returns false when the native completion belongs to a negotiation epoch that has already
    /// been superseded. Errors from such completions must not terminate the new session.
    private func addRemoteCandidate(
        _ candidate: RemoteICECandidate,
        expectedEpoch: UInt64
    ) async throws -> Bool {
        guard Self.isValidCandidateEnvelope(candidate) else {
            throw WebRTCTransportError.invalidICECandidate
        }
        let nativeCandidate = LKRTCIceCandidate(
            sdp: candidate.sdp,
            sdpMLineIndex: candidate.sdpMLineIndex ?? 0,
            sdpMid: candidate.sdpMid
        )
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                peerConnection.add(nativeCandidate) { error in
                    if let error {
                        continuation.resume(
                            throwing: WebRTCTransportError.nativeFailure(
                                error.localizedDescription
                            )
                        )
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            guard !isClosed, negotiationEpoch == expectedEpoch else { return false }
            throw error
        }
        return !isClosed && negotiationEpoch == expectedEpoch
    }

    private func flushRemoteCandidates(expectedEpoch: UInt64) async throws {
        var candidates = pendingRemoteCandidates
        pendingRemoteCandidates.removeAll(keepingCapacity: true)
        while !candidates.isEmpty {
            guard !isClosed, negotiationEpoch == expectedEpoch else { return }
            let rawCandidate = candidates.removeFirst()
            guard let candidate = currentRemoteCandidate(rawCandidate) else { continue }
            do {
                guard try await addRemoteCandidate(
                    candidate,
                    expectedEpoch: expectedEpoch
                ) else {
                    return
                }
            } catch {
                guard !isClosed, negotiationEpoch == expectedEpoch else { return }
                pendingRemoteCandidates.append(rawCandidate)
                pendingRemoteCandidates.append(contentsOf: candidates)
                throw error
            }
        }
    }

    private func preferH264OnVideoTransceivers() throws {
        let capabilities = factory.rtpReceiverCapabilities(
            forKind: kLKRTCMediaStreamTrackKindVideo
        )
        for transceiver in peerConnection.transceivers {
            guard transceiver.mediaType == .video else { continue }
            try Self.preferH264(on: transceiver, capabilities: capabilities)
        }
    }

    private func preferOpusOnAudioTransceivers() throws {
        let capabilities = factory.rtpReceiverCapabilities(
            forKind: kLKRTCMediaStreamTrackKindAudio
        )
        for transceiver in peerConnection.transceivers {
            guard transceiver.mediaType == .audio else { continue }
            try Self.preferOpus(on: transceiver, capabilities: capabilities)
        }
    }

    private func applyHighFidelityAudioSenderParameters() throws {
        for transceiver in peerConnection.transceivers {
            guard transceiver.mediaType == .audio,
                  let track = transceiver.sender.track,
                  (track.trackId as String)
                    == WebRTCAudioTrackIdentifiers.systemAudio else {
                continue
            }
            try Self.applyHighFidelityAudioSenderParameters(to: transceiver.sender)
        }
    }

    private static func iPhoneMicrophoneCurrentDirection(
        _ transceiver: LKRTCRtpTransceiver
    ) -> LKRTCRtpTransceiverDirection? {
        var currentDirection: LKRTCRtpTransceiverDirection = .stopped
        guard transceiver.currentDirection(&currentDirection) else {
            return nil
        }
        return currentDirection
    }

    private func currentIPhoneMicrophoneSenderTransceiver(
        for binding: WebRTCIPhoneMicrophoneSenderBinding
    ) -> LKRTCRtpTransceiver? {
        guard let currentTrack = localIPhoneMicrophoneTrack else {
            return nil
        }
        let currentTrackID = currentTrack.trackId as String
        let matches = peerConnection.transceivers.filter { transceiver in
            guard transceiver.mediaType == .audio else { return false }
            let currentSender = transceiver.sender
            return WebRTCIPhoneMicrophoneNativeOwnership.isCurrent(
                bindingTransceiver: binding.transceiver,
                currentTransceiver: transceiver,
                bindingSender: binding.sender,
                currentSender: currentSender,
                bindingTrack: binding.localTrack,
                currentTrack: currentTrack,
                bindingMID: binding.mid,
                currentMID: transceiver.mid as String?,
                bindingSenderID: binding.senderID,
                currentSenderID: currentSender.senderId as String,
                bindingTrackID: binding.localTrackID,
                currentTrackID: currentTrackID
            )
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func iPhoneMicrophoneSenderOwnsLocalTrack(
        expectedNegotiationEpoch: UInt64,
        requiresCurrentDirection: Bool = true
    ) -> Bool {
        guard role == .viewer,
              negotiationEpoch == expectedNegotiationEpoch,
              let currentLocalTrack = localIPhoneMicrophoneTrack,
              let binding = iPhoneMicrophoneSenderBinding,
              binding.negotiationEpoch == expectedNegotiationEpoch,
              binding.generation > 0,
              binding.trackGeneration > 0,
              binding.localTrackID
                == WebRTCAudioTrackIdentifiers.iPhoneMicrophone,
              let transceiver =
                currentIPhoneMicrophoneSenderTransceiver(
                    for: binding
                ) else {
            return false
        }
        let sender = transceiver.sender
        guard let senderTrack = sender.track,
              WebRTCNativeWrapperIdentity.isSemanticallyEqual(
                senderTrack,
                currentLocalTrack
              ),
              (senderTrack.trackId as String) == binding.localTrackID,
              WebRTCIPhoneMicrophoneTransceiverAdmission
                .permitsConfiguredSending(
                    isStopped: transceiver.isStopped,
                    preferredDirection: transceiver.direction
                ) else {
            return false
        }

        if requiresCurrentDirection {
            return WebRTCIPhoneMicrophoneTransceiverAdmission
                .permitsNegotiatedSending(
                    isStopped: transceiver.isStopped,
                    preferredDirection: transceiver.direction,
                    currentDirection:
                        Self.iPhoneMicrophoneCurrentDirection(transceiver)
                )
        }
        return true
    }

    private func requestRawIPhoneMicrophoneProcessing(
        expectedNegotiationEpoch: UInt64,
        requiresCurrentDirection: Bool = false
    ) throws {
        guard role == .viewer,
              let track = localIPhoneMicrophoneTrack else {
            throw WebRTCTransportError.invalidRole
        }
        let senderOwnsTrack = iPhoneMicrophoneSenderOwnsLocalTrack(
            expectedNegotiationEpoch: expectedNegotiationEpoch,
            requiresCurrentDirection: requiresCurrentDirection
        )
        #if DEBUG
        if !senderOwnsTrack {
            debugIPhoneMicrophoneRawProcessingWasEverRequestedWithoutCurrentSender = true
        }
        #endif
        guard senderOwnsTrack else {
            throw WebRTCTransportError.transportNotHealthy
        }

        #if DEBUG
        debugIPhoneMicrophoneRawProcessingRequestCount += 1
        #endif
        let result = track.setAudioProcessingOptions(.raw())
        let resultCodeRawValue = Int(result.code.rawValue)
        lastIPhoneMicrophoneRawProcessingResult = (
            negotiationEpoch: expectedNegotiationEpoch,
            codeRawValue: resultCodeRawValue
        )
        #if DEBUG
        if resultCodeRawValue == 0 {
            debugIPhoneMicrophoneRawProcessingAppliedResultCount += 1
        } else if resultCodeRawValue == 1 {
            debugIPhoneMicrophoneRawProcessingStoredResultCount += 1
        }
        #endif
        guard result.isSuccess else {
            throw WebRTCTransportError.nativeFailure(
                "WebRTC rejected raw iPhone-microphone processing "
                    + "(code=\(resultCodeRawValue)): \(result.message)"
            )
        }
    }

    private func reapplyRawIPhoneMicrophoneProcessing(
        expectedNegotiationEpoch: UInt64
    ) throws {
        guard iPhoneMicrophoneSenderBinding != nil else { return }
        try requestRawIPhoneMicrophoneProcessing(
            expectedNegotiationEpoch: expectedNegotiationEpoch
        )
    }

    private func awaitRawIPhoneMicrophoneProcessing(
        expectedNegotiationEpoch: UInt64,
        requiresHealthyTransport: Bool,
        maximumAttempts: Int? = nil
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        let boundedMaximumAttempts = maximumAttempts.map { max(0, $0) }
        var attempt = 0
        while true {
            guard !isClosed,
                  localIPhoneMicrophoneTrack?.isEnabled == true,
                  iPhoneMicrophoneSenderOwnsLocalTrack(
                      expectedNegotiationEpoch: expectedNegotiationEpoch
                  ),
                  !requiresHealthyTransport || isTransportHealthyForMedia() else {
                throw WebRTCTransportError.transportNotHealthy
            }

            try requestRawIPhoneMicrophoneProcessing(
                expectedNegotiationEpoch: expectedNegotiationEpoch,
                requiresCurrentDirection: true
            )
            if rawIPhoneMicrophoneProcessingIsLive() {
                return
            }
            let exhaustedAttemptOverride = boundedMaximumAttempts.map {
                attempt >= $0
            } ?? false
            if exhaustedAttemptOverride
                || (boundedMaximumAttempts == nil && clock.now >= deadline) {
                throw WebRTCTransportError.nativeFailure(
                    "WebRTC did not disable call-oriented iPhone-microphone processing "
                        + "within the 2-second safety deadline: "
                        + rawIPhoneMicrophoneProcessingDiagnostic()
                )
            }
            attempt += 1
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    #if DEBUG && os(macOS)
    private func awaitHeadlessMacIPhoneMicrophoneRecordingGeneration(
        expectedNegotiationEpoch: UInt64,
        baselineDeliveryCallbackCount: UInt64,
        baselineDeliveredFrameCount: UInt64,
        maximumAttempts: Int
    ) async throws -> UInt64 {
        guard let macStereoAudioDevice else {
            throw WebRTCTransportError.invalidRole
        }

        let finalAttempt = max(0, maximumAttempts)
        for attempt in 0...finalAttempt {
            let diagnostics = macStereoAudioDevice.diagnostics
            if diagnostics.recording,
               diagnostics.recordingGeneration != 0,
               diagnostics.approvedRecordingGeneration == 0,
               diagnostics.deliveryCallbackCount
                == baselineDeliveryCallbackCount,
               diagnostics.deliveredFrameCount
                == baselineDeliveredFrameCount {
                return diagnostics.recordingGeneration
            }

            if attempt == finalAttempt {
                throw WebRTCTransportError.nativeFailure(
                    "The headless microphone sender did not produce an unapproved "
                        + "native recording generation."
                )
            }

            try await Task.sleep(for: .milliseconds(10))
            guard !isClosed,
                  negotiationEpoch == expectedNegotiationEpoch,
                  localIPhoneMicrophoneTrack?.isEnabled == true,
                  iPhoneMicrophoneSenderOwnsLocalTrack(
                    expectedNegotiationEpoch: expectedNegotiationEpoch
                  ) else {
                throw WebRTCTransportError.transportNotHealthy
            }
        }
        throw WebRTCTransportError.transportNotHealthy
    }
    #endif

    private func rawIPhoneMicrophoneProcessingIsLive() -> Bool {
        #if DEBUG
        if let state = debugIPhoneMicrophoneAudioProcessingStateOverride {
            let components = [
                state.echoCancellation,
                state.noiseSuppression,
                state.autoGainControl,
                state.highPassFilter
            ]
            return components.allSatisfy { component in
                component.requestedEnabled == false
                    && !component.softwareActive
                    && !component.platformActive
            }
        }
        #endif
        return rawSystemAudioProcessingIsLive()
    }

    private func rawIPhoneMicrophoneProcessingDiagnostic() -> String {
        let setterCode: String
        if let result = lastIPhoneMicrophoneRawProcessingResult,
           result.negotiationEpoch == negotiationEpoch {
            setterCode = String(result.codeRawValue)
        } else {
            setterCode = "nil"
        }

        #if DEBUG
        if let state = debugIPhoneMicrophoneAudioProcessingStateOverride {
            return "setterCode=\(setterCode) " + [
                ("AEC", state.echoCancellation),
                ("NS", state.noiseSuppression),
                ("AGC", state.autoGainControl),
                ("HPF", state.highPassFilter)
            ].map { name, component in
                "\(name){requested=\(String(describing: component.requestedEnabled)),"
                    + "softwareActive=\(component.softwareActive),"
                    + "platformActive=\(component.platformActive)}"
            }.joined(separator: " ")
        }
        #endif
        return "setterCode=\(setterCode) "
            + rawSystemAudioProcessingDiagnostic()
    }

    /// Sender attachment and offer application can install WebRTC's communication defaults after
    /// a source-level raw request was accepted, so every negotiation stores a fresh raw request.
    private func requestRawSystemAudioProcessing() throws {
        guard role == .host, let localAudioTrack else { return }
        let result = localAudioTrack.setAudioProcessingOptions(.raw())
        guard result.isSuccess else {
            throw WebRTCTransportError.nativeFailure(
                "WebRTC rejected raw system-audio processing: \(result.message)"
            )
        }
    }

    /// The native voice engine may apply a successful track option asynchronously. Keep captured
    /// PCM blocked for at most 200 ms and trust only the live factory state, never the setter result.
    private func awaitRawSystemAudioProcessing(
        admissionEpoch: UInt64,
        authorization: WebRTCAudioAuthorization
    ) async throws {
        for attempt in 0...20 {
            try requestRawSystemAudioProcessing()
            if rawSystemAudioProcessingIsLive() {
                return
            }
            if attempt == 20 {
                throw WebRTCTransportError.nativeFailure(
                    "WebRTC did not disable call-oriented processing within 200 ms: "
                        + rawSystemAudioProcessingDiagnostic()
                )
            }
            try await Task.sleep(for: .milliseconds(10))
            try authorization.withValidAuthorization {}
            guard systemAudioAdmissionEpoch == admissionEpoch,
                  pendingSystemAudioAuthorization === authorization,
                  localAudioTrack?.isEnabled == true,
                  isTransportHealthyForCapture() else {
                throw WebRTCTransportError.transportNotHealthy
            }
        }
    }

    private func rawSystemAudioProcessingIsLive() -> Bool {
        let state = factory.audioProcessingState
        let components = [
            state.echoCancellation,
            state.noiseSuppression,
            state.autoGainControl,
            state.highPassFilter
        ]
        return components.allSatisfy { component in
            component.requested?.isEnabled == false
                && !component.isSoftwareActive
                && !component.isPlatformActive
        }
    }

    private func rawSystemAudioProcessingDiagnostic() -> String {
        let state = factory.audioProcessingState
        return [
            ("AEC", state.echoCancellation),
            ("NS", state.noiseSuppression),
            ("AGC", state.autoGainControl),
            ("HPF", state.highPassFilter)
        ].map { name, component in
                "\(name){requested=\(String(describing: component.requested?.isEnabled)),"
                    + "softwareResolved=\(component.isSoftwareResolved),"
                    + "softwareActive=\(component.isSoftwareActive),"
                    + "platformResolved=\(component.isPlatformResolved),"
                    + "platformActive=\(component.isPlatformActive),"
                    + "effective=\(component.effective.rawValue)}"
        }.joined(separator: " ")
    }

    #if os(iOS)
    private func iPhoneMicrophoneNativeStageIsCurrent(
        authorization: WebRTCIOSMicrophoneAuthorization,
        recordingGeneration: UInt64,
        baselineRealtimeAdmissionCount: UInt64,
        baselineDeliveryCallbackCount: UInt64,
        baselineDeliveredFrameCount: UInt64
    ) -> Bool {
        guard let device = iOSStereoPlayoutAudioDevice,
              recordingGeneration != 0,
              authorization.isValid,
              authorization.recordingGeneration == recordingGeneration else {
            return false
        }

        let diagnostics = device.diagnostics
        return diagnostics.initialized
            && diagnostics.playoutInitialized
            && diagnostics.playing
            && diagnostics.sessionActive
            && diagnostics.ownsSessionActivation
            && diagnostics.remoteIOCreated
            && diagnostics.inputBusEnabled
            && diagnostics.outputBusEnabled
            && diagnostics.categoryIsMediaPlayAndRecord
            && diagnostics.modeIsDefault
            && !diagnostics.recoveryRequired
            && !diagnostics.explicitResumeRequired
            && !diagnostics.hostedCallMode
            && diagnostics.microphoneDeviceGateClosedAndDrained
            && !diagnostics.microphoneAuthorizationGatePublished
            && diagnostics.microphoneRecordingGeneration
                == recordingGeneration
            && diagnostics.approvedMicrophoneRecordingGeneration == 0
            && diagnostics.microphoneRealtimeAdmissionCount
                == baselineRealtimeAdmissionCount
            && diagnostics.microphoneDeliveryCallbackCount
                == baselineDeliveryCallbackCount
            && diagnostics.microphoneDeliveredFrameCount
                == baselineDeliveredFrameCount
    }

    private func iPhoneMicrophoneNativeApprovalIsCurrent(
        authorization: WebRTCIOSMicrophoneAuthorization,
        recordingGeneration: UInt64
    ) -> Bool {
        guard let device = iOSStereoPlayoutAudioDevice,
              recordingGeneration != 0,
              authorization.isValid,
              authorization.recordingGeneration == recordingGeneration else {
            return false
        }

        let diagnostics = device.diagnostics
        return diagnostics.initialized
            && diagnostics.playoutInitialized
            && diagnostics.playing
            && diagnostics.sessionActive
            && diagnostics.ownsSessionActivation
            && diagnostics.remoteIOCreated
            && diagnostics.inputBusEnabled
            && diagnostics.outputBusEnabled
            && diagnostics.categoryIsMediaPlayAndRecord
            && diagnostics.modeIsDefault
            && !diagnostics.recoveryRequired
            && !diagnostics.explicitResumeRequired
            && !diagnostics.hostedCallMode
            && !diagnostics.microphoneDeviceGateClosedAndDrained
            && diagnostics.microphoneAuthorizationGatePublished
            && diagnostics.microphoneRecordingGeneration
                == recordingGeneration
            && diagnostics.approvedMicrophoneRecordingGeneration
                == recordingGeneration
    }
    #endif

    private func suspendIPhoneMicrophoneForTransportUncertainty() async -> Bool {
        localIPhoneMicrophoneTrack?.isEnabled = false
        #if os(iOS)
        iPhoneMicrophoneNativeRecordingGeneration = 0
        let authorization = activeIPhoneMicrophoneAuthorization
        let authorizationIdentity = authorization.map {
            ObjectIdentifier($0)
        } ?? iPhoneMicrophoneNativeTeardownAuthorizationIdentity
        activeIPhoneMicrophoneAuthorization = nil
        authorization?.revoke()

        guard authorization != nil || iPhoneMicrophoneNativeTeardownPending else {
            return true
        }

        iPhoneMicrophoneNativeTeardownPending = true
        iPhoneMicrophoneNativeTeardownAuthorizationIdentity =
            authorizationIdentity
        let policyGeneration = advanceIPhoneMicrophonePolicyGeneration()
        let retirementContext = WebRTCIOSMicrophoneRetirementContext(
            startSequence: iPhoneMicrophonePolicySequence,
            retiringAuthorizationIdentity: authorizationIdentity
        )
        iPhoneMicrophoneRetirementContext = retirementContext
        defer {
            if iPhoneMicrophoneRetirementContext === retirementContext {
                iPhoneMicrophoneRetirementContext = nil
            }
        }

        guard let iPhoneMicrophoneTransportSuspensionHandler else {
            failClosedForEventDeliveryLoss(
                "The application microphone policy owner was unavailable during transport suspension."
            )
            return false
        }

        #if DEBUG
        if let hook = debugIPhoneMicrophonePreSuspensionHandlerHook {
            debugIPhoneMicrophonePreSuspensionHandlerHook = nil
            await hook(retirementContext)
        }
        #endif

        guard let outputOnlyToken =
            await iPhoneMicrophoneTransportSuspensionHandler(
                retirementContext
            ) else {
            failClosedForEventDeliveryLoss(
                "The application could not authorize output-only microphone teardown."
            )
            return false
        }

        let selectedToken = retirementContext.selectToken(outputOnlyToken)
        guard selectedToken === outputOnlyToken else {
            failClosedForEventDeliveryLoss(
                "The application returned a conflicting output-only microphone token."
            )
            return false
        }

        #if DEBUG
        if let hook = debugIPhoneMicrophonePostSuspensionHandlerHook {
            debugIPhoneMicrophonePostSuspensionHandlerHook = nil
            await hook(retirementContext, outputOnlyToken)
        }
        #endif

        guard !isClosed else { return false }

        if activeIPhoneMicrophoneAuthorization != nil {
            outputOnlyToken.revoke()
            return false
        }

        if policyGeneration != iPhoneMicrophonePolicyGeneration
            || retirementContext.startSequence
                != iPhoneMicrophonePolicySequence {
            guard iPhoneMicrophoneRetirementWasCompleted(
                retirementContext,
                token: outputOnlyToken
            ) else {
                failClosedForEventDeliveryLoss(
                    "Microphone policy ownership changed during transport suspension."
                )
                return false
            }
            return true
        }

        let applied = performIPhoneMicrophoneOutputOnlyDisable(
            retiringAuthorization: authorization,
            retiringAuthorizationIdentity: authorizationIdentity,
            token: outputOnlyToken,
            origin: .transportSuspension,
            retirementContext: retirementContext
        )
        guard applied,
              iPhoneMicrophoneRetirementWasCompleted(
                retirementContext,
                token: outputOnlyToken
              ) else {
            failClosedForEventDeliveryLoss(
                "The native output-only microphone policy could not be restored."
            )
            return false
        }
        return true
        #else
        return true
        #endif
    }

    #if os(iOS)
    private func iPhoneMicrophoneRetirementWasCompleted(
        _ retirementContext: WebRTCIOSMicrophoneRetirementContext,
        token: WebRTCIOSOutputOnlyMicrophoneToken
    ) -> Bool {
        guard token.state == .succeeded,
              let latestIPhoneMicrophonePolicyCompletionStamp,
              latestIPhoneMicrophonePolicyCompletionStamp.sequence
                == iPhoneMicrophonePolicySequence,
              latestIPhoneMicrophonePolicyCompletionStamp.sequence
                > retirementContext.startSequence,
              latestIPhoneMicrophonePolicyCompletionStamp.kind
                == .outputOnlyDisable,
              latestIPhoneMicrophonePolicyCompletionStamp.retirementID
                == retirementContext.retirementID,
              latestIPhoneMicrophonePolicyCompletionStamp
                .retiredAuthorizationIdentity
                == retirementContext.retiringAuthorizationIdentity,
              latestIPhoneMicrophonePolicyCompletionStamp.tokenID
                == token.tokenID,
              latestIPhoneMicrophonePolicyCompletionStamp.nativeResult,
              activeIPhoneMicrophoneAuthorization == nil,
              localIPhoneMicrophoneTrack?.isEnabled != true,
              !iPhoneMicrophoneNativeTeardownPending else {
            return false
        }
        return true
    }
    #endif

    /// Permanent close and event-delivery loss cannot depend on an application
    /// event handler. Revoke any remaining sender ownership and synchronously
    /// restore the native output-only policy.
    private func forceIPhoneMicrophoneNativeTeardown() {
        #if os(iOS)
        // A dropped close event can re-enter terminal cleanup before `isClosed` flips. Fence the
        // permanent episode before touching sender, token, sequence, or native policy state.
        guard !iPhoneMicrophoneTerminalCleanupHasStarted else {
            return
        }
        iPhoneMicrophoneTerminalCleanupHasStarted = true
        #endif
        localIPhoneMicrophoneTrack?.isEnabled = false
        #if os(iOS)
        iPhoneMicrophoneNativeRecordingGeneration = 0
        defer {
            iPhoneMicrophoneRetirementContext = nil
            #if DEBUG
            debugIPhoneMicrophonePreSuspensionHandlerHook = nil
            debugIPhoneMicrophonePostSuspensionHandlerHook = nil
            #endif
        }

        guard !iPhoneMicrophoneOutputOnlyWasAlreadyReached(
            requestedAuthorizationIdentity: nil
        ) else {
            return
        }

        let authorization = activeIPhoneMicrophoneAuthorization
        let authorizationIdentity = authorization.map {
            ObjectIdentifier($0)
        } ?? iPhoneMicrophoneNativeTeardownAuthorizationIdentity
        let teardownWasPending =
            iPhoneMicrophoneNativeTeardownPending
        activeIPhoneMicrophoneAuthorization = nil
        authorization?.revoke()

        guard authorization != nil || teardownWasPending else {
            return
        }

        iPhoneMicrophoneNativeTeardownPending = true
        iPhoneMicrophoneNativeTeardownAuthorizationIdentity =
            authorizationIdentity

        let attemptStartSequence = iPhoneMicrophonePolicySequence
        if let retirementContext = iPhoneMicrophoneRetirementContext,
           retirementContext.startSequence == attemptStartSequence,
           retirementContext.retiringAuthorizationIdentity
                == authorizationIdentity,
           retirementContext.executingToken == nil,
           let token = retirementContext.selectedToken,
           token.state == .armed,
           token.target == Self.iPhoneMicrophoneOutputOnlyTarget {
            _ = performIPhoneMicrophoneOutputOnlyDisable(
                retiringAuthorization: authorization,
                retiringAuthorizationIdentity: authorizationIdentity,
                token: token,
                origin: .terminalCleanup,
                retirementContext: retirementContext
            )
        }

        guard iPhoneMicrophonePolicySequence == attemptStartSequence else {
            return
        }

        // A stale or revoked application token cannot suppress terminal cleanup.
        // If no exact selected token claimed a write, install one peer-owned operation.
        _ = iPhoneMicrophoneRetirementContext?
            .selectedToken?
            .revoke()
        let retirementContext =
            WebRTCIOSMicrophoneRetirementContext(
                startSequence: attemptStartSequence,
                retiringAuthorizationIdentity: authorizationIdentity
            )
        let token = WebRTCIOSOutputOnlyMicrophoneToken(
            ownerEpoch: iPhoneMicrophoneTerminalCleanupOwnerEpoch,
            lifecycleGeneration: iPhoneMicrophonePolicyGeneration,
            target: Self.iPhoneMicrophoneOutputOnlyTarget
        )
        _ = retirementContext.selectToken(token)
        iPhoneMicrophoneRetirementContext = retirementContext
        _ = performIPhoneMicrophoneOutputOnlyDisable(
            retiringAuthorization: authorization,
            retiringAuthorizationIdentity: authorizationIdentity,
            token: token,
            origin: .terminalCleanup,
            retirementContext: retirementContext
        )
        #endif
    }

    private func ensureOpen() throws {
        if isClosed { throw WebRTCTransportError.transportClosed }
    }

    private func closeTransport() {
        guard !isClosed else { return }
        resetMacHostedCallEvidenceTransportState()
        suspendSystemAudioForTransportUncertainty()
        forceIPhoneMicrophoneNativeTeardown()
        #if os(iOS)
        iPhoneMicrophoneTransportSuspensionHandler = nil
        #endif
        disableRemoteAudioPlayback()
        localVideoTrack?.isEnabled = false
        invalidateInputSession(reason: "WebRTC transport closed.")
        guard !isClosed else { return }
        isClosed = true
        statisticsTask?.cancel()
        statisticsTask = nil
        delegateEventTask?.cancel()
        delegateEventTask = nil
        invalidateIPhoneMicrophoneSenderBinding()
        negotiationEpoch &+= 1
        outstandingLocalOfferEpoch = nil
        applyingRemoteAnswerEpoch = nil
        applyingRemoteOfferEpoch = nil
        localICEUsernameFragmentMap = nil
        remoteICEUsernameFragmentMap = nil
        requiresCandidateUsernameFragment = false
        pendingLocalCandidates.removeAll(keepingCapacity: false)
        pendingRemoteCandidates.removeAll(keepingCapacity: false)
        delegateProxy.close()
        peerConnection.close()
        eventContinuation.finish()
    }

    #if DEBUG && os(iOS)
    private var debugIPhoneMicrophonePreSuspensionHandlerHook:
        (@Sendable @MainActor (
            WebRTCIOSMicrophoneRetirementContext
        ) async -> Void)?
    private var debugIPhoneMicrophonePostSuspensionHandlerHook:
        (@Sendable @MainActor (
            WebRTCIOSMicrophoneRetirementContext,
            WebRTCIOSOutputOnlyMicrophoneToken?
        ) async -> Void)?

    func debugInstallIPhoneMicrophonePolicyApplier(
        _ applier: @escaping @Sendable (Bool) -> Bool
    ) {
        debugIPhoneMicrophonePolicyApplier = applier
    }

    func debugInstallIPhoneMicrophoneStageFailureForTesting(
        _ diagnostics: WebRTCIOSPlayoutDiagnostics
    ) {
        debugIPhoneMicrophoneStageFailureDiagnostics = diagnostics
        debugIPhoneMicrophoneStageFailureReason = nil
    }

    func debugInstallIPhoneMicrophoneStageFailureForTesting(
        _ diagnostics: WebRTCIOSPlayoutDiagnostics,
        reason: WebRTCIOSMicrophoneStageFailureReason
    ) {
        debugIPhoneMicrophoneStageFailureDiagnostics = diagnostics
        debugIPhoneMicrophoneStageFailureReason = reason
    }

    func debugEnableIPhoneMicrophoneThroughNativeStageForTesting(
        _ authorization: WebRTCIOSMicrophoneAuthorization
    ) async throws {
        try await enableIPhoneMicrophone(
            authorization: authorization,
            requiresHealthyTransport: false,
            requiresRawNegotiatedSenderProof: true
        )
    }

    func debugInstallIPhoneMicrophonePreSuspensionHandlerHook(
        _ hook: @escaping @Sendable @MainActor (
            WebRTCIOSMicrophoneRetirementContext
        ) async -> Void
    ) {
        debugIPhoneMicrophonePreSuspensionHandlerHook = hook
    }

    func debugInstallIPhoneMicrophonePostSuspensionHandlerHook(
        _ hook: @escaping @Sendable @MainActor (
            WebRTCIOSMicrophoneRetirementContext,
            WebRTCIOSOutputOnlyMicrophoneToken?
        ) async -> Void
    ) {
        debugIPhoneMicrophonePostSuspensionHandlerHook = hook
    }

    func debugEnableIPhoneMicrophoneIgnoringTransportForTests(
        _ authorization: WebRTCIOSMicrophoneAuthorization
    ) async throws {
        try await enableIPhoneMicrophone(
            authorization: authorization,
            requiresHealthyTransport: false,
            requiresRawNegotiatedSenderProof: false
        )
    }

    func debugInstallIPhoneMicrophoneAuthorizationForTransportUncertainty(
        _ authorization: WebRTCIOSMicrophoneAuthorization
    ) {
        _ = advanceIPhoneMicrophonePolicyGeneration()
        activeIPhoneMicrophoneAuthorization?.revoke()
        activeIPhoneMicrophoneAuthorization = authorization
        iPhoneMicrophoneNativeTeardownPending = false
        iPhoneMicrophoneNativeTeardownAuthorizationIdentity = nil
        iPhoneMicrophoneRetirementContext = nil
        localIPhoneMicrophoneTrack?.isEnabled = true
    }

    func debugSimulateICETransportUncertainty() async {
        await consume(.iceState(.disconnected))
    }

    var isIPhoneMicrophoneNativeTeardownPendingForTesting: Bool {
        iPhoneMicrophoneNativeTeardownPending
    }

    var isIPhoneMicrophoneEnabledForTesting: Bool {
        localIPhoneMicrophoneTrack?.isEnabled == true
            && activeIPhoneMicrophoneAuthorization?.isValid == true
    }

    var debugIPhoneMicrophonePolicySnapshot:
        WebRTCIOSMicrophonePolicySnapshot {
        WebRTCIOSMicrophonePolicySnapshot(
            generation: iPhoneMicrophonePolicyGeneration,
            sequence: iPhoneMicrophonePolicySequence,
            activeAuthorizationIdentity:
                activeIPhoneMicrophoneAuthorization.map {
                    ObjectIdentifier($0)
                },
            nativeTeardownAuthorizationIdentity:
                iPhoneMicrophoneNativeTeardownAuthorizationIdentity,
            trackIsEnabled:
                localIPhoneMicrophoneTrack?.isEnabled == true,
            nativeTeardownPending:
                iPhoneMicrophoneNativeTeardownPending,
            completionStamp:
                latestIPhoneMicrophonePolicyCompletionStamp,
            retirementID:
                iPhoneMicrophoneRetirementContext?.retirementID
        )
    }

    #endif

    /// Mute native receive rendering synchronously at transport boundaries. Keeping the wrapper
    /// lets a recovered application session explicitly re-enable the same negotiated track after
    /// it has re-proved health, without depending on a second receiver callback.
    private func disableRemoteAudioPlayback() {
        currentRemoteAudioTrack?.setEnabled(false)
    }

    private static func preferH264(
        on transceiver: LKRTCRtpTransceiver,
        capabilities: LKRTCRtpCapabilities
    ) throws {
        let codecs = capabilities.codecs.filter { codec in
            let mimeType = (codec.mimeType as String).lowercased()
            return mimeType == "video/h264"
                || mimeType == "video/rtx"
                || mimeType == "video/red"
                || mimeType == "video/ulpfec"
                || mimeType == "video/flexfec-03"
        }
        guard codecs.contains(where: {
            ($0.mimeType as String).caseInsensitiveCompare("video/H264") == .orderedSame
        }) else {
            throw WebRTCTransportError.videoTrackCreationFailed
        }

        do {
            _ = try transceiver.setCodecPreferences(codecs, error: ())
        } catch {
            throw WebRTCTransportError.nativeFailure(error.localizedDescription)
        }
    }

    private static func preferOpus(
        on transceiver: LKRTCRtpTransceiver,
        capabilities: LKRTCRtpCapabilities
    ) throws {
        let codecs = capabilities.codecs.filter {
            ($0.mimeType as String).caseInsensitiveCompare("audio/opus") == .orderedSame
        }
        guard !codecs.isEmpty else {
            throw WebRTCTransportError.audioTrackCreationFailed
        }

        do {
            _ = try transceiver.setCodecPreferences(codecs, error: ())
        } catch {
            throw WebRTCTransportError.nativeFailure(error.localizedDescription)
        }
    }

    private static func applyHighFidelityAudioSenderParameters(
        to sender: LKRTCRtpSender
    ) throws {
        let parameters = sender.parameters
        guard !parameters.encodings.isEmpty else {
            throw WebRTCTransportError.nativeFailure(
                "The system-audio sender did not expose an RTP encoding."
            )
        }

        for encoding in parameters.encodings {
            encoding.maxBitrateBps = NSNumber(value: OpusStereoSDP.maximumAverageBitrateBps)
            encoding.minBitrateBps = nil
        }
        sender.parameters = parameters

        let appliedEncodings = sender.parameters.encodings
        guard appliedEncodings.count == parameters.encodings.count,
              appliedEncodings.allSatisfy({
                  $0.maxBitrateBps?.intValue == OpusStereoSDP.maximumAverageBitrateBps
                      && $0.minBitrateBps == nil
              }) else {
            throw WebRTCTransportError.nativeFailure(
                "WebRTC rejected the high-fidelity system-audio bitrate policy."
            )
        }
    }

    private static func containsTURNServer(_ server: RemoteICEServer) -> Bool {
        server.urls.contains {
            let value = $0.lowercased()
            return value.hasPrefix("turn:") || value.hasPrefix("turns:")
        }
    }

    private static func nativeError(
        _ error: (any Error)?,
        fallback: WebRTCTransportError
    ) -> WebRTCTransportError {
        if let error {
            return .nativeFailure(error.localizedDescription)
        }
        return fallback
    }
}

/// Strict versioned union carried by the ordered WebRTC control data channel.
enum ControlChannelMessage: Codable, Equatable, Sendable {
    static let currentVersion = 2

    case command(WebRTCControlRequest)
    case acknowledgement(WebRTCControlAcknowledgement)
    case input(WebRTCInputRequest)
    case inputFeedback(WebRTCInputFeedback)
    case macHostedCallChallenge(WebRTCMacHostedCallChallenge)
    case macHostedCallEvidence(WebRTCMacHostedCallEvidence)

    private enum Kind: String, Codable {
        case command
        case acknowledgement = "ack"
        case input
        case inputFeedback
        case macHostedCallChallenge
        case macHostedCallEvidence
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case kind
        case command
        case acknowledgement
        case input
        case inputFeedback
        case macHostedCallChallenge
        case macHostedCallEvidence
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported control-channel version."
            )
        }
        switch try container.decode(Kind.self, forKey: .kind) {
        case .command:
            self = .command(try container.decode(WebRTCControlRequest.self, forKey: .command))
        case .acknowledgement:
            self = .acknowledgement(
                try container.decode(WebRTCControlAcknowledgement.self, forKey: .acknowledgement)
            )
        case .input:
            self = .input(try container.decode(WebRTCInputRequest.self, forKey: .input))
        case .inputFeedback:
            self = .inputFeedback(
                try container.decode(WebRTCInputFeedback.self, forKey: .inputFeedback)
            )
        case .macHostedCallChallenge:
            self = .macHostedCallChallenge(
                try container.decode(
                    WebRTCMacHostedCallChallenge.self,
                    forKey: .macHostedCallChallenge
                )
            )
        case .macHostedCallEvidence:
            self = .macHostedCallEvidence(
                try container.decode(
                    WebRTCMacHostedCallEvidence.self,
                    forKey: .macHostedCallEvidence
                )
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        switch self {
        case .command(let command):
            try container.encode(Kind.command, forKey: .kind)
            try container.encode(command, forKey: .command)
        case .acknowledgement(let acknowledgement):
            try container.encode(Kind.acknowledgement, forKey: .kind)
            try container.encode(acknowledgement, forKey: .acknowledgement)
        case .input(let request):
            try container.encode(Kind.input, forKey: .kind)
            try container.encode(request, forKey: .input)
        case .inputFeedback(let feedback):
            try container.encode(Kind.inputFeedback, forKey: .kind)
            try container.encode(feedback, forKey: .inputFeedback)
        case .macHostedCallChallenge(let challenge):
            try container.encode(
                Kind.macHostedCallChallenge,
                forKey: .kind
            )
            try container.encode(
                challenge,
                forKey: .macHostedCallChallenge
            )
        case .macHostedCallEvidence(let evidence):
            try container.encode(
                Kind.macHostedCallEvidence,
                forKey: .kind
            )
            try container.encode(
                evidence,
                forKey: .macHostedCallEvidence
            )
        }
    }
}

private enum WebRTCRuntime {
    static let isInitialized = LKRTCInitializeSSL()
}
