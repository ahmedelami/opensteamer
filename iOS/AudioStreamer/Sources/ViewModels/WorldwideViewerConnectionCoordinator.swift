import Dispatch
import Foundation
import RemoteSessionCore

/// Injectable consume-once invitation transport used during authenticated pairing bootstrap.
/// It carries pairing protocol payloads only; media offers and ICE candidates use a later client.
protocol ViewerPairingBootstrapTransport: AnyObject, Sendable {
    func connect() async throws -> PairingBootstrapSignalingClient.EventStream
    func send(_ payload: RemotePairingPayload) async throws
    func close() async
}

extension PairingBootstrapSignalingClient: ViewerPairingBootstrapTransport {}

/// Injectable pair-scoped availability transport used to mint a fresh media-session credential.
protocol ViewerPairedAvailabilityTransport: AnyObject, Sendable {
    func connect() async throws -> PairedAvailabilitySignalingClient.EventStream
    func send(_ payload: RemoteAvailabilityPayload) async throws
    func close() async
}

extension PairedAvailabilitySignalingClient: ViewerPairedAvailabilityTransport {}

/// Stable identity for one retry budget against one durable pair.
struct SavedPairAttemptContext: Equatable, Sendable {
    let attemptID: UUID
    let pairID: UUID
}

/// Attempt-scoped reachability state for a durable pair. None of these cases revoke, expire,
/// deactivate, or delete the Keychain record. In particular, deadline exhaustion cannot tell a
/// sleeping Mac from a network outage or a Mac that was reset locally.
enum SavedPairConnectionState: Equatable, Sendable {
    case idle
    case waitingForAvailability(SavedPairAttemptContext)
    case preparingSession(SavedPairAttemptContext)
    case unavailableAfterDeadline(SavedPairAttemptContext)
}

/// Performs the identity bootstrap and paired reconnect phases that precede ordinary WebRTC
/// media signaling. Invitation transport never carries SDP/ICE, and persistent availability
/// never carries media signaling; each connection derives a fresh one-use session credential.
@MainActor
final class WorldwideViewerConnectionCoordinator: ObservableObject {
    @Published private(set) var isConnecting = false
    @Published private(set) var stateText = "Not connected"
    @Published private(set) var lastError: String?
    @Published private(set) var savedPairConnectionState: SavedPairConnectionState = .idle
    @Published private(set) var connectionTelemetrySnapshot: ConnectionTelemetrySnapshot

    typealias BootstrapClientFactory = (
        URL,
        RemoteInvitationCode
    ) throws -> any ViewerPairingBootstrapTransport
    typealias AvailabilityClientFactory = (
        URL,
        RemoteAvailabilityLocator
    ) throws -> any ViewerPairedAvailabilityTransport
    typealias AvailabilityMonotonicNow = @Sendable () -> UInt64
    typealias AvailabilityRetrySleep = @Sendable (
        _ baseDelayNanoseconds: UInt64,
        _ remainingDeadlineNanoseconds: UInt64
    ) async throws -> Void
    typealias AvailabilityAttemptDeadlineSleep = @Sendable (
        _ timeoutNanoseconds: UInt64
    ) async throws -> Void
    typealias ReconnectResponseTimeoutSleep = @Sendable (
        _ timeoutNanoseconds: UInt64
    ) async throws -> Void

    private let makeBootstrapClient: BootstrapClientFactory
    private let makeAvailabilityClient: AvailabilityClientFactory
    private let availabilityRetryDeadlineNanoseconds: UInt64
    private let availabilityMonotonicNow: AvailabilityMonotonicNow
    private let availabilityRetrySleep: AvailabilityRetrySleep
    private let availabilityAttemptDeadlineSleep: AvailabilityAttemptDeadlineSleep
    private let reconnectResponseTimeoutNanoseconds: UInt64
    private let reconnectResponseTimeoutSleep: ReconnectResponseTimeoutSleep
    private let pairingBackgroundTask: any TransitionBackgroundTaskCoordinating
    private let connectionTelemetry: any ConnectionTelemetryRecording
    private var activeOperationID: UUID?
    private var bootstrapClient: (any ViewerPairingBootstrapTransport)?
    private var bootstrapClientOperationID: UUID?
    private var availabilityClient: (any ViewerPairedAvailabilityTransport)?
    private var availabilityClientOperationID: UUID?
    private var terminalTelemetryAttempts = Set<UUID>()
    private var terminalTelemetryOrder: [UUID] = []
    private var deadlineTelemetryAttempts = Set<UUID>()

    init(
        bootstrapClientFactory: @escaping BootstrapClientFactory = { endpoint, invitation in
            try PairingBootstrapSignalingClient(
                endpoint: endpoint,
                invitation: invitation,
                role: .viewer
            )
        },
        availabilityClientFactory: @escaping AvailabilityClientFactory = { endpoint, locator in
            try PairedAvailabilitySignalingClient(
                endpoint: endpoint,
                locator: locator,
                role: .viewer
            )
        },
        availabilityRetryDeadlineNanoseconds: UInt64 = 60_000_000_000,
        availabilityMonotonicNow: @escaping AvailabilityMonotonicNow = {
            DispatchTime.now().uptimeNanoseconds
        },
        availabilityRetrySleep: @escaping AvailabilityRetrySleep = { baseDelay, remaining in
            let jitterRange = baseDelay / 5
            let lowerBound = baseDelay - jitterRange
            let upperBound = baseDelay + jitterRange
            let jitteredDelay = UInt64.random(in: lowerBound...upperBound)
            let boundedDelay = min(jitteredDelay, remaining)
            guard boundedDelay > 0 else { return }
            try await Task<Never, Never>.sleep(nanoseconds: boundedDelay)
        },
        availabilityAttemptDeadlineSleep: @escaping AvailabilityAttemptDeadlineSleep = { timeout in
            try await Task<Never, Never>.sleep(nanoseconds: timeout)
        },
        reconnectResponseTimeoutNanoseconds: UInt64 = 8_000_000_000,
        reconnectResponseTimeoutSleep: @escaping ReconnectResponseTimeoutSleep = { timeout in
            try await Task<Never, Never>.sleep(nanoseconds: timeout)
        },
        connectionTelemetry: any ConnectionTelemetryRecording =
            NoopConnectionTelemetryRecorder(),
        pairingBackgroundTask: any TransitionBackgroundTaskCoordinating =
            AppTransitionBackgroundTaskCoordinator(name: "AudioStreamerSecurePairing")
    ) {
        makeBootstrapClient = bootstrapClientFactory
        makeAvailabilityClient = availabilityClientFactory
        self.availabilityRetryDeadlineNanoseconds = availabilityRetryDeadlineNanoseconds
        self.availabilityMonotonicNow = availabilityMonotonicNow
        self.availabilityRetrySleep = availabilityRetrySleep
        self.availabilityAttemptDeadlineSleep = availabilityAttemptDeadlineSleep
        self.reconnectResponseTimeoutNanoseconds = max(
            1,
            reconnectResponseTimeoutNanoseconds
        )
        self.reconnectResponseTimeoutSleep = reconnectResponseTimeoutSleep
        self.connectionTelemetry = connectionTelemetry
        connectionTelemetrySnapshot = connectionTelemetry.snapshot()
        self.pairingBackgroundTask = pairingBackgroundTask
    }

