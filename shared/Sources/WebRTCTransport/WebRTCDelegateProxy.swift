@preconcurrency import LiveKitWebRTC
import Foundation
import RemoteSessionCore

/// Wire identifiers and resource limits for the ordered control data channel.
enum WebRTCWireConstants {
    // Compatibility ABI: existing host/viewer builds negotiate these deployed v2 tokens.
    static let controlChannelLabel = "audiostreamer.control"
    static let controlProtocol = "audiostreamer.control.v2"
    static let maximumControlMessageBytes = WebRTCInputCapability.maximumMessageBytes
    static let maximumBufferedControlBytes: UInt64 = 256 * 1_024

    // Client observability is intentionally isolated from the safety-critical ordered lane.
    static let screenDiagnosticsChannelLabel = "opensteamer.screen-diagnostics"
    static let screenDiagnosticsProtocol = "opensteamer.screen-diagnostics.v1"
    static let maximumScreenDiagnosticsMessageBytes = 8 * 1_024
    static let maximumBufferedScreenDiagnosticsBytes: UInt64 = 32 * 1_024
}

/// Value-semantic events crossing from native WebRTC callbacks into the peer actor.
enum NativePeerEvent: Sendable {
    case localCandidate(RemoteICECandidate)
    case peerState(WebRTCPeerState)
    case iceState(WebRTCICEState)
    case gatheringState(WebRTCICEGatheringState)
    case dataChannelState(WebRTCDataChannelState)
    case dataChannelMessage(Data)
    case remoteAudioTrack(WebRTCNativeRemoteAudioReceiverTrack)
    case remoteVideoTrack(WebRTCRemoteVideoTrack)
    case route(WebRTCICERouteDiagnostics)
    case iceCandidateError(WebRTCIceCandidateError)
    case negotiationNeeded
    case failure(String)
}

/// Optional native callbacks use their own newest-one queue. Dropping or terminating this queue
/// closes only the diagnostics channel and can never consume a safety-critical peer-event slot.
enum NativeScreenDiagnosticsEvent: Sendable {
    case message(Data)
    case failure(String)
}

/// Serializes the small amount of mutable state touched directly by native WebRTC callbacks.
///
/// Native delegates arrive on WebRTC queues; only channel ownership and synchronous authorization
/// revocation live here. Higher-level protocol state is consumed by `WebRTCPeer`'s actor.
final class WebRTCDelegateProxy: NSObject, @unchecked Sendable {
    let events: AsyncStream<NativePeerEvent>
    let screenDiagnosticsEvents: AsyncStream<NativeScreenDiagnosticsEvent>

    private let continuation: AsyncStream<NativePeerEvent>.Continuation
    private let screenDiagnosticsContinuation:
        AsyncStream<NativeScreenDiagnosticsEvent>.Continuation
    private let channelLock = NSLock()
    private var dataChannel: LKRTCDataChannel?
    private var screenDiagnosticsChannel: LKRTCDataChannel?
    private var inputAuthorization: WebRTCInputAuthorization?
    private var peerState: WebRTCPeerState = .new
    private var iceState: WebRTCICEState = .new
    private var dataChannelState: WebRTCDataChannelState = .connecting
    private var screenDiagnosticsEventIsPending = false
    private var emittedRemoteAudioReceiverIDs: Set<String> = []
    private var eventDeliveryFailed = false
    private var isClosed = false

    override init() {
        let pair = AsyncStream<NativePeerEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        events = pair.stream
        continuation = pair.continuation
        let diagnosticsPair = AsyncStream<NativeScreenDiagnosticsEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        screenDiagnosticsEvents = diagnosticsPair.stream
        screenDiagnosticsContinuation = diagnosticsPair.continuation
        super.init()
    }

