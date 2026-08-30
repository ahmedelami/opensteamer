import Foundation
import RemoteSessionCore

/// The screen state the host has actually reached, not merely the state the viewer requested.
public enum WebRTCScreenState: String, Codable, CaseIterable, Sendable {
    case active
    case inactive
}

/// A monotonically identified command delivered over the ordered WebRTC control channel.
public struct WebRTCControlRequest: Codable, Equatable, Sendable {
    public let id: UInt64
    public let command: RemoteControlCommand

    public init(id: UInt64, command: RemoteControlCommand) {
        self.id = id
        self.command = command
    }
}

/// Confirmation that the host has completed a request and reached `state`.
public struct WebRTCControlAcknowledgement: Codable, Equatable, Sendable {
    public let id: UInt64
    public let state: WebRTCScreenState
    /// Present only when a successful Show/Active transition also authorizes this exact
    /// screen generation for remote input. Older v2 peers safely ignore this optional field.
    public let inputCapability: WebRTCInputCapability?

    public init(
        id: UInt64,
        state: WebRTCScreenState,
        inputCapability: WebRTCInputCapability? = nil
    ) {
        self.id = id
        self.state = state
        self.inputCapability = inputCapability
    }
}

/// RFC 3550 serial-number ordering for the 32-bit RTP timestamp domain. A delta of exactly half
/// the serial space has no defined direction and is surfaced as `ambiguous`, never guessed.
public enum WebRTCRTPSerialComparison: Equatable, Sendable {
    case same
    case newer
    case older
    case ambiguous
}

public enum WebRTCRTPSerialComparator {
    public static func compare(
        _ candidate: UInt32,
        relativeTo reference: UInt32
    ) -> WebRTCRTPSerialComparison {
        guard candidate != reference else { return .same }
        let forwardDistance = candidate &- reference
        if forwardDistance == 0x8000_0000 { return .ambiguous }
        return forwardDistance < 0x8000_0000 ? .newer : .older
    }

    public static func isStrictlyNewer(_ candidate: UInt32, than reference: UInt32) -> Bool {
        compare(candidate, relativeTo: reference) == .newer
    }

    public static func isSameOrNewer(_ candidate: UInt32, than reference: UInt32) -> Bool {
        switch compare(candidate, relativeTo: reference) {
        case .same, .newer:
            true
        case .older, .ambiguous:
            false
        }
    }

    /// Returns the unambiguous forward serial distance only when `candidate` is strictly newer.
    public static func strictlyNewerForwardDistance(
        from reference: UInt32,
        to candidate: UInt32
    ) -> UInt32? {
        guard compare(candidate, relativeTo: reference) == .newer else { return nil }
        return candidate &- reference
    }
}

/// Capture geometry bound to one host-observed geometry revision. Dimensions are deliberately
/// bounded well above supported Apple displays so untrusted wire values cannot reach ratio math.
public struct WebRTCScreenMediaGeometry: Codable, Equatable, Sendable {
    public let geometryRevision: UInt64
    public let captureWidth: Int
    public let captureHeight: Int

    public init(
        geometryRevision: UInt64,
        captureWidth: Int,
        captureHeight: Int
    ) {
        self.geometryRevision = geometryRevision
        self.captureWidth = captureWidth
        self.captureHeight = captureHeight
    }

    private enum CodingKeys: String, CodingKey {
        case geometryRevision
        case captureWidth
        case captureHeight
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = Self(
            geometryRevision: try container.decode(UInt64.self, forKey: .geometryRevision),
            captureWidth: try container.decode(Int.self, forKey: .captureWidth),
            captureHeight: try container.decode(Int.self, forKey: .captureHeight)
        )
        guard value.isValid else {
            throw Self.invalidPayload(in: container, description: "Invalid screen-media geometry.")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw Self.invalidEncoding(self, encoder: encoder, description: "Invalid screen-media geometry.")
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(geometryRevision, forKey: .geometryRevision)
        try container.encode(captureWidth, forKey: .captureWidth)
        try container.encode(captureHeight, forKey: .captureHeight)
    }

