import SwiftUI

struct BrowserView: View {
    @EnvironmentObject private var viewModel: StreamSessionViewModel
    @AppStorage("remoteHost") private var remoteHost = ""
    @AppStorage("remotePort") private var remotePort = "9000"
    @State private var remoteToken = ""
    @State private var showsToken = false

    var body: some View {
        List {
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
                        TextField("Token", text: $remoteToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField("Token", text: $remoteToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Button {
                        showsToken.toggle()
                    } label: {
                        Image(systemName: showsToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showsToken ? "Hide token" : "Show token")
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
                            viewModel.connect(to: server)
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
            remoteToken = KeychainStore.remoteToken() ?? ""
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
        KeychainStore.saveRemoteToken(remoteToken)
        if isRelayURL {
            viewModel.connect(relayURLString: trimmedHost, authToken: remoteToken)
        } else if let parsedPort {
            viewModel.connect(host: trimmedHost, port: parsedPort, authToken: remoteToken)
        }
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