    // MARK: - Public pairing and reconnect operations

    func pairAndPrepareMediaSession(
        invitationCode input: String,
        endpoint: URL,
        pairingState: ViewerPairingState,
        onRecoverableInvitationAdmitted: @escaping @MainActor () throws -> Void,
        onAuthenticatedPairingCompleted: @escaping @MainActor () -> Void
    ) async throws -> RendezvousSignalingClient {
        let operationID = try beginOperation(state: "Pairing securely")
        defer { finishOperation(operationID) }
        var savedPairContext: SavedPairAttemptContext?

        do {
            let invitation = try RemoteInvitationCode(input)
            let activeRecord = try await bootstrapPairing(
                invitation: invitation,
                endpoint: endpoint,
                pairingState: pairingState,
                operationID: operationID,
                onRecoverableInvitationAdmitted: onRecoverableInvitationAdmitted,
                onAuthenticatedPairingCompleted: onAuthenticatedPairingCompleted
            )
            try requireCurrentOperation(operationID)
            let context = try beginSavedPairAttempt(
                operationID: operationID,
                record: activeRecord,
                pairingState: pairingState
            )
            savedPairContext = context
            stateText = "Finding paired Mac"
            let client = try await prepareMediaSession(
                endpoint: endpoint,
                identity: try requireIdentity(pairingState),
                record: activeRecord,
                pairingState: pairingState,
                operationID: operationID,
                onAuthenticatedPairingCompleted: nil,
                savedPairContext: context
            )
            try requireCurrentSavedPairAttempt(
                context,
                pairingState: pairingState,
                operationID: operationID
            )
            savedPairConnectionState = .idle
            stateText = "Starting secure media"
            lastError = nil
            recordTerminalTelemetryOnce(
                context: context,
                operationID: operationID,
                terminal: .success
            )
            return client
        } catch is CancellationError {
            recordTerminalTelemetryOnce(
                context: savedPairContext,
                operationID: operationID,
                terminal: .cancelled
            )
            await closeTransports(ownedBy: operationID)
            if activeOperationID == operationID {
                savedPairConnectionState = .idle
                stateText = "Not connected"
            }
            throw CancellationError()
        } catch {
            recordTerminalTelemetryOnce(
                context: savedPairContext,
                operationID: operationID,
                terminal: .failed,
                failure: terminalConnectionTelemetryFailure(
                    for: error,
                    context: savedPairContext
                )
            )
            await closeTransports(ownedBy: operationID)
            if activeOperationID == operationID {
                if !publishSavedPairExhaustion(
                    error,
                    context: savedPairContext,
                    pairingState: pairingState,
                    operationID: operationID
                ) {
                    savedPairConnectionState = .idle
                    publish(error)
                }
            }
            throw error
        }
    }

    func preparePairedMediaSession(
        endpoint: URL,
        pairingState: ViewerPairingState,
        onAuthenticatedPairingCompleted: @escaping @MainActor () -> Void
    ) async throws -> RendezvousSignalingClient {
        let operationID = try beginOperation(state: "Finding paired Mac")
        defer { finishOperation(operationID) }
        var savedPairContext: SavedPairAttemptContext?

        do {
            let identity = try requireIdentity(pairingState)
            let record = try requireRecoverableRecord(pairingState)
            let context = try beginSavedPairAttempt(
                operationID: operationID,
                record: record,
                pairingState: pairingState
            )
            savedPairContext = context
            let client = try await prepareMediaSession(
                endpoint: endpoint,
                identity: identity,
                record: record,
                pairingState: pairingState,
                operationID: operationID,
                onAuthenticatedPairingCompleted: onAuthenticatedPairingCompleted,
                savedPairContext: context
            )
            try requireCurrentSavedPairAttempt(
                context,
                pairingState: pairingState,
                operationID: operationID
            )
            savedPairConnectionState = .idle
            stateText = "Starting secure media"
            lastError = nil
            recordTerminalTelemetryOnce(
                context: context,
                operationID: operationID,
                terminal: .success
            )
            return client
        } catch is CancellationError {
            recordTerminalTelemetryOnce(
                context: savedPairContext,
                operationID: operationID,
                terminal: .cancelled
            )
            await closeTransports(ownedBy: operationID)
            if activeOperationID == operationID {
                savedPairConnectionState = .idle
                stateText = "Not connected"
            }
            throw CancellationError()
        } catch {
            recordTerminalTelemetryOnce(
                context: savedPairContext,
                operationID: operationID,
                terminal: .failed,
                failure: terminalConnectionTelemetryFailure(
                    for: error,
                    context: savedPairContext
                )
            )
            await closeTransports(ownedBy: operationID)
            if activeOperationID == operationID {
                if !publishSavedPairExhaustion(
                    error,
                    context: savedPairContext,
                    pairingState: pairingState,
                    operationID: operationID
                ) {
                    savedPairConnectionState = .idle
                    publish(error)
                }
            }
            throw error
        }
    }

