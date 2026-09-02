import Foundation

/// Privacy-reduced ICE candidate classes used by diagnostics.
public enum WebRTCCandidateType: String, Codable, Sendable {
    case host
    case serverReflexive
    case peerReflexive
    case relay
    case unknown
}

/// Non-address ICE candidate metadata sufficient to explain direct versus relayed routing.
public struct WebRTCCandidateDiagnostics: Codable, Equatable, Sendable {
    public let type: WebRTCCandidateType
    public let transport: String?
    public let networkType: String?
    public let relayProtocol: String?

    public init(
        type: WebRTCCandidateType,
        transport: String? = nil,
        networkType: String? = nil,
        relayProtocol: String? = nil
    ) {
        self.type = type
        self.transport = transport
        self.networkType = networkType
        self.relayProtocol = relayProtocol
    }
}

/// Whether the selected ICE pair is peer-to-peer, TURN-relayed, or not yet classified.
public enum WebRTCICERouteKind: String, Codable, Sendable {
    case direct
    case relayed
    case unknown
}

/// The privacy-reduced local and remote candidates in the selected ICE route.
public struct WebRTCICERouteDiagnostics: Codable, Equatable, Sendable {
    public let kind: WebRTCICERouteKind
    public let local: WebRTCCandidateDiagnostics?
    public let remote: WebRTCCandidateDiagnostics?

    public init(
        kind: WebRTCICERouteKind,
        local: WebRTCCandidateDiagnostics? = nil,
        remote: WebRTCCandidateDiagnostics? = nil
    ) {
        self.kind = kind
        self.local = local
        self.remote = remote
    }
}

/// Stable outbound or inbound video counters extracted from a native statistics report.
public struct WebRTCVideoStatistics: Codable, Equatable, Sendable {
    public let bytes: UInt64?
    public let packets: UInt64?
    public let packetsLost: Int64?
    public let totalPacketSendDelay: Double?
    public let framesPerSecond: Double?
    public let frameWidth: Int?
    public let frameHeight: Int?
    public let framesEncodedOrDecoded: UInt64?

    public init(
        bytes: UInt64? = nil,
        packets: UInt64? = nil,
        packetsLost: Int64? = nil,
        totalPacketSendDelay: Double? = nil,
        framesPerSecond: Double? = nil,
        frameWidth: Int? = nil,
        frameHeight: Int? = nil,
        framesEncodedOrDecoded: UInt64? = nil
    ) {
        self.bytes = bytes
        self.packets = packets
        self.packetsLost = packetsLost
        self.totalPacketSendDelay = totalPacketSendDelay
        self.framesPerSecond = framesPerSecond
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.framesEncodedOrDecoded = framesEncodedOrDecoded
    }
}

/// Release-safe ownership, processing, topology, and native-delivery state for the exact current
/// iPhone microphone sender. Native sender/track identifiers and object identities remain private
/// to `WebRTCPeer`; this projection carries only ephemeral generations and bounded state.
public struct WebRTCIPhoneMicrophoneSenderDiagnostics: Equatable, Sendable {
    public let peerEpoch: UUID
    public let bindingGeneration: UInt64
    public let negotiationEpoch: UInt64
    public let trackGeneration: UInt64
    public let microphonePolicyGeneration: UInt64
    public let senderOwnsMID: Bool
    public let senderOwnsLocalTrack: Bool
    public let transceiverIsStopped: Bool
    public let preferredDirectionIncludesSending: Bool
    public let currentDirectionIncludesSending: Bool
    public let trackIsEnabled: Bool
    public let rawProcessingIsLive: Bool
    public let transportIsHealthy: Bool
    public let authorizationIsCurrent: Bool
    public let authorizationIsValid: Bool
    public let senderIsAdmitted: Bool
    public let nativeDeviceIsOpen: Bool
    public let nativeDeviceGateIsOpen: Bool
    public let nativeAuthorizationGateIsOpen: Bool
    public let categoryIsPlayAndRecord: Bool
    public let modeIsDefault: Bool
    public let usesRemoteIO: Bool
    public let inputBusEnabled: Bool
    /// True only when native live-route diagnostics saw exactly the built-in iPhone microphone.
    public let captureRouteIsBuiltInMicrophone: Bool
    /// Ephemeral native exact-route publication generation; rotates across every revalidation.
    public let captureRouteProofGeneration: UInt64
    public let outputBusEnabled: Bool
    public let categoryOptionsAreEmpty: Bool
    public let categoryOptionsAreIPhoneMicrophoneRouting: Bool
    public let routeSharingPolicyIsDefault: Bool
    public let hasOutputRoute: Bool
    public let sampleRateIs48k: Bool
    public let ioBufferDurationIsBounded: Bool
    public let outputChannelCountIsStereo: Bool
    public let recoveryRequired: Bool
    public let explicitResumeRequired: Bool
    public let hostedCallMode: Bool
    public let failureCode: Int
    public let lastLifecycleStatus: Int32
    public let recordingGeneration: UInt64
    public let approvedRecordingGeneration: UInt64
    public let realtimeAdmissionCount: UInt64
    public let deliveryCallbackCount: UInt64
    public let deliveredFrameCount: UInt64
}

