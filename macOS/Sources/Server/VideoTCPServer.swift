import CaptureCore
import Foundation
import Network
import Streaming

/// Session and recovery events emitted by the screen-video transport.
public protocol VideoTCPServerEventHandler: AnyObject, Sendable {
    /// Reports a newly authenticated viewer and its unguessable local identity.
    func videoServerViewerConnected(_ sessionID: VideoViewerSessionID)
    /// Reports that the matching authenticated viewer has closed.
    func videoServerViewerDisconnected(_ sessionID: VideoViewerSessionID)
    /// Requests an encoder key frame after connection or transport recovery.
    func videoServerRequestedKeyFrame()
}

/// Opaque identity of one authenticated viewer lifetime.
public struct VideoViewerSessionID: Equatable, Sendable {
    fileprivate let rawValue: UUID

    fileprivate init() {
        rawValue = UUID()
    }
}

/// Exclusive permission to encode one frame in the current transport generation.
public struct ScreenVideoFrameReservation: Sendable {
    public let id: UInt64
    public let generation: UInt32
    public let forceKeyFrame: Bool
}

/// Queue-consistent operational counters for the screen-video server.
public struct VideoTCPServerSnapshot: Sendable {
    public let connectedClients: Int
    public let reconnects: Int
    public let queuedPackets: Int
    public let framesSent: Int64
    public let bytesSent: Int64
    public let framesAwaitingAcknowledgement: Int
}

/// Single-viewer, acknowledgement-paced TCP transport for encoded screen video.
///
/// The private queue owns listener/client lifecycle and the frame-flow state machine.
/// Only one frame can be reserved or awaiting acknowledgement, deliberately bounding
/// latency and memory when the viewer is slower than capture. TCP is unauthenticated
/// unless `authToken` is supplied; cross-network production media uses WebRTC instead.
public final class VideoTCPServer: @unchecked Sendable {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let bonjourName: String?
    private let authToken: String?
    private let logger: Logger
    private let queue = DispatchQueue(label: "opensteamer.VideoTCPServer")
    private weak var eventHandler: VideoTCPServerEventHandler?
    private var listener: NWListener?
    private var client: VideoClientConnection?
    private var activeViewerSessionID: VideoViewerSessionID?
    private var frameFlow = VideoFrameFlowState()
    private var acknowledgementTimeoutWorkItem: DispatchWorkItem?
    private var reconnects = 0
    private var framesSent: Int64 = 0
    private var closedClientBytesSent: Int64 = 0

