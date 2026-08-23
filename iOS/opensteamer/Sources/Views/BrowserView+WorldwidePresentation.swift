import CryptoKit
import Foundation

/// Pure state reduction for the mutually exclusive worldwide connection surfaces rendered by
/// `BrowserView`. Keeping these models outside the SwiftUI declaration lets the view focus on
/// composition and actions while preserving a deterministic, independently testable reducer.
extension BrowserView {
    /// Immutable inputs to the worldwide presentation reducer.
    struct WorldwidePresentationInput: Equatable {
        let hasActiveSession: Bool
        let activeStateText: String
        let activeAudioStateText: String
        let canResumeAudioPlayback: Bool
        let audioRecoveryButtonTitle: String
        let isPeerConnected: Bool
        let routeText: String
        let isPreparingFreshSession: Bool
        let preparationStateText: String
        let pairedMac: WorldwidePresentation.PairedMac?
        let savedPairState: SavedPairConnectionState
        let preparationError: String?
        let mediaError: String?
        let audioError: String?
        let invitationExpiresAt: Date?
    }

    /// Complete, deterministic description of the single worldwide card shown to the user.
    /// Modeling this separately from SwiftUI prevents simultaneous bootstrap, reconnect, and
    /// active-session actions when asynchronous owners change in the same render pass.
    struct WorldwidePresentation: Equatable {
        struct ActiveSession: Equatable {
            let stateText: String
            let audioStateText: String
            let canResumeAudioPlayback: Bool
            let audioRecoveryButtonTitle: String
            let isPeerConnected: Bool
            let routeText: String
        }

        struct PreparingSession: Equatable {
            let stateText: String
        }

        struct PairedMac: Equatable {
            let pairID: UUID
            let displayName: String
            let isPairingActive: Bool

            /// A non-secret, stable physical-test oracle. Never expose the raw pair identifier:
            /// the truncated digest is sufficient to prove that UI recovery did not silently
            /// replace the saved binding across process and host lifecycles.
            var accessibilityFingerprint: String {
                let digest = SHA256.hash(data: Data(pairID.uuidString.utf8))
                return "pair-" + digest.prefix(12).map {
                    String(format: "%02x", $0)
                }.joined()
            }
        }

        enum Surface: Equatable {
            case active(ActiveSession)
            case preparing(PreparingSession)
            case savedPairUnavailable(PairedMac)
            case pairedIdle(PairedMac)
            case bootstrap
        }

        enum Status: Equatable {
            case savedPairUnavailable(title: String, message: String)
            case preparationError(String)
            case mediaError(String)
            case audioError(String)
        }

        let surface: Surface
        let status: Status?
        let invitationExpiresAt: Date?

        var primaryActionTitle: String {
            switch surface {
            case .active:
                "Disconnect Remote Mac"
            case .preparing:
                "Cancel"
            case .savedPairUnavailable:
                "Retry Saved Pairing"
            case .pairedIdle(let pairedMac):
                pairedMac.isPairingActive
                    ? "Connect to Paired Mac"
                    : "Finish Secure Pairing"
            case .bootstrap:
                "Pair and Connect Securely"
            }
        }

        /// Stable, intentionally non-localized values used by the physical-device acceptance
        /// gate. This reports the selected surface, not transient child-row ordering.
        var accessibilityValue: String {
            switch surface {
            case .active:
                "active"
            case .preparing:
                "preparing"
            case .savedPairUnavailable:
                "savedPairUnavailable"
            case .pairedIdle:
                "pairedIdle"
            case .bootstrap:
                switch status {
                case .preparationError:
                    "preparationError"
                case .mediaError:
                    "mediaError"
                case .audioError:
                    "audioError"
                case .savedPairUnavailable, nil:
                    "bootstrap"
                }
            }
        }
    }

    // Compatibility projections for focused tests that predate the unified presentation model.
    // BrowserView itself renders exclusively from WorldwidePresentation.
    struct PairedMacPresentation: Equatable {
        struct Recovery: Equatable {
            let title: String
            let message: String
        }

        let primaryActionTitle: String
        let recovery: Recovery?
    }

    enum WorldwideStatusPresentation: Equatable {
        case savedPairUnavailable(title: String, message: String)
        case preparationError(String)
        case mediaError(String)
    }

