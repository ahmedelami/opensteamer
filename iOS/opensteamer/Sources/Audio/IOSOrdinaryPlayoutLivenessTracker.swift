import Foundation

enum IOSOrdinaryPlayoutLivenessFailure: Equatable {
    case callbacksFrozen
    case inboundEnergyWithoutPCM
}

enum IOSOrdinaryPlayoutLivenessResult: Equatable {
    case waiting
    case healthy
    case recover(IOSOrdinaryPlayoutLivenessFailure)
}

/// Statistics-clocked watchdog for the already-proven ordinary RemoteIO path.
///
/// The native render callback must keep advancing even when the Mac source is silent. When
/// WebRTC reports increasing inbound audio energy, the final decoded PCM counters must advance in
/// the same bounded window. The tracker observes counters only; lifecycle policy still owns
/// whether recovery is allowed.
struct IOSOrdinaryPlayoutLivenessTracker {
    static let failureWindow: TimeInterval = 3.5
    private static let maximumObservationGap: TimeInterval = 5

    private struct Scope: Equatable {
        let sessionGeneration: UUID
        let audioPolicyGeneration: UUID
        let peerIdentity: ObjectIdentifier
    }

    private struct Floor {
        let scope: Scope
        let collectedAt: Date
        let callbackCount: UInt64
        let frameCount: UInt64
        let failureCount: UInt64
        let pcmNonzeroSampleCount: UInt64
        let pcmAbsoluteSampleSum: UInt64
        let inboundAudioEnergy: Double?
    }

    private var floor: Floor?
    private var suspectedFailure: IOSOrdinaryPlayoutLivenessFailure?
    private var suspectedAt: Date?

    mutating func observe(
        sessionGeneration: UUID,
        audioPolicyGeneration: UUID,
        peerIdentity: ObjectIdentifier,
        collectedAt: Date,
        oracle: WorldwideAudioPlayoutOracleSnapshot
    ) -> IOSOrdinaryPlayoutLivenessResult {
        let scope = Scope(
            sessionGeneration: sessionGeneration,
            audioPolicyGeneration: audioPolicyGeneration,
            peerIdentity: peerIdentity
        )
        let current = Floor(
            scope: scope,
            collectedAt: collectedAt,
            callbackCount: oracle.callbackCount,
            frameCount: oracle.frameCount,
            failureCount: oracle.failureCount,
            pcmNonzeroSampleCount: oracle.pcmNonzeroSampleCount,
            pcmAbsoluteSampleSum: oracle.pcmAbsoluteSampleSum,
            inboundAudioEnergy: oracle.inboundAudioEnergy
        )

        guard sessionGeneration == oracle.sessionGeneration,
              audioPolicyGeneration == oracle.audioPolicyGeneration,
              collectedAt.timeIntervalSinceReferenceDate.isFinite,
              oracle.fullQualityInvariantsHold,
              let previous = floor,
              previous.scope == scope else {
            replaceFloor(with: current)
            return .waiting
        }

        let elapsed = collectedAt.timeIntervalSince(previous.collectedAt)
        guard elapsed.isFinite,
              elapsed > 0,
              elapsed <= Self.maximumObservationGap,
              current.callbackCount >= previous.callbackCount,
              current.frameCount >= previous.frameCount,
              current.failureCount == previous.failureCount,
              current.pcmNonzeroSampleCount >= previous.pcmNonzeroSampleCount,
              current.pcmAbsoluteSampleSum >= previous.pcmAbsoluteSampleSum,
              Self.energyDidNotRegress(
                  previous.inboundAudioEnergy,
                  current.inboundAudioEnergy
              ) else {
            replaceFloor(with: current)
            return .waiting
        }

        let callbacksAdvanced =
            current.callbackCount > previous.callbackCount
                && current.frameCount > previous.frameCount
        let pcmAdvanced =
            current.pcmNonzeroSampleCount > previous.pcmNonzeroSampleCount
                || current.pcmAbsoluteSampleSum > previous.pcmAbsoluteSampleSum
        let inboundEnergyAdvanced = Self.energyAdvanced(
            previous.inboundAudioEnergy,
            current.inboundAudioEnergy
        )

        let failure: IOSOrdinaryPlayoutLivenessFailure?
        if !callbacksAdvanced {
            failure = .callbacksFrozen
        } else if inboundEnergyAdvanced && !pcmAdvanced {
            failure = .inboundEnergyWithoutPCM
        } else {
            failure = nil
        }

        floor = current
        guard let failure else {
            suspectedFailure = nil
            suspectedAt = nil
            return .healthy
        }

        guard suspectedFailure == failure,
              let suspectedAt else {
            suspectedFailure = failure
            self.suspectedAt = collectedAt
            return .waiting
        }
        let failureElapsed = collectedAt.timeIntervalSince(suspectedAt)
        guard failureElapsed.isFinite,
              failureElapsed >= Self.failureWindow else {
            return .waiting
        }
        return .recover(failure)
    }

    mutating func reset() {
        floor = nil
        suspectedFailure = nil
        suspectedAt = nil
    }

    private mutating func replaceFloor(with floor: Floor) {
        self.floor = floor
        suspectedFailure = nil
        suspectedAt = nil
    }

    private static func energyDidNotRegress(
        _ previous: Double?,
        _ current: Double?
    ) -> Bool {
        switch (previous, current) {
        case (nil, nil):
            return true
        case let (.some(previous), .some(current)):
            return previous.isFinite
                && current.isFinite
                && previous >= 0
                && current >= previous
        default:
            return false
        }
    }

    private static func energyAdvanced(
        _ previous: Double?,
        _ current: Double?
    ) -> Bool {
        guard let previous, let current else { return false }
        return previous.isFinite
            && current.isFinite
            && previous >= 0
            && current > previous
    }
}