    public var isValid: Bool {
        geometryRevision > 0
            && ScreenMediaWireValidation.validDimension(captureWidth)
            && ScreenMediaWireValidation.validDimension(captureHeight)
    }

    /// Returns whether a bounded decoded presentation can represent this exact capture geometry.
    /// Downscaling is allowed, but rotation, aspect changes, zero, and oversized dimensions are
    /// rejected so renderer-side proof uses the same validation as the wire transcript.
    public func isCompatiblePresentation(width: Int, height: Int) -> Bool {
        ScreenMediaWireValidation.validDimension(width)
            && ScreenMediaWireValidation.validDimension(height)
            && width <= captureWidth
            && height <= captureHeight
            && ScreenMediaWireValidation.hasCompatibleAspectRatio(
                presentedWidth: width,
                presentedHeight: height,
                captureWidth: captureWidth,
                captureHeight: captureHeight
            )
    }

    private static func invalidPayload(
        in container: KeyedDecodingContainer<CodingKeys>,
        description: String
    ) -> DecodingError {
        .dataCorruptedError(forKey: .geometryRevision, in: container, debugDescription: description)
    }

    private static func invalidEncoding(
        _ value: Self,
        encoder: any Encoder,
        description: String
    ) -> EncodingError {
        .invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: description))
    }
}

/// Host notice that one still-requested screen has entered a new automatic suspension generation.
/// It is sent only after the viewer echoes `ScreenMediaSuspensionSDP` support.
public struct WebRTCScreenMediaSuspensionNotice: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let screenRequestID: UInt64
    public let suspensionGeneration: UInt64

    public init(
        screenRequestID: UInt64,
        suspensionGeneration: UInt64,
        protocolVersion: Int = Self.currentProtocolVersion
    ) {
        self.protocolVersion = protocolVersion
        self.screenRequestID = screenRequestID
        self.suspensionGeneration = suspensionGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case screenRequestID
        case suspensionGeneration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = Self(
            screenRequestID: try container.decode(UInt64.self, forKey: .screenRequestID),
            suspensionGeneration: try container.decode(UInt64.self, forKey: .suspensionGeneration),
            protocolVersion: try container.decode(Int.self, forKey: .protocolVersion)
        )
        guard value.isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription: "Invalid screen-media suspension notice."
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid screen-media suspension notice.")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(screenRequestID, forKey: .screenRequestID)
        try container.encode(suspensionGeneration, forKey: .suspensionGeneration)
    }

    public var isValid: Bool {
        protocolVersion == Self.currentProtocolVersion
            && screenRequestID > 0
            && suspensionGeneration > 0
    }
}

/// Viewer proof that the forced cover is installed. Embedding the complete notice makes the ACK an
/// exact, replay-safe echo rather than a separately reconstructed pair of generation counters.
public struct WebRTCScreenMediaCoveredAcknowledgement: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let suspension: WebRTCScreenMediaSuspensionNotice

    public init(
        suspension: WebRTCScreenMediaSuspensionNotice,
        protocolVersion: Int = Self.currentProtocolVersion
    ) {
        self.protocolVersion = protocolVersion
        self.suspension = suspension
    }

    private enum CodingKeys: String, CodingKey { case protocolVersion, suspension }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = Self(
            suspension: try container.decode(
                WebRTCScreenMediaSuspensionNotice.self,
                forKey: .suspension
            ),
            protocolVersion: try container.decode(Int.self, forKey: .protocolVersion)
        )
        guard value.isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription: "Invalid screen-media covered acknowledgement."
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid screen-media covered acknowledgement.")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(suspension, forKey: .suspension)
    }

    public var isValid: Bool {
        protocolVersion == Self.currentProtocolVersion && suspension.isValid
    }

    public func isExactEcho(of notice: WebRTCScreenMediaSuspensionNotice) -> Bool {
        isValid && suspension == notice
    }
}