/// Exact sender-scoped outbound evidence for the current admitted iPhone microphone sender.
///
/// This proves only that current native microphone delivery and that exact sender's outbound RTP
/// advanced coherently. It does not claim that BlackHole or another Mac application consumed it.
public struct WebRTCIPhoneMicrophoneSenderStatistics: Equatable, Sendable {
    public let collectedAt: Date
    public let sender: WebRTCIPhoneMicrophoneSenderDiagnostics
    public let packetsSent: UInt64
    public let bytesSent: UInt64
    public let totalAudioEnergy: Double?
    public let totalSamplesDuration: Double?
    public let sourceReportWasLinked: Bool
}

/// Stable audio quality, concealment, jitter-buffer, and transport counters.
public struct WebRTCAudioStatistics: Codable, Equatable, Sendable {
    public let bytes: UInt64?
    public let packets: UInt64?
    public let packetsLost: Int64?
    public let packetsDiscarded: UInt64?
    public let jitter: Double?
    public let jitterBufferDelay: Double?
    public let jitterBufferEmittedCount: UInt64?
    public let jitterBufferTargetDelay: Double?
    public let jitterBufferMinimumDelay: Double?
    public let totalSamplesReceived: UInt64?
    public let concealedSamples: UInt64?
    public let silentConcealedSamples: UInt64?
    public let concealmentEvents: UInt64?
    public let insertedSamplesForDeceleration: UInt64?
    public let removedSamplesForAcceleration: UInt64?
    public let totalAudioEnergy: Double?
    public let totalSamplesDuration: Double?
    public let audioLevel: Double?
    public let totalPacketSendDelay: Double?
    public let nackCount: UInt64?
    public let targetBitrate: Double?
    public let roundTripTime: Double?