    func installDataChannel(_ channel: LKRTCDataChannel) {
        if channel.label as String == WebRTCWireConstants.screenDiagnosticsChannelLabel,
           channel.protocol as String == WebRTCWireConstants.screenDiagnosticsProtocol {
            installScreenDiagnosticsChannel(channel)
            return
        }
        guard channel.label as String == WebRTCWireConstants.controlChannelLabel,
              channel.protocol as String == WebRTCWireConstants.controlProtocol else {
            channel.close()
            return
        }

        let installation = channelLock.withLock { () -> (
            previous: LKRTCDataChannel?,
            authorization: WebRTCInputAuthorization?,
            accepted: Bool
        ) in
            let previous = dataChannel
            guard !isClosed, !eventDeliveryFailed else {
                return (previous, nil, false)
            }
            let isReplacement = previous != nil && previous !== channel
            let authorization = isReplacement ? inputAuthorization : nil
            if isReplacement {
                inputAuthorization = nil
            }
            dataChannel = channel
            dataChannelState = channel.readyState.transportValue
            if dataChannelState != .open {
                let stateAuthorization = inputAuthorization
                inputAuthorization = nil
                return (previous, authorization ?? stateAuthorization, true)
            }
            return (previous, authorization, true)
        }
        guard installation.accepted else {
            channel.close()
            return
        }
        // A control-lane replacement or non-open channel is an input uncertainty boundary.
        // Revoke before closing/emitting so queued application work cannot enter afterward.
        installation.authorization?.revoke()
        if installation.previous !== channel {
            installation.previous?.delegate = nil
            installation.previous?.close()
        }
        channel.delegate = self
        emit(.dataChannelState(channel.readyState.transportValue))
    }

    private func installScreenDiagnosticsChannel(_ channel: LKRTCDataChannel) {
        let installation = channelLock.withLock { () -> (
            previous: LKRTCDataChannel?,
            accepted: Bool
        ) in
            let previous = screenDiagnosticsChannel
            guard !isClosed, !eventDeliveryFailed else {
                return (previous, false)
            }
            screenDiagnosticsChannel = channel
            if previous !== channel {
                screenDiagnosticsEventIsPending = false
            }
            return (previous, true)
        }
        guard installation.accepted else {
            channel.close()
            return
        }
        if installation.previous !== channel {
            installation.previous?.delegate = nil
            installation.previous?.close()
        }
        channel.delegate = self
    }

    /// Mirrors the peer's current process-local input gate so a native callback-buffer overflow
    /// can revoke queued input synchronously, before the peer actor drains any stale callbacks.
    @discardableResult
    func installInputAuthorization(_ authorization: WebRTCInputAuthorization?) -> Bool {
        let replacement = channelLock.withLock { () -> (
            previous: WebRTCInputAuthorization?,
            acceptsReplacement: Bool
        ) in
            let previous = inputAuthorization
            if authorization == nil {
                inputAuthorization = nil
                return (previous, true)
            }
            guard !isClosed,
                  !eventDeliveryFailed,
                  nativeTransportIsHealthyLocked(),
                  authorization?.isValid == true else {
                inputAuthorization = nil
                return (previous, false)
            }
            inputAuthorization = authorization
            return (previous, true)
        }
        if replacement.previous !== authorization {
            replacement.previous?.revoke()
        }
        if !replacement.acceptsReplacement {
            authorization?.revoke()
        }
        return replacement.acceptsReplacement
    }

    func hasHealthyInstalledInputAuthorization(
        _ authorization: WebRTCInputAuthorization
    ) -> Bool {
        channelLock.withLock {
            inputAuthorization === authorization
                && nativeTransportIsHealthyLocked()
                && authorization.isValid
        }
    }

    func didFailEventDelivery() -> Bool {
        channelLock.withLock { eventDeliveryFailed }
    }

#if DEBUG
    func emitForTesting(_ event: NativePeerEvent) {
        emit(event)
    }

    func emitScreenDiagnosticsForTesting(
        _ event: NativeScreenDiagnosticsEvent
    ) {
        emitScreenDiagnostics(event)
    }

    func markNativeTransportHealthyForTesting() {
        channelLock.withLock {
            peerState = .connected
            iceState = .connected
            dataChannelState = .open
        }
    }

    func receivePeerStateForTesting(_ state: WebRTCPeerState) {
        receivePeerState(state)
    }

    func receiveICEStateForTesting(_ state: WebRTCICEState) {
        receiveICEState(state)
    }

    func receiveDataChannelStateForTesting(_ state: WebRTCDataChannelState) {
        receiveDataChannelState(state, channel: nil)
    }

    func receiveControlProtocolFailureForTesting() {
        failInputAuthorizationSynchronously()
        emit(.failure("Invalid control-channel message rejected."))
    }

    @discardableResult
    func receiveRemoteAudioTrackForTesting(
        _ track: LKRTCAudioTrack,
        receiverID: String
    ) -> Bool {
        receiveRemoteAudioTrack(track, receiverID: receiverID)
    }
#endif

