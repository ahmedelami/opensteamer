import Foundation
import WebRTCTransport

/// Actor-owned protocol transcript for automatic screen-video suspension. It deliberately owns no
/// native objects: `WorldwideScreenService` must recheck the binding and its concrete source/sink
/// authorizations before performing each asynchronous action.
struct WorldwideScreenMediaSuspensionCoordinator: Equatable, Sendable {
    enum DiagnosticPhase: String, Equatable, Sendable {
        case idle
        case active
        case suspending
        case suspended
        case awaitingMarker
        case awaitingMarkerPresentation
        case awaitingRealFrame
        case awaitingRealPresentation
        case awaitingFinalization
    }

    /// Privacy-safe protocol correlation for host diagnostics. The values are monotonic protocol
    /// identifiers and local lifecycle epochs; no pairing, SDP, input, or frame data is exposed.
    struct DiagnosticSnapshot: Equatable, Sendable {
        let phase: DiagnosticPhase
        let screenRequestID: UInt64?
        let suspensionGeneration: UInt64?
        let binding: Binding?

        /// Once the viewer has covered an acknowledged Show, invalidating any suspension-owned
        /// phase clears WebRTC's host-video authorization. The old ordered Hide must not be
        /// contradicted locally; a fresh media session is required to obtain a new Show.
        var requiresFreshMediaSessionAfterInvalidation: Bool {
            switch phase {
            case .active:
                // A resumed Active phase still owns the completed suspension transcript until a
                // newer suspension generation or ordinary visibility command retires it. A
                // crossed cancellation can therefore invalidate that transcript after the final
                // resumed ACK and must close this media generation instead of leaving RTP off.
                suspensionGeneration != nil
            case .suspending, .suspended, .awaitingMarker,
                 .awaitingMarkerPresentation, .awaitingRealFrame,
                 .awaitingRealPresentation, .awaitingFinalization:
                true
            case .idle:
                false
            }
        }
    }

    struct Binding: Equatable, Sendable {
        let peerGeneration: UInt64
        let visibilityCommandEpoch: UInt64
        let recoveryEpoch: UInt64

        var isValid: Bool {
            peerGeneration > 0 && visibilityCommandEpoch > 0
        }
    }

    private struct Suspending: Equatable, Sendable {
        let notice: WebRTCScreenMediaSuspensionNotice
        var binding: Binding
        let priorResumedSuspension: WebRTCScreenMediaSuspensionNotice?
        var coverWasConfirmed: Bool
        var inactiveWasConfirmed: Bool
    }

    private struct ResumeAttempt: Equatable, Sendable {
        let notice: WebRTCScreenMediaSuspensionNotice
        let binding: Binding
        let attemptID: UUID
    }

    private enum Phase: Equatable, Sendable {
        case idle
        case active(
            screenRequestID: UInt64,
            binding: Binding,
            resumedSuspension: WebRTCScreenMediaSuspensionNotice?
        )
        case suspending(Suspending)
        case suspended(notice: WebRTCScreenMediaSuspensionNotice, binding: Binding)
        case awaitingMarker(ResumeAttempt)
        case awaitingMarkerPresentation(
            attempt: ResumeAttempt,
            ready: WebRTCScreenMediaMarkerReady
        )
        case awaitingRealFrame(
            attempt: ResumeAttempt,
            presentation: WebRTCScreenMediaMarkerPresentation
        )
        case awaitingRealPresentation(
            attempt: ResumeAttempt,
            ready: WebRTCScreenMediaResumeReady
        )
        case awaitingFinalization(
            attempt: ResumeAttempt,
            request: WebRTCScreenMediaResumeRequest
        )
    }

    private var phase: Phase = .idle
    private var nextSuspensionGeneration: UInt64 = 1