    /// Recovers a pairing that stopped after either peer had persisted only part of the
    /// distributed commit. A partial viewer record alone cannot reveal whether the Mac is
    /// still serving the one-time bootstrap or has already moved to pair-scoped availability.
    /// Retry the still-saved invitation first, then fall back to the latest durable record.
    func recoverInterruptedPairingAndPrepareMediaSession(
        invitationCode input: String,
        endpoint: URL,
        pairingState: ViewerPairingState,
        onRecoverableInvitationAdmitted: @escaping @MainActor () throws -> Void,
        onAuthenticatedPairingCompleted: @escaping @MainActor () -> Void
    ) async throws -> RendezvousSignalingClient {
        let operationID = try beginOperation(state: "Recovering secure pairing")
        defer { finishOperation(operationID) }
        var savedPairContext: SavedPairAttemptContext?

        do {
            let recordToPrepare: RemotePairedDeviceRecord
            var completionAfterAvailability: (@MainActor () -> Void)? =
                onAuthenticatedPairingCompleted
            var usesDurableFallback = false

            // This catch intentionally covers only acquisition through the one-time bootstrap.
            // Once bootstrap succeeds, every availability/media-preparation error belongs to that
            // single attempt and must propagate through the outer handler instead of silently
            // starting a second full deadline against the durable record.
            do {
                let invitation = try RemoteInvitationCode(input)
                var replacementRetry = 0
                while true {
                    do {
                        recordToPrepare = try await bootstrapPairing(
                            invitation: invitation,
                            endpoint: endpoint,
                            pairingState: pairingState,
                            operationID: operationID,
                            onRecoverableInvitationAdmitted: onRecoverableInvitationAdmitted,
                            onAuthenticatedPairingCompleted: onAuthenticatedPairingCompleted
                        )
                        break
                    } catch {
                        try Task.checkCancellation()
                        try requireCurrentOperation(operationID)
                        guard replacementRetry < 3,
                              isTransientBootstrapReplacementError(error) else {
                            throw error
                        }
                        // A force-closed socket can briefly remain in the network stack after
                        // process relaunch. Retry the same saved capability before concluding
                        // that the Mac has moved to pair-scoped availability.
                        replacementRetry += 1
                        stateText = "Waiting for the saved invitation"
                        try await Task<Never, Never>.sleep(
                            for: .milliseconds(200 * replacementRetry)
                        )
                    }
                }
                completionAfterAvailability = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Confirmation and ACK sends cross a distributed durability boundary. If the
                // Mac advanced farther than this process observed, raw bootstrap rejects while
                // the latest Keychain record remains the authenticated recovery credential.
                try requireCurrentOperation(operationID)
                recordToPrepare = try requireRecoverableRecord(pairingState)
                usesDurableFallback = true
            }

            try requireCurrentOperation(operationID)
            let context = try beginSavedPairAttempt(
                operationID: operationID,
                record: recordToPrepare,
                pairingState: pairingState
            )
            savedPairContext = context
            stateText = usesDurableFallback
                ? "Recovering saved secure pairing"
                : "Finding paired Mac"
            let client = try await prepareMediaSession(
                endpoint: endpoint,
                identity: try requireIdentity(pairingState),
                record: recordToPrepare,
                pairingState: pairingState,
                operationID: operationID,
                onAuthenticatedPairingCompleted: completionAfterAvailability,
                savedPairContext: context
            )
            try requireCurrentSavedPairAttempt(
                context,
                pairingState: pairingState,
                operationID: operationID
            )
            savedPairConnectionState = .idle
            stateText = "Starting secure media"
            lastError = nil
            recordTerminalTelemetryOnce(
                context: context,
                operationID: operationID,
                terminal: .success
            )
            return client
        } catch is CancellationError {
            recordTerminalTelemetryOnce(
                context: savedPairContext,
                operationID: operationID,
                terminal: .cancelled
            )
            await closeTransports(ownedBy: operationID)
            if activeOperationID == operationID {
                savedPairConnectionState = .idle
                stateText = "Not connected"
            }
            throw CancellationError()
        } catch {
            recordTerminalTelemetryOnce(
                context: savedPairContext,
                operationID: operationID,
                terminal: .failed,
                failure: terminalConnectionTelemetryFailure(
                    for: error,
                    context: savedPairContext
                )
            )
            await closeTransports(ownedBy: operationID)
            if activeOperationID == operationID {
                if !publishSavedPairExhaustion(
                    error,
                    context: savedPairContext,
                    pairingState: pairingState,
                    operationID: operationID
                ) {
                    savedPairConnectionState = .idle
                    publish(error)
                }
            }
            throw error
        }
    }

    func cancel() {
        guard let operationID = activeOperationID else { return }
        recordTerminalTelemetryOnce(
            context: nil,
            operationID: operationID,
            terminal: .cancelled
        )
        activeOperationID = nil
        isConnecting = false
        savedPairConnectionState = .idle
        stateText = "Not connected"
        pairingBackgroundTask.endTransitionTask()
        let transports = removeTransports(ownedBy: operationID)
        Task {
            await transports.bootstrap?.close()
            await transports.availability?.close()
        }
    }

    func clearError() {
        lastError = nil
        savedPairConnectionState = .idle
    }

    func reportConfigurationError(_ message: String) {
        savedPairConnectionState = .idle
        stateText = "Service unavailable"
        lastError = message
    }

    // MARK: - Pairing bootstrap