/// Terminal, ordered cancellation for one exact negotiated suspension. The wire carries no
/// application-authored reason: each side reports its own bounded local diagnostic after the
/// exact suspension echo synchronizes the teardown. A fresh nonzero UUID makes duplicate replay
/// idempotent without relying on wall-clock or host/viewer-local sequence domains.
public struct WebRTCScreenMediaCancellation: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let cancellationID: UUID
    public let suspension: WebRTCScreenMediaSuspensionNotice

    public init(
        suspension: WebRTCScreenMediaSuspensionNotice,
        cancellationID: UUID = UUID(),
        protocolVersion: Int = Self.currentProtocolVersion
    ) {
        self.protocolVersion = protocolVersion
        self.cancellationID = cancellationID
        self.suspension = suspension
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case cancellationID
        case suspension
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = Self(
            suspension: try container.decode(
                WebRTCScreenMediaSuspensionNotice.self,
                forKey: .suspension
            ),
            cancellationID: try container.decode(
                UUID.self,
                forKey: .cancellationID
            ),
            protocolVersion: try container.decode(
                Int.self,
                forKey: .protocolVersion
            )
        )
        guard value.isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription: "Invalid screen-media cancellation."
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Invalid screen-media cancellation."
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(cancellationID, forKey: .cancellationID)
        try container.encode(suspension, forKey: .suspension)
    }

    public var isValid: Bool {
        protocolVersion == Self.currentProtocolVersion
            && cancellationID != ScreenMediaWireValidation.zeroUUID
            && suspension.isValid
    }

    public func isExactCancellation(
        of notice: WebRTCScreenMediaSuspensionNotice
    ) -> Bool {
        isValid && suspension == notice
    }
}

/// Host proof that the exact per-attempt marker reached the post-aligner encoder callback as a key
/// frame. `encoderMarkerRTPTimestamp` is encoder-domain Tm; the RTP sender may apply a stable
/// offset before the receiver observes it, so this value is never compared directly to a viewer
/// frame timestamp.
public struct WebRTCScreenMediaMarkerReady: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let attemptID: UUID
    public let screenRequestID: UInt64
    public let suspensionGeneration: UInt64
    public let encoderGeneration: UInt64
    public let encoderMarkerRTPTimestamp: UInt32
    public let boundaryRevision: UInt64
    public let geometry: WebRTCScreenMediaGeometry

    public init(
        attemptID: UUID,
        screenRequestID: UInt64,
        suspensionGeneration: UInt64,
        encoderGeneration: UInt64,
        encoderMarkerRTPTimestamp: UInt32,
        boundaryRevision: UInt64,
        geometry: WebRTCScreenMediaGeometry,
        protocolVersion: Int = Self.currentProtocolVersion
    ) {
        self.protocolVersion = protocolVersion
        self.attemptID = attemptID
        self.screenRequestID = screenRequestID
        self.suspensionGeneration = suspensionGeneration
        self.encoderGeneration = encoderGeneration
        self.encoderMarkerRTPTimestamp = encoderMarkerRTPTimestamp
        self.boundaryRevision = boundaryRevision
        self.geometry = geometry
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case attemptID
        case screenRequestID
        case suspensionGeneration
        case encoderGeneration
        case encoderMarkerRTPTimestamp
        case boundaryRevision
        case geometry
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = Self(
            attemptID: try container.decode(UUID.self, forKey: .attemptID),
            screenRequestID: try container.decode(UInt64.self, forKey: .screenRequestID),
            suspensionGeneration: try container.decode(UInt64.self, forKey: .suspensionGeneration),
            encoderGeneration: try container.decode(UInt64.self, forKey: .encoderGeneration),
            encoderMarkerRTPTimestamp: try container.decode(
                UInt32.self,
                forKey: .encoderMarkerRTPTimestamp
            ),
            boundaryRevision: try container.decode(UInt64.self, forKey: .boundaryRevision),
            geometry: try container.decode(WebRTCScreenMediaGeometry.self, forKey: .geometry),
            protocolVersion: try container.decode(Int.self, forKey: .protocolVersion)
        )
        guard value.isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription: "Invalid screen-media marker-ready proof."
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid screen-media marker-ready proof.")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(attemptID, forKey: .attemptID)
        try container.encode(screenRequestID, forKey: .screenRequestID)
        try container.encode(suspensionGeneration, forKey: .suspensionGeneration)
        try container.encode(encoderGeneration, forKey: .encoderGeneration)
        try container.encode(
            encoderMarkerRTPTimestamp,
            forKey: .encoderMarkerRTPTimestamp
        )
        try container.encode(boundaryRevision, forKey: .boundaryRevision)
        try container.encode(geometry, forKey: .geometry)
    }

    public var isValid: Bool {
        protocolVersion == Self.currentProtocolVersion
            && attemptID != ScreenMediaWireValidation.zeroUUID
            && screenRequestID > 0
            && suspensionGeneration > 0
            && encoderGeneration > 0
            && boundaryRevision > 0
            && geometry.isValid
    }

    public func belongs(to notice: WebRTCScreenMediaSuspensionNotice) -> Bool {
        isValid
            && notice.isValid
            && screenRequestID == notice.screenRequestID
            && suspensionGeneration == notice.suspensionGeneration
    }
}

