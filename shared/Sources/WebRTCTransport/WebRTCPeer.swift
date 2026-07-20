@preconcurrency import LiveKitWebRTC
#if os(macOS)
import MacWebRTCAudioDeviceShim
#elseif os(iOS)
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
struct WebRTCAudioSenderEncodingParameters: Equatable, Sendable {
    let maximumBitrateBps: Int?
    let minimumBitrateBps: Int?
}

struct WebRTCAudioProcessingComponentSnapshot: Equatable, Sendable {
    let requestedEnabled: Bool?
    let softwareActive: Bool
    let platformActive: Bool
}

struct WebRTCAudioProcessingSnapshot: Equatable, Sendable {
    let hasAudioProcessingModule: Bool
    let echoCancellation: WebRTCAudioProcessingComponentSnapshot
    let noiseSuppression: WebRTCAudioProcessingComponentSnapshot
    let autoGainControl: WebRTCAudioProcessingComponentSnapshot
    let highPassFilter: WebRTCAudioProcessingComponentSnapshot
}
#endif

#if os(iOS)
/// Revocable ownership for one explicit native RemoteIO recovery attempt.
///
/// The Objective-C gate is linearizable: revocation shares the lock held across the final native
/// rebuild, so an ADM block queued by a retired peer cannot reactivate audio for a newer session.
public final class WebRTCIOSPlayoutRecoveryAuthorization: @unchecked Sendable {
    fileprivate let native = ASIOSStereoPlayoutRecoveryAuthorization()

    public init() {}

    public var isValid: Bool { native.isValid }

    public func revoke() {
        native.revoke()
    }

    #if DEBUG
    @discardableResult
    public func performIfValidForTesting(_ operation: () -> Void) -> Bool {
        native.performIfValid(operation)
    }
    #endif
}

#if DEBUG
public struct WebRTCIOSPlayoutPublicationTestSnapshot: Equatable, Sendable {
    public let callbackCount: UInt64
    public let frameCount: UInt64
    public let failureCount: UInt64
    public let lastFrameCount: UInt32
    public let lastStatus: Int32
}

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
            lastFrameCount: value.lastFrameCount,
            lastStatus: value.lastStatus
        )
    }
}

public struct WebRTCIOSPlayoutRecoveryTestDiagnostics: Equatable, Sendable {
    public let requestCount: UInt64
    public let authorizationRejectionCount: UInt64
    public let rebuildCount: UInt64
    public let playoutCallbackCount: UInt64
    public let playoutFrameCount: UInt64
    public let playoutFailureCount: UInt64
    public let lastPlayoutFrameCount: UInt32
    public let lastPlayoutStatus: Int32
    public let sessionActive: Bool
    public let remoteIOCreated: Bool
}

public final class WebRTCIOSPlayoutRecoveryTestHarness: @unchecked Sendable {
    private let native = ASIOSStereoPlayoutRecoveryTestHarness()

    public init() {}

    public var queuedOperationCount: Int { Int(native.queuedOperationCount) }

    public var diagnostics: WebRTCIOSPlayoutRecoveryTestDiagnostics {
        let value = native.diagnostics
        return WebRTCIOSPlayoutRecoveryTestDiagnostics(
            requestCount: value.recoveryRequestCount,
            authorizationRejectionCount: value.recoveryAuthorizationRejectionCount,
            rebuildCount: value.recoveryRebuildCount,
            playoutCallbackCount: value.playoutCallbackCount,
            playoutFrameCount: value.playoutFrameCount,
            playoutFailureCount: value.playoutFailureCount,
            lastPlayoutFrameCount: value.lastPlayoutFrameCount,
            lastPlayoutStatus: value.lastPlayoutStatus,
            sessionActive: value.sessionActive,
            remoteIOCreated: value.remoteIOCreated
        )
    }

    public func publishCallback(frameCount: UInt32, status: Int32) {
        native.publishCallback(withFrameCount: frameCount, status: status)
    }

    public func queueRecovery(
        authorization: WebRTCIOSPlayoutRecoveryAuthorization
    ) {
        native.queueRecovery(authorization: authorization.native)
    }

    @discardableResult
    public func runNextQueuedOperation() -> Bool {
        native.runNextQueuedOperation()
    }
}
#endif

