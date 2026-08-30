import Foundation
import WebRTCTransport

/// Actor-owned protocol transcript for automatic screen-video suspension. It deliberately owns no
/// native objects: `WorldwideScreenService` must recheck the binding and its concrete source/sink
/// authorizations before performing each asynchronous action.
struct WorldwideScreenMediaSuspensionCoordinator: Equatable, Sendable {
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
        case active(screenRequestID: UInt64, binding: Binding)
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
        case .active(let screenRequestID, _):
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
        phase = .active(screenRequestID: screenRequestID, binding: binding)
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
            binding: binding
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
              case .active(let screenRequestID, let activeBinding) = phase,
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
            binding: binding
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
              case .active(let screenRequestID, let activeBinding) = phase,
              activeBinding == binding,
              screenRequestID == notice.screenRequestID else {
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
        case .active(_, let current), .suspended(_, let current):
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
        case .suspending(let state):
            (state.notice, state.binding)
        case .suspended(let notice, let binding):
            (notice, binding)
        case .awaitingMarker(let attempt),
             .awaitingMarkerPresentation(let attempt, _),
             .awaitingRealFrame(let attempt, _),
             .awaitingRealPresentation(let attempt, _),
             .awaitingFinalization(let attempt, _):
            (attempt.notice, attempt.binding)
        case .idle, .active:
            nil
        }
    }

    private mutating func finishSuspensionIfReady(_ state: Suspending) {
        if state.coverWasConfirmed && state.inactiveWasConfirmed {
            phase = .suspended(notice: state.notice, binding: state.binding)
        } else {
            phase = .suspending(state)
        }
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}