/// Viewer proof that the exact in-band marker reached a Metal drawable on one bounded
/// receiver/source identity. `receiverMarkerRTPTimestamp` is receiver-domain Tm; the complete
/// encoder-domain marker-ready object is echoed byte-for-field for replay fencing.
public struct WebRTCScreenMediaMarkerPresentation: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let markerReady: WebRTCScreenMediaMarkerReady
    public let receiverMarkerRTPTimestamp: UInt32
    public let receiverID: String
    public let sourceID: UInt32
    public let presentedWidth: Int
    public let presentedHeight: Int

    public init(
        markerReady: WebRTCScreenMediaMarkerReady,
        receiverMarkerRTPTimestamp: UInt32,
        receiverID: String,
        sourceID: UInt32,
        presentedWidth: Int,
        presentedHeight: Int,
        protocolVersion: Int = Self.currentProtocolVersion
    ) {
        self.protocolVersion = protocolVersion
        self.markerReady = markerReady
        self.receiverMarkerRTPTimestamp = receiverMarkerRTPTimestamp
        self.receiverID = receiverID
        self.sourceID = sourceID
        self.presentedWidth = presentedWidth
        self.presentedHeight = presentedHeight
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case markerReady
        case receiverMarkerRTPTimestamp
        case receiverID
        case sourceID
        case presentedWidth
        case presentedHeight
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = Self(
            markerReady: try container.decode(WebRTCScreenMediaMarkerReady.self, forKey: .markerReady),
            receiverMarkerRTPTimestamp: try container.decode(
                UInt32.self,
                forKey: .receiverMarkerRTPTimestamp
            ),
            receiverID: try container.decode(String.self, forKey: .receiverID),
            sourceID: try container.decode(UInt32.self, forKey: .sourceID),
            presentedWidth: try container.decode(Int.self, forKey: .presentedWidth),
            presentedHeight: try container.decode(Int.self, forKey: .presentedHeight),
            protocolVersion: try container.decode(Int.self, forKey: .protocolVersion)
        )
        guard value.isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription: "Invalid screen-media marker presentation."
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid screen-media marker presentation.")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(markerReady, forKey: .markerReady)
        try container.encode(
            receiverMarkerRTPTimestamp,
            forKey: .receiverMarkerRTPTimestamp
        )
        try container.encode(receiverID, forKey: .receiverID)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(presentedWidth, forKey: .presentedWidth)
        try container.encode(presentedHeight, forKey: .presentedHeight)
    }

    public var isValid: Bool {
        protocolVersion == Self.currentProtocolVersion
            && markerReady.isValid
            && ScreenMediaWireValidation.validReceiverID(receiverID)
            && sourceID > 0
            && markerReady.geometry.isCompatiblePresentation(
                width: presentedWidth,
                height: presentedHeight
            )
    }

    public func isExactEcho(of ready: WebRTCScreenMediaMarkerReady) -> Bool {
        isValid && markerReady == ready
    }
}

