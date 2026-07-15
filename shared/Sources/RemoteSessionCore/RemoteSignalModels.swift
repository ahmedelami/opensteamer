import Foundation

public enum RemotePeerRole: String, Codable, CaseIterable, Sendable {
    case host
    case viewer
}

public struct RemoteICEServer: Codable, Equatable, Sendable {
    public let urls: [String]
    public let username: String?
    public let credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

public struct RemoteICECandidate: Codable, Equatable, Sendable {
    public let sdp: String
    public let sdpMid: String?
    public let sdpMLineIndex: Int32?
    /// ICE username fragment for the candidate's negotiation generation.
    ///
    /// This is optional so pre-recovery clients that sent only the legacy three fields still
    /// decode. Recovery-capable peers require it after the first negotiation to reject delayed
    /// candidates from an older ICE generation.
    public let usernameFragment: String?

    public init(
        sdp: String,
        sdpMid: String? = nil,
        sdpMLineIndex: Int32? = nil,
        usernameFragment: String? = nil
    ) {
        self.sdp = sdp
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.usernameFragment = usernameFragment
    }
}

public enum RemoteControlCommand: String, Codable, CaseIterable, Sendable {
    case showScreen
    case hideScreen
    case requestKeyFrame
}

public enum RemoteSessionEndReason: String, Codable, CaseIterable, Sendable {
    case normal
    case hostStopped
    case viewerDisconnected
    case replaced
    case protocolError
}

public struct RemotePeerIdentity: Codable, Equatable, Sendable {
    public let deviceID: UUID
    public let role: RemotePeerRole
    public let publicKey: Data
    public let displayName: String?

    public init(
        deviceID: UUID,
        role: RemotePeerRole,
        publicKey: Data,
        displayName: String? = nil
    ) {
        self.deviceID = deviceID
        self.role = role
        self.publicKey = publicKey
        self.displayName = displayName
    }
}

/// A viewer request for the host to begin a bounded ICE-restart workflow.
///
/// Request identifiers are monotonically increasing within one encrypted rendezvous session so
/// the host can ignore duplicate or stale requests without retaining an unbounded replay set.
public struct RemoteICERestartRequest: Codable, Equatable, Sendable {
    public static let currentProtocolVersion: UInt8 = 1

    public let protocolVersion: UInt8
    public let requestID: UInt64

    public init(
        requestID: UInt64,
        protocolVersion: UInt8 = RemoteICERestartRequest.currentProtocolVersion
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
    }
}

/// The application-level messages exchanged through encrypted rendezvous signaling.
public enum RemoteSignalPayload: Equatable, Sendable {
    case offer(sdp: String)
    case answer(sdp: String)
    case candidate(RemoteICECandidate)
    case end(RemoteSessionEndReason)
    case control(RemoteControlCommand)
    case identity(RemotePeerIdentity)
    case iceRestartRequest(RemoteICERestartRequest)
}

extension RemoteSignalPayload: Codable {
    private enum Kind: String, Codable {
        case offer
        case answer
        case candidate
        case end
        case control
        case identity
        case iceRestartRequest
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case sdp
        case candidate
        case endReason
        case control
        case identity
        case iceRestartRequest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .offer:
            self = .offer(sdp: try container.decode(String.self, forKey: .sdp))
        case .answer:
            self = .answer(sdp: try container.decode(String.self, forKey: .sdp))
        case .candidate:
            self = .candidate(try container.decode(RemoteICECandidate.self, forKey: .candidate))
        case .end:
            self = .end(try container.decode(RemoteSessionEndReason.self, forKey: .endReason))
        case .control:
            self = .control(try container.decode(RemoteControlCommand.self, forKey: .control))
        case .identity:
            self = .identity(try container.decode(RemotePeerIdentity.self, forKey: .identity))
        case .iceRestartRequest:
            self = .iceRestartRequest(
                try container.decode(RemoteICERestartRequest.self, forKey: .iceRestartRequest)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .offer(let sdp):
            try container.encode(Kind.offer, forKey: .kind)
            try container.encode(sdp, forKey: .sdp)
        case .answer(let sdp):
            try container.encode(Kind.answer, forKey: .kind)
            try container.encode(sdp, forKey: .sdp)
        case .candidate(let candidate):
            try container.encode(Kind.candidate, forKey: .kind)
            try container.encode(candidate, forKey: .candidate)
        case .end(let reason):
            try container.encode(Kind.end, forKey: .kind)
            try container.encode(reason, forKey: .endReason)
        case .control(let command):
            try container.encode(Kind.control, forKey: .kind)
            try container.encode(command, forKey: .control)
        case .identity(let identity):
            try container.encode(Kind.identity, forKey: .kind)
            try container.encode(identity, forKey: .identity)
        case .iceRestartRequest(let request):
            try container.encode(Kind.iceRestartRequest, forKey: .kind)
            try container.encode(request, forKey: .iceRestartRequest)
        }
    }
}
