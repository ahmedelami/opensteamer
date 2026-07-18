import Dispatch
import Foundation
import RemoteSessionCore

protocol ViewerPairingBootstrapTransport: AnyObject, Sendable {
    func connect() async throws -> PairingBootstrapSignalingClient.EventStream
    func send(_ payload: RemotePairingPayload) async throws
    func close() async
}

extension PairingBootstrapSignalingClient: ViewerPairingBootstrapTransport {}

protocol ViewerPairedAvailabilityTransport: AnyObject, Sendable {
    func connect() async throws -> PairedAvailabilitySignalingClient.EventStream
    func send(_ payload: RemoteAvailabilityPayload) async throws
    func close() async
}

extension PairedAvailabilitySignalingClient: ViewerPairedAvailabilityTransport {}

/// Performs the identity bootstrap and paired reconnect phases that precede ordinary WebRTC
/// media signaling. Invitation transport never carries SDP/ICE, and persistent availability
/// never carries media signaling; each connection derives a fresh one-use session credential.
@MainActor
final class WorldwideViewerConnectionCoordinator: ObservableObject {
    @Published private(set) var isConnecting = false
    @Published private(set) var stateText = "Not connected"
    @Published private(set) var lastError: String?

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

    private let makeBootstrapClient: BootstrapClientFactory
    private let makeAvailabilityClient: AvailabilityClientFactory
    private let availabilityRetryDeadlineNanoseconds: UInt64
    private let availabilityMonotonicNow: AvailabilityMonotonicNow
    private let availabilityRetrySleep: AvailabilityRetrySleep
    private let pairingBackgroundTask: any TransitionBackgroundTaskCoordinating
    private var activeOperationID: UUID?
    private var bootstrapClient: (any ViewerPairingBootstrapTransport)?
    private var bootstrapClientOperationID: UUID?
    private var availabilityClient: (any ViewerPairedAvailabilityTransport)?
    private var availabilityClientOperationID: UUID?

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
        availabilityRetryDeadlineNanoseconds: UInt64 = 30_000_000_000,
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
        pairingBackgroundTask: any TransitionBackgroundTaskCoordinating =
            AppTransitionBackgroundTaskCoordinator(name: "AudioStreamerSecurePairing")
    ) {
        makeBootstrapClient = bootstrapClientFactory
        makeAvailabilityClient = availabilityClientFactory
        self.availabilityRetryDeadlineNanoseconds = availabilityRetryDeadlineNanoseconds
        self.availabilityMonotonicNow = availabilityMonotonicNow
        self.availabilityRetrySleep = availabilityRetrySleep
        self.pairingBackgroundTask = pairingBackgroundTask
    }

    func pairAndPrepareMediaSession(
        invitationCode input: String,
        endpoint: URL,
        pairingState: ViewerPairingState,
        onRecoverableInvitationAdmitted: @escaping @MainActor () throws -> Void,
        onAuthenticatedPairingCompleted: @escaping @MainActor () -> Void
    ) async throws -> RendezvousSignalingClient {
        let operationID = try beginOperation(state: "Pairing securely")
        defer { finishOperation(operationID) }

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
            stateText = "Finding paired Mac"
            let client = try await prepareMediaSession(
                endpoint: endpoint,
                identity: try requireIdentity(pairingState),
                record: activeRecord,
                pairingState: pairingState,
                operationID: operationID,
                onAuthenticatedPairingCompleted: nil
            )
            try requireCurrentOperation(operationID)
            stateText = "Starting secure media"
            lastError = nil
            return client
        } catch is CancellationError {
            await closeTransports(ownedBy: operationID)
            if activeOperationID == operationID {
                stateText = "Not connected"
            }
            throw CancellationError()
        } catch {
            await closeTransports(ownedBy: operationID)
            if activeOperationID == operationID {
                publish(error)
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

        do {
            let identity = try requireIdentity(pairingState)
            let record = try requireRecoverableRecord(pairingState)
            let client = try await prepareMediaSession(
                endpoint: endpoint,
                identity: identity,
                record: record,
                pairingState: pairingState,
                operationID: operationID,
                onAuthenticatedPairingCompleted: onAuthenticatedPairingCompleted
            )
            try requireCurrentOperation(operationID)
            stateText = "Starting secure media"
            lastError = nil
            return client
        } catch is CancellationError {
            await closeTransports(ownedBy: operationID)
            if activeOperationID == operationID {
                stateText = "Not connected"
            }
            throw CancellationError()
        } catch {
            await closeTransports(ownedBy: operationID)
            if activeOperationID == operationID {
                publish(error)
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

        do {
            do {
                let invitation = try RemoteInvitationCode(input)
                var replacementRetry = 0
                let activeRecord: RemotePairedDeviceRecord
                while true {
                    do {
                        activeRecord = try await bootstrapPairing(
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
                try requireCurrentOperation(operationID)
                stateText = "Finding paired Mac"
                let client = try await prepareMediaSession(
                    endpoint: endpoint,
                    identity: try requireIdentity(pairingState),
                    record: activeRecord,
                    pairingState: pairingState,
                    operationID: operationID,
                    onAuthenticatedPairingCompleted: nil
                )
                try requireCurrentOperation(operationID)
                stateText = "Starting secure media"
                lastError = nil
                return client
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Confirmation and ACK sends cross a distributed durability boundary. If the
                // Mac advanced farther than this process observed, raw bootstrap rejects while
                // the latest Keychain record remains the authenticated recovery credential.
                try requireCurrentOperation(operationID)
                let identity = try requireIdentity(pairingState)
                let recoverableRecord = try requireRecoverableRecord(pairingState)
                stateText = "Recovering saved secure pairing"
                let client = try await prepareMediaSession(
                    endpoint: endpoint,
                    identity: identity,
                    record: recoverableRecord,
                    pairingState: pairingState,
                    operationID: operationID,
                    onAuthenticatedPairingCompleted: onAuthenticatedPairingCompleted
                )
                try requireCurrentOperation(operationID)
                stateText = "Starting secure media"
                lastError = nil
                return client
            }
        } catch is CancellationError {
            await closeTransports(ownedBy: operationID)
            if activeOperationID == operationID {
                stateText = "Not connected"
            }
            throw CancellationError()
        } catch {
            await closeTransports(ownedBy: operationID)
            if activeOperationID == operationID {
                publish(error)
            }
            throw error
        }
    }

    func cancel() {
        guard let operationID = activeOperationID else { return }
        activeOperationID = nil
        isConnecting = false
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
    }

    func reportConfigurationError(_ message: String) {
        stateText = "Service unavailable"
        lastError = message
    }

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
        onAuthenticatedPairingCompleted: (@MainActor () -> Void)?
    ) async throws -> RendezvousSignalingClient {
        var record = initialRecord
        var retryIndex = 0
        let retryStartedAt = availabilityMonotonicNow()

        while true {
            try Task.checkCancellation()
            try requireCurrentOperation(operationID)
            do {
                return try await prepareMediaSessionAttempt(
                    endpoint: endpoint,
                    identity: identity,
                    record: record,
                    pairingState: pairingState,
                    operationID: operationID,
                    onAuthenticatedPairingCompleted: onAuthenticatedPairingCompleted
                )
            } catch {
                try Task.checkCancellation()
                try requireCurrentOperation(operationID)
                guard isTransientAvailabilityError(error),
                      let remaining = availabilityRetryTimeRemaining(
                        since: retryStartedAt
                      ) else {
                    throw error
                }

                stateText = "Waiting for paired Mac"
                let delay = availabilityRetryBaseDelay(retryIndex: retryIndex)
                retryIndex += 1
                try await availabilityRetrySleep(delay, remaining)
                try Task.checkCancellation()
                try requireCurrentOperation(operationID)
                guard availabilityRetryTimeRemaining(since: retryStartedAt) != nil else {
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
        onAuthenticatedPairingCompleted: (@MainActor () -> Void)?
    ) async throws -> RendezvousSignalingClient {
        try requireCurrentOperation(operationID)
        let client = try makeAvailabilityClient(
            endpoint,
            try initialRecord.availabilityLocator()
        )
        availabilityClient = client
        availabilityClientOperationID = operationID
        var record = initialRecord
        var reconnect: RemoteReconnectInitiator?
        let recoveryGeneration = UUID()
        var acceptance = InvitationAcceptanceAction()
        acceptance.arm(generation: recoveryGeneration) { activeRecord in
            try pairingState.saveAuthenticatedPairing(activeRecord)
            onAuthenticatedPairingCompleted?()
        }

        do {
            let events = try await client.connect()
            for try await event in events {
                try Task.checkCancellation()
                try requireCurrentOperation(operationID)
                switch event {
                case .waiting:
                    stateText = "Waiting for paired Mac"

                case .ready:
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
                        case .none, .awaitProposal, .issueProposal, .issueCompletion:
                            throw WorldwideViewerConnectionError.invalidPairingRecovery
                        }
                        if onAuthenticatedPairingCompleted != nil {
                            _ = try acceptance.completeAuthenticatedPairing(
                                record,
                                generation: recoveryGeneration
                            )
                        }
                        guard reconnect == nil else { continue }
                        let initiator = try record.beginReconnect(using: identity)
                        // The monotonic request counter must be durable before transmission.
                        try pairingState.savePairingRecord(record)
                        reconnect = initiator
                        stateText = "Authorizing fresh session"
                        try await client.send(.reconnectRequest(initiator.request))
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
                        guard reconnect == nil else { continue }
                        let initiator = try record.beginReconnect(using: identity)
                        try pairingState.savePairingRecord(record)
                        reconnect = initiator
                        stateText = "Authorizing fresh session"
                        try await client.send(.reconnectRequest(initiator.request))

                    case .acknowledgement, .activationAcknowledgement:
                        throw WorldwideViewerConnectionError.unexpectedAvailabilityMessage
                    }

                case .signal(.reconnectResponse(let response)):
                    guard let reconnect else {
                        throw WorldwideViewerConnectionError.unexpectedAvailabilityMessage
                    }
                    let credential = try reconnect.complete(with: response)
                    if availabilityClientOperationID == operationID {
                        availabilityClient = nil
                        availabilityClientOperationID = nil
                    }
                    await client.close()
                    try requireCurrentOperation(operationID)
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

    private func isTransientAvailabilityError(_ error: any Error) -> Bool {
        if let signalingError = error as? RendezvousSignalingError {
            return signalingError == .connectionFailed
                || signalingError == .connectionClosed
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

    private func beginOperation(state: String) throws -> UUID {
        guard activeOperationID == nil else {
            throw WorldwideViewerConnectionError.alreadyConnecting
        }
        let operationID = UUID()
        activeOperationID = operationID
        isConnecting = true
        stateText = state
        lastError = nil
        pairingBackgroundTask.beginTransitionTask()
        return operationID
    }

    private func requireCurrentOperation(_ operationID: UUID) throws {
        guard activeOperationID == operationID else { throw CancellationError() }
    }

    private func finishOperation(_ operationID: UUID) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        isConnecting = false
        pairingBackgroundTask.endTransitionTask()
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
