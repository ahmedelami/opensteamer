import RemoteSessionCore
import SwiftUI

struct BrowserView: View {
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
        List {
            Section("Connect from Anywhere") {
                if worldwideViewModel.hasActiveSession {
                    LabeledContent("State", value: worldwideViewModel.stateText)
                    LabeledContent("Audio", value: worldwideViewModel.audioStateText)
                        .accessibilityIdentifier("worldwideAudioState")

                    if worldwideViewModel.canResumeAudioPlayback {
                        Button {
                            worldwideViewModel.resumeAudioPlayback()
                        } label: {
                            Label(
                                worldwideViewModel.audioRecoveryButtonTitle,
                                systemImage: "play.fill"
                            )
                        }
                        .accessibilityIdentifier("resumeWorldwideAudio")
                    }

                    if worldwideViewModel.isPeerConnected {
                        LabeledContent("Route", value: worldwideViewModel.routeText)
                    }

                    Button(role: .destructive) {
                        worldwideViewModel.disconnect()
                    } label: {
                        Label("Disconnect Remote Mac", systemImage: "stop.fill")
                    }
                } else if worldwideConnection.isConnecting {
                    LabeledContent("State", value: worldwideConnection.stateText)

                    Button(role: .destructive) {
                        cancelWorldwidePreparation()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle.fill")
                    }
                } else if let pairingRecord = viewerPairingState.pairingRecord {
                    if pairingRecord.pairingState == .active {
                        LabeledContent(
                            "Paired Mac",
                            value: pairingRecord.remoteDisplayName ?? "Mac"
                        )
                        Label(
                            "Saved securely on this iPhone",
                            systemImage: "checkmark.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        Label(
                            pairingRecord.pairingState == .active
                                ? "Connect to Paired Mac"
                                : "Finish Secure Pairing",
                            systemImage: "network.badge.shield.half.filled"
                        )
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
                } else {
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
                        Label(
                            "Pair and Connect Securely",
                            systemImage: "network.badge.shield.half.filled"
                        )
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

                if let storageError = viewerPairingState.storageError {
                    Label(storageError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                if let preparationError = worldwideConnection.lastError {
                    Label(preparationError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                if let expiration = worldwideViewModel.invitationExpiresAt {
                    LabeledContent("Invitation expires", value: expiration.formatted(date: .omitted, time: .shortened))
                }

                if let audioError = worldwideViewModel.audioError {
                    Label(audioError, systemImage: "speaker.slash")
                        .foregroundStyle(.orange)
                }

                if Self.shouldShowPreviousMediaError(
                    isPreparingFreshSession: worldwideConnection.isConnecting
                ), let lastError = worldwideViewModel.lastError {
                    Label(lastError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

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

    static func shouldShowPreviousMediaError(
        isPreparingFreshSession: Bool
    ) -> Bool {
        !isPreparingFreshSession
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
                await startPreparedWorldwideSession(client)
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
                await startPreparedWorldwideSession(client)
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
        _ client: RendezvousSignalingClient
    ) async {
        let started = worldwideViewModel.connect(
            signalingClient: client,
            beforeAudioActivation: {
                if viewModel.selectedServer != nil {
                    viewModel.disconnect()
                }
            }
        )
        guard started else {
            await client.close()
            worldwideConnection.reportConfigurationError(
                "Another worldwide session is already active."
            )
            return
        }
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