    var diagnosticSnapshot: DiagnosticSnapshot {
        switch phase {
        case .idle:
            DiagnosticSnapshot(
                phase: .idle,
                screenRequestID: nil,
                suspensionGeneration: nil,
                binding: nil
            )
        case .active(let screenRequestID, let binding, let resumedSuspension):
            DiagnosticSnapshot(
                phase: .active,
                screenRequestID: screenRequestID,
                suspensionGeneration: resumedSuspension?.suspensionGeneration,
                binding: binding
            )
        case .suspending(let state):
            DiagnosticSnapshot(
                phase: .suspending,
                screenRequestID: state.notice.screenRequestID,
                suspensionGeneration: state.notice.suspensionGeneration,
                binding: state.binding
            )
        case .suspended(let notice, let binding):
            DiagnosticSnapshot(
                phase: .suspended,
                screenRequestID: notice.screenRequestID,
                suspensionGeneration: notice.suspensionGeneration,
                binding: binding
            )
        case .awaitingMarker(let attempt):
            resumeDiagnosticSnapshot(
                phase: .awaitingMarker,
                attempt: attempt
            )
        case .awaitingMarkerPresentation(let attempt, _):
            resumeDiagnosticSnapshot(
                phase: .awaitingMarkerPresentation,
                attempt: attempt
            )
        case .awaitingRealFrame(let attempt, _):
            resumeDiagnosticSnapshot(
                phase: .awaitingRealFrame,
                attempt: attempt
            )
        case .awaitingRealPresentation(let attempt, _):
            resumeDiagnosticSnapshot(
                phase: .awaitingRealPresentation,
                attempt: attempt
            )
        case .awaitingFinalization(let attempt, _):
            resumeDiagnosticSnapshot(
                phase: .awaitingFinalization,
                attempt: attempt
            )
        }
    }

    var isAutomaticallySuspended: Bool {
        switch phase {
        case .suspended, .awaitingMarker,
             .awaitingMarkerPresentation, .awaitingRealFrame,
             .awaitingRealPresentation, .awaitingFinalization:
            true
        case .idle, .active, .suspending:
            false
        }
    }

    var suspensionIsInFlight: Bool {
        if case .suspending = phase { return true }
        return false
    }

    var currentSuspensionNotice: WebRTCScreenMediaSuspensionNotice? {
        suspensionOwnership?.notice
    }

    var isResumeProbeInFlight: Bool {
        switch phase {
        case .awaitingMarker, .awaitingMarkerPresentation, .awaitingRealFrame,
             .awaitingRealPresentation, .awaitingFinalization:
            true
        case .idle, .active, .suspending, .suspended:
            false
        }
    }

    var activeScreenRequestID: UInt64? {
        switch phase {
        case .active(let screenRequestID, _, _):
            screenRequestID
        case .suspending(let state):
            state.notice.screenRequestID
        case .suspended(let notice, _):
            notice.screenRequestID
        case .awaitingMarker(let attempt),
             .awaitingMarkerPresentation(let attempt, _),
             .awaitingRealFrame(let attempt, _),
             .awaitingRealPresentation(let attempt, _),
             .awaitingFinalization(let attempt, _):
            attempt.notice.screenRequestID
        case .idle:
            nil
        }
    }

    mutating func activate(screenRequestID: UInt64, binding: Binding) -> Bool {
        guard screenRequestID > 0, binding.isValid else { return false }
        phase = .active(
            screenRequestID: screenRequestID,
            binding: binding,
            resumedSuspension: nil
        )
        return true
    }

    mutating func retire() {
        phase = .idle
    }

    mutating func abortSuspensionBeforeInactive(binding: Binding) -> Bool {
        guard case .suspending(let state) = phase,
              state.binding == binding,
              !state.inactiveWasConfirmed else {
            return false
        }
        phase = .active(
            screenRequestID: state.notice.screenRequestID,
            binding: binding,
            // Sending the newer notice may fail before WebRTCPeer retires the completed prior
            // transcript. Preserve that provenance so a later cancellation remains correlated.
            resumedSuspension: state.priorResumedSuspension
        )
        return true
    }

