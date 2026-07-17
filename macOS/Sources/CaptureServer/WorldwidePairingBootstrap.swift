import CaptureCore
import Foundation
import RemoteSessionCore

actor WorldwidePairingBootstrap {
    nonisolated let completion: AsyncThrowingStream<RemotePairedDeviceRecord, Error>

    private let identity: RemoteDeviceIdentity
    private let participant: RemotePairingParticipant
    private let signaling: PairingBootstrapSignalingClient
    private let store: WorldwidePairingStore
    private let logger: Logger
    private let invitation: RemoteInvitationCode
    private let completionContinuation:
        AsyncThrowingStream<RemotePairedDeviceRecord, Error>.Continuation

    private var signalingTask: Task<Void, Never>?
    private var agreement: RemotePairingAgreement?
    private var record: RemotePairedDeviceRecord?
    private var helloSent = false
    private var isStarted = false
    private var isFinished = false

    init(
        endpoint: URL,
        identity: RemoteDeviceIdentity,
        store: WorldwidePairingStore,
        logger: Logger
    ) throws {
        let pair = AsyncThrowingStream<RemotePairedDeviceRecord, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        completion = pair.stream
        completionContinuation = pair.continuation
        let invitation = try RemoteInvitationCode.generate()
        self.invitation = invitation
        self.identity = identity
        participant = try RemotePairingParticipant(identity: identity, invitation: invitation)
        signaling = try PairingBootstrapSignalingClient(
            endpoint: endpoint,
            invitation: invitation,
            role: .host
        )
        self.store = store
        self.logger = logger
    }

    func start() async throws -> String {
        guard !isStarted, !isFinished else {
            throw WorldwidePairingBootstrapError.invalidLifecycle
        }
        isStarted = true
        do {
            let events = try await signaling.connect()
            signalingTask = Task { [weak self] in
                await self?.consume(events)
            }
            logger.info("Worldwide pairing host is waiting for the iPhone")
            return invitation.exportedCode
        } catch {
            finish(throwing: error)
            throw error
        }
    }

    func stop() async {
        guard !isFinished else { return }
        signalingTask?.cancel()
        signalingTask = nil
        await signaling.close()
        finish(throwing: nil)
    }

    private func consume(
        _ events: PairingBootstrapSignalingClient.EventStream
    ) async {
        do {
            for try await event in events {
                guard !isFinished else { return }
                try await handle(event)
            }
            guard !isFinished else { return }
            throw WorldwidePairingBootstrapError.connectionEndedBeforeCommit
        } catch is CancellationError {
            return
        } catch {
            guard !isFinished else { return }
            logger.error("Worldwide pairing failed: \(error.localizedDescription)")
            await signaling.close()
            finish(throwing: error)
        }
    }

    private func handle(_ event: PairingBootstrapSignalingEvent) async throws {
        switch event {
        case .waiting(let invitationExpiresAt):
            let seconds = max(0, Int(invitationExpiresAt.timeIntervalSinceNow.rounded()))
            logger.info("Worldwide pairing invitation expires in about \(seconds) seconds")

        case .ready:
            guard !helloSent else { return }
            helloSent = true
            try await signaling.send(.hello(participant.hello))

        case .signal(.hello(let peerHello)):
            guard helloSent, agreement == nil, record == nil else {
                throw WorldwidePairingBootstrapError.unexpectedMessage
            }
            let agreement = try participant.accept(peerHello)
            self.agreement = agreement
            try await signaling.send(.confirmation(try agreement.makeConfirmation()))

        case .signal(.confirmation(let peerConfirmation)):
            guard let agreement, record == nil else {
                throw WorldwidePairingBootstrapError.unexpectedMessage
            }
            var pending = try agreement.makePendingRecord(
                peerConfirmation: peerConfirmation
            )
            try store.savePairedViewer(pending, for: identity)
            let proposal = try pending.prepareProposal(using: identity)
            try store.savePairedViewer(pending, for: identity)
            record = pending
            try await signaling.send(.commit(proposal))

        case .signal(.commit(let commit)):
            switch commit.phase {
            case .acknowledgement:
                try await acceptAcknowledgementAndSendCompletion(commit)
            case .activationAcknowledgement:
                try await acceptActivationAcknowledgement(commit)
            case .proposal, .completion:
                throw WorldwidePairingBootstrapError.unexpectedMessage
            }

        case .peerLeft:
            throw WorldwidePairingBootstrapError.connectionEndedBeforeCommit

        case .serverError(let error):
            throw WorldwidePairingBootstrapError.rendezvous(error)
        }
    }

    private func acceptAcknowledgementAndSendCompletion(
        _ acknowledgement: RemotePairingCommit
    ) async throws {
        guard var record else {
            throw WorldwidePairingBootstrapError.unexpectedMessage
        }

        try validateAndAcceptWorldwidePairingAcknowledgement(
            acknowledgement,
            record: &record
        )
        try store.savePairedViewer(record, for: identity)

        let completion = try record.prepareCompletion(using: identity)
        try store.savePairedViewer(record, for: identity)
        self.record = record
        try await signaling.send(.commit(completion))

        try record.markCompletionSent(commitID: completion.commitID)
        try store.savePairedViewer(record, for: identity)
        self.record = record
    }

    private func acceptActivationAcknowledgement(
        _ acknowledgement: RemotePairingCommit
    ) async throws {
        guard var record else {
            throw WorldwidePairingBootstrapError.unexpectedMessage
        }
        try record.acceptActivationAcknowledgement(acknowledgement)
        try store.savePairedViewer(record, for: identity)
        self.record = record
        logger.info("Worldwide pairing committed; the Mac will now accept secure reconnects")
        completionContinuation.yield(record)
        completionContinuation.finish()
        isFinished = true
        signalingTask?.cancel()
        signalingTask = nil
        await signaling.close()
    }

    private func finish(throwing error: (any Error)?) {
        guard !isFinished else { return }
        isFinished = true
        signalingTask?.cancel()
        signalingTask = nil
        if let error {
            completionContinuation.finish(throwing: error)
        } else {
            completionContinuation.finish()
        }
    }
}

/// Authenticates every acknowledgement, including an idempotent replay received after the host
/// has already persisted `.acceptedReceived`. A phase-shaped replay must never trigger a stored
/// completion resend without passing the peer signature and pair-root MAC checks again.
func validateAndAcceptWorldwidePairingAcknowledgement(
    _ acknowledgement: RemotePairingCommit,
    record: inout RemotePairedDeviceRecord
) throws {
    switch record.pairingState {
    case .pending, .acceptedReceived:
        try record.acceptAcknowledgement(acknowledgement)
    case .acceptedIssued, .active:
        throw WorldwidePairingBootstrapError.unexpectedMessage
    }
}

enum WorldwidePairingBootstrapError: LocalizedError {
    case invalidLifecycle
    case unexpectedMessage
    case connectionEndedBeforeCommit
    case rendezvous(RendezvousServerError)

    var errorDescription: String? {
        switch self {
        case .invalidLifecycle:
            "The worldwide pairing bootstrap cannot be started in its current state."
        case .unexpectedMessage:
            "The iPhone sent an unexpected worldwide pairing message."
        case .connectionEndedBeforeCommit:
            "The worldwide pairing connection ended before both devices committed."
        case .rendezvous(let error):
            "The rendezvous rejected worldwide pairing (\(String(describing: error)))."
        }
    }
}