    func sendControlData(_ data: Data) throws {
        guard data.count <= WebRTCWireConstants.maximumControlMessageBytes else {
            throw WebRTCTransportError.invalidInputRequest
        }
        let channel = channelLock.withLock { dataChannel }
        guard let channel, channel.readyState == .open else {
            throw WebRTCTransportError.dataChannelUnavailable
        }
        guard channel.bufferedAmount < WebRTCWireConstants.maximumBufferedControlBytes else {
            throw WebRTCTransportError.dataChannelBackpressured
        }
        guard channel.sendData(LKRTCDataBuffer(data: data, isBinary: false)) else {
            throw WebRTCTransportError.dataChannelSendFailed
        }
    }

    func sendScreenDiagnosticsData(_ data: Data) throws {
        guard data.count <= WebRTCWireConstants.maximumScreenDiagnosticsMessageBytes else {
            throw WebRTCTransportError.invalidInputRequest
        }
        let channel = channelLock.withLock { screenDiagnosticsChannel }
        guard let channel, channel.readyState == .open else {
            throw WebRTCTransportError.dataChannelUnavailable
        }
        guard channel.bufferedAmount
                < WebRTCWireConstants.maximumBufferedScreenDiagnosticsBytes else {
            throw WebRTCTransportError.dataChannelBackpressured
        }
        guard channel.sendData(LKRTCDataBuffer(data: data, isBinary: false)) else {
            throw WebRTCTransportError.dataChannelSendFailed
        }
    }

    func closeScreenDiagnosticsChannel() {
        let channel = channelLock.withLock { () -> LKRTCDataChannel? in
            defer {
                screenDiagnosticsChannel = nil
                screenDiagnosticsEventIsPending = false
            }
            return screenDiagnosticsChannel
        }
        channel?.delegate = nil
        channel?.close()
    }

    func didConsumeScreenDiagnosticsEvent() {
        channelLock.withLock {
            screenDiagnosticsEventIsPending = false
        }
    }

    func isControlChannelOpen() -> Bool {
        channelLock.withLock { dataChannel?.readyState == .open }
    }

    func close() {
        let resources = channelLock.withLock { () -> (
            channel: LKRTCDataChannel?,
            screenDiagnosticsChannel: LKRTCDataChannel?,
            authorization: WebRTCInputAuthorization?
        ) in
            isClosed = true
            defer {
                dataChannel = nil
                screenDiagnosticsChannel = nil
                screenDiagnosticsEventIsPending = false
                inputAuthorization = nil
                dataChannelState = .closed
            }
            return (dataChannel, screenDiagnosticsChannel, inputAuthorization)
        }
        resources.authorization?.revoke()
        resources.channel?.delegate = nil
        resources.channel?.close()
        resources.screenDiagnosticsChannel?.delegate = nil
        resources.screenDiagnosticsChannel?.close()
        screenDiagnosticsContinuation.finish()
        continuation.finish()
    }

    private func emit(_ event: NativePeerEvent) {
        switch continuation.yield(event) {
        case .enqueued:
            break
        case .dropped, .terminated:
            failClosedForEventDeliveryLoss()
        @unknown default:
            failClosedForEventDeliveryLoss()
        }
    }

    private func emitScreenDiagnostics(_ event: NativeScreenDiagnosticsEvent) {
        switch screenDiagnosticsContinuation.yield(event) {
        case .enqueued:
            break
        case .dropped, .terminated:
            // This lane is optional. Its own delivery uncertainty must never revoke input or
            // close media/control, so retire only the channel that produced the event.
            closeScreenDiagnosticsChannel()
        @unknown default:
            closeScreenDiagnosticsChannel()
        }
    }

    /// Publishes each modern remote-audio receiver once and mutes its first wrapper synchronously.
    ///
    /// A duplicate callback must be discarded before touching `isEnabled`: a later getter may
    /// return a fresh wrapper for the same already-admitted receiver.
    @discardableResult
    private func receiveRemoteAudioTrack(
        _ track: LKRTCAudioTrack,
        receiverID: String
    ) -> Bool {
        guard !receiverID.isEmpty else {
            track.isEnabled = false
            emit(.failure("Remote audio receiver did not expose a nonempty identity."))
            return false
        }

        let isFirstCallback = channelLock.withLock {
            guard !isClosed, !eventDeliveryFailed else { return false }
            return emittedRemoteAudioReceiverIDs.insert(receiverID).inserted
        }
        guard isFirstCallback else { return false }

        track.isEnabled = false
        emit(
            .remoteAudioTrack(
                WebRTCNativeRemoteAudioReceiverTrack(
                    track,
                    receiverID: receiverID
                )
            )
        )
        return true
    }