    /// Returns nil for old/unnegotiated viewers and leaves their established nonzero-floor state
    /// untouched. A negotiated suspension always receives a unique, nonzero service generation.
    mutating func beginSuspensionIfNegotiated(
        negotiated: Bool,
        binding: Binding
    ) -> WebRTCScreenMediaSuspensionNotice? {
        guard negotiated,
              binding.isValid,
              case .active(
                let screenRequestID,
                let activeBinding,
                let priorResumedSuspension
              ) = phase,
              activeBinding == binding else {
            return nil
        }
        let generation = nextSuspensionGeneration
        nextSuspensionGeneration &+= 1
        if nextSuspensionGeneration == 0 { nextSuspensionGeneration = 1 }
        let notice = WebRTCScreenMediaSuspensionNotice(
            screenRequestID: screenRequestID,
            suspensionGeneration: generation
        )
        guard notice.isValid else { return nil }
        phase = .suspending(
            Suspending(
                notice: notice,
                binding: binding,
                priorResumedSuspension: priorResumedSuspension,
                coverWasConfirmed: false,
                inactiveWasConfirmed: false
            )
        )
        return notice
    }

    mutating func confirmCover(
        _ acknowledgement: WebRTCScreenMediaCoveredAcknowledgement,
        binding: Binding
    ) -> Bool {
        guard case .suspending(var state) = phase,
              state.binding == binding,
              acknowledgement.isExactEcho(of: state.notice),
              !state.coverWasConfirmed else {
            return false
        }
        state.coverWasConfirmed = true
        finishSuspensionIfReady(state)
        return true
    }

    mutating func confirmInactive(
        for notice: WebRTCScreenMediaSuspensionNotice,
        binding: Binding
    ) -> Bool {
        guard case .suspending(var state) = phase,
              state.binding.peerGeneration == binding.peerGeneration,
              state.binding.recoveryEpoch == binding.recoveryEpoch,
              binding.visibilityCommandEpoch
                >= state.binding.visibilityCommandEpoch,
              state.notice == notice,
              !state.inactiveWasConfirmed else {
            return false
        }
        // The viewer's protocol-owned Hide is itself the newest visibility command. Rebind the
        // covered logical screen to that exact epoch so a later manual command cancels the probe.
        state.binding = binding
        state.inactiveWasConfirmed = true
        finishSuspensionIfReady(state)
        return true
    }

    mutating func beginResumeAttempt(
        attemptID: UUID,
        binding: Binding
    ) -> Bool {
        guard attemptID != Self.zeroUUID,
              case .suspended(let notice, let suspendedBinding) = phase,
              suspendedBinding == binding else {
            return false
        }
        phase = .awaitingMarker(
            ResumeAttempt(notice: notice, binding: binding, attemptID: attemptID)
        )
        return true
    }

    mutating func acceptMarkerReady(
        _ ready: WebRTCScreenMediaMarkerReady,
        binding: Binding
    ) -> Bool {
        guard case .awaitingMarker(let attempt) = phase,
              attempt.binding == binding,
              ready.attemptID == attempt.attemptID,
              ready.belongs(to: attempt.notice) else {
            return false
        }
        phase = .awaitingMarkerPresentation(attempt: attempt, ready: ready)
        return true
    }

    mutating func acceptMarkerPresentation(
        _ presentation: WebRTCScreenMediaMarkerPresentation,
        binding: Binding
    ) -> Bool {
        guard case .awaitingMarkerPresentation(let attempt, let ready) = phase,
              attempt.binding == binding,
              presentation.isExactEcho(of: ready) else {
            return false
        }
        phase = .awaitingRealFrame(attempt: attempt, presentation: presentation)
        return true
    }

    mutating func acceptResumeReady(
        _ ready: WebRTCScreenMediaResumeReady,
        binding: Binding
    ) -> Bool {
        guard case .awaitingRealFrame(let attempt, let presentation) = phase,
              attempt.binding == binding,
              ready.isValid,
              ready.markerPresentation == presentation,
              ready.attemptID == attempt.attemptID else {
            return false
        }
        phase = .awaitingRealPresentation(attempt: attempt, ready: ready)
        return true
    }

    mutating func acceptResumeRequest(
        _ request: WebRTCScreenMediaResumeRequest,
        binding: Binding
    ) -> Bool {
        guard case .awaitingRealPresentation(let attempt, let ready) = phase,
              attempt.binding == binding,
              request.isValid,
              request.presentation.resumeReady == ready,
              request.presentation.resumeReady.attemptID == attempt.attemptID else {
            return false
        }
        phase = .awaitingFinalization(attempt: attempt, request: request)
        return true
    }