    private func bootstrapPairing(
        invitation: RemoteInvitationCode,
        endpoint: URL,
        pairingState: ViewerPairingState,
        operationID: UUID,
        onRecoverableInvitationAdmitted: @escaping @MainActor () throws -> Void,
        onAuthenticatedPairingCompleted: @escaping @MainActor () -> Void
    ) async throws -> RemotePairedDeviceRecord {
        try requireCurrentOperation(operationID)
        let identity = try requireIdentity(pairingState)
        guard identity.role == .viewer else {
            throw WorldwideViewerConnectionError.invalidViewerIdentity
        }

        let participant = try RemotePairingParticipant(
            identity: identity,
            invitation: invitation
        )
        let client = try makeBootstrapClient(endpoint, invitation)
        bootstrapClient = client
        bootstrapClientOperationID = operationID

        var agreement: RemotePairingAgreement?
        var record: RemotePairedDeviceRecord?
        var helloSent = false
        let generation = UUID()
        var acceptance = InvitationAcceptanceAction()
        acceptance.arm(
            generation: generation,
            onAdmitted: onRecoverableInvitationAdmitted
        ) { record in
            try pairingState.saveAuthenticatedPairing(record)
            onAuthenticatedPairingCompleted()
        }

        do {
            let events = try await client.connect()
            for try await event in events {
                try Task.checkCancellation()
                try requireCurrentOperation(operationID)
                switch event {
                case .waiting(let expiration):
                    stateText = "Waiting for Mac until \(expiration.formatted(date: .omitted, time: .shortened))"

                case .ready:
                    // Readiness alone leaves no durable authenticated state to resume. Do not
                    // mark the saved invitation as admitted until the viewer acknowledgement
                    // record has reached Keychain below.
                    guard !helloSent else { continue }
                    helloSent = true
                    stateText = "Authenticating Mac"
                    try await client.send(.hello(participant.hello))

                case .signal(.hello(let peerHello)):
                    guard helloSent, agreement == nil, record == nil else {
                        throw WorldwideViewerConnectionError.unexpectedPairingMessage
                    }
                    let accepted = try participant.accept(peerHello)
                    agreement = accepted

                case .signal(.confirmation(let peerConfirmation)):
                    guard let agreement, record == nil else {
                        throw WorldwideViewerConnectionError.unexpectedPairingMessage
                    }
                    let pending = try agreement.makePendingRecord(
                        peerConfirmation: peerConfirmation
                    )
                    // Persist the pair root before either side enters the commit protocol.
                    try pairingState.savePairingRecord(pending)
                    record = pending
                    // The viewer confirmation is deliberately asymmetric: the Mac cannot
                    // create a durable record until it receives this message, and this message
                    // is never sent until the viewer's matching record is already durable.
                    // Therefore a Mac-side partial record always has an iPhone recovery peer.
                    try await client.send(.confirmation(try agreement.makeConfirmation()))
                    try Task.checkCancellation()
                    try requireCurrentOperation(operationID)
                    stateText = "Committing secure pairing"

                case .signal(.commit(let commit)):
                    guard var current = record else {
                        throw WorldwideViewerConnectionError.unexpectedPairingMessage
                    }
                    switch commit.phase {
                    case .proposal:
                        guard current.pairingState == .pending
                                || current.pairingState == .acceptedIssued else {
                            throw WorldwideViewerConnectionError.unexpectedPairingMessage
                        }
                        // An idempotent replay still authenticates this freshly received
                        // proposal before the durable acknowledgement may be resent.
                        let acknowledgement = try current.prepareAcknowledgement(
                            after: commit,
                            using: identity
                        )
                        guard acknowledgement.phase == .acknowledgement else {
                            throw WorldwideViewerConnectionError.invalidPairingRecovery
                        }
                        // Crash-safe boundary: ACK state is durable before every transmission.
                        try pairingState.savePairingRecord(current)
                        record = current
                        // The one-time admission marker follows the recoverable record and is
                        // written immediately before sequence-2 (viewer ACK) transmission. Thus
                        // every admitted relaunch can route through pairing recovery, never the
                        // raw invitation field.
                        try acceptance.persistAdmissionAfterRecoverablePairing(
                            current,
                            generation: generation
                        )
                        try await client.send(.commit(acknowledgement))

                    case .completion:
                        guard current.pairingState == .acceptedIssued else {
                            throw WorldwideViewerConnectionError.unexpectedPairingMessage
                        }
                        let activation = try current.acceptCompletion(
                            commit,
                            using: identity
                        )
                        guard current.pairingState == .active else {
                            throw WorldwideViewerConnectionError.incompletePairing
                        }
                        // The action persists active state first, then clears the invitation.
                        guard try acceptance.completeAuthenticatedPairing(
                            current,
                            generation: generation
                        ) else {
                            throw WorldwideViewerConnectionError.incompletePairing
                        }
                        record = current
                        // Active state is durable before the host receives this proof.
                        try await client.send(.commit(activation))
                        if bootstrapClientOperationID == operationID {
                            bootstrapClient = nil
                            bootstrapClientOperationID = nil
                        }
                        await client.close()
                        try requireCurrentOperation(operationID)
                        return current

                    case .acknowledgement, .activationAcknowledgement:
                        throw WorldwideViewerConnectionError.unexpectedPairingMessage
                    }

                case .peerLeft:
                    throw WorldwideViewerConnectionError.pairingEndedBeforeCommit

                case .serverError(let error):
                    throw WorldwideViewerConnectionError.rendezvous(error)
                }
            }
            throw WorldwideViewerConnectionError.pairingEndedBeforeCommit
        } catch {
            acceptance.cancel(generation: generation)
            if bootstrapClientOperationID == operationID {
                bootstrapClient = nil
                bootstrapClientOperationID = nil
            }
            await client.close()
            throw error
        }
    }

    private func prepareMediaSession(
        endpoint: URL,
        identity: RemoteDeviceIdentity,
        record initialRecord: RemotePairedDeviceRecord,
        pairingState: ViewerPairingState,
        operationID: UUID,
        onAuthenticatedPairingCompleted: (@MainActor () -> Void)?,
        savedPairContext: SavedPairAttemptContext
    ) async throws -> RendezvousSignalingClient {
        var record = initialRecord
        var retryIndex = 0
        let retryStartedAt = availabilityMonotonicNow()

        while true {
            try Task.checkCancellation()
            let retryOrdinal = UInt16(clamping: retryIndex)
            try transitionSavedPairAttempt(
                to: .waitingForAvailability(savedPairContext),
                context: savedPairContext,
                pairingState: pairingState,
                operationID: operationID
            )
            guard let remainingDeadline = availabilityRetryTimeRemaining(
                since: retryStartedAt
            ) else {
                let error = WorldwideViewerConnectionError.pairedMacUnavailable
                recordAvailabilityDeadlineTelemetryOnce(
                    context: savedPairContext,
                    retryOrdinal: retryOrdinal
                )
                try markSavedPairDeadlineExhausted(
                    error,
                    context: savedPairContext,
                    pairingState: pairingState,
                    operationID: operationID
                )
                throw error
            }
            do {
                recordConnectionTelemetry(
                    .availabilitySocketOpening,
                    context: savedPairContext,
                    retryOrdinal: retryOrdinal
                )
                let mediaClient = try await prepareMediaSessionAttempt(
                    endpoint: endpoint,
                    identity: identity,
                    record: record,
                    pairingState: pairingState,
                    operationID: operationID,
                    onAuthenticatedPairingCompleted: onAuthenticatedPairingCompleted,
                    savedPairContext: savedPairContext,
                    retryOrdinal: retryOrdinal,
                    availabilityDeadlineNanoseconds: remainingDeadline,
                    reconnectResponseTimeoutNanoseconds: min(
                        reconnectResponseTimeoutNanoseconds,
                        remainingDeadline
                    )
                )
                // A valid response that was already buffered can race the attempt deadline's
                // transport close. Re-check the coordinator's authoritative monotonic budget
                // before allowing that response to create a session beyond the advertised
                // availability window.
                guard availabilityRetryTimeRemaining(since: retryStartedAt) != nil else {
                    await mediaClient.close()
                    let error = WorldwideViewerConnectionError.pairedMacUnavailable
                    recordAvailabilityDeadlineTelemetryOnce(
                        context: savedPairContext,
                        retryOrdinal: retryOrdinal
                    )
                    try markSavedPairDeadlineExhausted(
                        error,
                        context: savedPairContext,
                        pairingState: pairingState,
                        operationID: operationID
                    )
                    throw error
                }
                return mediaClient
            } catch {
                try Task.checkCancellation()
                try requireCurrentSavedPairAttempt(
                    savedPairContext,
                    pairingState: pairingState,
                    operationID: operationID
                )
                guard isTransientAvailabilityError(error) else {
                    throw error
                }
                guard let remaining = availabilityRetryTimeRemaining(
                    since: retryStartedAt
                ) else {
                    recordAvailabilityDeadlineTelemetryOnce(
                        context: savedPairContext,
                        retryOrdinal: retryOrdinal
                    )
                    try markSavedPairDeadlineExhausted(
                        error,
                        context: savedPairContext,
                        pairingState: pairingState,
                        operationID: operationID
                    )
                    throw error
                }

                try transitionSavedPairAttempt(
                    to: .waitingForAvailability(savedPairContext),
                    context: savedPairContext,
                    pairingState: pairingState,
                    operationID: operationID
                )
                stateText = "Waiting for paired Mac"
                let delay = availabilityRetryBaseDelay(retryIndex: retryIndex)
                recordConnectionTelemetry(
                    .retryScheduled,
                    context: savedPairContext,
                    retryOrdinal: retryOrdinal,
                    delayMilliseconds: delay / 1_000_000,
                    failure: connectionTelemetryFailure(for: error)
                )
                retryIndex += 1
                try await availabilityRetrySleep(delay, remaining)
                try Task.checkCancellation()
                try requireCurrentSavedPairAttempt(
                    savedPairContext,
                    pairingState: pairingState,
                    operationID: operationID
                )
                guard availabilityRetryTimeRemaining(since: retryStartedAt) != nil else {
                    recordAvailabilityDeadlineTelemetryOnce(
                        context: savedPairContext,
                        retryOrdinal: retryOrdinal
                    )
                    try markSavedPairDeadlineExhausted(
                        error,
                        context: savedPairContext,
                        pairingState: pairingState,
                        operationID: operationID
                    )
                    throw error
                }

                // A prior attempt may have durably advanced pairing recovery or the reconnect
                // sequence. Always retry from the latest Keychain-backed record.
                guard let latestRecord = pairingState.pairingRecord,
                      latestRecord.pairID == initialRecord.pairID,
                      latestRecord.localDeviceID == identity.deviceID else {
                    throw WorldwideViewerConnectionError.incompletePairing
                }
                record = latestRecord
            }
        }
    }

