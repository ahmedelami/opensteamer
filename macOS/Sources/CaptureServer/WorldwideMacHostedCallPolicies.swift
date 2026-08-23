import CaptureCore
import WebRTCTransport

/// Rejects callbacks that independent Task scheduling delivered out of native callback order, and
/// rejects every sample that was taken before the currently installed viewer challenge.
enum WorldwideMacHostedCallObservationPolicy {
    static func admits(
        observationSequence: UInt64,
        highestAdmittedSequence: UInt64,
        observationChallenge: SystemAudioMacFaceTimeActivityChallenge?,
        currentChallenge: WebRTCMacHostedCallChallenge?
    ) -> Bool {
        guard observationSequence > highestAdmittedSequence,
              let observationChallenge,
              let currentChallenge,
              currentChallenge.isValid,
              observationChallenge.sequence == currentChallenge.sequence,
              observationChallenge.nonce == currentChallenge.nonce,
              observationChallenge.callEpochNonce
                == currentChallenge.callEpochNonce else {
            return false
        }
        return true
    }
}

/// Converts only a self-consistent native binder state into the protocol-v3 wire state. Inactive
/// is deliberately distinct from a known-empty prospective arm acknowledgement.
enum WorldwideMacHostedCallEvidenceStatePolicy {
    static func state(
        isCausallyBoundActive: Bool,
        isCausallyArmed: Bool
    ) -> WebRTCMacHostedCallEvidence.State? {
        switch (isCausallyBoundActive, isCausallyArmed) {
        case (true, false):
            return .active
        case (false, true):
            return .preflightArmed
        case (false, false):
            return .inactive
        case (true, true):
            return nil
        }
    }
}

/// Requires the native source and stored viewer challenge to belong to the exact current peer.
enum WorldwideMacHostedCallPeerGenerationPolicy {
    static func admits(
        audioPeerGeneration: UInt64?,
        challengePeerGeneration: UInt64?,
        currentPeerGeneration: UInt64
    ) -> Bool {
        currentPeerGeneration > 0
            && audioPeerGeneration == currentPeerGeneration
            && challengePeerGeneration == currentPeerGeneration
    }
}
