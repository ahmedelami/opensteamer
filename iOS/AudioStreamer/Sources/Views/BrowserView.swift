import CryptoKit
import RemoteSessionCore
import SwiftUI

struct BrowserView: View {
    /// Commits a prepared signaling client to the process-wide media owner without allowing a
    /// superseded preparation task to cross an asynchronous boundary and mutate current UI state.
    /// The ownership check and `connect` call intentionally share one non-suspending MainActor
    /// region; if arbitration loses, the post-close guard fences a non-cooperative `close()`.
    @MainActor
    static func handoffPreparedWorldwideSession(
        generation: UUID,
        isCurrentGeneration: () -> Bool,
        connect: () -> Bool,
        close: () async -> Void,
        reportActiveSessionConflict: () -> Void
    ) async {
        guard !Task.isCancelled, isCurrentGeneration() else {
            await close()
            return
        }

        guard connect() else {
            await close()
            guard !Task.isCancelled, isCurrentGeneration() else { return }
            reportActiveSessionConflict()
            return
        }
    }

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

    // Compatibility projections for the focused tests already present in the shared worktree.
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

    static let savedPairUnavailableMessage =
        "AudioStreamer couldn’t reach the saved paired Mac. The pairing remains saved securely on this iPhone. The Mac may be asleep, offline, or temporarily unavailable."

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var viewModel: StreamSessionViewModel
    @EnvironmentObject private var worldwideViewModel: WorldwideSessionViewModel
    @AppStorage("remoteHost") private var remoteHost = ""
    @AppStorage("remotePort") private var remotePort = "9000"
    @StateObject private var remoteTokenState = RemoteTokenState()
    @StateObject private var invitationCodeState = RemoteTokenState(
        store: KeychainStore(item: KeychainStore.worldwideInvitationCodeItem),
        codeDisplayName: "invitation code"
    )
    @StateObject private var viewerPairingState = ViewerPairingState()
    @StateObject private var invitationAdmissionState = WorldwideInvitationAdmissionState()
    @StateObject private var worldwideConnection = WorldwideViewerConnectionCoordinator()
    @State private var showsToken = false
    @State private var showsInvitationCode = false
    @State private var worldwidePreparationTask: Task<Void, Never>?
    @State private var worldwidePreparationGeneration = UUID()
    @FocusState private var invitationCodeIsFocused: Bool
    #if DEBUG
    @AppStorage("debugWorldwideRendezvousEndpoint")
    private var debugWorldwideRendezvousEndpoint = "ws://127.0.0.1:8788"
    #endif