    // MARK: - Availability retry policy

    private func availabilityRetryBaseDelay(retryIndex: Int) -> UInt64 {
        switch retryIndex {
        case 0: 250_000_000
        case 1: 500_000_000
        case 2: 1_000_000_000
        case 3: 2_000_000_000
        default: 4_000_000_000
        }
    }

    private func availabilityRetryTimeRemaining(since startedAt: UInt64) -> UInt64? {
        let now = availabilityMonotonicNow()
        // A monotonic clock moving backwards is a fail-closed deadline expiration.
        guard now >= startedAt else { return nil }
        let elapsed = now - startedAt
        guard elapsed < availabilityRetryDeadlineNanoseconds else { return nil }
        return availabilityRetryDeadlineNanoseconds - elapsed
    }

    private func prepareMediaSessionAttempt(
        endpoint: URL,
        identity: RemoteDeviceIdentity,
        record initialRecord: RemotePairedDeviceRecord,
        pairingState: ViewerPairingState,
        operationID: UUID,
        onAuthenticatedPairingCompleted: (@MainActor () -> Void)?,
        savedPairContext: SavedPairAttemptContext,
        retryOrdinal: UInt16,
        availabilityDeadlineNanoseconds: UInt64,
        reconnectResponseTimeoutNanoseconds: UInt64
    ) async throws -> RendezvousSignalingClient {
        try requireCurrentSavedPairAttempt(
            savedPairContext,
            pairingState: pairingState,
            operationID: operationID
        )
        let client = try makeAvailabilityClient(
            endpoint,
            try initialRecord.availabilityLocator()
        )
        availabilityClient = client
        availabilityClientOperationID = operationID
        var record = initialRecord
        var reconnect: RemoteReconnectInitiator?
        var activeAvailabilityExchangeID: RemoteAvailabilityExchangeID?
        var reconnectExchangeID: RemoteAvailabilityExchangeID?
        let availabilityDeadlineTask = makeAvailabilityAttemptDeadlineTask(
            client: client,
            timeoutNanoseconds: availabilityDeadlineNanoseconds,
            context: savedPairContext,
            retryOrdinal: retryOrdinal
        )
        var reconnectResponseDeadlineTask: Task<Void, Never>?
        let recoveryGeneration = UUID()
        var acceptance = InvitationAcceptanceAction()
        acceptance.arm(generation: recoveryGeneration) { activeRecord in
            try self.requireCurrentSavedPairMutation(
                savedPairContext,
                record: activeRecord,
                pairingState: pairingState,
                operationID: operationID
            )
            try pairingState.saveAuthenticatedPairing(activeRecord)
            try self.requireCurrentSavedPairMutation(
                savedPairContext,
                record: activeRecord,
                pairingState: pairingState,
                operationID: operationID
            )
            onAuthenticatedPairingCompleted?()
        }
        defer {
            availabilityDeadlineTask.cancel()
            reconnectResponseDeadlineTask?.cancel()
        }

        do {
            let events = try await client.connect()
            recordConnectionTelemetry(
                .availabilitySocketOpened,
                context: savedPairContext,
                retryOrdinal: retryOrdinal
            )
            for try await event in events {
                try Task.checkCancellation()
                try requireCurrentSavedPairAttempt(
                    savedPairContext,
                    pairingState: pairingState,
                    operationID: operationID
                )
                switch event {
                case .waiting:
                    recordConnectionTelemetry(
                        .viewerWorkerWaitingForHost,
                        context: savedPairContext,
                        retryOrdinal: retryOrdinal
                    )
                    try transitionSavedPairAttempt(
                        to: .waitingForAvailability(savedPairContext),
                        context: savedPairContext,
                        pairingState: pairingState,
                        operationID: operationID
                    )
                    stateText = "Waiting for paired Mac"

                case .ready(_, let exchangeID):
                    recordConnectionTelemetry(
                        .availabilityReady,
                        context: savedPairContext,
                        exchangeID: exchangeID.wireValue,
                        retryOrdinal: retryOrdinal
                    )
                    try transitionSavedPairAttempt(
                        to: .preparingSession(savedPairContext),
                        context: savedPairContext,
                        pairingState: pairingState,
                        operationID: operationID
                    )
                    activeAvailabilityExchangeID = exchangeID
                    switch record.pairingState {
                    case .pending:
                        stateText = "Recovering secure pairing"
                    case .acceptedIssued:
                        guard case .resend(let acknowledgement) = record.recoveryAction,
                              acknowledgement.phase == .acknowledgement else {
                            throw WorldwideViewerConnectionError.invalidPairingRecovery
                        }
                        stateText = "Recovering secure pairing"
                        try await client.send(.pairingCommit(acknowledgement))
                    case .active:
                        switch record.recoveryAction {
                        case .resend(let activation):
                            guard activation.phase == .activationAcknowledgement else {
                                throw WorldwideViewerConnectionError.invalidPairingRecovery
                            }
                            // Resend the durable activation proof before the reconnect request.
                            try await client.send(.pairingCommit(activation))
                            try requireCurrentSavedPairMutation(
                                savedPairContext,
                                record: record,
                                pairingState: pairingState,
                                operationID: operationID
                            )
                        case .none, .awaitProposal, .issueProposal, .issueCompletion:
                            throw WorldwideViewerConnectionError.invalidPairingRecovery
                        }
                        if onAuthenticatedPairingCompleted != nil {
                            _ = try acceptance.completeAuthenticatedPairing(
                                record,
                                generation: recoveryGeneration
                            )
                        }
                        if let reconnectExchangeID {
                            guard reconnectExchangeID != exchangeID else { continue }
                            reconnectResponseDeadlineTask?.cancel()
                            reconnectResponseDeadlineTask = nil
                            reconnect = nil
                        }
                        let initiator = try record.beginReconnect(using: identity)
                        // The monotonic request counter must be durable before transmission.
                        try pairingState.savePairingRecord(record)
                        reconnect = initiator
                        reconnectExchangeID = exchangeID
                        stateText = "Authorizing fresh session"
                        reconnectResponseDeadlineTask = makeReconnectResponseDeadlineTask(
                            client: client,
                            timeoutNanoseconds: reconnectResponseTimeoutNanoseconds,
                            context: savedPairContext,
                            retryOrdinal: retryOrdinal
                        )
                        try await client.send(.reconnectRequest(initiator.request))
                        recordConnectionTelemetry(
                            .reconnectRequestSent,
                            context: savedPairContext,
                            exchangeID: exchangeID.wireValue,
                            retryOrdinal: retryOrdinal
                        )
                    case .acceptedReceived:
                        throw WorldwideViewerConnectionError.invalidPairingRecovery
                    }

                case .signal(.pairingCommit(let commit)):
                    switch commit.phase {
                    case .proposal:
                        guard record.pairingState == .pending
                                || record.pairingState == .acceptedIssued else {
                            throw WorldwideViewerConnectionError.unexpectedAvailabilityMessage
                        }
                        let acknowledgement = try record.prepareAcknowledgement(
                            after: commit,
                            using: identity
                        )
                        try pairingState.savePairingRecord(record)
                        try await client.send(.pairingCommit(acknowledgement))

                    case .completion:
                        guard record.pairingState == .acceptedIssued
                                || record.pairingState == .active else {
                            throw WorldwideViewerConnectionError.unexpectedAvailabilityMessage
                        }
                        let activation = try record.acceptCompletion(
                            commit,
                            using: identity
                        )
                        guard record.pairingState == .active else {
                            throw WorldwideViewerConnectionError.incompletePairing
                        }
                        _ = try acceptance.completeAuthenticatedPairing(
                            record,
                            generation: recoveryGeneration
                        )
                        // Persist active state before sending its signed activation proof.
                        try await client.send(.pairingCommit(activation))
                        try requireCurrentSavedPairMutation(
                            savedPairContext,
                            record: record,
                            pairingState: pairingState,
                            operationID: operationID
                        )
                        guard reconnect == nil else { continue }
                        let initiator = try record.beginReconnect(using: identity)
                        try pairingState.savePairingRecord(record)
                        reconnect = initiator
                        reconnectExchangeID = activeAvailabilityExchangeID
                        stateText = "Authorizing fresh session"
                        reconnectResponseDeadlineTask = makeReconnectResponseDeadlineTask(
                            client: client,
                            timeoutNanoseconds: reconnectResponseTimeoutNanoseconds,
                            context: savedPairContext,
                            retryOrdinal: retryOrdinal
                        )
                        try await client.send(.reconnectRequest(initiator.request))
                        recordConnectionTelemetry(
                            .reconnectRequestSent,
                            context: savedPairContext,
                            exchangeID: activeAvailabilityExchangeID?.wireValue,
                            retryOrdinal: retryOrdinal
                        )

                    case .acknowledgement, .activationAcknowledgement:
                        throw WorldwideViewerConnectionError.unexpectedAvailabilityMessage
                    }

                case .signal(.reconnectResponse(let response)):
                    guard let reconnect else {
                        throw WorldwideViewerConnectionError.unexpectedAvailabilityMessage
                    }
                    reconnectResponseDeadlineTask?.cancel()
                    reconnectResponseDeadlineTask = nil
                    recordConnectionTelemetry(
                        .reconnectResponseReceived,
                        context: savedPairContext,
                        exchangeID: reconnectExchangeID?.wireValue,
                        retryOrdinal: retryOrdinal
                    )
                    let credential = try reconnect.complete(with: response)
                    if availabilityClientOperationID == operationID {
                        availabilityClient = nil
                        availabilityClientOperationID = nil
                    }
                    await client.close()
                    try requireCurrentSavedPairMutation(
                        savedPairContext,
                        record: record,
                        pairingState: pairingState,
                        operationID: operationID
                    )
                    recordConnectionTelemetry(
                        .mediaSignalingPrepared,
                        context: savedPairContext,
                        exchangeID: reconnectExchangeID?.wireValue,
                        retryOrdinal: retryOrdinal
                    )
                    return try RendezvousSignalingClient(
                        endpoint: endpoint,
                        credential: credential,
                        role: .viewer
                    )

                case .signal(.reconnectRequest):
                    throw WorldwideViewerConnectionError.unexpectedAvailabilityMessage

                case .peerLeft:
                    throw WorldwideViewerConnectionError.pairedMacUnavailable

                case .serverError(let error):
                    throw WorldwideViewerConnectionError.rendezvous(error)
                }
            }
            throw WorldwideViewerConnectionError.pairedMacUnavailable
        } catch {
            acceptance.cancel(generation: recoveryGeneration)
            if availabilityClientOperationID == operationID {
                availabilityClient = nil
                availabilityClientOperationID = nil
            }
            await client.close()
            throw error
        }
    }