/// Host boundary for real-video admission across the encoder and receiver RTP serial domains.
/// The exact encoder Tm/Rr pair supplies a strictly-newer unsigned delta. Applying that delta to
/// exact receiver Tm predicts the receiver-domain real-frame floor without comparing wall clocks
/// or assuming that the sender's random RTP offset is zero.
public struct WebRTCScreenMediaResumeReady: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let markerPresentation: WebRTCScreenMediaMarkerPresentation
    public let encoderMarkerRTPTimestamp: UInt32
    public let encoderRealFrameRTPTimestamp: UInt32
    public let receiverMarkerRTPTimestamp: UInt32
    public let receiverRealFrameFloorRTPTimestamp: UInt32
    public let geometry: WebRTCScreenMediaGeometry

    public init(
        markerPresentation: WebRTCScreenMediaMarkerPresentation,
        encoderMarkerRTPTimestamp: UInt32,
        encoderRealFrameRTPTimestamp: UInt32,
        receiverMarkerRTPTimestamp: UInt32,
        receiverRealFrameFloorRTPTimestamp: UInt32,
        geometry: WebRTCScreenMediaGeometry,
        protocolVersion: Int = Self.currentProtocolVersion
    ) {
        self.protocolVersion = protocolVersion
        self.markerPresentation = markerPresentation
        self.encoderMarkerRTPTimestamp = encoderMarkerRTPTimestamp
        self.encoderRealFrameRTPTimestamp = encoderRealFrameRTPTimestamp
        self.receiverMarkerRTPTimestamp = receiverMarkerRTPTimestamp
        self.receiverRealFrameFloorRTPTimestamp = receiverRealFrameFloorRTPTimestamp
        self.geometry = geometry
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case markerPresentation
        case encoderMarkerRTPTimestamp
        case encoderRealFrameRTPTimestamp
        case receiverMarkerRTPTimestamp
        case receiverRealFrameFloorRTPTimestamp
        case geometry
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = Self(
            markerPresentation: try container.decode(
                WebRTCScreenMediaMarkerPresentation.self,
                forKey: .markerPresentation
            ),
            encoderMarkerRTPTimestamp: try container.decode(
                UInt32.self,
                forKey: .encoderMarkerRTPTimestamp
            ),
            encoderRealFrameRTPTimestamp: try container.decode(
                UInt32.self,
                forKey: .encoderRealFrameRTPTimestamp
            ),
            receiverMarkerRTPTimestamp: try container.decode(
                UInt32.self,
                forKey: .receiverMarkerRTPTimestamp
            ),
            receiverRealFrameFloorRTPTimestamp: try container.decode(
                UInt32.self,
                forKey: .receiverRealFrameFloorRTPTimestamp
            ),
            geometry: try container.decode(WebRTCScreenMediaGeometry.self, forKey: .geometry),
            protocolVersion: try container.decode(Int.self, forKey: .protocolVersion)
        )
        guard value.isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription: "Invalid screen-media resume-ready proof."
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid screen-media resume-ready proof.")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(markerPresentation, forKey: .markerPresentation)
        try container.encode(
            encoderMarkerRTPTimestamp,
            forKey: .encoderMarkerRTPTimestamp
        )
        try container.encode(
            encoderRealFrameRTPTimestamp,
            forKey: .encoderRealFrameRTPTimestamp
        )
        try container.encode(
            receiverMarkerRTPTimestamp,
            forKey: .receiverMarkerRTPTimestamp
        )
        try container.encode(
            receiverRealFrameFloorRTPTimestamp,
            forKey: .receiverRealFrameFloorRTPTimestamp
        )
        try container.encode(geometry, forKey: .geometry)
    }

    public var isValid: Bool {
        guard protocolVersion == Self.currentProtocolVersion,
              markerPresentation.isValid,
              encoderMarkerRTPTimestamp
                == markerPresentation.markerReady.encoderMarkerRTPTimestamp,
              receiverMarkerRTPTimestamp
                == markerPresentation.receiverMarkerRTPTimestamp,
              geometry == markerPresentation.markerReady.geometry,
              let forwardDistance = WebRTCRTPSerialComparator
                .strictlyNewerForwardDistance(
                    from: encoderMarkerRTPTimestamp,
                    to: encoderRealFrameRTPTimestamp
                ) else {
            return false
        }
        return receiverRealFrameFloorRTPTimestamp
            == receiverMarkerRTPTimestamp &+ forwardDistance
    }

    public static func predictedReceiverRealFrameFloorRTPTimestamp(
        markerPresentation: WebRTCScreenMediaMarkerPresentation,
        encoderRealFrameRTPTimestamp: UInt32
    ) -> UInt32? {
        guard markerPresentation.isValid,
              let forwardDistance = WebRTCRTPSerialComparator
                .strictlyNewerForwardDistance(
                    from: markerPresentation.markerReady.encoderMarkerRTPTimestamp,
                    to: encoderRealFrameRTPTimestamp
                ) else {
            return nil
        }
        return markerPresentation.receiverMarkerRTPTimestamp &+ forwardDistance
    }

    public var attemptID: UUID { markerPresentation.markerReady.attemptID }
    public var screenRequestID: UInt64 { markerPresentation.markerReady.screenRequestID }
    public var suspensionGeneration: UInt64 {
        markerPresentation.markerReady.suspensionGeneration
    }
    public var encoderGeneration: UInt64 { markerPresentation.markerReady.encoderGeneration }
}

