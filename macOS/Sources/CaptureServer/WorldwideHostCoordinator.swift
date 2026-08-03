import CaptureCore
import Foundation
import RemoteSessionCore

/// Startup outcome presented by the host process.
enum WorldwideHostStartResult: Equatable {
    case invitation(String)
    case paired(remoteDisplayName: String?)
}

/// Injectable paired-availability signaling boundary used by the coordinator.
protocol WorldwideHostAvailabilityTransport: AnyObject, Sendable {
    func connect() async throws -> PairedAvailabilitySignalingClient.EventStream
    func send(_ payload: RemoteAvailabilityPayload) async throws
    func close() async
}

extension PairedAvailabilitySignalingClient: WorldwideHostAvailabilityTransport {}

/// Supervises durable pairing, availability signaling, and one active media session.
///
/// Actor isolation is the ownership boundary for lifecycle state, cryptographic records,
/// signaling clients, and child tasks. The rendezvous endpoint carries authenticated
/// signaling only; `WorldwideScreenService` negotiates end-to-end WebRTC media separately.
actor WorldwideHostCoordinator {
    /// Finishes when the host shuts down normally or with a fatal supervision error.
    nonisolated let completion: AsyncThrowingStream<Void, Error>

    private let endpoint: URL
    private let forceRelay: Bool
    private let displayID: UInt32?
    private let maximumWidth: Int
    private let framesPerSecond: Int
    private let maximumVideoBitrate: Int
    private let remoteInputController: MacRemoteInputController
    private let iPhoneMicrophoneForwardingPolicy:
        WorldwideIPhoneMicrophoneForwardingPolicy
    private let store: WorldwidePairingStore
    private let logger: Logger
    private let hostDisplayName: String?
    private let availabilityMarkerProcessIdentifier: Int32
    private let availabilityMarkerGenerationNonce: String
    private let completionContinuation: AsyncThrowingStream<Void, Error>.Continuation
    private let makeAvailabilityClient: @Sendable (
        URL,
        RemoteAvailabilityLocator
    ) throws -> any WorldwideHostAvailabilityTransport
    private let availabilityRetrySleep: @Sendable (Int) async throws -> Void
    private let availabilityLoopOverride: (@Sendable () async -> Void)?
    private let connectionTelemetry: any ConnectionTelemetryRecording

    private var lifecycle = WorldwideHostLifecycle()
    private var identity: RemoteDeviceIdentity?
    private var pairedRecord: RemotePairedDeviceRecord?
    private var pairingBootstrap: WorldwidePairingBootstrap?
    private var availabilityClient: (any WorldwideHostAvailabilityTransport)?
    private var mediaService: WorldwideScreenService?
    private var pairingTask: Task<Void, Never>?
    private var availabilityTask: Task<Void, Never>?
    private var availabilityGeneration: UUID?
    private var mediaCompletionTask: Task<Void, Never>?
    private var isStarted = false
    private var isStopped = false

    /// Creates a coordinator with injectable availability and timing dependencies for tests.
    init(
        endpoint: URL,
        forceRelay: Bool,
        displayID: UInt32?,
        maximumWidth: Int,
        framesPerSecond: Int,
        maximumVideoBitrate: Int,
        remoteInputController: MacRemoteInputController,
        iPhoneMicrophoneForwardingPolicy:
            WorldwideIPhoneMicrophoneForwardingPolicy = .enabled,
        store: WorldwidePairingStore,
        hostDisplayName: String? = Host.current().localizedName,
        availabilityMarkerProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        availabilityMarkerGenerationNonce: String = String(repeating: "0", count: 64),
        availabilityClientFactory: @escaping @Sendable (
            URL,
            RemoteAvailabilityLocator
        ) throws -> any WorldwideHostAvailabilityTransport = { endpoint, locator in
            try PairedAvailabilitySignalingClient(
                endpoint: endpoint,
                locator: locator,
                role: .host
            )
        },
        availabilityRetrySleep: @escaping @Sendable (Int) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        availabilityLoopOverride: (@Sendable () async -> Void)? = nil,
        connectionTelemetry: any ConnectionTelemetryRecording =
            NoopConnectionTelemetryRecorder(),
        logger: Logger
    ) {
        let pair = AsyncThrowingStream<Void, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        completion = pair.stream
        completionContinuation = pair.continuation
        self.endpoint = endpoint
        self.forceRelay = forceRelay
        self.displayID = displayID
        self.maximumWidth = maximumWidth
        self.framesPerSecond = framesPerSecond
        self.maximumVideoBitrate = maximumVideoBitrate
        self.remoteInputController = remoteInputController
        self.iPhoneMicrophoneForwardingPolicy =
            iPhoneMicrophoneForwardingPolicy
        self.store = store
        self.hostDisplayName = hostDisplayName
        self.availabilityMarkerProcessIdentifier = availabilityMarkerProcessIdentifier
        self.availabilityMarkerGenerationNonce = availabilityMarkerGenerationNonce
        makeAvailabilityClient = availabilityClientFactory
        self.availabilityRetrySleep = availabilityRetrySleep
        self.availabilityLoopOverride = availabilityLoopOverride
        self.connectionTelemetry = connectionTelemetry
        self.logger = logger
    }

    // MARK: - Host lifecycle

    /// Loads durable identity state, then begins pairing or paired-device availability.
    ///
    /// Resetting removes only the viewer binding; the stable Mac identity remains so
    /// operators do not unexpectedly rotate the host's cryptographic identity.
    func start(resetPairing: Bool) async throws -> WorldwideHostStartResult {
        guard !isStarted, !isStopped else {
            throw WorldwideHostCoordinatorError.invalidLifecycle
        }
        if resetPairing {
            try store.resetPairedViewer()
            logger.info("Forgot the paired iPhone; the Mac identity was preserved")
        }

        let identity = try store.loadOrCreateHostIdentity(displayName: hostDisplayName)
        let record = try store.loadPairedViewer(for: identity)

        self.identity = identity
        pairedRecord = record
        try lifecycle.start(hasPairedViewer: record != nil)
        isStarted = true

        if let record {
            startAvailabilityLoop()
            if record.pairingState == .active {
                logger.info("Loaded the paired iPhone and started worldwide availability")
            } else {
                logger.info("Loaded an interrupted pairing and started secure commit recovery")
            }
            return .paired(remoteDisplayName: record.remoteDisplayName)
        }

        do {
            let bootstrap = try WorldwidePairingBootstrap(
                endpoint: endpoint,
                identity: identity,
                store: store,
                logger: logger
            )
            pairingBootstrap = bootstrap
            let code = try await bootstrap.start()
            pairingTask = Task { [weak self, bootstrap] in
                do {
                    for try await record in bootstrap.completion {
                        await self?.pairingDidCommit(record, bootstrap: bootstrap)
                        return
                    }
                    await self?.pairingBootstrapDidEnd(
                        error: WorldwideHostCoordinatorError.pairingEndedBeforeCommit,
                        bootstrap: bootstrap
                    )
                } catch is CancellationError {
                    return
                } catch {
                    await self?.pairingBootstrapDidEnd(
                        error: error,
                        bootstrap: bootstrap
                    )
                }
            }
            return .invitation(code)
        } catch {
            isStarted = false
            lifecycle = WorldwideHostLifecycle()
            pairingBootstrap = nil
            throw error
        }
    }

    /// Performs idempotent, ordered shutdown of every child service and completion stream.
    func stop() async {
        await shutdown(throwing: nil)
    }

    /// Returns the current forwarding boundary without treating absence as failure.
    func iPhoneMicrophoneForwardingSnapshot() async
        -> WorldwideIPhoneMicrophoneForwardingHostSnapshot {
        guard let mediaService else {
            return .inactive(
                policy: iPhoneMicrophoneForwardingPolicy
            )
        }
        return await mediaService.iPhoneMicrophoneForwardingSnapshot()
    }

    // MARK: - Pairing completion

    /// Promotes an active bootstrap record into durable availability.
    private func pairingDidCommit(
        _ record: RemotePairedDeviceRecord,
        bootstrap: WorldwidePairingBootstrap
    ) async {
        guard !isStopped,
              pairingBootstrap === bootstrap,
              record.pairingState == .active else {
            return
        }
        do {
            try lifecycle.durablePairingRecordAvailable()
        } catch {
            await fail(error, bootstrap: bootstrap)
            return
        }
        pairedRecord = record
        pairingBootstrap = nil
        pairingTask = nil
        startAvailabilityLoop()
    }

    /// Recovers a bootstrap disconnect when a durable commit checkpoint already exists.
    private func pairingBootstrapDidEnd(
        error: any Error,
        bootstrap: WorldwidePairingBootstrap
    ) async {
        guard !isStopped,
              pairingBootstrap === bootstrap,
              let identity else {
            return
        }
        do {
            guard let record = try store.loadPairedViewer(for: identity) else {
                await fail(error, bootstrap: bootstrap)
                return
            }
            try lifecycle.durablePairingRecordAvailable()
            pairedRecord = record
            pairingBootstrap = nil
            pairingTask = nil
            logger.info(
                "Pairing bootstrap ended after durable state was saved; " +
                "continuing on authenticated availability recovery"
            )
            startAvailabilityLoop()
        } catch {
            await fail(error, bootstrap: bootstrap)
        }
    }

    // MARK: - Availability supervision

    /// Starts exactly one generation-tagged availability supervisor task.
    private func startAvailabilityLoop() {
        guard availabilityTask == nil, !isStopped else { return }
        let generation = UUID()
        availabilityGeneration = generation
        recordConnectionTelemetry(
            .availabilityLoopStarted,
            generation: generation
        )
        let override = availabilityLoopOverride
        availabilityTask = Task { [weak self] in
            guard let self else { return }
            if let override {
                await override()
            } else {
                await self.runAvailabilityLoop()
            }
            await self.availabilityLoopDidEnd(generation: generation)
        }
    }

    /// Converts an unsanctioned current-loop exit into a fatal host failure.
    private func availabilityLoopDidEnd(generation: UUID) async {
        guard availabilityGeneration == generation else { return }
        availabilityGeneration = nil
        availabilityTask = nil
        guard !Task.isCancelled, !isStopped else { return }
        recordConnectionTelemetry(
            .availabilityLoopUnexpectedlyEnded,
            generation: generation,
            failure: .unexpectedLoopEnd,
            terminal: .failed
        )
        await shutdown(
            throwing: WorldwideHostCoordinatorError.availabilityLoopEndedUnexpectedly
        )
    }

    /// Maintains paired availability indefinitely with validated-state exponential backoff.
    ///
    /// A WebSocket upgrade alone does not reset backoff: the Worker must first send a
    /// protocol state proving that this socket owns the host availability role.
    private func runAvailabilityLoop() async {
        var retryPolicy = WorldwideAvailabilityRetryPolicy()
        var retryOrdinal: UInt16 = 0
        while !Task.isCancelled, !isStopped {
            do {
                guard let record = pairedRecord else {
                    throw WorldwideHostCoordinatorError.activePairMissing
                }
                let client = try makeAvailabilityClient(
                    endpoint,
                    record.availabilityLocator()
                )
                recordConnectionTelemetry(
                    .availabilitySocketOpening,
                    retryOrdinal: retryOrdinal
                )
                availabilityClient = client
                let events = try await client.connect()
                recordConnectionTelemetry(
                    .availabilitySocketOpened,
                    retryOrdinal: retryOrdinal
                )
                for try await event in events {
                    try Task.checkCancellation()
                    guard !isStopped, isCurrentAvailabilityClient(client) else { return }
                    try await handleAvailabilityEvent(event, client: client)
                    if event.validatesHostAvailability,
                       retryPolicy.observedValidAvailabilityState() {
                        retryOrdinal = 0
                        logger.info(
                            "Worldwide paired-device availability is online " +
                            "pid=\(availabilityMarkerProcessIdentifier) " +
                            "nonce=\(availabilityMarkerGenerationNonce)"
                        )
                    }
                }
                guard !isStopped else { return }
                throw RendezvousSignalingError.connectionClosed
            } catch {
                // Foundation transports can surface a literal CancellationError without
                // cancelling this owner task. Treat only owner cancellation as terminal;
                // otherwise the durable-pair availability loop must clean up and retry.
                guard !Task.isCancelled, !isStopped else { return }
                if let exchangeID = lifecycle.activeExchangeID {
                    lifecycle.availabilityPeerLeft(exchangeID: exchangeID)
                }
                let client = availabilityClient
                availabilityClient = nil
                await client?.close()
                let retryDelaySeconds = retryPolicy.delayAfterFailure()
                recordConnectionTelemetry(
                    .retryScheduled,
                    retryOrdinal: retryOrdinal,
                    delayMilliseconds: UInt64(retryDelaySeconds) * 1_000,
                    failure: connectionTelemetryFailure(for: error)
                )
                retryOrdinal = retryOrdinal == .max ? .max : retryOrdinal + 1
                let sanitizedFailure = connectionTelemetryFailure(for: error).rawValue
                logger.error(
                    "Worldwide availability disconnected; retrying in " +
                    "\(retryDelaySeconds) seconds " +
                    "(failure=\(sanitizedFailure))"
                )
                do {
                    try await availabilityRetrySleep(retryDelaySeconds)
                } catch {
                    guard !Task.isCancelled, !isStopped else { return }
                    logger.error(
                        "Worldwide availability retry delay failed without owner " +
                        "cancellation; retrying immediately"
                    )
                }
            }
        }
    }

    /// Uses object identity to reject callbacks from a replaced signaling connection.
    private func isCurrentAvailabilityClient(
        _ client: any WorldwideHostAvailabilityTransport
    ) -> Bool {
        guard let availabilityClient else { return false }
        return ObjectIdentifier(availabilityClient) == ObjectIdentifier(client)
    }

    /// Applies one authenticated availability event to exchange and media ownership.
    private func handleAvailabilityEvent(
        _ event: PairedAvailabilitySignalingEvent,
        client: any WorldwideHostAvailabilityTransport
    ) async throws {
        switch event {
        case .waiting:
            recordConnectionTelemetry(.hostWorkerWaitingForViewer)
            logger.debug("Worldwide availability is waiting for the paired iPhone")

        case .ready(_, let exchangeID):
            recordConnectionTelemetry(
                .availabilityReady,
                exchangeID: exchangeID.wireValue
            )
            if let activeExchangeID = lifecycle.activeExchangeID,
               activeExchangeID != exchangeID.wireValue {
                await stopActiveMediaSession()
                lifecycle.availabilityPeerLeft(exchangeID: activeExchangeID)
            }
            try lifecycle.availabilityReady(exchangeID: exchangeID.wireValue)
            try await sendPairingRecoveryIfNeeded(client: client)

        case .signal(.pairingCommit(let commit)):
            try await handlePairingRecoveryCommit(commit, client: client)

        case .signal(.reconnectRequest(let request)):
            guard let exchangeValue = lifecycle.activeExchangeID else {
                throw WorldwideHostCoordinatorError.reconnectWithoutExchange
            }
            recordConnectionTelemetry(
                .reconnectRequestReceived,
                exchangeID: exchangeValue
            )
            try await beginMediaSession(
                request: request,
                exchangeID: exchangeValue,
                client: client
            )

        case .signal(.reconnectResponse):
            throw WorldwideHostCoordinatorError.unexpectedAvailabilityPayload

        case .peerLeft(_, let exchangeID):
            lifecycle.availabilityPeerLeft(exchangeID: exchangeID.wireValue)
            logger.debug("The paired iPhone left the availability exchange")

        case .serverError(let error):
            throw WorldwideHostCoordinatorError.availabilityServer(error)
        }
    }

    // MARK: - Pairing recovery

    /// Sends the next crash-recoverable pairing commit required by the stored record.
    private func sendPairingRecoveryIfNeeded(
        client: any WorldwideHostAvailabilityTransport
    ) async throws {
        guard isCurrentAvailabilityClient(client),
              let identity,
              var record = pairedRecord else {
            throw WorldwideHostCoordinatorError.activePairMissing
        }

        let commit: RemotePairingCommit?
        switch record.recoveryAction {
        case .awaitProposal, .none:
            commit = nil
        case .issueProposal:
            commit = try record.prepareProposal(using: identity)
            try store.savePairedViewer(record, for: identity)
        case .issueCompletion:
            commit = try record.prepareCompletion(using: identity)
            try store.savePairedViewer(record, for: identity)
        case .resend(let savedCommit):
            commit = savedCommit
        }
        pairedRecord = record
        guard let commit else { return }

        try await client.send(.pairingCommit(commit))
        if commit.phase == .completion {
            try record.markCompletionSent(commitID: commit.commitID)
            try store.savePairedViewer(record, for: identity)
            pairedRecord = record
        }
    }

    /// Authenticates and persists inbound recovery phases before responding.
    private func handlePairingRecoveryCommit(
        _ commit: RemotePairingCommit,
        client: any WorldwideHostAvailabilityTransport
    ) async throws {
        guard isCurrentAvailabilityClient(client),
              let identity,
              var record = pairedRecord else {
            throw WorldwideHostCoordinatorError.activePairMissing
        }
        switch commit.phase {
        case .acknowledgement:
            try record.acceptAcknowledgement(commit)
            try store.savePairedViewer(record, for: identity)
            let completion = try record.prepareCompletion(using: identity)
            try store.savePairedViewer(record, for: identity)
            pairedRecord = record

            try await client.send(.pairingCommit(completion))
            try record.markCompletionSent(commitID: completion.commitID)
            try store.savePairedViewer(record, for: identity)
            pairedRecord = record

        case .activationAcknowledgement:
            try record.acceptActivationAcknowledgement(commit)
            try store.savePairedViewer(record, for: identity)
            pairedRecord = record
            logger.info("Worldwide pairing commit recovery completed")

        case .proposal, .completion:
            throw WorldwideHostCoordinatorError.unexpectedAvailabilityPayload
        }
    }

    // MARK: - Media sessions

    /// Authenticates a reconnect request and prepares one fresh WebRTC media rendezvous.
    ///
    /// The replay high-water mark is persisted before the response leaves the Mac, so a
    /// crash can never make the same signed reconnect request valid again.
    private func beginMediaSession(
        request: RemoteReconnectRequest,
        exchangeID: String,
        client: any WorldwideHostAvailabilityTransport
    ) async throws {
        guard isCurrentAvailabilityClient(client),
              lifecycle.activeExchangeID == exchangeID,
              let identity,
              var record = pairedRecord else {
            throw WorldwideHostCoordinatorError.reconnectWithoutExchange
        }

        let responder = try record.respond(to: request, using: identity)
        // The replay high-water mark must be durable before any response is sent.
        try store.savePairedViewer(record, for: identity)
        pairedRecord = record

        await stopActiveMediaSession()
        guard !isStopped,
              isCurrentAvailabilityClient(client),
              lifecycle.activeExchangeID == exchangeID else {
            throw CancellationError()
        }

        let service = try WorldwideScreenService(
            endpoint: endpoint,
            sessionCredential: responder.credential,
            forceRelay: forceRelay,
            displayID: displayID,
            maximumWidth: maximumWidth,
            framesPerSecond: framesPerSecond,
            maximumVideoBitrate: maximumVideoBitrate,
            remoteInputController: remoteInputController,
            iPhoneMicrophoneForwardingPolicy:
                iPhoneMicrophoneForwardingPolicy,
            logger: logger
        )
        try lifecycle.mediaStarted(exchangeID: exchangeID)
        mediaService = service
        do {
            try await service.startPairedSession()
            guard !isStopped,
                  isCurrentAvailabilityClient(client),
                  lifecycle.activeExchangeID == exchangeID,
                  mediaService === service else {
                throw CancellationError()
            }
            mediaCompletionTask = Task { [weak self, service] in
                for await _ in service.completion { break }
                await self?.mediaDidEnd(service: service, exchangeID: exchangeID)
            }
            try await client.send(.reconnectResponse(responder.response))
            recordConnectionTelemetry(
                .reconnectResponseSent,
                exchangeID: exchangeID
            )
            recordConnectionTelemetry(
                .mediaSignalingPrepared,
                exchangeID: exchangeID
            )
            logger.info("A fresh encrypted media rendezvous is ready for the paired iPhone")
        } catch {
            await service.stop()
            if mediaService === service {
                mediaService = nil
                mediaCompletionTask?.cancel()
                mediaCompletionTask = nil
            }
            lifecycle.mediaEnded(exchangeID: exchangeID)
            throw error
        }
    }

    /// Releases only the media service that still owns the active exchange.
    private func mediaDidEnd(
        service: WorldwideScreenService,
        exchangeID: String
    ) async {
        guard mediaService === service else { return }
        mediaService = nil
        mediaCompletionTask = nil
        lifecycle.mediaEnded(exchangeID: exchangeID)
        logger.info("Worldwide media ended; the Mac remains available for the paired iPhone")
    }

    /// Detaches actor state before awaiting media teardown and clears lifecycle ownership.
    private func stopActiveMediaSession() async {
        mediaCompletionTask?.cancel()
        mediaCompletionTask = nil
        let service = mediaService
        mediaService = nil
        let exchangeID = lifecycle.mediaExchangeID
        await service?.stop()
        if let exchangeID {
            lifecycle.mediaEnded(exchangeID: exchangeID)
        }
    }

    /// Escalates a current bootstrap failure into full coordinator shutdown.
    private func fail(
        _ error: any Error,
        bootstrap: WorldwidePairingBootstrap
    ) async {
        guard pairingBootstrap === bootstrap, !isStopped else { return }
        logger.error("Worldwide host stopped: \(error.localizedDescription)")
        await shutdown(throwing: error)
    }

    /// Cancels child tasks, closes transports in dependency order, then flushes telemetry.
    private func shutdown(throwing error: (any Error)?) async {
        guard !isStopped else { return }
        isStopped = true
        lifecycle.stop()

        pairingTask?.cancel()
        pairingTask = nil
        let availabilityTask = availabilityTask
        self.availabilityTask = nil
        availabilityGeneration = nil
        availabilityTask?.cancel()
        mediaCompletionTask?.cancel()
        mediaCompletionTask = nil

        let bootstrap = pairingBootstrap
        pairingBootstrap = nil
        let availability = availabilityClient
        availabilityClient = nil
        let media = mediaService
        mediaService = nil

        await bootstrap?.stop()
        await availability?.close()
        await media?.stop()

        if let error {
            _ = await connectionTelemetry.flush()
            completionContinuation.finish(throwing: error)
        } else {
            recordConnectionTelemetry(.hostStopped, terminal: .success)
            _ = await connectionTelemetry.flush()
            completionContinuation.yield(())
            completionContinuation.finish()
        }
    }

    // MARK: - Privacy-preserving telemetry

    /// Records connection state using one-way references instead of raw pair/exchange IDs.
    private func recordConnectionTelemetry(
        _ stage: ConnectionTelemetryStage,
        generation: UUID? = nil,
        exchangeID: String? = nil,
        retryOrdinal: UInt16? = nil,
        delayMilliseconds: UInt64? = nil,
        failure: ConnectionTelemetryFailure? = nil,
        terminal: ConnectionTelemetryTerminal? = nil
    ) {
        let activeGeneration = generation ?? availabilityGeneration
        let attemptReference = activeGeneration.map {
            ConnectionTelemetryFingerprint.derive(domain: .attempt, uuid: $0)
        }
        let pairReference = pairedRecord.map {
            ConnectionTelemetryFingerprint.derive(domain: .pair, uuid: $0.pairID)
        }
        let exchangeReference = exchangeID.map {
            ConnectionTelemetryFingerprint.derive(
                domain: .exchange,
                bytes: Data($0.utf8)
            )
        }
        connectionTelemetry.record(
            ConnectionTelemetryDraft(
                role: .host,
                stage: stage,
                attemptReference: attemptReference,
                pairReference: pairReference,
                exchangeReference: exchangeReference,
                retryOrdinal: retryOrdinal,
                delayMilliseconds: delayMilliseconds,
                failure: failure,
                terminal: terminal
            )
        )
    }

    /// Maps rich local errors into the bounded, non-sensitive telemetry vocabulary.
    private func connectionTelemetryFailure(
        for error: any Error
    ) -> ConnectionTelemetryFailure {
        if error is CancellationError { return .transportCancellation }
        if let signaling = error as? RendezvousSignalingError {
            switch signaling {
            case .connectionClosed, .notConnected:
                return .connectionClosed
            case .connectionFailed:
                return .connectionFailed
            case .sendFailed:
                return .sendFailed
            case .invalidServerMessage, .eventBufferOverflow:
                return .protocolViolation
            case .invalidEndpoint, .alreadyConnected:
                return .unknown
            }
        }
        if let coordinator = error as? WorldwideHostCoordinatorError {
            switch coordinator {
            case .availabilityServer(.peerUnavailable):
                return .peerUnavailable
            case .availabilityServer(.roleConflict):
                return .roleConflict
            case .unexpectedAvailabilityPayload, .reconnectWithoutExchange:
                return .protocolViolation
            case .availabilityLoopEndedUnexpectedly:
                return .unexpectedLoopEnd
            case .invalidLifecycle, .pairingEndedBeforeCommit,
                 .activePairMissing, .availabilityServer:
                return .unknown
            }
        }
        if let core = error as? RemoteSessionCoreError,
           core == .authenticationFailed {
            return .authenticationFailed
        }
        return .unknown
    }
}