    private func failClosedForEventDeliveryLoss() {
        let resources = channelLock.withLock { () -> (
            shouldClose: Bool,
            channel: LKRTCDataChannel?,
            screenDiagnosticsChannel: LKRTCDataChannel?,
            authorization: WebRTCInputAuthorization?
        ) in
            guard !eventDeliveryFailed, !isClosed else {
                return (false, nil, nil, nil)
            }
            eventDeliveryFailed = true
            let channel = dataChannel
            let screenDiagnosticsChannel = screenDiagnosticsChannel
            let authorization = inputAuthorization
            dataChannel = nil
            self.screenDiagnosticsChannel = nil
            screenDiagnosticsEventIsPending = false
            inputAuthorization = nil
            dataChannelState = .closed
            return (true, channel, screenDiagnosticsChannel, authorization)
        }
        guard resources.shouldClose else { return }
        resources.authorization?.revoke()
        resources.channel?.delegate = nil
        resources.channel?.close()
        resources.screenDiagnosticsChannel?.delegate = nil
        resources.screenDiagnosticsChannel?.close()
        continuation.finish()
    }

    private func nativeTransportIsHealthyLocked() -> Bool {
        peerState == .connected
            && (iceState == .connected || iceState == .completed)
            && dataChannelState == .open
    }

    private func failInputAuthorizationSynchronously() {
        let authorization = channelLock.withLock { () -> WebRTCInputAuthorization? in
            defer { inputAuthorization = nil }
            return inputAuthorization
        }
        // Revocation linearizes with in-flight injection. It deliberately occurs before the
        // native callback emits an asynchronously drained event.
        authorization?.revoke()
    }

    private func receivePeerState(_ state: WebRTCPeerState) {
        let authorization = channelLock.withLock { () -> WebRTCInputAuthorization? in
            peerState = state
            guard state != .connected else { return nil }
            defer { inputAuthorization = nil }
            return inputAuthorization
        }
        authorization?.revoke()
        emit(.peerState(state))
    }

    private func receiveICEState(_ state: WebRTCICEState) {
        let authorization = channelLock.withLock { () -> WebRTCInputAuthorization? in
            iceState = state
            guard state != .connected && state != .completed else { return nil }
            defer { inputAuthorization = nil }
            return inputAuthorization
        }
        authorization?.revoke()
        emit(.iceState(state))
    }

    private func receiveDataChannelState(
        _ state: WebRTCDataChannelState,
        channel: LKRTCDataChannel?
    ) {
        let transition = channelLock.withLock { () -> (
            isCurrent: Bool,
            authorization: WebRTCInputAuthorization?
        ) in
            if let channel, self.dataChannel !== channel {
                return (false, nil)
            }
            dataChannelState = state
            let authorization: WebRTCInputAuthorization?
            if state == .open {
                authorization = nil
            } else {
                authorization = inputAuthorization
                inputAuthorization = nil
            }
            if state == .closed {
                dataChannel = nil
            }
            return (true, authorization)
        }
        guard transition.isCurrent else { return }
        transition.authorization?.revoke()
        emit(.dataChannelState(state))
    }

    private func receiveScreenDiagnosticsChannelState(
        _ state: WebRTCDataChannelState,
        channel: LKRTCDataChannel
    ) {
        let isCurrent = channelLock.withLock { () -> Bool in
            guard screenDiagnosticsChannel === channel else { return false }
            if state == .closed {
                screenDiagnosticsChannel = nil
                screenDiagnosticsEventIsPending = false
            }
            return true
        }
        guard isCurrent else { return }
    }

    /// At most one best-effort diagnostics callback may occupy the safety-critical native event
    /// stream. A noisy viewer therefore cannot evict ordered control or transport transitions.
    private func beginScreenDiagnosticsEvent() -> Bool {
        channelLock.withLock {
            guard !screenDiagnosticsEventIsPending,
                  !isClosed,
                  !eventDeliveryFailed else {
                return false
            }
            screenDiagnosticsEventIsPending = true
            return true
        }
    }
}

