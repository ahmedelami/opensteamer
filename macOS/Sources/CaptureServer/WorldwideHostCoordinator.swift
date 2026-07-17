import CaptureCore
import Foundation
import RemoteSessionCore

enum WorldwideHostStartResult: Equatable {
    case invitation(String)
    case paired(remoteDisplayName: String?)
}

actor WorldwideHostCoordinator {
    nonisolated let completion: AsyncThrowingStream<Void, Error>

    private let endpoint: URL
    private let forceRelay: Bool
    private let displayID: UInt32?
    private let maximumWidth: Int
    private let framesPerSecond: Int
    private let maximumVideoBitrate: Int
    private let remoteInputController: MacRemoteInputController
    private let store: WorldwidePairingStore
    private let logger: Logger
    private let hostDisplayName: String?
    private let completionContinuation: AsyncThrowingStream<Void, Error>.Continuation

    private var lifecycle = WorldwideHostLifecycle()
    private var identity: RemoteDeviceIdentity?
    private var pairedRecord: RemotePairedDeviceRecord?
    private var pairingBootstrap: WorldwidePairingBootstrap?
    private var availabilityClient: PairedAvailabilitySignalingClient?
    private var mediaService: WorldwideScreenService?
    private var pairingTask: Task<Void, Never>?
    private var availabilityTask: Task<Void, Never>?
    private var mediaCompletionTask: Task<Void, Never>?
    private var isStarted = false
    private var isStopped = false

    init(
        endpoint: URL,
        forceRelay: Bool,
        displayID: UInt32?,
        maximumWidth: Int,
        framesPerSecond: Int,
        maximumVideoBitrate: Int,
        remoteInputController: MacRemoteInputController,
        store: WorldwidePairingStore = WorldwidePairingStore(),
        hostDisplayName: String? = Host.current().localizedName,
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
        self.store = store
        self.hostDisplayName = hostDisplayName
        self.logger = logger
    }

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

    func stop() async {
        await shutdown(throwing: nil)
    }

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

    private func startAvailabilityLoop() {
        guard availabilityTask == nil, !isStopped else { return }
        availabilityTask = Task { [weak self] in
            await self?.runAvailabilityLoop()
        }
    }

    private func runAvailabilityLoop() async {
        var retryDelaySeconds = 1
        while !Task.isCancelled, !isStopped {
            do {
                guard let record = pairedRecord else {
                    throw WorldwideHostCoordinatorError.activePairMissing
                }
                let client = try PairedAvailabilitySignalingClient(
                    endpoint: endpoint,
                    locator: record.availabilityLocator(),
                    role: .host
                )
                availabilityClient = client
                let events = try await client.connect()
                retryDelaySeconds = 1
                logger.info("Worldwide paired-device availability is online")
                for try await event in events {
                    try Task.checkCancellation()
                    guard !isStopped, availabilityClient === client else { return }
                    try await handleAvailabilityEvent(event, client: client)
                }
                guard !isStopped else { return }
                throw RendezvousSignalingError.connectionClosed
            } catch is CancellationError {
                return
            } catch {
                guard !isStopped else { return }
                if let exchangeID = lifecycle.activeExchangeID {
                    lifecycle.availabilityPeerLeft(exchangeID: exchangeID)
                }
                let client = availabilityClient
                availabilityClient = nil
                await client?.close()
                logger.error(
                    "Worldwide availability disconnected; retrying in " +
                    "\(retryDelaySeconds) seconds (\(error.localizedDescription))"
                )
                do {
                    try await Task.sleep(for: .seconds(retryDelaySeconds))
                } catch {
                    return
                }
                retryDelaySeconds = min(retryDelaySeconds * 2, 30)
            }
        }
    }

    private func handleAvailabilityEvent(
        _ event: PairedAvailabilitySignalingEvent,
        client: PairedAvailabilitySignalingClient
    ) async throws {
        switch event {
        case .waiting:
            logger.debug("Worldwide availability is waiting for the paired iPhone")

        case .ready(_, let exchangeID):
            try lifecycle.availabilityReady(exchangeID: exchangeID.wireValue)
            try await sendPairingRecoveryIfNeeded(client: client)

        case .signal(.pairingCommit(let commit)):
            try await handlePairingRecoveryCommit(commit, client: client)

        case .signal(.reconnectRequest(let request)):
            guard let exchangeValue = lifecycle.activeExchangeID else {
                throw WorldwideHostCoordinatorError.reconnectWithoutExchange
            }
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

        case .serverError:
            throw WorldwideHostCoordinatorError.unexpectedAvailabilityPayload
        }
    }

    private func sendPairingRecoveryIfNeeded(
        client: PairedAvailabilitySignalingClient
    ) async throws {
        guard availabilityClient === client,
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

    private func handlePairingRecoveryCommit(
        _ commit: RemotePairingCommit,
        client: PairedAvailabilitySignalingClient
    ) async throws {
        guard availabilityClient === client,
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

    private func beginMediaSession(
        request: RemoteReconnectRequest,
        exchangeID: String,
        client: PairedAvailabilitySignalingClient
    ) async throws {
        guard availabilityClient === client,
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
              availabilityClient === client,
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
            logger: logger
        )
        try lifecycle.mediaStarted(exchangeID: exchangeID)
        mediaService = service
        do {
            try await service.startPairedSession()
            guard !isStopped,
                  availabilityClient === client,
                  lifecycle.activeExchangeID == exchangeID,
                  mediaService === service else {
                throw CancellationError()
            }
            mediaCompletionTask = Task { [weak self, service] in
                for await _ in service.completion { break }
                await self?.mediaDidEnd(service: service, exchangeID: exchangeID)
            }
            try await client.send(.reconnectResponse(responder.response))
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

    private func fail(
        _ error: any Error,
        bootstrap: WorldwidePairingBootstrap
    ) async {
        guard pairingBootstrap === bootstrap, !isStopped else { return }
        logger.error("Worldwide host stopped: \(error.localizedDescription)")
        await shutdown(throwing: error)
    }

    private func shutdown(throwing error: (any Error)?) async {
        guard !isStopped else { return }
        isStopped = true
        lifecycle.stop()

        pairingTask?.cancel()
        pairingTask = nil
        availabilityTask?.cancel()
        availabilityTask = nil
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
            completionContinuation.finish(throwing: error)
        } else {
            completionContinuation.yield(())
            completionContinuation.finish()
        }
    }
}

enum WorldwideHostCoordinatorError: LocalizedError {
    case invalidLifecycle
    case pairingEndedBeforeCommit
    case activePairMissing
    case reconnectWithoutExchange
    case unexpectedAvailabilityPayload

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
        }
    }
}