    /// Every suspension point permits cancellation, explicit Forget, or a newly authenticated
    /// replacement pair to run on the main actor. No result resumed from that suspension may
    /// persist, invoke completion callbacks, or advance reconnect state unless both the operation
    /// and the exact durable pair are still authoritative.
    private func requireCurrentSavedPairMutation(
        _ context: SavedPairAttemptContext,
        record: RemotePairedDeviceRecord,
        pairingState: ViewerPairingState,
        operationID: UUID
    ) throws {
        try Task.checkCancellation()
        try requireCurrentSavedPairAttempt(
            context,
            pairingState: pairingState,
            operationID: operationID
        )
        guard record.pairID == context.pairID else {
            throw WorldwideViewerConnectionError.incompletePairing
        }
    }

    /// A connected WebSocket is not proof that the paired Mac is still able to answer this
    /// exchange. Closing this exact attempt turns a silent response into the same recoverable
    /// availability failure as `peerLeft`, so the outer loop reloads the latest durable reconnect
    /// counter before sending another request. The task captures no coordinator-global client and
    /// therefore cannot close a replacement operation.
    private func makeReconnectResponseDeadlineTask(
        client: any ViewerPairedAvailabilityTransport,
        timeoutNanoseconds: UInt64,
        context: SavedPairAttemptContext,
        retryOrdinal: UInt16
    ) -> Task<Void, Never> {
        let timeoutSleep = reconnectResponseTimeoutSleep
        return Task {
            do {
                try await timeoutSleep(timeoutNanoseconds)
                try Task.checkCancellation()
            } catch {
                return
            }
            recordConnectionTelemetry(
                .reconnectResponseTimedOut,
                context: context,
                retryOrdinal: retryOrdinal,
                failure: .reconnectResponseTimedOut
            )
            await client.close()
        }
    }