extension WebRTCDelegateProxy: LKRTCPeerConnectionDelegate {
    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange stateChanged: LKRTCSignalingState
    ) {}

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didAdd stream: LKRTCMediaStream
    ) {
        // This peer is Unified Plan. Only the receiver callback below carries the stable receiver
        // and SSRC evidence required by screen-resume proof, so the legacy stream callback must
        // not compete with or duplicate either audio or video delivery.
        _ = stream
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didRemove stream: LKRTCMediaStream
    ) {}

    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {
        emit(.negotiationNeeded)
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange newState: LKRTCIceConnectionState
    ) {
        receiveICEState(newState.transportValue)
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange newState: LKRTCIceGatheringState
    ) {
        emit(.gatheringState(newState.transportValue))
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didGenerate candidate: LKRTCIceCandidate
    ) {
        let sdp = candidate.sdp as String
        emit(
            .localCandidate(
                RemoteICECandidate(
                    sdp: sdp,
                    sdpMid: candidate.sdpMid as String?,
                    sdpMLineIndex: candidate.sdpMLineIndex,
                    usernameFragment: ICEUsernameFragmentParser.fragment(inCandidateSDP: sdp)
                )
            )
        )
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didRemove candidates: [LKRTCIceCandidate]
    ) {}

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didOpen dataChannel: LKRTCDataChannel
    ) {
        installDataChannel(dataChannel)
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange newState: LKRTCPeerConnectionState
    ) {
        receivePeerState(newState.transportValue)
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didAdd rtpReceiver: LKRTCRtpReceiver,
        streams mediaStreams: [LKRTCMediaStream]
    ) {
        switch rtpReceiver.track {
        case let audioTrack as LKRTCAudioTrack:
            _ = receiveRemoteAudioTrack(
                audioTrack,
                receiverID: rtpReceiver.receiverId as String
            )
        case let videoTrack as LKRTCVideoTrack:
            let receiverID = rtpReceiver.receiverId as String
            guard !receiverID.isEmpty else {
                videoTrack.isEnabled = false
                emit(
                    .failure(
                        "Rejected a remote video receiver without an identity."
                    )
                )
                return
            }
            emit(
                .remoteVideoTrack(
                    WebRTCRemoteVideoTrack(
                        videoTrack,
                        receiver: rtpReceiver
                    )
                )
            )
        default:
            break
        }
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChangeLocalCandidate local: LKRTCIceCandidate,
        remoteCandidate remote: LKRTCIceCandidate,
        lastReceivedMs lastDataReceivedMs: Int32,
        changeReason reason: String
    ) {
        let localDiagnostics = WebRTCNativeDiagnostics.candidate(fromSDP: local.sdp as String)
        let remoteDiagnostics = WebRTCNativeDiagnostics.candidate(fromSDP: remote.sdp as String)
        emit(
            .route(
                WebRTCNativeDiagnostics.route(
                    local: localDiagnostics,
                    remote: remoteDiagnostics
                )
            )
        )
    }

    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didFailToGatherIceCandidate event: LKRTCIceCandidateErrorEvent
    ) {
        emit(
            .iceCandidateError(
                WebRTCIceCandidateError(
                    address: event.address,
                    port: Int(event.port),
                    url: event.url,
                    errorCode: Int(event.errorCode),
                    reason: event.errorText
                )
            )
        )
    }
}

extension WebRTCDelegateProxy: LKRTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        if dataChannel.label as String
                == WebRTCWireConstants.screenDiagnosticsChannelLabel {
            receiveScreenDiagnosticsChannelState(
                dataChannel.readyState.transportValue,
                channel: dataChannel
            )
            return
        }
        receiveDataChannelState(dataChannel.readyState.transportValue, channel: dataChannel)
    }

    func dataChannel(
        _ dataChannel: LKRTCDataChannel,
        didReceiveMessageWith buffer: LKRTCDataBuffer
    ) {
        if dataChannel.label as String
                == WebRTCWireConstants.screenDiagnosticsChannelLabel {
            guard !buffer.isBinary else {
                if beginScreenDiagnosticsEvent() {
                    emitScreenDiagnostics(.failure(
                        "Binary screen-client diagnostics messages are not accepted."
                    ))
                }
                closeScreenDiagnosticsChannel()
                return
            }
            guard buffer.data.count
                    <= WebRTCWireConstants.maximumScreenDiagnosticsMessageBytes else {
                if beginScreenDiagnosticsEvent() {
                    emitScreenDiagnostics(.failure(
                        "Oversized screen-client diagnostics message rejected."
                    ))
                }
                closeScreenDiagnosticsChannel()
                return
            }
            if beginScreenDiagnosticsEvent() {
                emitScreenDiagnostics(.message(buffer.data))
            }
            return
        }
        guard !buffer.isBinary else {
            failInputAuthorizationSynchronously()
            emit(.failure("Binary control-channel messages are not accepted."))
            return
        }
        guard buffer.data.count <= WebRTCWireConstants.maximumControlMessageBytes else {
            failInputAuthorizationSynchronously()
            emit(.failure("Oversized control-channel message rejected."))
            return
        }
        emit(.dataChannelMessage(buffer.data))
    }
}