    /// Creates a listener endpoint with optional Bonjour and token authentication.
    public init(
        host: String,
        port: UInt16,
        bonjourName: String?,
        authToken: String?,
        logger: Logger
    ) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw VideoTCPServerError.invalidPort(port)
        }
        self.host = NWEndpoint.Host(host)
        self.port = nwPort
        self.bonjourName = bonjourName
        self.authToken = authToken
        self.logger = logger
    }

    /// Replaces the weak event handler on the server's ownership queue.
    public func setEventHandler(_ eventHandler: VideoTCPServerEventHandler?) {
        queue.sync {
            self.eventHandler = eventHandler
        }
    }

    /// Starts a low-latency TCP listener and waits up to five seconds for readiness.
    public func start() throws {
        // Disable Nagle and use keepalives to surface dead interactive sessions promptly.
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 5
        tcpOptions.keepaliveInterval = 2
        tcpOptions.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        let listener = try NWListener(using: parameters, on: port)
        let startupGate = VideoListenerStartupGate()
        if let bonjourName {
            listener.service = NWListener.Service(
                name: bonjourName,
                type: "_mcap-screen._tcp",
                txtRecord: NWTXTRecord([
                    "version": "\(ScreenVideoProtocol.version)",
                    "codec": "h264",
                    "transport": "tcp",
                    "security": authToken == nil ? "none" : "token"
                ])
            )
            logger.info("Advertising Bonjour service \(bonjourName)._mcap-screen._tcp")
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let listener else {
                connection.cancel()
                return
            }
            self?.accept(connection, from: listener)
        }
        listener.stateUpdateHandler = { [weak self] state in
            self?.logger.info("Screen TCP listener state: \(state)")
            switch state {
            case .ready:
                startupGate.resolve(.ready)
            case .failed(let error):
                startupGate.resolve(.failed(error))
            case .cancelled:
                startupGate.resolve(.failed(VideoTCPServerError.listenerCancelledBeforeReady))
            default:
                break
            }
        }
        let installed = queue.sync { () -> Bool in
            guard self.listener == nil else { return false }
            self.listener = listener
            listener.start(queue: self.queue)
            return true
        }
        guard installed else {
            listener.cancel()
            throw VideoTCPServerError.listenerAlreadyRunning
        }

        switch startupGate.wait(timeout: .now() + .seconds(5)) {
        case .ready:
            break
        case .failed(let error):
            clearListenerIfCurrent(listener)
            throw error
        case .timedOut:
            clearListenerIfCurrent(listener)
            throw VideoTCPServerError.listenerStartTimedOut
        }
        logger.info("Listening for screen viewers on \(host):\(port.rawValue)")
    }

    /// Synchronously tears down listener, viewer, timeouts, and frame-flow state.
    public func stop() {
        queue.sync {
            acknowledgementTimeoutWorkItem?.cancel()
            acknowledgementTimeoutWorkItem = nil
            let stoppedListener = listener
            listener = nil
            let stoppedClient = client
            client = nil
            activeViewerSessionID = nil
            if let stoppedClient {
                closedClientBytesSent += stoppedClient.bytesSent
                stoppedClient.cancel(reason: "screen server stopping")
            }
            stoppedListener?.cancel()
            resetFrameFlow()
        }
    }

    /// Cancels only the still-current authenticated viewer identified by `expectedSessionID`.
    public func failActiveViewer(
        _ expectedSessionID: VideoViewerSessionID,
        reason: String
    ) {
        queue.async {
            guard self.activeViewerSessionID == expectedSessionID,
                  let client = self.client,
                  client.isAuthorized else {
                return
            }
            client.cancel(reason: reason)
        }
    }

    /// Starts a fresh decoder/flow-control generation for an in-place capture format rebuild.
    /// Delayed acknowledgements from the retired canvas are ignored by their old generation.
    public func beginCaptureFormatDiscontinuity(
        for expectedSessionID: VideoViewerSessionID
    ) -> Bool {
        queue.sync {
            guard activeViewerSessionID == expectedSessionID,
                  let client,
                  client.isAuthorized else {
                return false
            }
            beginNewFrameGeneration()
            return true
        }
    }

    /// Reserves the sole encoding slot when no frame or acknowledgement is outstanding.
    public func reserveFrameForEncoding() -> ScreenVideoFrameReservation? {
        queue.sync {
            guard let client,
                  client.isAuthorized,
                  frameFlow.activeReservationID == nil,
                  frameFlow.awaitingAcknowledgement == nil else {
                return nil
            }
            let reservationID = frameFlow.nextReservationID
            frameFlow.nextReservationID &+= 1
            let reservation = ScreenVideoFrameReservation(
                id: reservationID,
                generation: frameFlow.generation,
                forceKeyFrame: frameFlow.forceNextKeyFrame
            )
            frameFlow.activeReservationID = reservationID
            frameFlow.forceNextKeyFrame = false
            return reservation
        }
    }

    /// Releases a matching reservation and optionally enters key-frame recovery.
    public func cancelFrameReservation(
        _ reservation: ScreenVideoFrameReservation,
        requestKeyFrame: Bool
    ) {
        queue.async {
            guard reservation.generation == self.frameFlow.generation,
                  self.frameFlow.activeReservationID == reservation.id else { return }
            self.frameFlow.activeReservationID = nil
            if requestKeyFrame {
                self.frameFlow.forceNextKeyFrame = true
                self.eventHandler?.videoServerRequestedKeyFrame()
            }
        }
    }

    /// Serializes a reserved frame, preceding changed key-frame metadata with configuration.
    public func sendEncodedFrame(
        _ frame: EncodedScreenVideoFrame,
        reservation: ScreenVideoFrameReservation,
        format: ScreenVideoCaptureFormat,
        bitrate: UInt32
    ) {
        queue.async {
            guard reservation.generation == self.frameFlow.generation,
                  self.frameFlow.activeReservationID == reservation.id,
                  let client = self.client,
                  client.isAuthorized else {
                return
            }
            self.frameFlow.activeReservationID = nil

            if reservation.forceKeyFrame && !frame.isKeyFrame {
                self.frameFlow.forceNextKeyFrame = true
                self.eventHandler?.videoServerRequestedKeyFrame()
                return
            }

            let sequence = self.frameFlow.nextSequence
            self.frameFlow.nextSequence &+= 1

            do {
                if frame.isKeyFrame {
                    guard frame.parameterSets.count >= 2 else {
                        throw VideoTCPServerError.missingParameterSets
                    }
                    let configuration = ScreenVideoConfiguration(
                        width: UInt32(format.width),
                        height: UInt32(format.height),
                        nalUnitHeaderLength: UInt8(frame.nalUnitHeaderLength),
                        framesPerSecondMilli: UInt32(format.framesPerSecond * 1_000),
                        bitrate: bitrate,
                        parameterSets: frame.parameterSets.map { bytes in
                            ScreenVideoParameterSet(
                                nalUnitType: bytes.first.map { $0 & 0x1f } ?? 0,
                                bytes: bytes
                            )
                        }
                    )
                    if self.frameFlow.lastSentConfiguration != configuration {
                        let configurationPacket = ScreenVideoPacket(
                            type: .configuration,
                            flags: [.discontinuity],
                            generation: self.frameFlow.generation,
                            sequence: sequence,
                            presentationTimestampNanoseconds: frame.presentationTimestampNanoseconds,
                            payload: try ScreenVideoFraming.makeConfiguration(configuration)
                        )
                        try client.sendPacket(configurationPacket)
                        self.frameFlow.lastSentConfiguration = configuration
                    }
                }

                let framePacket = ScreenVideoPacket(
                    type: .frame,
                    flags: frame.isKeyFrame ? [.keyFrame] : [],
                    generation: self.frameFlow.generation,
                    sequence: sequence,
                    presentationTimestampNanoseconds: frame.presentationTimestampNanoseconds,
                    payload: frame.bytes
                )
                try client.sendPacket(framePacket)
                self.framesSent += 1
                self.frameFlow.awaitingAcknowledgement = sequence
                self.scheduleAcknowledgementTimeout(
                    generation: self.frameFlow.generation,
                    sequence: sequence,
                    client: client
                )
            } catch {
                self.logger.error("Could not send screen frame: \(error.localizedDescription)")
                self.frameFlow.forceNextKeyFrame = true
                client.cancel(reason: "screen frame serialization failed")
            }
        }
    }

    /// Returns a queue-consistent snapshot of connection and flow-control counters.
    public func snapshot() -> VideoTCPServerSnapshot {
        queue.sync {
            VideoTCPServerSnapshot(
                connectedClients: client == nil ? 0 : 1,
                reconnects: reconnects,
                queuedPackets: client?.queuedPackets ?? 0,
                framesSent: framesSent,
                bytesSent: closedClientBytesSent + (client?.bytesSent ?? 0),
                framesAwaitingAcknowledgement:
                    frameFlow.awaitingAcknowledgement == nil ? 0 : 1
            )
        }
    }

    // MARK: - Viewer lifecycle

    /// Accepts one connection only if it belongs to the current listener generation.
    private func accept(_ connection: NWConnection, from expectedListener: NWListener) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard listener === expectedListener else {
            connection.cancel()
            return
        }
        guard client == nil else {
            logger.info("Rejecting extra screen viewer \(connection.endpoint)")
            connection.cancel()
            return
        }

        reconnects += 1
        let client = VideoClientConnection(
            connection: connection,
            logger: logger,
            authToken: authToken,
            onAuthorized: { [weak self] client in
                self?.handleAuthorized(client)
            },
            onControlPacket: { [weak self] client, packet in
                self?.handleControlPacket(packet, from: client)
            },
            onClose: { [weak self] client in
                self?.handleClosed(client)
            }
        )
        self.client = client
        client.start(on: queue)
    }

    /// Clears startup state without disturbing a subsequently installed listener.
    private func clearListenerIfCurrent(_ expectedListener: NWListener) {
        queue.sync {
            if listener === expectedListener {
                listener = nil
            }
            expectedListener.cancel()
        }
    }

    /// Creates a fresh viewer session and resets encoding flow after authentication.
    private func handleAuthorized(_ authorizedClient: VideoClientConnection) {
        guard client === authorizedClient, activeViewerSessionID == nil else { return }
        let sessionID = VideoViewerSessionID()
        activeViewerSessionID = sessionID
        beginNewFrameGeneration()
        eventHandler?.videoServerViewerConnected(sessionID)
    }

    // MARK: - Frame flow control

    /// Applies acknowledgements and key-frame requests for the active generation.
    private func handleControlPacket(
        _ packet: ScreenVideoPacket,
        from controlClient: VideoClientConnection
    ) {
        guard client === controlClient else { return }

        switch packet.type {
        case .acknowledgement:
            guard frameFlow.acknowledgementMatches(
                generation: packet.generation,
                sequence: packet.sequence
            ) else {
                if packet.generation == frameFlow.generation,
                   let awaitingAcknowledgement = frameFlow.awaitingAcknowledgement,
                   packet.sequence > awaitingAcknowledgement {
                    controlClient.cancel(reason: "screen acknowledgement is ahead of the stream")
                }
                return
            }
            guard let awaitingAcknowledgement = frameFlow.awaitingAcknowledgement else { return }
            guard packet.sequence == awaitingAcknowledgement else {
                // Duplicate ACKs for an older frame are harmless.
                return
            }
            acknowledgementTimeoutWorkItem?.cancel()
            acknowledgementTimeoutWorkItem = nil
            frameFlow.awaitingAcknowledgement = nil
        case .keyFrameRequest:
            guard packet.generation == frameFlow.generation else {
                // A request from before configuration, or from an abandoned
                // recovery generation, cannot describe the current stream.
                return
            }
            forceRecovery()
        default:
            controlClient.cancel(reason: "unsupported screen control packet")
        }
    }

    /// Detaches the current client and reports its session's end exactly once.
    private func handleClosed(_ closedClient: VideoClientConnection) {
        guard client === closedClient else { return }
        let disconnectedSessionID = activeViewerSessionID
        activeViewerSessionID = nil
        closedClientBytesSent += closedClient.bytesSent
        client = nil
        resetFrameFlow()
        if let disconnectedSessionID {
            eventHandler?.videoServerViewerDisconnected(disconnectedSessionID)
        }
    }

    /// Starts a new generation and requires configuration plus a key frame.
    private func forceRecovery() {
        beginNewFrameGeneration()
        eventHandler?.videoServerRequestedKeyFrame()
    }

    /// Rolls generation and clears all state that can refer to the retired decoder canvas.
    private func beginNewFrameGeneration() {
        acknowledgementTimeoutWorkItem?.cancel()
        acknowledgementTimeoutWorkItem = nil
        frameFlow.beginNewGeneration()
    }

    /// Clears reservations, acknowledgements, and decoder configuration for a generation.
    private func resetFrameFlow() {
        acknowledgementTimeoutWorkItem?.cancel()
        acknowledgementTimeoutWorkItem = nil
        frameFlow.resetWithinGeneration()
    }

    /// Disconnects a viewer that does not acknowledge the one outstanding frame.
    private func scheduleAcknowledgementTimeout(
        generation: UInt32,
        sequence: UInt32,
        client timeoutClient: VideoClientConnection
    ) {
        acknowledgementTimeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self, weak timeoutClient] in
            guard let self,
                  let timeoutClient,
                  self.client === timeoutClient,
                  self.frameFlow.generation == generation,
                  self.frameFlow.awaitingAcknowledgement == sequence else {
                return
            }
            timeoutClient.cancel(reason: "screen frame acknowledgement timeout")
        }
        acknowledgementTimeoutWorkItem = timeout
        queue.asyncAfter(deadline: .now() + .seconds(2), execute: timeout)
    }
}