    func authorizesFinalization(
        of request: WebRTCScreenMediaResumeRequest,
        binding: Binding
    ) -> Bool {
        guard case .awaitingFinalization(let attempt, let currentRequest) = phase else {
            return false
        }
        return attempt.binding == binding
            && currentRequest == request
            && currentRequest.presentation.resumeReady.attemptID == attempt.attemptID
    }

    mutating func commitFinalization(
        of request: WebRTCScreenMediaResumeRequest,
        binding: Binding
    ) -> Bool {
        guard case .awaitingFinalization(let attempt, let currentRequest) = phase,
              attempt.binding == binding,
              currentRequest == request else {
            return false
        }
        phase = .active(
            screenRequestID: attempt.notice.screenRequestID,
            binding: binding,
            resumedSuspension: attempt.notice
        )
        return true
    }

    /// Restores the covered suspension only when this exact binding was provisionally made active
    /// before its irreversible resumed acknowledgement failed. A replacement Show has a different
    /// binding and can never be rolled back by the older attempt's cleanup.
    mutating func rollbackFinalizationBeforeAcknowledgement(
        notice: WebRTCScreenMediaSuspensionNotice,
        binding: Binding
    ) -> Bool {
        guard notice.isValid,
              case .active(
                let screenRequestID,
                let activeBinding,
                let resumedSuspension
              ) = phase,
              activeBinding == binding,
              screenRequestID == notice.screenRequestID,
              resumedSuspension == notice else {
            return false
        }
        phase = .suspended(notice: notice, binding: binding)
        return true
    }

    /// Cancels any partial proof. A still-current logical viewer remains covered and suspended;
    /// a lifecycle mutation retires the transcript completely.
    mutating func cancelResume(
        binding: Binding,
        logicalScreenIsStillRequested: Bool
    ) {
        // An async cleanup may resume after a newer visibility/recovery owner has already won.
        // Only the exact attempt binding may mutate this transcript; lifecycle owners retire their
        // own state explicitly instead of letting stale cleanup erase a replacement generation.
        guard let owned = suspensionOwnership, owned.binding == binding else { return }
        if logicalScreenIsStillRequested {
            phase = .suspended(notice: owned.notice, binding: binding)
        } else {
            phase = .idle
        }
    }

    func owns(_ binding: Binding) -> Bool {
        switch phase {
        case .active(_, let current, _), .suspended(_, let current):
            current == binding
        case .suspending(let state):
            state.binding == binding
        case .awaitingMarker(let attempt),
             .awaitingMarkerPresentation(let attempt, _),
             .awaitingRealFrame(let attempt, _),
             .awaitingRealPresentation(let attempt, _),
             .awaitingFinalization(let attempt, _):
            attempt.binding == binding
        case .idle:
            false
        }
    }

    private var suspensionOwnership: (
        notice: WebRTCScreenMediaSuspensionNotice,
        binding: Binding
    )? {
        switch phase {
        case .active(_, let binding, let resumedSuspension):
            guard let resumedSuspension else { return nil }
            return (resumedSuspension, binding)
        case .suspending(let state):
            return (state.notice, state.binding)
        case .suspended(let notice, let binding):
            return (notice, binding)
        case .awaitingMarker(let attempt),
             .awaitingMarkerPresentation(let attempt, _),
             .awaitingRealFrame(let attempt, _),
             .awaitingRealPresentation(let attempt, _),
             .awaitingFinalization(let attempt, _):
            return (attempt.notice, attempt.binding)
        case .idle:
            return nil
        }
    }

    private mutating func finishSuspensionIfReady(_ state: Suspending) {
        if state.coverWasConfirmed && state.inactiveWasConfirmed {
            phase = .suspended(notice: state.notice, binding: state.binding)
        } else {
            phase = .suspending(state)
        }
    }

    private func resumeDiagnosticSnapshot(
        phase: DiagnosticPhase,
        attempt: ResumeAttempt
    ) -> DiagnosticSnapshot {
        DiagnosticSnapshot(
            phase: phase,
            screenRequestID: attempt.notice.screenRequestID,
            suspensionGeneration: attempt.notice.suspensionGeneration,
            binding: attempt.binding
        )
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}