/// Converts native ICE candidate metadata into privacy-reduced route diagnostics.
enum WebRTCNativeDiagnostics {
    static func candidate(fromSDP sdp: String) -> WebRTCCandidateDiagnostics {
        let tokens = sdp.split(whereSeparator: \.isWhitespace).map(String.init)
        let lowercased = tokens.map { $0.lowercased() }
        let type: WebRTCCandidateType
        if let typeIndex = lowercased.firstIndex(of: "typ"), lowercased.indices.contains(typeIndex + 1) {
            type = candidateType(lowercased[typeIndex + 1])
        } else {
            type = .unknown
        }

        let transport = lowercased.indices.contains(2) ? lowercased[2] : nil
        return WebRTCCandidateDiagnostics(
            type: type,
            transport: transport,
            relayProtocol: value(after: "relayprotocol", in: lowercased)
        )
    }

    static func candidate(from values: [String: Any]) -> WebRTCCandidateDiagnostics {
        WebRTCCandidateDiagnostics(
            type: candidateType(string("candidateType", in: values)),
            transport: string("protocol", in: values)?.lowercased(),
            networkType: string("networkType", in: values)?.lowercased(),
            relayProtocol: string("relayProtocol", in: values)?.lowercased()
        )
    }

    static func route(
        local: WebRTCCandidateDiagnostics?,
        remote: WebRTCCandidateDiagnostics?
    ) -> WebRTCICERouteDiagnostics {
        let kind: WebRTCICERouteKind
        if local?.type == .relay || remote?.type == .relay {
            kind = .relayed
        } else if let local, let remote,
                  local.type != .unknown, remote.type != .unknown {
            kind = .direct
        } else {
            kind = .unknown
        }
        return WebRTCICERouteDiagnostics(kind: kind, local: local, remote: remote)
    }

    static func string(_ key: String, in values: [String: Any]) -> String? {
        if let value = values[key] as? String { return value }
        if let value = values[key] as? NSString { return value as String }
        return nil
    }

    static func number(_ key: String, in values: [String: Any]) -> NSNumber? {
        values[key] as? NSNumber
    }

    private static func candidateType(_ rawValue: String?) -> WebRTCCandidateType {
        switch rawValue?.lowercased() {
        case "host": .host
        case "srflx": .serverReflexive
        case "prflx": .peerReflexive
        case "relay": .relay
        default: .unknown
        }
    }

    private static func value(after key: String, in tokens: [String]) -> String? {
        guard let index = tokens.firstIndex(of: key), tokens.indices.contains(index + 1) else {
            return nil
        }
        return tokens[index + 1]
    }
}

private extension LKRTCPeerConnectionState {
    var transportValue: WebRTCPeerState {
        switch self {
        case .new: .new
        case .connecting: .connecting
        case .connected: .connected
        case .disconnected: .disconnected
        case .failed: .failed
        case .closed: .closed
        @unknown default: .failed
        }
    }
}

private extension LKRTCIceConnectionState {
    var transportValue: WebRTCICEState {
        switch self {
        case .new: .new
        case .checking: .checking
        case .connected: .connected
        case .completed: .completed
        case .disconnected: .disconnected
        case .failed: .failed
        case .closed: .closed
        case .count: .unknown
        @unknown default: .unknown
        }
    }
}

private extension LKRTCIceGatheringState {
    var transportValue: WebRTCICEGatheringState {
        switch self {
        case .new: .new
        case .gathering: .gathering
        case .complete: .complete
        @unknown default: .complete
        }
    }
}

private extension LKRTCDataChannelState {
    var transportValue: WebRTCDataChannelState {
        switch self {
        case .connecting: .connecting
        case .open: .open
        case .closing: .closing
        case .closed: .closed
        @unknown default: .closed
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