    public init(
        bytes: UInt64? = nil,
        packets: UInt64? = nil,
        packetsLost: Int64? = nil,
        packetsDiscarded: UInt64? = nil,
        jitter: Double? = nil,
        jitterBufferDelay: Double? = nil,
        jitterBufferEmittedCount: UInt64? = nil,
        jitterBufferTargetDelay: Double? = nil,
        jitterBufferMinimumDelay: Double? = nil,
        totalSamplesReceived: UInt64? = nil,
        concealedSamples: UInt64? = nil,
        silentConcealedSamples: UInt64? = nil,
        concealmentEvents: UInt64? = nil,
        insertedSamplesForDeceleration: UInt64? = nil,
        removedSamplesForAcceleration: UInt64? = nil,
        totalAudioEnergy: Double? = nil,
        totalSamplesDuration: Double? = nil,
        audioLevel: Double? = nil,
        totalPacketSendDelay: Double? = nil,
        nackCount: UInt64? = nil,
        targetBitrate: Double? = nil,
        roundTripTime: Double? = nil
    ) {
        self.bytes = bytes
        self.packets = packets
        self.packetsLost = packetsLost
        self.packetsDiscarded = packetsDiscarded
        self.jitter = jitter
        self.jitterBufferDelay = jitterBufferDelay
        self.jitterBufferEmittedCount = jitterBufferEmittedCount
        self.jitterBufferTargetDelay = jitterBufferTargetDelay
        self.jitterBufferMinimumDelay = jitterBufferMinimumDelay
        self.totalSamplesReceived = totalSamplesReceived
        self.concealedSamples = concealedSamples
        self.silentConcealedSamples = silentConcealedSamples
        self.concealmentEvents = concealmentEvents
        self.insertedSamplesForDeceleration = insertedSamplesForDeceleration
        self.removedSamplesForAcceleration = removedSamplesForAcceleration
        self.totalAudioEnergy = totalAudioEnergy
        self.totalSamplesDuration = totalSamplesDuration
        self.audioLevel = audioLevel
        self.totalPacketSendDelay = totalPacketSendDelay
        self.nackCount = nackCount
        self.targetBitrate = targetBitrate
        self.roundTripTime = roundTripTime
    }
}

/// A timestamped diagnostic snapshot across route, video, and audio statistics.
public struct WebRTCStatisticsSnapshot: Codable, Equatable, Sendable {
    public let collectedAt: Date
    /// The peer-local order in which the native statistics request was started. Synthetic and
    /// parser-only snapshots leave this unset because no native request was assigned to them.
    public let collectionSequence: UInt64?
    public let route: WebRTCICERouteDiagnostics?
    public let currentRoundTripTime: Double?
    public let availableOutgoingBitrate: Double?
    public let jitter: Double?
    public let outboundVideo: WebRTCVideoStatistics?
    public let inboundVideo: WebRTCVideoStatistics?
    public let audioSource: WebRTCAudioStatistics?
    public let outboundAudio: WebRTCAudioStatistics?
    public let inboundAudio: WebRTCAudioStatistics?
    public let remoteInboundAudio: WebRTCAudioStatistics?

    public init(
        collectedAt: Date = Date(),
        collectionSequence: UInt64? = nil,
        route: WebRTCICERouteDiagnostics? = nil,
        currentRoundTripTime: Double? = nil,
        availableOutgoingBitrate: Double? = nil,
        jitter: Double? = nil,
        outboundVideo: WebRTCVideoStatistics? = nil,
        inboundVideo: WebRTCVideoStatistics? = nil,
        audioSource: WebRTCAudioStatistics? = nil,
        outboundAudio: WebRTCAudioStatistics? = nil,
        inboundAudio: WebRTCAudioStatistics? = nil,
        remoteInboundAudio: WebRTCAudioStatistics? = nil
    ) {
        self.collectedAt = collectedAt
        self.collectionSequence = collectionSequence
        self.route = route
        self.currentRoundTripTime = currentRoundTripTime
        self.availableOutgoingBitrate = availableOutgoingBitrate
        self.jitter = jitter
        self.outboundVideo = outboundVideo
        self.inboundVideo = inboundVideo
        self.audioSource = audioSource
        self.outboundAudio = outboundAudio
        self.inboundAudio = inboundAudio
        self.remoteInboundAudio = remoteInboundAudio
    }
}

/// A failed STUN/TURN candidate probe. This is diagnostic evidence, not by itself a
/// transport failure: ICE can still select a healthy candidate from another interface
/// or server URL.
public struct WebRTCIceCandidateError: Codable, Equatable, Sendable {
    public let address: String
    public let port: Int
    public let url: String
    public let errorCode: Int
    public let reason: String

    public init(
        address: String,
        port: Int,
        url: String,
        errorCode: Int,
        reason: String
    ) {
        self.address = address
        self.port = port
        self.url = url
        self.errorCode = errorCode
        self.reason = reason
    }
}