/// Fatal lifecycle, authentication-flow, and availability protocol failures.
enum WorldwideHostCoordinatorError: LocalizedError {
    case invalidLifecycle
    case pairingEndedBeforeCommit
    case activePairMissing
    case reconnectWithoutExchange
    case unexpectedAvailabilityPayload
    case availabilityServer(RendezvousServerError)
    case availabilityLoopEndedUnexpectedly

    var errorDescription: String? {
        switch self {
        case .invalidLifecycle:
            "The worldwide host cannot be started in its current state."
        case .pairingEndedBeforeCommit:
            "Worldwide pairing ended before both devices committed."
        case .activePairMissing:
            "The active paired-iPhone record is unavailable."
        case .reconnectWithoutExchange:
            "The reconnect request is not bound to an active availability exchange."
        case .unexpectedAvailabilityPayload:
            "The paired iPhone sent an unexpected availability payload."
        case .availabilityServer(let error):
            switch error {
            case .peerUnavailable:
                "The paired iPhone is no longer available on this exchange."
            case .rateLimited:
                "The availability service rate-limited the Mac; retrying with backoff."
            case .roleConflict:
                "Another Mac availability connection still owns this paired-device channel."
            case .invitationUnavailable, .invitationExpired, .requestRejected:
                "The availability service rejected the Mac connection."
            }
        case .availabilityLoopEndedUnexpectedly:
            "The worldwide availability supervisor ended unexpectedly."
        }
    }

}

private extension PairedAvailabilitySignalingEvent {
    /// Whether this event proves the current socket has a valid host role at the Worker.
    var validatesHostAvailability: Bool {
        switch self {
        case .waiting, .ready:
            true
        case .signal, .peerLeft, .serverError:
            false
        }
    }
}
