import Foundation
import RemoteSessionCore

/// Controls whether ICE may use direct candidates or must prove the TURN fallback.
public enum WebRTCICEPolicy: String, Codable, Sendable {
    /// Lets ICE prefer a peer-to-peer candidate while retaining configured TURN as the standards-based reachability fallback.
    case directPreferred
    /// Forces TURN so the production fallback can be tested even on an easy local network.
    case relayOnly
}

/// Immutable inputs used to construct one role-specific WebRTC peer.
public struct WebRTCTransportConfiguration: Sendable {
    public let role: RemotePeerRole
    public let iceServers: [RemoteICEServer]
    public let icePolicy: WebRTCICEPolicy
    public let maximumVideoBitrate: Int?

    public init(
        role: RemotePeerRole,
        iceServers: [RemoteICEServer],
        icePolicy: WebRTCICEPolicy = .directPreferred,
        maximumVideoBitrate: Int? = nil
    ) {
        self.role = role
        self.iceServers = iceServers
        self.icePolicy = icePolicy
        self.maximumVideoBitrate = maximumVideoBitrate
    }
}

/// Stable projection of the native peer-connection lifecycle.
public enum WebRTCPeerState: String, Codable, Sendable {
    case new
    case connecting
    case connected
    case disconnected
    case failed
    case closed
}

/// Stable projection of the native ICE connection lifecycle.
public enum WebRTCICEState: String, Codable, Sendable {
    case new
    case checking
    case connected
    case completed
    case disconnected
    case failed
    case closed
    case unknown
}

/// Stable projection of native candidate-gathering progress.
public enum WebRTCICEGatheringState: String, Codable, Sendable {
    case new
    case gathering
    case complete
}

/// Stable projection of the ordered control data-channel lifecycle.
public enum WebRTCDataChannelState: String, Codable, Sendable {
    case connecting
    case open
    case closing
    case closed
}

/// Typed native boundary for a staged iPhone microphone request. Only the first six reasons are
/// eligible for one bounded audio-recovery retry; lifecycle and authorization reasons remain
/// fail-closed until their owning boundary changes.
public enum WebRTCIOSMicrophoneStageFailureReason:
    String,
    Equatable,
    Sendable
{
    case delegateUnavailable
    case deviceNotInitialized
    case playoutNotReady
    case nativeRecoveryRequired
    case topologyRebuildFailed
    case topologyStillNotStaged
    case hostedCall
    case interrupted
    case explicitResumeRequired
    case authorizationInvalid
    case recordingGenerationBindFailed
    case deviceUnavailable
    case unknown

    public var permitsAutomaticAudioRecovery: Bool {
        switch self {
        case .delegateUnavailable,
             .deviceNotInitialized,
             .playoutNotReady,
             .nativeRecoveryRequired,
             .topologyRebuildFailed,
             .topologyStillNotStaged:
            true
        case .hostedCall,
             .interrupted,
             .explicitResumeRequired,
             .authorizationInvalid,
             .recordingGenerationBindFailed,
             .deviceUnavailable,
             .unknown:
            false
        }
    }

    public var isLifecycleControlled: Bool {
        switch self {
        case .hostedCall, .interrupted, .explicitResumeRequired:
            true
        case .delegateUnavailable,
             .deviceNotInitialized,
             .playoutNotReady,
             .nativeRecoveryRequired,
             .topologyRebuildFailed,
             .topologyStillNotStaged,
             .authorizationInvalid,
             .recordingGenerationBindFailed,
             .deviceUnavailable,
             .unknown:
            false
        }
    }
}