    /// Keeps the coordinator's monotonic retry deadline authoritative while one healthy socket
    /// emits `waiting` forever or its upgrade/receive path goes silent. The task captures the
    /// exact attempt client, so it cannot close a newer retry or replacement operation.
    private func makeAvailabilityAttemptDeadlineTask(
        client: any ViewerPairedAvailabilityTransport,
        timeoutNanoseconds: UInt64,
        context: SavedPairAttemptContext,
        retryOrdinal: UInt16
    ) -> Task<Void, Never> {
        let deadlineSleep = availabilityAttemptDeadlineSleep
        return Task {
            do {
                try await deadlineSleep(timeoutNanoseconds)
                try Task.checkCancellation()
            } catch {
                return
            }
            recordAvailabilityDeadlineTelemetryOnce(
                context: context,
                retryOrdinal: retryOrdinal
            )
            await client.close()
        }
    }

    private func isTransientAvailabilityError(_ error: any Error) -> Bool {
        if let signalingError = error as? RendezvousSignalingError {
            return signalingError == .notConnected
                || signalingError == .connectionFailed
                || signalingError == .connectionClosed
                || signalingError == .sendFailed
        }
        guard let connectionError = error as? WorldwideViewerConnectionError else {
            return false
        }
        return connectionError == .pairedMacUnavailable
            || connectionError == .rendezvous(.peerUnavailable)
    }

    private func isTransientBootstrapReplacementError(_ error: any Error) -> Bool {
        if let signalingError = error as? RendezvousSignalingError {
            return signalingError == .connectionFailed
                || signalingError == .connectionClosed
        }
        guard let connectionError = error as? WorldwideViewerConnectionError else {
            return false
        }
        return connectionError == .pairingEndedBeforeCommit
            || connectionError == .rendezvous(.roleConflict)
    }

    private func beginSavedPairAttempt(
        operationID: UUID,
        record: RemotePairedDeviceRecord,
        pairingState: ViewerPairingState
    ) throws -> SavedPairAttemptContext {
        let context = SavedPairAttemptContext(
            attemptID: operationID,
            pairID: record.pairID
        )
        try transitionSavedPairAttempt(
            to: .waitingForAvailability(context),
            context: context,
            pairingState: pairingState,
            operationID: operationID
        )
        recordConnectionTelemetry(.attemptStarted, context: context)
        return context
    }

    /// Prevents an async callback from one connection attempt (or from a replaced pair) from
    /// changing the presentation of the current durable pair.
    private func requireCurrentSavedPairAttempt(
        _ context: SavedPairAttemptContext,
        pairingState: ViewerPairingState,
        operationID: UUID
    ) throws {
        try requireCurrentOperation(operationID)
        guard context.attemptID == operationID,
              let durableRecord = pairingState.pairingRecord,
              durableRecord.pairID == context.pairID else {
            savedPairConnectionState = .idle
            throw WorldwideViewerConnectionError.incompletePairing
        }
    }

    private func transitionSavedPairAttempt(
        to state: SavedPairConnectionState,
        context: SavedPairAttemptContext,
        pairingState: ViewerPairingState,
        operationID: UUID
    ) throws {
        try requireCurrentSavedPairAttempt(
            context,
            pairingState: pairingState,
            operationID: operationID
        )
        let stateContext: SavedPairAttemptContext
        switch state {
        case .idle:
            savedPairConnectionState = .idle
            return
        case .waitingForAvailability(let candidate),
             .preparingSession(let candidate),
             .unavailableAfterDeadline(let candidate):
            stateContext = candidate
        }
        guard stateContext == context else {
            savedPairConnectionState = .idle
            throw WorldwideViewerConnectionError.incompletePairing
        }
        savedPairConnectionState = state
    }

    private func markSavedPairDeadlineExhausted(
        _ error: any Error,
        context: SavedPairAttemptContext,
        pairingState: ViewerPairingState,
        operationID: UUID
    ) throws {
        guard isTransientAvailabilityError(error) else { throw error }
        try transitionSavedPairAttempt(
            to: .unavailableAfterDeadline(context),
            context: context,
            pairingState: pairingState,
            operationID: operationID
        )
        stateText = "Paired Mac unavailable"
        // Reachability failure is a recoverable presentation state. The durable pair remains
        // authoritative and no generic error may imply that it expired or must be replaced.
        lastError = nil
    }

    /// Only preserves the typed recovery state that an actual monotonic-deadline branch marked.
    /// A transient error from any other source must still use the normal error presentation.
    @discardableResult
    private func publishSavedPairExhaustion(
        _ error: any Error,
        context: SavedPairAttemptContext?,
        pairingState: ViewerPairingState,
        operationID: UUID
    ) -> Bool {
        guard isTransientAvailabilityError(error),
              activeOperationID == operationID,
              let context,
              context.attemptID == operationID,
              let durableRecord = pairingState.pairingRecord,
              durableRecord.pairID == context.pairID else {
            return false
        }

        guard case .unavailableAfterDeadline(let exhaustedContext) = savedPairConnectionState,
              exhaustedContext == context else {
            return false
        }

        lastError = nil
        return true
    }

    private func beginOperation(state: String) throws -> UUID {
        guard activeOperationID == nil else {
            throw WorldwideViewerConnectionError.alreadyConnecting
        }
        let operationID = UUID()
        activeOperationID = operationID
        isConnecting = true
        savedPairConnectionState = .idle
        stateText = state
        lastError = nil
        pairingBackgroundTask.beginTransitionTask()
        return operationID
    }

    // MARK: - Operation ownership and telemetry

    private func requireCurrentOperation(_ operationID: UUID) throws {
        guard activeOperationID == operationID else { throw CancellationError() }
    }

