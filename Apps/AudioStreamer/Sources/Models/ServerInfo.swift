import Foundation
import Network

struct ServerInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
    let version: String?
    let sampleRate: String?
    let channels: String?
    let format: String?
    let compatibility: ServerCompatibility

    init?(host: String, port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return nil
        }

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            return nil
        }

        self.endpoint = .hostPort(host: NWEndpoint.Host(trimmedHost), port: nwPort)
        self.id = "remote:\(trimmedHost):\(port)"
        self.name = trimmedHost
        self.version = nil
        self.sampleRate = nil
        self.channels = nil
        self.format = nil
        self.compatibility = .missingTXT
    }

    init(relayURL: URL) {
        let portValue = relayURL.port ?? (relayURL.scheme == "ws" ? 80 : 443)
        let port = NWEndpoint.Port(rawValue: UInt16(portValue)) ?? 443
        let host = relayURL.host ?? "Relay"

        self.endpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        self.id = "relay:\(relayURL.absoluteString)"
        self.name = relayURL.host ?? "Relay"
        self.version = nil
        self.sampleRate = nil
        self.channels = nil
        self.format = nil
        self.compatibility = .missingTXT
    }

    init(endpoint: NWEndpoint, metadata: NWBrowser.Result.Metadata) {
        self.endpoint = endpoint
        self.id = endpoint.debugDescription
        self.name = endpoint.serviceName ?? endpoint.debugDescription

        let txt = metadata.bonjourTXT
        self.version = txt["version"]
        self.sampleRate = txt["rate"]
        self.channels = txt["channels"]
        self.format = txt["format"]
        self.compatibility = ServerCompatibility(
            version: txt["version"],
            sampleRate: txt["rate"],
            channels: txt["channels"],
            format: txt["format"]
        )
    }

    var isCompatible: Bool {
        compatibility.allowsConnection
    }
}

enum ServerCompatibility: Hashable {
    case compatible
    case missingTXT
    case unsupportedVersion(String)
    case unsupportedSampleRate(String)
    case unsupportedChannels(String)
    case unsupportedFormat(String)

    init(version: String?, sampleRate: String?, channels: String?, format: String?) {
        guard let version, let sampleRate, let channels, let format else {
            self = .missingTXT
            return
        }

        guard version == "1" else {
            self = .unsupportedVersion(version)
            return
        }

        guard sampleRate == "48000" else {
            self = .unsupportedSampleRate(sampleRate)
            return
        }

        guard channels == "2" else {
            self = .unsupportedChannels(channels)
            return
        }

        guard format.lowercased() == "pcm16le" else {
            self = .unsupportedFormat(format)
            return
        }

        self = .compatible
    }

    var message: String {
        switch self {
        case .compatible:
            "Ready"
        case .missingTXT:
            "Ready, metadata pending"
        case .unsupportedVersion(let value):
            "Unsupported version \(value)"
        case .unsupportedSampleRate(let value):
            "Unsupported rate \(value)"
        case .unsupportedChannels(let value):
            "Unsupported channels \(value)"
        case .unsupportedFormat(let value):
            "Unsupported format \(value)"
        }
    }

    var allowsConnection: Bool {
        switch self {
        case .compatible, .missingTXT:
            true
        case .unsupportedVersion, .unsupportedSampleRate, .unsupportedChannels, .unsupportedFormat:
            false
        }
    }
}

private extension NWEndpoint {
    var serviceName: String? {
        if case .service(let name, _, _, _) = self {
            return name
        }
        return nil
    }
}

private extension NWBrowser.Result.Metadata {
    var bonjourTXT: [String: String] {
        guard case .bonjour(let record) = self else {
            return [:]
        }

        return record.dictionary
    }
}