/// Exact viewer observation of a current-generation real frame. The receiver/source and decoded
/// size must remain identical to the marker presentation, while its RTP key may equal Rr or be a
/// later unambiguous serial value if the first real frame was lost before presentation.
public struct WebRTCScreenMediaPresentation: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let resumeReady: WebRTCScreenMediaResumeReady
    public let presentedRTPTimestamp: UInt32
    public let receiverID: String
    public let sourceID: UInt32
    public let presentedWidth: Int
    public let presentedHeight: Int

    public init(
        resumeReady: WebRTCScreenMediaResumeReady,
        presentedRTPTimestamp: UInt32,
        receiverID: String,
        sourceID: UInt32,
        presentedWidth: Int,
        presentedHeight: Int,
        protocolVersion: Int = Self.currentProtocolVersion
    ) {
        self.protocolVersion = protocolVersion
        self.resumeReady = resumeReady
        self.presentedRTPTimestamp = presentedRTPTimestamp
        self.receiverID = receiverID
        self.sourceID = sourceID
        self.presentedWidth = presentedWidth
        self.presentedHeight = presentedHeight
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case resumeReady
        case presentedRTPTimestamp
        case receiverID
        case sourceID
        case presentedWidth
        case presentedHeight
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = Self(
            resumeReady: try container.decode(WebRTCScreenMediaResumeReady.self, forKey: .resumeReady),
            presentedRTPTimestamp: try container.decode(UInt32.self, forKey: .presentedRTPTimestamp),
            receiverID: try container.decode(String.self, forKey: .receiverID),
            sourceID: try container.decode(UInt32.self, forKey: .sourceID),
            presentedWidth: try container.decode(Int.self, forKey: .presentedWidth),
            presentedHeight: try container.decode(Int.self, forKey: .presentedHeight),
            protocolVersion: try container.decode(Int.self, forKey: .protocolVersion)
        )
        guard value.isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription: "Invalid screen-media real-frame presentation."
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid screen-media real-frame presentation.")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(resumeReady, forKey: .resumeReady)
        try container.encode(presentedRTPTimestamp, forKey: .presentedRTPTimestamp)
        try container.encode(receiverID, forKey: .receiverID)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(presentedWidth, forKey: .presentedWidth)
        try container.encode(presentedHeight, forKey: .presentedHeight)
    }

    public var isValid: Bool {
        let marker = resumeReady.markerPresentation
        return protocolVersion == Self.currentProtocolVersion
            && resumeReady.isValid
            && WebRTCRTPSerialComparator.isSameOrNewer(
                presentedRTPTimestamp,
                than: resumeReady.receiverRealFrameFloorRTPTimestamp
            )
            && receiverID == marker.receiverID
            && sourceID == marker.sourceID
            && presentedWidth == marker.presentedWidth
            && presentedHeight == marker.presentedHeight
            && ScreenMediaWireValidation.validReceiverID(receiverID)
            && sourceID > 0
            && resumeReady.geometry.isCompatiblePresentation(
                width: presentedWidth,
                height: presentedHeight
            )
    }
}

