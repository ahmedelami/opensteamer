import SwiftUI

struct BrowserView: View {
    @EnvironmentObject private var viewModel: StreamSessionViewModel
    @EnvironmentObject private var worldwideViewModel: WorldwideSessionViewModel
    @AppStorage("remoteHost") private var remoteHost = ""
    @AppStorage("remotePort") private var remotePort = "9000"
    @StateObject private var remoteTokenState = RemoteTokenState()
    @StateObject private var invitationCodeState = RemoteTokenState(
        store: KeychainStore(item: KeychainStore.worldwideInvitationCodeItem),
        codeDisplayName: "invitation code"
    )
    @State private var showsToken = false
    @State private var showsInvitationCode = false
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
                        connectWorldwide()
                    } label: {
                        if worldwideViewModel.isConnecting {
                            Label("Connecting", systemImage: "hourglass")
                        } else {
                            Label("Connect Securely", systemImage: "network.badge.shield.half.filled")
                        }
                    }
                    .disabled(trimmedInvitationCode.isEmpty || worldwideViewModel.isConnecting)
                    .accessibilityIdentifier("connectWorldwide")

                    if let storageError = invitationCodeState.storageError {
                        Label(storageError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if invitationCodeState.isStored && !trimmedInvitationCode.isEmpty {
                        Label(
                            "Saved securely on this iPhone until used",
                            systemImage: "checkmark.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if invitationCodeState.isStored {
                        Button(role: .destructive) {
                            invitationCodeState.clearSavedCode()
                        } label: {
                            Label("Clear Saved Invitation Code", systemImage: "trash")
                        }
                    }

                    Text("The Mac must be awake with AudioStreamer Host running. The app tries direct WebRTC first and otherwise relays end-to-end-encrypted WebRTC media through TURN.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let expiration = worldwideViewModel.invitationExpiresAt {
                    LabeledContent("Invitation expires", value: expiration.formatted(date: .omitted, time: .shortened))
                }

                if let audioError = worldwideViewModel.audioError {
                    Label(audioError, systemImage: "speaker.slash")
                        .foregroundStyle(.orange)
                }

                if let lastError = worldwideViewModel.lastError {
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

    private func connectWorldwide() {
        #if DEBUG
        let debugEndpoint: String? = debugWorldwideRendezvousEndpoint
        #else
        let debugEndpoint: String? = nil
        #endif

        invitationCodeState.persistNow()
        if worldwideViewModel.connect(
            invitationCode: trimmedInvitationCode,
            debugEndpointOverride: debugEndpoint,
            beforeAudioActivation: {
                if viewModel.selectedServer != nil {
                    viewModel.disconnect()
                }
            },
            onInvitationAccepted: {
                // Retain the one-time code through relaunches, updates, and asynchronous
                // connection failures. Erase it only after rendezvous accepts this attempt.
                invitationCodeState.clearSavedCode()
                showsInvitationCode = false
                invitationCodeIsFocused = false
            }
        ) {
            // Connection started. Destructive cleanup is deferred to `onInvitationAccepted`.
        }
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