/// Bounded events emitted by `WebRTCPeer` to its signaling and media owner.
public enum WebRTCTransportEvent: Sendable {
    case outboundSignal(RemoteSignalPayload)
    case peerStateChanged(WebRTCPeerState)
    case iceStateChanged(WebRTCICEState)
    case iceGatheringStateChanged(WebRTCICEGatheringState)
    case dataChannelStateChanged(WebRTCDataChannelState)
    /// A new command for the host application to complete. The transport never acknowledges it itself.
    case controlRequestReceived(WebRTCControlRequest)
    /// The current viewer request was completed by the host. Stale and duplicate acknowledgements are suppressed.
    case controlAcknowledgementReceived(
        WebRTCControlAcknowledgement,
        inputAuthorization: WebRTCInputAuthorization?
    )
    /// A validated, session-bound input request for the host application to inject at most once.
    case inputRequestReceived(
        WebRTCInputRequest,
        authorization: WebRTCInputAuthorization
    )
    /// The host's result for a viewer input request. Duplicate feedback is suppressed.
    case inputFeedbackReceived(WebRTCInputFeedback)
    /// The input capability was fail-closed independently of screen media/control state.
    case inputSessionInvalidated(String)
    /// A current-peer viewer challenge that the Mac must satisfy with a fresh native process scan.
    case macHostedCallChallengeReceived(WebRTCMacHostedCallChallenge)
    /// Current-peer Mac-hosted call proof, or nil when any evidence boundary is uncertain.
    case macHostedCallEvidenceChanged(WebRTCMacHostedCallEvidence?)
    /// Host notice that the currently shown screen entered a negotiated suspension generation.
    case screenMediaSuspensionReceived(WebRTCScreenMediaSuspensionNotice)
    /// Viewer proof that its forced presentation cover is installed for the exact suspension.
    case screenMediaCoveredAcknowledgementReceived(
        WebRTCScreenMediaCoveredAcknowledgement
    )
    /// Exact encoder-domain marker boundary that the viewer must present under its cover.
    case screenMediaMarkerReadyReceived(WebRTCScreenMediaMarkerReady)
    /// Exact receiver-domain marker presentation returned to the host.
    case screenMediaMarkerPresentationReceived(
        WebRTCScreenMediaMarkerPresentation
    )
    /// Affine encoder-to-receiver RTP boundary for the first admissible real frame.
    case screenMediaResumeReadyReceived(WebRTCScreenMediaResumeReady)
    /// Viewer request to commit one exact presented real-frame proof.
    case screenMediaResumeRequestReceived(WebRTCScreenMediaResumeRequest)
    /// Host commit for the exact resume request. Input is installed only at this event.
    case screenMediaResumedAcknowledgementReceived(
        WebRTCScreenMediaResumedAcknowledgement,
        inputAuthorization: WebRTCInputAuthorization?
    )
    /// Immediate post-aligner encoder observation for the active negotiated resume probe.
    case screenMediaEncoderResumeProbeEvent(
        ScreenVideoEncoderResumeProbeEvent
    )
    /// The transient negotiated resume state was fail-closed. A cover must remain installed.
    case screenMediaSuspensionInvalidated(String)
    /// Legacy signaling control event. Worldwide data-channel control uses the typed request/ack events above.
    case controlReceived(RemoteControlCommand)
    case identityReceived(RemotePeerIdentity)
    case remoteAudioTrack(WebRTCRemoteAudioTrack)
    case remoteVideoTrack(WebRTCRemoteVideoTrack)
    case routeChanged(WebRTCICERouteDiagnostics)
    case statistics(WebRTCStatisticsSnapshot)
    case iceCandidateError(WebRTCIceCandidateError)
    case negotiationNeeded
    case ended(RemoteSessionEndReason)
    case diagnosticFailure(String)
}