/// Typed viewer request to finalize one proven resume. Its independent nonzero ID shares the
/// ordered control-ID domain, while the complete presentation remains an exact replay key.
public struct WebRTCScreenMediaResumeRequest: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let id: UInt64
    public let presentation: WebRTCScreenMediaPresentation

    public init(
        id: UInt64,
        presentation: WebRTCScreenMediaPresentation,
        protocolVersion: Int = Self.currentProtocolVersion
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.presentation = presentation
    }

    private enum CodingKeys: String, CodingKey { case protocolVersion, id, presentation }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = Self(
            id: try container.decode(UInt64.self, forKey: .id),
            presentation: try container.decode(
                WebRTCScreenMediaPresentation.self,
                forKey: .presentation
            ),
            protocolVersion: try container.decode(Int.self, forKey: .protocolVersion)
        )
        guard value.isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription: "Invalid screen-media resume request."
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid screen-media resume request.")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(id, forKey: .id)
        try container.encode(presentation, forKey: .presentation)
    }

    public var isValid: Bool {
        protocolVersion == Self.currentProtocolVersion && id > 0 && presentation.isValid
    }
}

/// Host acknowledgement for the exact resume request. A fresh input capability is optional and,
/// when present, must be valid for the same screen request proved by the echoed presentation.
public struct WebRTCScreenMediaResumedAcknowledgement: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let request: WebRTCScreenMediaResumeRequest
    public let inputCapability: WebRTCInputCapability?

    public init(
        request: WebRTCScreenMediaResumeRequest,
        inputCapability: WebRTCInputCapability? = nil,
        protocolVersion: Int = Self.currentProtocolVersion
    ) {
        self.protocolVersion = protocolVersion
        self.request = request
        self.inputCapability = inputCapability
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case request
        case inputCapability
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = Self(
            request: try container.decode(WebRTCScreenMediaResumeRequest.self, forKey: .request),
            inputCapability: try container.decodeIfPresent(
                WebRTCInputCapability.self,
                forKey: .inputCapability
            ),
            protocolVersion: try container.decode(Int.self, forKey: .protocolVersion)
        )
        guard value.isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription: "Invalid screen-media resumed acknowledgement."
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid screen-media resumed acknowledgement.")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(request, forKey: .request)
        try container.encodeIfPresent(inputCapability, forKey: .inputCapability)
    }

    public var isValid: Bool {
        protocolVersion == Self.currentProtocolVersion
            && request.isValid
            && (inputCapability == nil || (
                inputCapability?.isValid == true
                    && inputCapability?.screenRequestID
                        == request.presentation.resumeReady.screenRequestID
            ))
    }
}

private enum ScreenMediaWireValidation {
    static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    static func validDimension(_ value: Int) -> Bool {
        (2 ... 32_768).contains(value)
    }

