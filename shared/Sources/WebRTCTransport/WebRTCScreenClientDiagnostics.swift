import Foundation

/// A privacy-safe diagnosis of the viewer's screen pipeline. These states deliberately describe
/// evidence rather than asserting that unchanged desktop content is frozen.
public enum WebRTCScreenClientLiveness: String, Codable, Equatable, Sendable {
    case intentionallyCovered
    case covered
    case trackMissing
    case awaitingEvidence
    case inboundRTPStalled
    case decodeStalled
    case presentationStalled
    case presentingUnchanged
    case presentingLive
    case unavailable
}

public enum WebRTCScreenClientCoverReason: String, Codable, Equatable, Sendable {
    case none
    case bandwidthPause
    case privacy
    case resuming
    case screenHidden
}

/// One bounded, content-free client heartbeat sent to the paired Mac on an isolated data channel.
/// Pixels, digests, SDP, candidates, track IDs, SSRCs, and arbitrary strings are never carried.
public struct WebRTCScreenClientDiagnosticsHeartbeat: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1
    public static let maximumPresentationAgeMilliseconds: UInt64 = 86_400_000
    public static let maximumDimension = 32_768
    public static let maximumFramesPerSecond = 1_000.0

    public let protocolVersion: Int
    public let sequence: UInt64
    public let screenRequestID: UInt64?
    public let liveness: WebRTCScreenClientLiveness
    public let trackAttached: Bool
    public let coverVisible: Bool
    public let coverReason: WebRTCScreenClientCoverReason
    public let inboundBytes: UInt64?
    public let inboundPackets: UInt64?
    public let framesDecoded: UInt64?
    public let framesPresented: UInt64?
    public let contentSamples: UInt64?
    public let contentChanges: UInt64?
    public let presentationAgeMilliseconds: UInt64?
    public let frameWidth: Int?
    public let frameHeight: Int?
    public let framesPerSecond: Double?

    public init(
        sequence: UInt64,
        screenRequestID: UInt64?,
        liveness: WebRTCScreenClientLiveness,
        trackAttached: Bool,
        coverVisible: Bool,
        coverReason: WebRTCScreenClientCoverReason,
        inboundBytes: UInt64? = nil,
        inboundPackets: UInt64? = nil,
        framesDecoded: UInt64? = nil,
        framesPresented: UInt64? = nil,
        contentSamples: UInt64? = nil,
        contentChanges: UInt64? = nil,
        presentationAgeMilliseconds: UInt64? = nil,
        frameWidth: Int? = nil,
        frameHeight: Int? = nil,
        framesPerSecond: Double? = nil
    ) {
        protocolVersion = Self.currentProtocolVersion
        self.sequence = sequence
        self.screenRequestID = screenRequestID
        self.liveness = liveness
        self.trackAttached = trackAttached
        self.coverVisible = coverVisible
        self.coverReason = coverReason
        self.inboundBytes = inboundBytes
        self.inboundPackets = inboundPackets
        self.framesDecoded = framesDecoded
        self.framesPresented = framesPresented
        self.contentSamples = contentSamples
        self.contentChanges = contentChanges
        self.presentationAgeMilliseconds = presentationAgeMilliseconds
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.framesPerSecond = framesPerSecond
    }

    public var isValid: Bool {
        guard protocolVersion == Self.currentProtocolVersion,
              sequence > 0,
              screenRequestID.map({ $0 > 0 }) ?? true,
              presentationAgeMilliseconds.map({
                  $0 <= Self.maximumPresentationAgeMilliseconds
              }) ?? true,
              Self.validDimension(frameWidth),
              Self.validDimension(frameHeight),
              framesPerSecond.map({
                  $0.isFinite && $0 >= 0 && $0 <= Self.maximumFramesPerSecond
              }) ?? true else {
            return false
        }
        if liveness == .trackMissing {
            guard !trackAttached else { return false }
        } else if liveness != .unavailable && liveness != .covered {
            guard trackAttached else { return false }
        }
        if liveness == .presentingLive || liveness == .presentingUnchanged {
            guard framesPresented != nil,
                  contentSamples != nil,
                  contentChanges != nil,
                  presentationAgeMilliseconds != nil,
                  frameWidth != nil,
                  frameHeight != nil else {
                return false
            }
        }
        if contentChanges != nil, contentSamples == nil { return false }
        if contentSamples != nil, framesPresented == nil { return false }
        if let contentChanges, let contentSamples,
           contentChanges > contentSamples {
            return false
        }
        if let contentSamples, let framesPresented,
           contentSamples > framesPresented {
            return false
        }
        guard coverVisible == (coverReason != .none) else { return false }
        switch coverReason {
        case .bandwidthPause:
            return liveness == .intentionallyCovered
        case .privacy, .resuming, .screenHidden:
            return liveness == .covered
        case .none:
            return liveness != .intentionallyCovered && liveness != .covered
        }
    }

    private static func validDimension(_ value: Int?) -> Bool {
        value.map { $0 > 0 && $0 <= maximumDimension } ?? true
    }
}

/// Strict union for the non-critical diagnostics lane. Malformed messages close only this lane.
enum ScreenClientDiagnosticsChannelMessage: Codable, Equatable, Sendable {
    static let currentVersion = 1

    case heartbeat(WebRTCScreenClientDiagnosticsHeartbeat)

    private enum Kind: String, Codable {
        case heartbeat
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case kind
        case heartbeat
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported screen-client diagnostics version."
            )
        }
        switch try container.decode(Kind.self, forKey: .kind) {
        case .heartbeat:
            self = .heartbeat(
                try container.decode(
                    WebRTCScreenClientDiagnosticsHeartbeat.self,
                    forKey: .heartbeat
                )
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        switch self {
        case .heartbeat(let heartbeat):
            try container.encode(Kind.heartbeat, forKey: .kind)
            try container.encode(heartbeat, forKey: .heartbeat)
        }
    }
}
