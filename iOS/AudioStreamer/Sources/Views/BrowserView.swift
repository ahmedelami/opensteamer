import SwiftUI

struct BrowserView: View {
    @EnvironmentObject private var viewModel: StreamSessionViewModel
    @EnvironmentObject private var worldwideViewModel: WorldwideSessionViewModel
    @AppStorage("remoteHost") private var remoteHost = ""
    @AppStorage("remotePort") private var remotePort = "9000"
    @StateObject private var remoteTokenState = RemoteTokenState()
    @State private var showsToken = false
    @State private var invitationCode = ""
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

                    if worldwideViewModel.audioRequiresExplicitResume {
                        Button {
                            worldwideViewModel.resumeAudioPlayback()
                        } label: {
                            Label("Resume Audio", systemImage: "play.fill")
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
                                TextField("One-time invitation code", text: $invitationCode)
                            } else {
                                SecureField("One-time invitation code", text: $invitationCode)
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

                    Text("The Mac must be awake with AudioStreamer Host running. The app tries direct WebRTC first and otherwise relays end-to-end-encrypted WebRTC media through TURN.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let expiration = worldwideViewModel.invitationExpiresAt {
                    LabeledContent("Invitation expires", value: expiration.formatted(date: .omitted, time: .shortened))
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
        invitationCode.trimmingCharacters(in: .whitespacesAndNewlines)
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

        if worldwideViewModel.connect(
            invitationCode: trimmedInvitationCode,
            debugEndpointOverride: debugEndpoint,
            beforeAudioActivation: {
                if viewModel.selectedServer != nil {
                    viewModel.disconnect()
                }
            }
        ) {
            // A one-time capability should not remain in visible or persisted UI state.
            invitationCode = ""
            showsInvitationCode = false
            invitationCodeIsFocused = false
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