    static func validReceiverID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 256
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    static func hasCompatibleAspectRatio(
        presentedWidth: Int,
        presentedHeight: Int,
        captureWidth: Int,
        captureHeight: Int
    ) -> Bool {
        let left = Int64(presentedWidth) * Int64(captureHeight)
        let right = Int64(presentedHeight) * Int64(captureWidth)
        let difference = abs(left - right)
        let pixelRoundingTolerance = Int64(captureWidth + captureHeight)
        return difference <= pixelRoundingTolerance
    }
}

/// Privacy-minimal viewer challenge that causally binds a later Mac process sample to one
/// prospective next-call epoch and then one exact CallKit epoch. It contains no process,
/// participant, handle, or contact identity.
public struct WebRTCMacHostedCallChallenge: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 3

    public let protocolVersion: Int
    public let sequence: UInt64
    public let nonce: UUID
    /// Stable privacy-random identity for one prospectively armed next-call epoch and, once the
    /// iPhone observes its first inactive-to-active CallKit membership edge, that exact call.
    /// Challenge nonces may rotate before admission; this epoch nonce must not cross a
    /// contamination, peer, transport, interruption, or replacement-call boundary.
    public let callEpochNonce: UUID

    public init(
        sequence: UInt64,
        callEpochNonce: UUID,
        nonce: UUID = UUID(),
        protocolVersion: Int = Self.currentProtocolVersion
    ) {
        self.protocolVersion = protocolVersion
        self.sequence = sequence
        self.nonce = nonce
        self.callEpochNonce = callEpochNonce
    }

    public var isValid: Bool {
        protocolVersion == Self.currentProtocolVersion
            && sequence > 0
            && nonce != Self.zeroUUID
            && callEpochNonce != Self.zeroUUID
            && nonce != callEpochNonce
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}

/// Privacy-minimal, transport-bound proof that the Mac freshly sampled one exact FaceTime duplex
/// process after receiving the echoed viewer challenge. Evidence sequence numbers are monotonic
/// for one peer lifetime.
public struct WebRTCMacHostedCallEvidence: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 3

    public enum State: String, Codable, Sendable {
        case active
        /// The host installed this exact prospective challenge from a known-empty native
        /// baseline. It is never microphone authorization by itself.
        case preflightArmed
        /// The exact binder is neither prospectively armed nor causally active. This includes a
        /// poisoned/revoked transition and can never acknowledge a preflight.
        case inactive
    }

    public let protocolVersion: Int
    public let sequence: UInt64
    public let challengeSequence: UInt64
    public let challengeNonce: UUID
    /// Echo of the challenged CallKit-call identity; it must match independently of the rotating
    /// challenge nonce and monotonic sequence.
    public let callEpochNonce: UUID
    public let state: State

    public init(
        sequence: UInt64,
        challengeSequence: UInt64,
        challengeNonce: UUID,
        callEpochNonce: UUID,
        state: State,
        protocolVersion: Int = Self.currentProtocolVersion
    ) {
        self.protocolVersion = protocolVersion
        self.sequence = sequence
        self.challengeSequence = challengeSequence
        self.challengeNonce = challengeNonce
        self.callEpochNonce = callEpochNonce
        self.state = state
    }

    public var isValid: Bool {
        protocolVersion == Self.currentProtocolVersion
            && sequence > 0
            && challengeSequence > 0
            && challengeNonce != Self.zeroUUID
            && callEpochNonce != Self.zeroUUID
            && challengeNonce != callEpochNonce
    }

    /// Exact three-dimensional challenge identity. None of these identities may be inferred from
    /// another: the sequence orders challenges, the nonce prevents replay, and the CallKit epoch
    /// prevents a replacement call with the same aggregate counts from inheriting evidence.
    func matches(_ challenge: WebRTCMacHostedCallChallenge) -> Bool {
        isValid
            && challenge.isValid
            && challengeSequence == challenge.sequence
            && challengeNonce == challenge.nonce
            && callEpochNonce == challenge.callEpochNonce
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}