    /// Selects exactly one Connect-from-Anywhere surface. Status and invitation metadata are
    /// reduced with the same precedence and explicit fresh-attempt retirement boundary.
    static func worldwidePresentation(
        _ input: WorldwidePresentationInput
    ) -> WorldwidePresentation {
        if input.hasActiveSession {
            let status = input.mediaError.map(WorldwidePresentation.Status.mediaError)
                ?? input.audioError.map(WorldwidePresentation.Status.audioError)
            return WorldwidePresentation(
                surface: .active(
                    .init(
                        stateText: input.activeStateText,
                        audioStateText: input.activeAudioStateText,
                        canResumeAudioPlayback: input.canResumeAudioPlayback,
                        audioRecoveryButtonTitle: input.audioRecoveryButtonTitle,
                        isPeerConnected: input.isPeerConnected,
                        routeText: input.routeText
                    )
                ),
                status: status,
                invitationExpiresAt: input.invitationExpiresAt
            )
        }

        if input.isPreparingFreshSession {
            return WorldwidePresentation(
                surface: .preparing(.init(stateText: input.preparationStateText)),
                status: input.preparationError.map(
                    WorldwidePresentation.Status.preparationError
                ),
                invitationExpiresAt: nil
            )
        }

        if let pairedMac = input.pairedMac,
           case .unavailableAfterDeadline(let context) = input.savedPairState,
           context.pairID == pairedMac.pairID {
            return WorldwidePresentation(
                surface: .savedPairUnavailable(pairedMac),
                status: .savedPairUnavailable(
                    title: "Paired Mac Unavailable",
                    message: savedPairUnavailableMessage
                ),
                invitationExpiresAt: nil
            )
        }

        if let pairedMac = input.pairedMac {
            return WorldwidePresentation(
                surface: .pairedIdle(pairedMac),
                // Preparation failures remain first because they belong to the newest explicit
                // connection attempt. Otherwise retain the current media session's terminal
                // outcome beside the durable pair until a fresh attempt explicitly retires it.
                status: input.preparationError.map(
                    WorldwidePresentation.Status.preparationError
                ) ?? input.mediaError.map(WorldwidePresentation.Status.mediaError),
                invitationExpiresAt: nil
            )
        }

        // With no active/preparing/paired surface, only current top-level connection failures
        // belong to bootstrap. Audio state and invitation expiry are session-scoped history.
        let bootstrapStatus = input.preparationError.map(
            WorldwidePresentation.Status.preparationError
        ) ?? input.mediaError.map(WorldwidePresentation.Status.mediaError)
        return WorldwidePresentation(
            surface: .bootstrap,
            status: bootstrapStatus,
            invitationExpiresAt: nil
        )
    }

    static func pairedMacPresentation(
        pairID: UUID,
        isPairingActive: Bool,
        savedPairState: SavedPairConnectionState
    ) -> PairedMacPresentation {
        let presentation = worldwidePresentation(
            compatibilityPresentationInput(
                pairedMac: .init(
                    pairID: pairID,
                    displayName: "Mac",
                    isPairingActive: isPairingActive
                ),
                savedPairState: savedPairState
            )
        )
        let recovery: PairedMacPresentation.Recovery?
        if case .savedPairUnavailable(let title, let message) = presentation.status {
            recovery = .init(title: title, message: message)
        } else {
            recovery = nil
        }
        return PairedMacPresentation(
            primaryActionTitle: presentation.primaryActionTitle,
            recovery: recovery
        )
    }

    static func worldwideStatusPresentation(
        hasActiveSession: Bool,
        isPreparingFreshSession: Bool,
        pairedMacID: UUID?,
        savedPairState: SavedPairConnectionState,
        preparationError: String?,
        mediaError: String?
    ) -> WorldwideStatusPresentation? {
        let presentation = worldwidePresentation(
            compatibilityPresentationInput(
                hasActiveSession: hasActiveSession,
                isPreparingFreshSession: isPreparingFreshSession,
                pairedMac: pairedMacID.map {
                    .init(pairID: $0, displayName: "Mac", isPairingActive: true)
                },
                savedPairState: savedPairState,
                preparationError: preparationError,
                mediaError: mediaError
            )
        )
        return switch presentation.status {
        case .savedPairUnavailable(let title, let message):
            .savedPairUnavailable(title: title, message: message)
        case .preparationError(let message):
            .preparationError(message)
        case .mediaError(let message):
            .mediaError(message)
        case .audioError, nil:
            nil
        }
    }

    private static func compatibilityPresentationInput(
        hasActiveSession: Bool = false,
        isPreparingFreshSession: Bool = false,
        pairedMac: WorldwidePresentation.PairedMac? = nil,
        savedPairState: SavedPairConnectionState = .idle,
        preparationError: String? = nil,
        mediaError: String? = nil
    ) -> WorldwidePresentationInput {
        WorldwidePresentationInput(
            hasActiveSession: hasActiveSession,
            activeStateText: "Connected",
            activeAudioStateText: "Playing",
            canResumeAudioPlayback: false,
            audioRecoveryButtonTitle: "Resume Audio",
            isPeerConnected: hasActiveSession,
            routeText: "Direct",
            isPreparingFreshSession: isPreparingFreshSession,
            preparationStateText: "Finding paired Mac",
            pairedMac: pairedMac,
            savedPairState: savedPairState,
            preparationError: preparationError,
            mediaError: mediaError,
            audioError: nil,
            invitationExpiresAt: nil
        )
    }
}