/// Pure decoder/flow state shared by live transport and discontinuity regression tests.
struct VideoFrameFlowState {
    var generation: UInt32 = 0
    var nextSequence: UInt32 = 0
    var nextReservationID: UInt64 = 1
    var activeReservationID: UInt64?
    var awaitingAcknowledgement: UInt32?
    var forceNextKeyFrame = true
    var lastSentConfiguration: ScreenVideoConfiguration?

    mutating func beginNewGeneration() {
        generation &+= 1
        if generation == 0 {
            generation = 1
        }
        resetWithinGeneration()
    }

    mutating func resetWithinGeneration() {
        nextSequence = 0
        activeReservationID = nil
        awaitingAcknowledgement = nil
        forceNextKeyFrame = true
        lastSentConfiguration = nil
    }

    func acknowledgementMatches(generation: UInt32, sequence: UInt32) -> Bool {
        generation == self.generation && sequence == awaitingAcknowledgement
    }
}

/// Listener, configuration, and frame-serialization failures for video TCP.
public enum VideoTCPServerError: LocalizedError {
    case invalidPort(UInt16)
    case missingParameterSets
    case listenerAlreadyRunning
    case listenerCancelledBeforeReady
    case listenerStartTimedOut

    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            "Invalid screen TCP port \(port)"
        case .missingParameterSets:
            "The H.264 key frame did not include SPS and PPS parameter sets"
        case .listenerAlreadyRunning:
            "The screen video listener is already running"
        case .listenerCancelledBeforeReady:
            "The screen video listener was cancelled before it became ready"
        case .listenerStartTimedOut:
            "The screen video listener did not become ready within five seconds"
        }
    }
}

/// Terminal outcomes used by the synchronous listener startup gate.
private enum VideoListenerStartupResult {
    case ready
    case failed(Error)
    case timedOut
}

/// Resolves listener startup exactly once across Network.framework state callbacks.
private final class VideoListenerStartupGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: VideoListenerStartupResult?

    /// Records the first terminal state and releases the synchronous starter.
    func resolve(_ result: VideoListenerStartupResult) {
        let shouldSignal = lock.withLock { () -> Bool in
            guard self.result == nil else { return false }
            self.result = result
            return true
        }
        if shouldSignal {
            semaphore.signal()
        }
    }

    /// Waits for readiness or failure, mapping a missed deadline to `.timedOut`.
    func wait(timeout: DispatchTime) -> VideoListenerStartupResult {
        guard semaphore.wait(timeout: timeout) == .success else { return .timedOut }
        return lock.withLock { result ?? .timedOut }
    }
}