/// Construction, signaling, authorization, and data-channel failures for WebRTC transport.
public enum WebRTCTransportError: Error, Equatable, LocalizedError, Sendable {
    case relayPolicyRequiresTURN
    case peerConnectionCreationFailed
    case audioTrackCreationFailed
    case videoTrackCreationFailed
    case dataChannelCreationFailed
    case invalidRole
    case alreadyStarted
    case iceRestartAlreadyInProgress
    case unexpectedSignal
    case invalidSessionDescription
    case invalidICECandidate
    case pendingRemoteCandidateLimitExceeded(Int)
    case dataChannelUnavailable
    case transportNotHealthy
    case dataChannelBackpressured
    case dataChannelSendFailed
    case controlRequestIDExhausted
    case controlAuthorizationRequired
    case controlAuthorizationRevoked
    case audioAuthorizationRevoked
    case macHostedCallEvidenceAuthorizationRevoked
    case unknownControlRequest(UInt64)
    case staleControlRequest(UInt64)
    case conflictingControlAcknowledgement(UInt64)
    case inputUnavailable
    case inputRequestIDExhausted
    case invalidInputCapability
    case invalidInputRequest
    case unknownInputRequest(UInt64)
    case staleInputRequest(UInt64)
    case conflictingInputFeedback(UInt64)
    case transportClosed
    case iPhoneMicrophoneStageFailed(
        reason: WebRTCIOSMicrophoneStageFailureReason,
        message: String
    )
    case nativeFailure(String)

    public var errorDescription: String? {
        switch self {
        case .relayPolicyRequiresTURN:
            "Relay-only testing requires at least one TURN server."
        case .peerConnectionCreationFailed:
            "The WebRTC peer connection could not be created."
        case .audioTrackCreationFailed:
            "The WebRTC system-audio track could not be created."
        case .videoTrackCreationFailed:
            "The WebRTC screen video track could not be created."
        case .dataChannelCreationFailed:
            "The WebRTC control channel could not be created."
        case .invalidRole:
            "This operation is not valid for the peer role."
        case .alreadyStarted:
            "The WebRTC peer has already started."
        case .iceRestartAlreadyInProgress:
            "An ICE restart offer is already awaiting its answer."
        case .unexpectedSignal:
            "The signaling message is not valid in the current peer state."
        case .invalidSessionDescription:
            "The remote session description is invalid."
        case .invalidICECandidate:
            "The remote ICE candidate is invalid."
        case .pendingRemoteCandidateLimitExceeded(let limit):
            "The pre-description remote ICE candidate limit (\(limit)) was exceeded."
        case .dataChannelUnavailable:
            "The WebRTC control channel is not open."
        case .transportNotHealthy:
            "The WebRTC transport is not stable and healthy enough for remote media capture."
        case .dataChannelBackpressured:
            "The WebRTC control channel is temporarily backpressured."
        case .dataChannelSendFailed:
            "The WebRTC control message could not be sent."
        case .controlRequestIDExhausted:
            "The WebRTC control request identifier space was exhausted."
        case .controlAuthorizationRequired:
            "An Active screen acknowledgement requires a current capture authorization."
        case .controlAuthorizationRevoked:
            "The screen-control authorization was revoked before capture could be exposed."
        case .audioAuthorizationRevoked:
            "The system-audio authorization was revoked before capture could be exposed."
        case .macHostedCallEvidenceAuthorizationRevoked:
            "The Mac-hosted-call evidence authorization was revoked before evidence could be published."
        case .unknownControlRequest(let id):
            "Control request \(id) is unknown."
        case .staleControlRequest(let id):
            "Control request \(id) is stale."
        case .conflictingControlAcknowledgement(let id):
            "Control request \(id) was already acknowledged with a different state."
        case .inputUnavailable:
            "Remote input is not authorized for the active screen session."
        case .inputRequestIDExhausted:
            "The remote-input request identifier space was exhausted."
        case .invalidInputCapability:
            "The remote-input capability is invalid for this screen request."
        case .invalidInputRequest:
            "The remote-input request is invalid."
        case .unknownInputRequest(let id):
            "Remote-input request \(id) is unknown."
        case .staleInputRequest(let id):
            "Remote-input request \(id) is stale."
        case .conflictingInputFeedback(let id):
            "Remote-input request \(id) was already completed with different feedback."
        case .transportClosed:
            "The WebRTC transport is closed."
        case .iPhoneMicrophoneStageFailed(_, let message):
            message
        case .nativeFailure(let message):
            message
        }
    }
}