    private func finishOperation(_ operationID: UUID) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        isConnecting = false
        pairingBackgroundTask.endTransitionTask()
    }

    private func recordConnectionTelemetry(
        _ stage: ConnectionTelemetryStage,
        context: SavedPairAttemptContext,
        exchangeID: String? = nil,
        retryOrdinal: UInt16? = nil,
        delayMilliseconds: UInt64? = nil,
        failure: ConnectionTelemetryFailure? = nil,
        terminal: ConnectionTelemetryTerminal? = nil
    ) {
        guard terminal != nil || !terminalTelemetryAttempts.contains(context.attemptID) else {
            return
        }
        let snapshot = connectionTelemetry.record(
            ConnectionTelemetryDraft(
                role: .viewer,
                stage: stage,
                attemptReference: .derive(domain: .attempt, uuid: context.attemptID),
                pairReference: .derive(domain: .pair, uuid: context.pairID),
                exchangeReference: exchangeID.map {
                    .derive(domain: .exchange, bytes: Data($0.utf8))
                },
                retryOrdinal: retryOrdinal,
                delayMilliseconds: delayMilliseconds,
                failure: failure,
                terminal: terminal
            )
        )
        connectionTelemetrySnapshot = snapshot
    }

    private func recordAvailabilityDeadlineTelemetryOnce(
        context: SavedPairAttemptContext,
        retryOrdinal: UInt16
    ) {
        guard deadlineTelemetryAttempts.insert(context.attemptID).inserted else { return }
        recordConnectionTelemetry(
            .availabilityDeadlineExpired,
            context: context,
            retryOrdinal: retryOrdinal,
            failure: .availabilityDeadlineExpired
        )
    }

    private func recordTerminalTelemetryOnce(
        context: SavedPairAttemptContext?,
        operationID: UUID,
        terminal: ConnectionTelemetryTerminal,
        failure: ConnectionTelemetryFailure? = nil
    ) {
        guard terminalTelemetryAttempts.insert(operationID).inserted else { return }
        terminalTelemetryOrder.append(operationID)
        if terminalTelemetryOrder.count > 512 {
            let retired = terminalTelemetryOrder.removeFirst()
            terminalTelemetryAttempts.remove(retired)
            deadlineTelemetryAttempts.remove(retired)
        }
        let stage: ConnectionTelemetryStage = switch terminal {
        case .success: .attemptSucceeded
        case .cancelled: .attemptCancelled
        case .failed: .attemptFailed
        }
        if let context {
            recordConnectionTelemetry(
                stage,
                context: context,
                failure: failure,
                terminal: terminal
            )
            return
        }
        connectionTelemetrySnapshot = connectionTelemetry.record(
            ConnectionTelemetryDraft(
                role: .viewer,
                stage: stage,
                attemptReference: .derive(domain: .attempt, uuid: operationID),
                failure: failure,
                terminal: terminal
            )
        )
    }

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
        if let viewer = error as? WorldwideViewerConnectionError {
            switch viewer {
            case .pairedMacUnavailable, .rendezvous(.peerUnavailable):
                return .peerUnavailable
            case .rendezvous(.roleConflict):
                return .roleConflict
            case .unexpectedPairingMessage, .invalidPairingRecovery,
                 .unexpectedAvailabilityMessage:
                return .protocolViolation
            case .alreadyConnecting, .invalidViewerIdentity, .incompletePairing,
                 .pairingEndedBeforeCommit, .rendezvous:
                return .unknown
            }
        }
        if let core = error as? RemoteSessionCoreError,
           core == .authenticationFailed {
            return .authenticationFailed
        }
        return .unknown
    }

    private func terminalConnectionTelemetryFailure(
        for error: any Error,
        context: SavedPairAttemptContext?
    ) -> ConnectionTelemetryFailure {
        if let context,
           deadlineTelemetryAttempts.contains(context.attemptID) {
            return .availabilityDeadlineExpired
        }
        return connectionTelemetryFailure(for: error)
    }

    private func requireIdentity(
        _ pairingState: ViewerPairingState
    ) throws -> RemoteDeviceIdentity {
        guard let identity = pairingState.viewerIdentity, identity.role == .viewer else {
            throw WorldwideViewerConnectionError.invalidViewerIdentity
        }
        return identity
    }

    private func requireRecoverableRecord(
        _ pairingState: ViewerPairingState
    ) throws -> RemotePairedDeviceRecord {
        guard let record = pairingState.pairingRecord else {
            throw WorldwideViewerConnectionError.incompletePairing
        }
        return record
    }

    private func closeTransports(ownedBy operationID: UUID) async {
        let transports = removeTransports(ownedBy: operationID)
        await transports.bootstrap?.close()
        await transports.availability?.close()
    }

    private func removeTransports(
        ownedBy operationID: UUID
    ) -> (
        bootstrap: (any ViewerPairingBootstrapTransport)?,
        availability: (any ViewerPairedAvailabilityTransport)?
    ) {
        let bootstrap: (any ViewerPairingBootstrapTransport)?
        if bootstrapClientOperationID == operationID {
            bootstrap = bootstrapClient
            bootstrapClient = nil
            bootstrapClientOperationID = nil
        } else {
            bootstrap = nil
        }

        let availability: (any ViewerPairedAvailabilityTransport)?
        if availabilityClientOperationID == operationID {
            availability = availabilityClient
            availabilityClient = nil
            availabilityClientOperationID = nil
        } else {
            availability = nil
        }
        return (bootstrap, availability)
    }

    private func publish(_ error: any Error) {
        stateText = "Connection failed"
        lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// User-presentable failures from bootstrap, availability, or operation arbitration.
enum WorldwideViewerConnectionError: Error, Equatable, LocalizedError {
    case alreadyConnecting
    case invalidViewerIdentity
    case unexpectedPairingMessage
    case invalidPairingRecovery
    case incompletePairing
    case pairingEndedBeforeCommit
    case unexpectedAvailabilityMessage
    case pairedMacUnavailable
    case rendezvous(RendezvousServerError)

    var errorDescription: String? {
        switch self {
        case .alreadyConnecting:
            "A secure connection is already being prepared."
        case .invalidViewerIdentity:
            "This iPhone's secure pairing identity is unavailable."
        case .unexpectedPairingMessage:
            "The Mac sent an unexpected secure pairing message."
        case .invalidPairingRecovery:
            "The saved pairing recovery state is invalid."
        case .incompletePairing:
            "Secure pairing did not finish on both devices."
        case .pairingEndedBeforeCommit:
            "The pairing connection closed before both devices committed."
        case .unexpectedAvailabilityMessage:
            "The paired Mac sent an unexpected reconnect message."
        case .pairedMacUnavailable:
            "The paired Mac is not currently available."
        case .rendezvous(let error):
            switch error {
            case .peerUnavailable:
                "The Mac is not available."
            case .rateLimited:
                "Too many connection attempts. Wait briefly and try again."
            case .invitationUnavailable:
                "This invitation has already been used or is unavailable."
            case .invitationExpired:
                "This invitation expired. Generate a new one on the Mac."
            case .roleConflict:
                "Another iPhone already claimed this invitation."
            case .requestRejected:
                "The rendezvous service rejected the connection."
            }
        }
    }
}