    var body: some View {
        let presentation = worldwidePresentation

        List {
            Section("Connect from Anywhere") {
                switch presentation.surface {
                case .active(let activeSession):
                    activeWorldwideContent(
                        activeSession,
                        actionTitle: presentation.primaryActionTitle
                    )

                case .preparing(let preparingSession):
                    preparingWorldwideContent(
                        preparingSession,
                        actionTitle: presentation.primaryActionTitle
                    )

                case .savedPairUnavailable(let pairedMac),
                     .pairedIdle(let pairedMac):
                    pairedWorldwideContent(
                        pairedMac,
                        actionTitle: presentation.primaryActionTitle
                    )

                case .bootstrap:
                    worldwideBootstrapContent(actionTitle: presentation.primaryActionTitle)
                }

                if let storageError = viewerPairingState.storageError {
                    Label(storageError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("worldwidePairingStorageError")
                }

                if let expiration = presentation.invitationExpiresAt {
                    LabeledContent("Invitation expires", value: expiration.formatted(date: .omitted, time: .shortened))
                        .accessibilityIdentifier("worldwideInvitationExpiration")
                }

                if let status = presentation.status {
                    worldwideStatusContent(status)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Connect from Anywhere")
            .accessibilityValue(presentation.accessibilityValue)
            .accessibilityIdentifier("worldwidePresentationState")

            #if DEBUG
            Section("Worldwide Development") {
                TextField("Rendezvous WebSocket URL", text: $debugWorldwideRendezvousEndpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                Text("Debug builds may override the bundled WSS endpoint. Plain ws:// is accepted only for loopback testing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif

            Section("Remote Mac") {
                TextField("Host or Relay URL", text: $remoteHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                if !isRelayURL {
                    TextField("Port", text: $remotePort)
                        .keyboardType(.numberPad)
                }

                HStack {
                    if showsToken {
                        TextField("Activation code", text: $remoteTokenState.token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("remoteActivationCode")
                    } else {
                        SecureField("Activation code", text: $remoteTokenState.token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("remoteActivationCode")
                    }

                    Button {
                        showsToken.toggle()
                    } label: {
                        Image(systemName: showsToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(
                        showsToken ? "Hide activation code" : "Show activation code"
                    )
                }

                if let storageError = remoteTokenState.storageError {
                    Label(storageError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if remoteTokenState.isStored && !trimmedRemoteToken.isEmpty {
                    Label(
                        "Saved securely and kept across app updates",
                        systemImage: "checkmark.shield"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if remoteTokenState.isStored {
                    Button(role: .destructive) {
                        remoteTokenState.clearSavedCode()
                    } label: {
                        Label("Clear Saved Activation Code", systemImage: "trash")
                    }
                }

                Button {
                    connectRemote()
                } label: {
                    Label("Connect", systemImage: "play.fill")
                }
                .disabled(!canConnectRemote)
            }

            if viewModel.servers.isEmpty {
                ContentUnavailableView(
                    "No Mac Found",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("Start CaptureServer on the Mac mini.")
                )
            } else {
                Section("Available Macs") {
                    ForEach(viewModel.servers) { server in
                        Button {
                            connectLocal(to: server)
                        } label: {
                            ServerRow(server: server)
                        }
                        .disabled(!server.isCompatible)
                    }
                }
            }

            if let lastError = viewModel.lastError {
                Section("Status") {
                    Label(lastError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("AudioStreamer")
        .onAppear {
            invitationCodeState.loadIfNeeded()
            remoteTokenState.loadIfNeeded()
            viewerPairingState.retryHydrationIfNeeded()
            invitationAdmissionState.retryHydrationIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                viewerPairingState.retryHydrationIfNeeded()
                invitationAdmissionState.retryHydrationIfNeeded()
            default:
                // Pairing and reconnect are intentionally allowed to finish under the
                // coordinator's short iOS background-task lease. Only the explicit Cancel
                // button may abandon the authenticated transition before durable recovery.
                break
            }
        }
        .toolbar {
            Button {
                viewModel.startBrowsing()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Refresh")
        }
    }

    @ViewBuilder
    private func activeWorldwideContent(
        _ activeSession: WorldwidePresentation.ActiveSession,
        actionTitle: String
    ) -> some View {
        LabeledContent("State", value: activeSession.stateText)
            .accessibilityLabel("State")
            .accessibilityValue(activeSession.stateText)
            .accessibilityIdentifier("worldwideSessionState")
        LabeledContent("Audio", value: activeSession.audioStateText)
            .accessibilityLabel("Audio")
            .accessibilityValue(activeSession.audioStateText)
            .accessibilityIdentifier("worldwideAudioState")

        if activeSession.canResumeAudioPlayback {
            Button {
                worldwideViewModel.resumeAudioPlayback()
            } label: {
                Label(
                    activeSession.audioRecoveryButtonTitle,
                    systemImage: "play.fill"
                )
            }
            .accessibilityIdentifier("resumeWorldwideAudio")
        }

        if activeSession.isPeerConnected {
            LabeledContent("Route", value: activeSession.routeText)
                .accessibilityLabel("Route")
                .accessibilityValue(activeSession.routeText)
                .accessibilityIdentifier("worldwideSessionRoute")
        }

        Button(role: .destructive) {
            worldwideViewModel.disconnect()
        } label: {
            Label(actionTitle, systemImage: "stop.fill")
        }
        .accessibilityIdentifier("disconnectWorldwide")
    }

    @ViewBuilder
    private func preparingWorldwideContent(
        _ preparingSession: WorldwidePresentation.PreparingSession,
        actionTitle: String
    ) -> some View {
        LabeledContent("State", value: preparingSession.stateText)
            .accessibilityLabel("State")
            .accessibilityValue(preparingSession.stateText)
            .accessibilityIdentifier("worldwidePreparationState")

        Button(role: .destructive) {
            cancelWorldwidePreparation()
        } label: {
            Label(actionTitle, systemImage: "xmark.circle.fill")
        }
        .accessibilityIdentifier("cancelWorldwidePreparation")
    }

    @ViewBuilder
    private func pairedWorldwideContent(
        _ pairedMac: WorldwidePresentation.PairedMac,
        actionTitle: String
    ) -> some View {
        if pairedMac.isPairingActive {
            LabeledContent("Paired Mac", value: pairedMac.displayName)
                .accessibilityLabel("Paired Mac")
                .accessibilityValue(pairedMac.displayName)
                .accessibilityIdentifier("worldwidePairedMac")
            Label(
                "Saved securely on this iPhone",
                systemImage: "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Saved secure pairing")
            .accessibilityValue(pairedMac.accessibilityFingerprint)
            .accessibilityIdentifier("worldwidePairingSaved")
        } else {
            Label(
                "Secure pairing needs to finish",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .foregroundStyle(.orange)
            Text("Reconnect retries the saved invitation first, then uses the authenticated recovery record if the Mac already advanced. Media stays disabled until both devices are active.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Button {
            connectPairedWorldwide()
        } label: {
            Label(actionTitle, systemImage: "network.badge.shield.half.filled")
        }
        .accessibilityIdentifier("connectPairedWorldwide")

        Button(role: .destructive) {
            forgetWorldwidePairing()
        } label: {
            Label("Forget Paired Mac", systemImage: "trash")
        }

        Text("The Mac must be awake with AudioStreamer Host running. Each connection uses fresh end-to-end-encrypted WebRTC keys; direct routing is preferred and TURN is only a fallback.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func worldwideBootstrapContent(actionTitle: String) -> some View {
        HStack {
            Group {
                if showsInvitationCode {
                    TextField(
                        "One-time invitation code",
                        text: $invitationCodeState.token
                    )
                } else {
                    SecureField(
                        "One-time invitation code",
                        text: $invitationCodeState.token
                    )
                }
            }
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .focused($invitationCodeIsFocused)
            .fontDesign(.monospaced)
            .accessibilityIdentifier("worldwideInvitationCode")

            Button {
                showsInvitationCode.toggle()
            } label: {
                Image(systemName: showsInvitationCode ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
                showsInvitationCode ? "Hide invitation code" : "Show invitation code"
            )
        }

        Button {
            pairAndConnectWorldwide()
        } label: {
            Label(actionTitle, systemImage: "network.badge.shield.half.filled")
        }
        .disabled(
            trimmedInvitationCode.isEmpty
                || invitationAdmissionState.blocksPairing(trimmedInvitationCode)
        )
        .accessibilityIdentifier("connectWorldwide")

        if let storageError = invitationCodeState.storageError {
            Label(storageError, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let storageError = invitationAdmissionState.storageError {
            Label(storageError, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if invitationAdmissionState.isAdmitted(trimmedInvitationCode) {
            Label(
                "Pairing was interrupted after this one-time code was accepted. Reset pairing on the Mac, then clear this code and generate a new one.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        } else if invitationCodeState.isStored && !trimmedInvitationCode.isEmpty {
            Label(
                "Saved securely until authenticated pairing completes",
                systemImage: "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if invitationCodeState.isStored {
            Button(role: .destructive) {
                clearSavedInvitation()
            } label: {
                Label("Clear Saved Invitation Code", systemImage: "trash")
            }
        }

        Text("The one-time code pairs this iPhone to the Mac. After that, the durable device binding survives app and phone restarts; every media connection still gets fresh keys.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func worldwideStatusContent(
        _ status: WorldwidePresentation.Status
    ) -> some View {
        switch status {
        case .savedPairUnavailable(let title, let message):
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    Text(message)
                        .font(.caption)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("worldwideSavedPairUnavailable")

        case .preparationError(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityIdentifier("worldwidePreparationError")

        case .mediaError(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityIdentifier("worldwideMediaError")

        case .audioError(let message):
            Label(message, systemImage: "speaker.slash")
                .foregroundStyle(.orange)
                .accessibilityIdentifier("worldwideAudioError")
        }
    }

    private var trimmedHost: String {
        remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedRemoteToken: String {
        remoteTokenState.token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedInvitationCode: String {
        invitationCodeState.token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedPort: UInt16? {
        UInt16(remotePort.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var isRelayURL: Bool {
        let value = trimmedHost.lowercased()
        return value.hasPrefix("ws://") ||
            value.hasPrefix("wss://") ||
            value.hasPrefix("http://") ||
            value.hasPrefix("https://")
    }

    private var canConnectRemote: Bool {
        !trimmedHost.isEmpty && (isRelayURL || parsedPort != nil)
    }

    private var worldwidePresentation: WorldwidePresentation {
        let pairedMac = viewerPairingState.pairingRecord.map {
            WorldwidePresentation.PairedMac(
                pairID: $0.pairID,
                displayName: $0.remoteDisplayName ?? "Mac",
                isPairingActive: $0.pairingState == .active
            )
        }
        return Self.worldwidePresentation(
            WorldwidePresentationInput(
                hasActiveSession: worldwideViewModel.hasActiveSession,
                activeStateText: worldwideViewModel.stateText,
                activeAudioStateText: worldwideViewModel.audioStateText,
                canResumeAudioPlayback: worldwideViewModel.canResumeAudioPlayback,
                audioRecoveryButtonTitle: worldwideViewModel.audioRecoveryButtonTitle,
                isPeerConnected: worldwideViewModel.isPeerConnected,
                routeText: worldwideViewModel.routeText,
                isPreparingFreshSession: worldwideConnection.isConnecting,
                preparationStateText: worldwideConnection.stateText,
                pairedMac: pairedMac,
                savedPairState: worldwideConnection.savedPairConnectionState,
                preparationError: worldwideConnection.lastError,
                mediaError: worldwideViewModel.lastError,
                audioError: worldwideViewModel.audioError,
                invitationExpiresAt: worldwideViewModel.invitationExpiresAt
            )
        )
    }

    /// Selects exactly one Connect-from-Anywhere surface. Status and invitation metadata are
    /// derived inside the same reduction so an idle durable pair cannot inherit rows from an
    /// earlier media session.
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
                // A coordinator error is the outcome of the user's latest preparation attempt:
                // keep it actionable beside the retained pair. Media/audio errors belong to the
                // previous session and remain structurally suppressed here.
                status: input.preparationError.map(
                    WorldwidePresentation.Status.preparationError
                ),
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

    private func connectRemote() {
        // The legacy PCM renderer and worldwide WebRTC renderer both own the process-wide
        // iOS audio session. Keep the UI connection paths mutually exclusive so one renderer
        // cannot deactivate or reconfigure the other's background playback session.
        if worldwideViewModel.hasActiveSession {
            worldwideViewModel.disconnect()
        }
        remoteTokenState.persistNow()
        if isRelayURL {
            viewModel.connect(relayURLString: trimmedHost, authToken: remoteTokenState.token)
        } else if let parsedPort {
            viewModel.connect(host: trimmedHost, port: parsedPort, authToken: remoteTokenState.token)
        }
    }

    private func pairAndConnectWorldwide() {
        invitationCodeState.persistNow()
        guard !invitationAdmissionState.blocksPairing(trimmedInvitationCode) else {
            worldwideConnection.reportConfigurationError(
                invitationAdmissionState.storageError
                    ?? "This one-time invitation was already admitted. Clear it and enter a new code from the Mac."
            )
            return
        }
        guard let endpoint = configuredWorldwideEndpoint() else {
            worldwideConnection.reportConfigurationError(
                "This build does not have a valid worldwide rendezvous endpoint."
            )
            return
        }

        cancelWorldwidePreparation()
        worldwideViewModel.beginFreshConnectionAttempt()
        let invitation = trimmedInvitationCode
        let generation = UUID()
        worldwidePreparationGeneration = generation
        worldwidePreparationTask = Task { @MainActor in
            do {
                let client = try await worldwideConnection.pairAndPrepareMediaSession(
                    invitationCode: invitation,
                    endpoint: endpoint,
                    pairingState: viewerPairingState,
                    onRecoverableInvitationAdmitted: {
                        try invitationAdmissionState.markAdmitted(invitation)
                    },
                    onAuthenticatedPairingCompleted: clearInvitationAfterPairing
                )
                try Task.checkCancellation()
                await startPreparedWorldwideSession(client, generation: generation)
            } catch is CancellationError {
                // Explicit cancellation is already reflected by the coordinator UI.
            } catch {
                // The coordinator publishes a non-sensitive, user-facing error.
            }
            if worldwidePreparationGeneration == generation {
                worldwidePreparationTask = nil
            }
        }
    }

    private func connectPairedWorldwide() {
        guard let endpoint = configuredWorldwideEndpoint() else {
            worldwideConnection.reportConfigurationError(
                "This build does not have a valid worldwide rendezvous endpoint."
            )
            return
        }

        cancelWorldwidePreparation()
        worldwideViewModel.beginFreshConnectionAttempt()
        invitationCodeState.persistNow()
        let interruptedInvitation = trimmedInvitationCode
        let needsInterruptedRecovery =
            viewerPairingState.pairingRecord?.pairingState != .active
                && !interruptedInvitation.isEmpty
        let generation = UUID()
        worldwidePreparationGeneration = generation
        worldwidePreparationTask = Task { @MainActor in
            do {
                let client: RendezvousSignalingClient
                if needsInterruptedRecovery {
                    client = try await worldwideConnection
                        .recoverInterruptedPairingAndPrepareMediaSession(
                            invitationCode: interruptedInvitation,
                            endpoint: endpoint,
                            pairingState: viewerPairingState,
                            onRecoverableInvitationAdmitted: {
                                try invitationAdmissionState.markAdmitted(
                                    interruptedInvitation
                                )
                            },
                            onAuthenticatedPairingCompleted: clearInvitationAfterPairing
                        )
                } else {
                    client = try await worldwideConnection.preparePairedMediaSession(
                        endpoint: endpoint,
                        pairingState: viewerPairingState,
                        onAuthenticatedPairingCompleted: clearInvitationAfterPairing
                    )
                }
                try Task.checkCancellation()
                await startPreparedWorldwideSession(client, generation: generation)
            } catch is CancellationError {
                // Explicit cancellation is already reflected by the coordinator UI.
            } catch {
                // The coordinator publishes a non-sensitive, user-facing error.
            }
            if worldwidePreparationGeneration == generation {
                worldwidePreparationTask = nil
            }
        }
    }

    private func startPreparedWorldwideSession(
        _ client: RendezvousSignalingClient,
        generation: UUID
    ) async {
        await Self.handoffPreparedWorldwideSession(
            generation: generation,
            isCurrentGeneration: {
                worldwidePreparationGeneration == generation
            },
            connect: {
                worldwideViewModel.connect(
                    signalingClient: client,
                    beforeAudioActivation: {
                        if viewModel.selectedServer != nil {
                            viewModel.disconnect()
                        }
                    }
                )
            },
            close: {
                await client.close()
            },
            reportActiveSessionConflict: {
                worldwideConnection.reportConfigurationError(
                    "Another worldwide session is already active."
                )
            }
        )
    }

    private func clearInvitationAfterPairing() {
        // Active paired state has already reached the this-device-only Keychain before this
        // destructive cleanup runs. The admission marker remains unless code deletion itself
        // succeeds, preserving the no-retry invariant across partial Keychain failures.
        guard invitationCodeState.clearSavedCode() else { return }
        _ = invitationAdmissionState.clearMarker()
        showsInvitationCode = false
        invitationCodeIsFocused = false
    }

    private func clearSavedInvitation() {
        guard invitationCodeState.clearSavedCode() else { return }
        _ = invitationAdmissionState.clearMarker()
        showsInvitationCode = false
        invitationCodeIsFocused = false
    }

    private func forgetWorldwidePairing() {
        cancelWorldwidePreparation()
        if worldwideViewModel.hasActiveSession {
            worldwideViewModel.disconnect()
        }
        do {
            try viewerPairingState.forgetPairedMac()
            clearSavedInvitation()
            worldwideConnection.clearError()
        } catch {
            // ViewerPairingState publishes the Keychain failure without dropping in-memory state.
        }
    }

    private func cancelWorldwidePreparation() {
        worldwidePreparationGeneration = UUID()
        worldwidePreparationTask?.cancel()
        worldwidePreparationTask = nil
        worldwideConnection.cancel()
    }

    private func configuredWorldwideEndpoint() -> URL? {
        #if DEBUG
        let debugEndpoint: String? = debugWorldwideRendezvousEndpoint
        #else
        let debugEndpoint: String? = nil
        #endif
        return WorldwideSessionViewModel.rendezvousEndpoint(debugOverride: debugEndpoint)
    }

    private func connectLocal(to server: ServerInfo) {
        if worldwideViewModel.hasActiveSession {
            worldwideViewModel.disconnect()
        }
        viewModel.connect(to: server)
    }
}

private struct ServerRow: View {
    let server: ServerInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "macmini")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: server.isCompatible ? "chevron.right" : "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(server.isCompatible ? Color.secondary : Color.orange)
        }
        .padding(.vertical, 4)
    }

    private var details: String {
        let metadata = [
            server.sampleRate.map { "\($0) Hz" },
            server.channels.map { "\($0) ch" },
            server.format
        ]
        .compactMap { $0 }
        .joined(separator: " · ")

        guard server.isCompatible else {
            return metadata.isEmpty
                ? server.compatibility.message
                : "\(metadata) · \(server.compatibility.message)"
        }

        return metadata.isEmpty ? server.compatibility.message : metadata
    }
}