/// Runtime proof that iOS is using one output-only RemoteIO media path rather than WebRTC's
/// call-oriented default audio device or a duplicate application renderer.
public struct WebRTCIOSPlayoutDiagnostics: Sendable {
    public let initialized: Bool
    public let playoutInitialized: Bool
    public let playing: Bool
    public let sessionActive: Bool
    public let ownsSessionActivation: Bool
    public let remoteIOCreated: Bool
    public let inputBusEnabled: Bool
    public let outputBusEnabled: Bool
    public let recoveryRequired: Bool
    public let explicitResumeRequired: Bool
    public let categoryIsMediaPlayback: Bool
    public let modeIsDefault: Bool
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
    public let unexpectedRecordingRequestCount: UInt64
    public let recoveryRequestCount: UInt64
    public let recoveryAuthorizationRejectionCount: UInt64
    public let recoveryRebuildCount: UInt64
    public let lastPlayoutFrameCount: UInt32
    public let lastPlayoutStatus: Int32
}
#endif

public actor WebRTCPeer {
    private static let controlHistoryLimit = 256
    private static let inputHistoryLimit = 256
    private static let maximumPendingRemoteCandidateCount = 256
    private static let maximumCandidateBytes = 8_192
    private static let maximumCandidateMIDBytes = 128
    private static let maximumCandidateUsernameFragmentBytes = 256
    #if DEBUG && os(macOS)
    @TaskLocal private static var useHeadlessMacViewerAudioForTesting = false
    #endif

    public nonisolated let events: AsyncStream<WebRTCTransportEvent>
    public nonisolated let externalAudioCapturer: MacExternalAudioCapturer?
    public nonisolated let externalVideoCapturer: MacExternalVideoCapturer?

    private let role: RemotePeerRole
    private let eventContinuation: AsyncStream<WebRTCTransportEvent>.Continuation
    private let factory: LKRTCPeerConnectionFactory
    private let peerConnection: LKRTCPeerConnection
    private let delegateProxy: WebRTCDelegateProxy
    private let localAudioTrack: LKRTCAudioTrack?
    private let localVideoTrack: LKRTCVideoTrack?
    private let mediaConstraints: LKRTCMediaConstraints
    #if os(macOS)
    // The native custom-ADM factory is expected to retain its device, but keeping ownership
    // explicit also supports the DEBUG headless viewer used by hardware-independent codec tests.
    private let macStereoAudioDevice: ASMacStereoAudioDevice?
    #endif
    #if os(iOS)
    private let iOSStereoPlayoutAudioDevice: ASIOSStereoPlayoutAudioDevice?
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
            if isRestartOffer {
                requiresCandidateUsernameFragment = true
                pendingRemoteCandidates.removeAll(keepingCapacity: true)
                invalidateCurrentRoute()
                failCloseScreenMedia()
            }

            try await setRemoteDescription(sdp: sdp, type: .offer)
            try ensureOpen()
            guard applyingRemoteOfferEpoch == offerEpoch else {
                throw WebRTCTransportError.unexpectedSignal
            }
            try installRemoteICEUsernameFragments(from: sdp)
            remoteDescriptionIsSet = true
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
        failCloseScreenMedia()
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

    /// Compatibility spelling for callers that send a control command directly.
    @discardableResult
    public func sendControl(_ command: RemoteControlCommand) throws -> UInt64 {
        try requestControl(command)
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
        inputAuthorization: WebRTCInputAuthorization? = nil
    ) throws {
        try authorization.withValidAuthorization {
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
        inputAuthorization: WebRTCInputAuthorization? = nil
    ) throws {
        try acknowledgeControlRequestIfTransportHealthy(
            id: id,
            state: .active,
            authorization: authorization,
            inputCapability: inputCapability,
            inputAuthorization: inputAuthorization
        )
    }

    /// Sends one input operation using the capability from the most recent Show/Active ACK.
    /// Input IDs are monotonic independently of screen-control request IDs.
    @discardableResult
    public func requestInput(_ action: WebRTCInputAction) throws -> UInt64 {
        guard let activeViewerInputCapability,
              let activeViewerInputAuthorization else {
            throw WebRTCTransportError.inputUnavailable
        }
        return try requestInput(
            action,
            capability: activeViewerInputCapability,
            authorization: activeViewerInputAuthorization
        )
    }

    /// Explicit-capability spelling lets UI code reject a stale task captured before a new
    /// Show/Active generation. The supplied capability must still equal the peer's current one.
    @discardableResult
    public func requestInput(
        _ action: WebRTCInputAction,
        capability: WebRTCInputCapability
    ) throws -> UInt64 {
        guard let activeViewerInputAuthorization else {
            throw WebRTCTransportError.inputUnavailable
        }
        return try requestInput(
            action,
            capability: capability,
            authorization: activeViewerInputAuthorization
        )
    }

    /// The explicit authorization closes the gap between UI cancellation and the final native
    /// data-channel send. Revocation waits for an in-progress send, or wins before it starts.
    @discardableResult
    public func requestInput(
        _ action: WebRTCInputAction,
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
            action: action
        )
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
    public func sendInput(_ action: WebRTCInputAction) throws -> UInt64 {
        try requestInput(action)
    }

    @discardableResult
    public func sendInput(
        _ action: WebRTCInputAction,
        capability: WebRTCInputCapability
    ) throws -> UInt64 {
        try requestInput(action, capability: capability)
    }

    @discardableResult
    public func sendInput(
        _ action: WebRTCInputAction,
        capability: WebRTCInputCapability,
        authorization: WebRTCInputAuthorization
    ) throws -> UInt64 {
        try requestInput(
            action,
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
        authorization?.revoke()
        if pendingAuthorization !== authorization {
            pendingAuthorization?.revoke()
        }
    }

    public func remoteAudioTrack() -> WebRTCRemoteAudioTrack? {
        currentRemoteAudioTrack
    }

    public func remoteVideoTrack() -> WebRTCRemoteVideoTrack? {
        currentRemoteVideoTrack
    }

    public func routeDiagnostics() -> WebRTCICERouteDiagnostics? {
        currentRoute
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
            outputBusEnabled: value.outputBusEnabled,
            recoveryRequired: value.recoveryRequired,
            explicitResumeRequired: value.explicitResumeRequired,
            categoryIsMediaPlayback: value.categoryIsMediaPlayback,
            modeIsDefault: value.modeIsDefault,
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
            unexpectedRecordingRequestCount: value.unexpectedRecordingRequestCount,
            recoveryRequestCount: value.recoveryRequestCount,
            recoveryAuthorizationRejectionCount:
                value.recoveryAuthorizationRejectionCount,
            recoveryRebuildCount: value.recoveryRebuildCount,
            lastPlayoutFrameCount: value.lastPlayoutFrameCount,
            lastPlayoutStatus: value.lastPlayoutStatus
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
    #endif

    /// A fresh native snapshot used in addition to application-owned recovery gates before the
    /// host enables capture. It is deliberately not the ICE-restart success oracle: libwebrtc can
    /// keep these states connected while a restart is being negotiated.
    public func isTransportHealthyForCapture() -> Bool {
        guard role == .host,
              hasStarted,
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

    public func statisticsSnapshot() async -> WebRTCStatisticsSnapshot {
        let nativeSnapshot = await withCheckedContinuation {
            (continuation: CheckedContinuation<WebRTCStatisticsSnapshot, Never>) in
            peerConnection.statistics { report in
                continuation.resume(returning: WebRTCStatisticsParser.parse(report))
            }
        }

        guard nativeSnapshot.route == nil, let currentRoute else {
            return nativeSnapshot
        }
        return WebRTCStatisticsSnapshot(
            collectedAt: nativeSnapshot.collectedAt,
            route: currentRoute,
            currentRoundTripTime: nativeSnapshot.currentRoundTripTime,
            availableOutgoingBitrate: nativeSnapshot.availableOutgoingBitrate,
            jitter: nativeSnapshot.jitter,
            outboundVideo: nativeSnapshot.outboundVideo,
            inboundVideo: nativeSnapshot.inboundVideo,
            audioSource: nativeSnapshot.audioSource,
            outboundAudio: nativeSnapshot.outboundAudio,
            inboundAudio: nativeSnapshot.inboundAudio,
            remoteInboundAudio: nativeSnapshot.remoteInboundAudio
        )
    }

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
                let snapshot = await self.statisticsSnapshot()
                await self.publishStatistics(snapshot)
            }
        }
    }

    public func stopStatistics() {
        statisticsTask?.cancel()
        statisticsTask = nil
    }

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

    private func consume(_ event: NativePeerEvent) {
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
                failCloseScreenMedia()
            }
            emit(.peerStateChanged(state))
        case .iceState(let state):
            if state != .connected && state != .completed {
                failCloseScreenMedia()
            }
            emit(.iceStateChanged(state))
        case .gatheringState(let state):
            emit(.iceGatheringStateChanged(state))
        case .dataChannelState(let state):
            if state != .open {
                failCloseScreenMedia()
            }
            emit(.dataChannelStateChanged(state))
        case .dataChannelMessage(let data):
            receiveControlChannelData(data)
        case .remoteAudioTrack(let track):
            // Unified Plan can report the same receiver through both legacy stream and modern
            // receiver callbacks. Adopt it once so duplicate callbacks cannot toggle playout or
            // produce two application-owned wrappers for one native track.
            if currentRemoteAudioTrack?.wrapsSameNativeTrack(as: track) == true {
                return
            }
            // Native receive tracks start enabled. Fail closed before publishing the wrapper so
            // audio cannot escape during the actor -> application lifecycle handoff. The viewer
            // explicitly unmutes only after its current transport/background-audio proof passes.
            currentRemoteAudioTrack?.setEnabled(false)
            track.setEnabled(false)
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
        suspendSystemAudioForTransportUncertainty()
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
            }
        } catch {
            invalidateInputSession(reason: "Invalid control-channel message.")
            emit(.diagnosticFailure("Invalid control-channel message."))
        }
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
            // Revoke before the application event is yielded so a queued input cannot race a
            // newer screen generation through lagging service state.
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

    private func failCloseScreenMedia() {
        suspendSystemAudioForTransportUncertainty()
        disableRemoteAudioPlayback()
        localVideoTrack?.isEnabled = false
        // Clear the peer-owned capability before lifecycle state events can reach application
        // actors. This closes the window where their health booleans still describe the old route.
        invalidateInputSession(reason: "WebRTC transport became uncertain.")
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
                let localDescription = Self.applyingHighFidelityOpusPolicy(to: description)
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
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String, any Error>) in
            peerConnection.answer(for: mediaConstraints) { [peerConnection] description, error in
                guard let description else {
                    continuation.resume(
                        throwing: Self.nativeError(error, fallback: .invalidSessionDescription)
                    )
                    return
                }
                let localDescription = Self.applyingHighFidelityOpusAnswerPolicy(
                    to: description,
                    remoteOfferSDP: remoteOfferSDP
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
    }

    private static func applyingHighFidelityOpusPolicy(
        to description: LKRTCSessionDescription
    ) -> LKRTCSessionDescription {
        LKRTCSessionDescription(
            type: description.type,
            sdp: OpusStereoSDP.applyingHighFidelityPolicy(
                to: description.sdp as String
            )
        )
    }

    private static func applyingHighFidelityOpusAnswerPolicy(
        to description: LKRTCSessionDescription,
        remoteOfferSDP: String
    ) -> LKRTCSessionDescription {
        LKRTCSessionDescription(
            type: description.type,
            sdp: OpusStereoSDP.applyingHighFidelityAnswerPolicy(
                to: description.sdp as String,
                remoteOffer: remoteOfferSDP
            )
        )
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
                  transceiver.sender.track != nil else {
                continue
            }
            try Self.applyHighFidelityAudioSenderParameters(to: transceiver.sender)
        }
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

    private func ensureOpen() throws {
        if isClosed { throw WebRTCTransportError.transportClosed }
    }

    private func closeTransport() {
        guard !isClosed else { return }
        suspendSystemAudioForTransportUncertainty()
        disableRemoteAudioPlayback()
        localVideoTrack?.isEnabled = false
        invalidateInputSession(reason: "WebRTC transport closed.")
        guard !isClosed else { return }
        isClosed = true
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
    }

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

enum ControlChannelMessage: Codable, Equatable, Sendable {
    static let currentVersion = 2

    case command(WebRTCControlRequest)
    case acknowledgement(WebRTCControlAcknowledgement)
    case input(WebRTCInputRequest)
    case inputFeedback(WebRTCInputFeedback)

    private enum Kind: String, Codable {
        case command
        case acknowledgement = "ack"
        case input
        case inputFeedback
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case kind
        case command
        case acknowledgement
        case input
        case inputFeedback
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
        }
    }
}

private enum WebRTCRuntime {
    static let isInitialized = LKRTCInitializeSSL()
}
