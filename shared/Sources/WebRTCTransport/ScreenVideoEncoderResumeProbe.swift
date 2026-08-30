@preconcurrency import LiveKitWebRTC
import CoreVideo
import Foundation

/// A per-attempt resume nonce. Production callers must provide the full 128 bits; a shortened or
/// padded identifier is never accepted as an in-band proof.
public struct ScreenVideoInBandMarkerNonce: Equatable, Hashable, Sendable {
    public static let byteCount = 16

    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    /// The one canonical wire/renderer nonce for a resume attempt. Reading the UUID tuple as its
    /// 16 RFC 4122 bytes avoids descriptions, locale, or integer endianness entering the proof.
    public init(attemptID: UUID) {
        var uuid = attemptID.uuid
        bytes = withUnsafeBytes(of: &uuid) { Array($0) }
    }

    func bit(at index: Int) -> Bool {
        let byte = bytes[index / 8]
        return ((byte >> UInt8(7 - index % 8)) & 1) == 1
    }
}

/// Builds the exact low-frequency BGRA nonce frame injected through `MacExternalVideoCapturer`.
/// The encoder may downscale it to the supported 40x80 floor without erasing any of its 160 cells.
public enum ScreenVideoInBandMarkerPixelBufferFactory {
    public enum FactoryError: Error, Equatable, Sendable {
        case dimensionsBelowFloor(width: Int, height: Int)
        case creationFailed(CVReturn)
        case lockFailed(CVReturn)
        case missingBaseAddress
    }

    public static func make(
        width: Int,
        height: Int,
        marker: ScreenVideoInBandMarkerNonce
    ) throws -> CVPixelBuffer {
        guard width >= 40, height >= 80 else {
            throw FactoryError.dimensionsBelowFloor(width: width, height: height)
        }
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let creationStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard creationStatus == kCVReturnSuccess, let pixelBuffer else {
            throw FactoryError.creationFailed(creationStatus)
        }
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw FactoryError.lockFailed(lockStatus)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw FactoryError.missingBaseAddress
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            let cellRow = min(9, y * 10 / height)
            let row = baseAddress.advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let cellColumn = min(15, x * 16 / width)
                let bit: Bool
                switch cellRow {
                case 0:
                    bit = ((UInt16(0xA55A) >> (15 - cellColumn)) & 1) == 1
                case 9:
                    bit = ((UInt16(0x3CC3) >> (15 - cellColumn)) & 1) == 1
                default:
                    bit = marker.bit(at: (cellRow - 1) * 16 + cellColumn)
                }
                // Each symbol is spatially low-frequency, but strong contrast is necessary after
                // the negotiated 12x scaler and a 32 kbps H.264 key frame quantize 2-3px cells.
                let value: UInt8 = bit ? 0xE0 : 0x20
                let offset = x * 4
                row[offset] = value
                row[offset + 1] = value
                row[offset + 2] = value
                row[offset + 3] = 0xFF
            }
        }
        return pixelBuffer
    }
}

/// Exact marker classification shared by the post-aligner encoder boundary and receiver proof.
/// The 128 nonce bits occupy an 8x16 luminance payload, with two additional fixed anchor rows for
/// orientation/polarity. At the supported 40x80 floor, every symbol still contributes at least
/// eight samples. A lossy or marker-like frame is uncertain, never inferred to be a real frame.
public enum ScreenVideoInBandMarkerClassification: Equatable, Sendable {
    case exactMarker(ScreenVideoInBandMarkerNonce)
    case definitelyNotMarker
    case uncertain
}

public enum ScreenVideoInBandMarkerClassifier {
    enum ExpectedClassification: Equatable {
        case exactMarker
        case definitelyNotMarker
        case uncertain
    }

    /// Decodes only a complete, correctly oriented marker. A caller may retain the returned nonce
    /// and frame metadata, but never needs to retain decoded pixels while waiting for MarkerReady.
    public static func classify(
        _ frame: LKRTCVideoFrame
    ) -> ScreenVideoInBandMarkerClassification {
        let buffer = frame.buffer.toI420()
        guard buffer.width >= 40, buffer.height >= 80 else { return .uncertain }
        var luminances = Array(repeating: Double(0), count: 160)
        var darkAnchors: [Double] = []
        var lightAnchors: [Double] = []
        for cellRow in 0..<10 {
            for cellColumn in 0..<16 {
                guard let luminance = sampledCellLuminance(
                    buffer: buffer,
                    row: cellRow,
                    column: cellColumn
                ) else {
                    return .uncertain
                }
                luminances[cellRow * 16 + cellColumn] = luminance
                if cellRow == 0 || cellRow == 9 {
                    if anchorBit(row: cellRow, column: cellColumn) {
                        lightAnchors.append(luminance)
                    } else {
                        darkAnchors.append(luminance)
                    }
                }
            }
        }
        guard !darkAnchors.isEmpty, !lightAnchors.isEmpty else {
            return .uncertain
        }
        let darkCenter = darkAnchors.reduce(0, +) / Double(darkAnchors.count)
        let lightCenter = lightAnchors.reduce(0, +) / Double(lightAnchors.count)
        let separation = lightCenter - darkCenter
        guard separation >= 8 else { return .definitelyNotMarker }
        let threshold = (darkCenter + lightCenter) / 2
        let confidenceMargin = max(2, separation * 0.04)
        var anchorMismatches = 0
        for cellRow in 0..<10 {
            for cellColumn in 0..<16 {
                let index = cellRow * 16 + cellColumn
                let observed = luminances[index] > threshold
                if cellRow == 0 || cellRow == 9 {
                    let expected = anchorBit(row: cellRow, column: cellColumn)
                    if observed != expected { anchorMismatches += 1 }
                }
            }
        }
        guard anchorMismatches <= 4 else { return .definitelyNotMarker }
        var bytes = Array(repeating: UInt8(0), count: ScreenVideoInBandMarkerNonce.byteCount)
        for bitIndex in 0..<128 {
            let luminance = luminances[16 + bitIndex]
            guard abs(luminance - threshold) >= confidenceMargin else {
                return .uncertain
            }
            if luminance > threshold {
                bytes[bitIndex / 8] |= UInt8(1 << (7 - bitIndex % 8))
            }
        }
        guard let nonce = ScreenVideoInBandMarkerNonce(bytes: bytes) else {
            return .uncertain
        }
        return .exactMarker(nonce)
    }

    static func classify(
        _ frame: LKRTCVideoFrame,
        expectedMarker: ScreenVideoInBandMarkerNonce
    ) -> ExpectedClassification {
        switch classify(frame) {
        case .exactMarker(let observed):
            return observed == expectedMarker
                ? .exactMarker
                : .definitelyNotMarker
        case .definitelyNotMarker:
            return .definitelyNotMarker
        case .uncertain:
            return .uncertain
        }
    }

    private static func anchorBit(row: Int, column: Int) -> Bool {
        let anchor: UInt16 = row == 0 ? 0xA55A : 0x3CC3
        return ((anchor >> (15 - column)) & 1) == 1
    }

    private static func sampledCellLuminance(
        buffer: any LKRTCI420BufferProtocol,
        row: Int,
        column: Int
    ) -> Double? {
        let width = Int(buffer.width)
        let height = Int(buffer.height)
        let xStart = column * width / 16
        let xEnd = (column + 1) * width / 16
        let yStart = row * height / 10
        let yEnd = (row + 1) * height / 10
        guard xEnd > xStart, yEnd > yStart else { return nil }
        let xSampleCount = min(3, xEnd - xStart)
        let ySampleCount = min(4, yEnd - yStart)
        var total = 0
        var sampleCount = 0
        for yIndex in 0..<ySampleCount {
            let y = yStart
                + ((2 * yIndex + 1) * (yEnd - yStart)) / (2 * ySampleCount)
            for xIndex in 0..<xSampleCount {
                let x = xStart
                    + ((2 * xIndex + 1) * (xEnd - xStart)) / (2 * xSampleCount)
                let value = buffer.dataY[y * Int(buffer.strideY) + x]
                sampleCount += 1
                total += Int(value)
            }
        }
        guard sampleCount > 0 else { return nil }
        return Double(total) / Double(sampleCount)
    }
}

public struct ScreenVideoEncoderMarkerProof: Equatable, Sendable {
    public let attemptID: UUID
    public let encoderGeneration: UInt64
    public let rtpTimestamp: UInt32
    public let boundaryRevision: UInt64
}

public struct ScreenVideoEncoderRealFrameProof: Equatable, Sendable {
    public let attemptID: UUID
    public let encoderGeneration: UInt64
    public let rtpTimestamp: UInt32
    /// Strict RFC 3550 forward delta from the encoded marker. Zero, half-range, and backward
    /// values never produce a proof, so the receiver can safely apply its constant sender offset.
    public let forwardDeltaFromMarker: UInt32
}

public enum ScreenVideoEncoderResumeProbeEvent: Equatable, Sendable {
    case markerEncoded(ScreenVideoEncoderMarkerProof)
    case realFrameEncoded(ScreenVideoEncoderRealFrameProof)
    case cancelled(attemptID: UUID, reason: String)
}

/// Every state mutation that can sever the one-track marker/real relationship must synchronously
/// retire the proof. Keeping the reasons typed makes it harder for a lifecycle owner to silently
/// omit a new mutation when the production integration is added.
public enum ScreenVideoEncoderResumeMutation: String, Sendable {
    case senderActivityChanged
    case encodingParametersChanged
    case captureSourceChanged
    case captureFormatChanged
    case trackChanged
    case receiverChanged
    case negotiationChanged
    case transportChanged
    case presentationCoverChanged
    case timedOut
}

#if DEBUG
struct ScreenVideoEncoderResumeProbeDebugSnapshot: Equatable, Sendable {
    let attemptID: UUID?
    let phase: String?
    let encoderGeneration: UInt64
    let willEncodeCount: Int
    let lastClassification: String?
    let pendingSubmissionTimestamp: UInt32?
    let admittedTimestampCount: Int
    let callbackTimestampCount: Int
    let realPendingReplacementCount: Int
    let abandonedCallbackTimestampCount: Int
}
#endif

/// A one-shot capability minted only after both admitted frames have encoded and the viewer has
/// presented two exact, strictly ordered receiver RTP timestamps. It stays revocable until the
/// probe atomically consumes it; callers cannot turn a stale event into resume authority.
public final class ScreenVideoEncoderResumeAuthorization: @unchecked Sendable {
    public let attemptID: UUID
    public let encoderGeneration: UInt64
    public let markerEncoderRTPTimestamp: UInt32
    public let realEncoderRTPTimestamp: UInt32
    public let encoderForwardDelta: UInt32
    public let markerReceiverRTPTimestamp: UInt32
    public let realReceiverRTPTimestamp: UInt32

    private enum State {
        case valid
        case consumed
        case revoked
    }

    private let lock = NSLock()
    private var state: State = .valid

    fileprivate init(
        attemptID: UUID,
        encoderGeneration: UInt64,
        markerEncoderRTPTimestamp: UInt32,
        realEncoderRTPTimestamp: UInt32,
        encoderForwardDelta: UInt32,
        markerReceiverRTPTimestamp: UInt32,
        realReceiverRTPTimestamp: UInt32
    ) {
        self.attemptID = attemptID
        self.encoderGeneration = encoderGeneration
        self.markerEncoderRTPTimestamp = markerEncoderRTPTimestamp
        self.realEncoderRTPTimestamp = realEncoderRTPTimestamp
        self.encoderForwardDelta = encoderForwardDelta
        self.markerReceiverRTPTimestamp = markerReceiverRTPTimestamp
        self.realReceiverRTPTimestamp = realReceiverRTPTimestamp
    }

    public var isValid: Bool {
        lock.withLock {
            if case .valid = state { return true }
            return false
        }
    }

    fileprivate func consumeIfValid() -> Bool {
        lock.withLock {
            guard case .valid = state else { return false }
            state = .consumed
            return true
        }
    }

    @discardableResult
    fileprivate func revoke() -> Bool {
        lock.withLock {
            guard case .valid = state else { return false }
            state = .revoked
            return true
        }
    }
}

/// Lock-serialized transcript between the post-aligner encoder boundary and its encoded callback.
/// It is intentionally transport-agnostic: peer/show/source/display generations remain mandatory
/// owners in the eventual lifecycle state machine, but no lifecycle code consumes this prototype.
final class ScreenVideoEncoderResumeProbe: @unchecked Sendable {
    enum InputDisposition {
        case passThrough
        case drop
        case encode(
            attemptID: UUID,
            submissionID: UInt64,
            timestamp: UInt32,
            generation: UInt64,
            forceKeyFrame: Bool
        )
    }

    private enum Phase {
        case marker
        case awaitingMarkerPresentation
        case awaitingReal(receiverMarkerRTPTimestamp: UInt32?)
        case awaitingRealPresentation
        case authorizationIssued(ScreenVideoEncoderResumeAuthorization)
    }

    private enum SubmittedKind: Equatable {
        case marker
        case real
        case postFloorReal
    }

    private struct Attempt {
        let id: UUID
        let marker: ScreenVideoInBandMarkerNonce
        var encoderGeneration: UInt64
        let markerInputGateIsClosed: Bool
        let boundaryRevision: UInt64
        var permitsNextActivationEncoderRestart: Bool
        var awaitsPermittedActivationEncoderRestart = false
        var phase: Phase
        var pendingSubmission: PendingSubmission?
        var admittedTimestamps: Set<UInt32> = []
        var callbackTimestamps: Set<UInt32> = []
        var lastCallbackTimestamp: UInt32?
        var markerProof: ScreenVideoEncoderMarkerProof?
        var realProof: ScreenVideoEncoderRealFrameProof?
        var receiverMarkerRTPTimestamp: UInt32?
        var realPendingReplacementCount = 0
        var abandonedCallbackTimestamps: Set<UInt32> = []
    }

    private struct PendingSubmission {
        let id: UInt64
        let kind: SubmittedKind
        let timestamp: UInt32
        var encodeWasAccepted: Bool?
        var callback: EncodedCallback?
    }

    private struct EncodedCallback {
        let timestamp: UInt32
        let frameType: LKRTCFrameType
    }

    private enum RTPOrder {
        case same
        case newer
        case older
        case ambiguous
    }

    private let lock = NSLock()
    private static let minimumRealReplacementRTPDelta: UInt32 = 90_000
    private static let maximumRealPendingReplacements = 11
    private var attempt: Attempt?
    private var encoderGeneration: UInt64 = 0
    private var activeEncoderIdentity: ObjectIdentifier?
    private var nextSubmissionID: UInt64 = 1
    private var events: [ScreenVideoEncoderResumeProbeEvent] = []
    private var eventHandler:
        (@Sendable (ScreenVideoEncoderResumeProbeEvent) -> Void)?
    private let eventDeliveryQueue = DispatchQueue(
        label: "opensteamer.screen-video-resume-probe.events"
    )
    #if DEBUG
    private var debugWillEncodeCount = 0
    private var debugLastClassification: String?
    #endif

    /// Installs the peer-lifetime production bridge exactly once. Events are enqueued in transcript
    /// order and the callback always executes on a private serial queue outside `lock`, so the
    /// callback may safely hop into `WebRTCPeer` without a probe reentrancy deadlock.
    @discardableResult
    func installEventHandler(
        _ handler: @escaping @Sendable (
            ScreenVideoEncoderResumeProbeEvent
        ) -> Void
    ) -> Bool {
        lock.withLock {
            guard eventHandler == nil else { return false }
            eventHandler = handler
            return true
        }
    }

    /// A factory may create several speculative codec instances. Only a successful start owns the
    /// active generation; mere construction must not steal or cancel the current encoder.
    func encoderDidStart(_ encoder: any LKRTCVideoEncoder) -> UInt64 {
        lock.withLock {
            let rebindsPermittedActivation = attempt.map { current in
                guard case .marker = current.phase else { return false }
                return current.permitsNextActivationEncoderRestart
                    && current.awaitsPermittedActivationEncoderRestart
                    && current.pendingSubmission == nil
                    && current.markerProof == nil
                    && current.admittedTimestamps.isEmpty
                    && current.callbackTimestamps.isEmpty
            } == true
            if attempt != nil, !rebindsPermittedActivation {
                cancelLocked(reason: "The video encoder started or restarted during resume proof.")
            }
            encoderGeneration &+= 1
            if encoderGeneration == 0 { encoderGeneration = 1 }
            activeEncoderIdentity = ObjectIdentifier(encoder as AnyObject)
            if rebindsPermittedActivation, var rebound = attempt {
                rebound.encoderGeneration = encoderGeneration
                rebound.permitsNextActivationEncoderRestart = false
                rebound.awaitsPermittedActivationEncoderRestart = false
                attempt = rebound
            }
            return encoderGeneration
        }
    }

    func encoderStartFailed(
        _ encoder: any LKRTCVideoEncoder,
        priorGeneration: UInt64?
    ) {
        lock.withLock {
            if attempt != nil {
                cancelLocked(reason: "The video encoder failed to start during resume proof.")
            }
            if activeEncoderIdentity == ObjectIdentifier(encoder as AnyObject),
               priorGeneration == encoderGeneration {
                activeEncoderIdentity = nil
            }
        }
    }

    func encoderLifecycleWasReset(
        _ encoder: any LKRTCVideoEncoder,
        generation: UInt64
    ) {
        lock.withLock {
            guard activeEncoderIdentity == ObjectIdentifier(encoder as AnyObject),
                  generation == encoderGeneration else { return }
            if var current = attempt,
               current.permitsNextActivationEncoderRestart,
               !current.awaitsPermittedActivationEncoderRestart,
               current.pendingSubmission == nil,
               current.markerProof == nil,
               current.admittedTimestamps.isEmpty,
               current.callbackTimestamps.isEmpty,
               case .marker = current.phase {
                current.awaitsPermittedActivationEncoderRestart = true
                attempt = current
            } else if attempt != nil {
                cancelLocked(reason: "The video encoder reset during resume proof.")
            }
            activeEncoderIdentity = nil
        }
    }

    func armMarker(
        attemptID: UUID,
        marker: ScreenVideoInBandMarkerNonce,
        boundaryRevision: UInt64,
        permitsNextActivationEncoderRestart: Bool = false,
        markerInputGateIsClosed: Bool
    ) -> Bool {
        lock.withLock {
            guard activeEncoderIdentity != nil,
                  boundaryRevision > 0,
                  markerInputGateIsClosed,
                  attempt == nil else {
                return false
            }
            attempt = Attempt(
                id: attemptID,
                marker: marker,
                encoderGeneration: encoderGeneration,
                markerInputGateIsClosed: markerInputGateIsClosed,
                boundaryRevision: boundaryRevision,
                permitsNextActivationEncoderRestart:
                    permitsNextActivationEncoderRestart,
                phase: .marker
            )
            #if DEBUG
            debugWillEncodeCount = 0
            debugLastClassification = nil
            #endif
            return true
        }
    }

    /// Atomically accepts only the latest fully encoded marker, with no submitted marker callback
    /// outstanding. `markerRTPTimestamp` is the sender-side encoder RTP timestamp; it is not
    /// compared to the receiver's randomly-offset wire RTP timestamp.
    func beginRealFrameAdmission(
        attemptID: UUID,
        markerRTPTimestamp: UInt32,
        boundaryRevision: UInt64
    ) -> Bool {
        beginRealFrameAdmission(
            attemptID: attemptID,
            markerRTPTimestamp: markerRTPTimestamp,
            boundaryRevision: boundaryRevision,
            receiverMarkerRTPTimestamp: nil
        )
    }

    /// Production form of real admission. The viewer contributes the exact timestamp of the only
    /// rendered frame admitted during marker phase. RTP's sender offset means it is deliberately
    /// retained as a separate serial domain from the encoder callback timestamp.
    func beginRealFrameAdmission(
        attemptID: UUID,
        markerRTPTimestamp: UInt32,
        boundaryRevision: UInt64,
        receiverMarkerRTPTimestamp: UInt32
    ) -> Bool {
        beginRealFrameAdmission(
            attemptID: attemptID,
            markerRTPTimestamp: markerRTPTimestamp,
            boundaryRevision: boundaryRevision,
            receiverMarkerRTPTimestamp: Optional(receiverMarkerRTPTimestamp)
        )
    }

    private func beginRealFrameAdmission(
        attemptID: UUID,
        markerRTPTimestamp: UInt32,
        boundaryRevision: UInt64,
        receiverMarkerRTPTimestamp: UInt32?
    ) -> Bool {
        lock.withLock {
            guard var attempt,
                  attempt.id == attemptID,
                  attempt.encoderGeneration == encoderGeneration,
                  case .awaitingMarkerPresentation = attempt.phase,
                  attempt.pendingSubmission == nil,
                  attempt.markerProof?.rtpTimestamp == markerRTPTimestamp,
                  attempt.boundaryRevision == boundaryRevision else {
                return false
            }
            attempt.phase = .awaitingReal(
                receiverMarkerRTPTimestamp: receiverMarkerRTPTimestamp
            )
            attempt.receiverMarkerRTPTimestamp = receiverMarkerRTPTimestamp
            self.attempt = attempt
            return true
        }
    }

    /// Converts the exact first post-marker receiver timestamp into a revocable, one-shot resume
    /// capability. The two receiver values are checked only in their own RFC 3550 serial domain.
    func issueResumeAuthorization(
        attemptID: UUID,
        encoderGeneration: UInt64,
        realEncoderRTPTimestamp: UInt32,
        receiverRealRTPTimestamp: UInt32
    ) -> ScreenVideoEncoderResumeAuthorization? {
        lock.withLock {
            guard var attempt,
                  attempt.id == attemptID,
                  attempt.encoderGeneration == encoderGeneration,
                  case .awaitingRealPresentation = attempt.phase,
                  let markerProof = attempt.markerProof,
                  let realProof = attempt.realProof,
                  realProof.rtpTimestamp == realEncoderRTPTimestamp,
                  let receiverMarkerRTPTimestamp =
                    attempt.receiverMarkerRTPTimestamp else {
                return nil
            }
            guard let receiverForwardDelta = Self.safeForwardDelta(
                receiverRealRTPTimestamp,
                from: receiverMarkerRTPTimestamp
            ), receiverForwardDelta >= realProof.forwardDeltaFromMarker else {
                cancelLocked(
                    reason: "The receiver RTP presentation was older than the translated real-frame floor."
                )
                return nil
            }
            let authorization = ScreenVideoEncoderResumeAuthorization(
                attemptID: attempt.id,
                encoderGeneration: attempt.encoderGeneration,
                markerEncoderRTPTimestamp: markerProof.rtpTimestamp,
                realEncoderRTPTimestamp: realProof.rtpTimestamp,
                encoderForwardDelta: realProof.forwardDeltaFromMarker,
                markerReceiverRTPTimestamp: receiverMarkerRTPTimestamp,
                realReceiverRTPTimestamp: receiverRealRTPTimestamp
            )
            attempt.phase = .authorizationIssued(authorization)
            self.attempt = attempt
            return authorization
        }
    }

    /// Consumes the exact currently-issued capability and releases ordinary frames in one critical
    /// section. A mutation can revoke the token until this method wins the race.
    func consumeResumeAuthorization(
        _ authorization: ScreenVideoEncoderResumeAuthorization
    ) -> Bool {
        lock.withLock {
            guard let attempt,
                  case .authorizationIssued(let current) = attempt.phase,
                  current === authorization,
                  current.consumeIfValid() else {
                return false
            }
            self.attempt = nil
            return true
        }
    }

    func cancelForMutation(_ mutation: ScreenVideoEncoderResumeMutation) {
        lock.withLock {
            guard attempt != nil else { return }
            cancelLocked(reason: "Resume proof invalidated: \(mutation.rawValue).")
        }
    }

    func cancelAttempt(attemptID: UUID, reason: String) {
        lock.withLock {
            guard attempt?.id == attemptID else { return }
            cancelLocked(reason: reason)
        }
    }

    func willEncode(
        _ frame: LKRTCVideoFrame,
        encoder: any LKRTCVideoEncoder,
        generation: UInt64
    ) -> InputDisposition {
        lock.withLock {
            guard var attempt else { return .passThrough }
            guard generation == encoderGeneration,
                  activeEncoderIdentity == ObjectIdentifier(encoder as AnyObject) else {
                cancelLocked(reason: "A retired video encoder submitted a resume frame.")
                return .drop
            }
            guard attempt.encoderGeneration == generation else {
                cancelLocked(reason: "The resume encoder generation changed.")
                return .drop
            }
            let timestamp = UInt32(bitPattern: frame.timeStamp)
            let classification = ScreenVideoInBandMarkerClassifier.classify(
                frame,
                expectedMarker: attempt.marker
            )
            #if DEBUG
            debugWillEncodeCount += 1
            switch classification {
            case .exactMarker: debugLastClassification = "exactMarker"
            case .definitelyNotMarker:
                debugLastClassification = "definitelyNotMarker"
            case .uncertain: debugLastClassification = "uncertain"
            }
            #endif

            if let pending = attempt.pendingSubmission {
                switch pending.kind {
                case .marker:
                    // A marker retry inside the same nonce/attempt cannot distinguish a late
                    // callback from the replacement. It must remain single-submission.
                    if classification == .uncertain {
                        cancelLocked(
                            reason: "An ambiguous frame raced an admitted resume marker."
                        )
                    }
                    return .drop

                case .real, .postFloorReal:
                    switch classification {
                    case .exactMarker:
                        return .drop
                    case .uncertain:
                        cancelLocked(
                            reason: "An ambiguous frame raced an admitted resume real frame."
                        )
                        return .drop
                    case .definitelyNotMarker:
                        guard pending.encodeWasAccepted == true,
                              pending.callback == nil,
                              let replacementDelta = Self.safeForwardDelta(
                                timestamp,
                                from: pending.timestamp
                              ),
                              replacementDelta
                                >= Self.minimumRealReplacementRTPDelta else {
                            return .drop
                        }
                        guard attempt.realPendingReplacementCount
                                < Self.maximumRealPendingReplacements else {
                            cancelLocked(
                                reason: "The bounded resume real-frame replacement budget was exhausted."
                            )
                            return .drop
                        }
                        attempt.realPendingReplacementCount += 1
                        attempt.abandonedCallbackTimestamps.insert(
                            pending.timestamp
                        )
                        attempt.pendingSubmission = nil
                        return admitLocked(
                            attempt: &attempt,
                            kind: pending.kind,
                            timestamp: timestamp,
                            forceKeyFrame: pending.kind == .real
                        )
                    }
                }
            }

            switch attempt.phase {
            case .marker:
                switch classification {
                case .exactMarker:
                    return admitLocked(
                        attempt: &attempt,
                        kind: .marker,
                        timestamp: timestamp,
                        forceKeyFrame: true
                    )
                case .definitelyNotMarker:
                    guard attempt.markerInputGateIsClosed else {
                        cancelLocked(reason: "A non-marker reached an open marker input gate.")
                        return .drop
                    }
                    // The capture gate is independently closed. Suppress any already-queued real
                    // input locally instead of allowing it to race the marker boundary.
                    return .drop
                case .uncertain:
                    cancelLocked(reason: "The uncompressed marker was ambiguous.")
                    return .drop
                }

            case .awaitingMarkerPresentation:
                // Keep the RTP sender active so the already-encoded marker can leave the pacer,
                // but submit no further video until the viewer proves exact presentation of Tm.
                if classification == .uncertain {
                    cancelLocked(reason: "Marker-ACK input was ambiguous.")
                }
                return .drop

            case .awaitingReal:
                switch classification {
                case .exactMarker:
                    // Zero-Hz repeats of the retired marker are suppressed before the codec.
                    return .drop
                case .uncertain:
                    cancelLocked(reason: "Ambiguous marker-like input reached real admission.")
                    return .drop
                case .definitelyNotMarker:
                    guard let markerTimestamp = attempt.markerProof?.rtpTimestamp,
                          Self.safeForwardDelta(
                            timestamp,
                            from: markerTimestamp
                          ) != nil,
                          !attempt.admittedTimestamps.contains(timestamp) else {
                        cancelLocked(reason: "The first real RTP key was stale or ambiguous.")
                        return .drop
                    }
                    return admitLocked(
                        attempt: &attempt,
                        kind: .real,
                        timestamp: timestamp,
                        forceKeyFrame: true
                    )
                }

            case .awaitingRealPresentation:
                switch classification {
                case .exactMarker:
                    return .drop
                case .uncertain:
                    cancelLocked(reason: "Marker-like input followed the admitted real frame.")
                    return .drop
                case .definitelyNotMarker:
                    guard let markerTimestamp = attempt.markerProof?.rtpTimestamp,
                          Self.safeForwardDelta(
                            timestamp,
                            from: markerTimestamp
                          ) != nil,
                          !attempt.admittedTimestamps.contains(timestamp) else {
                        cancelLocked(reason: "A post-floor real RTP key was stale or ambiguous.")
                        return .drop
                    }
                    // Once Rr has encoded, later real frames may continue so a lossy link can
                    // present a frame at or after the translated floor. Marker frames never pass.
                    return admitLocked(
                        attempt: &attempt,
                        kind: .postFloorReal,
                        timestamp: timestamp,
                        forceKeyFrame: false
                    )
                }

            case .authorizationIssued:
                if classification == .uncertain {
                    cancelLocked(reason: "Marker-like input followed issued resume authority.")
                }
                // Freeze the boundary between proof issuance and one-shot consumption.
                return .drop
            }
        }
    }

    func didReturnFromEncode(
        submissionID: UInt64,
        result: Int,
        encoder: any LKRTCVideoEncoder,
        generation: UInt64
    ) {
        lock.withLock {
            guard var attempt,
                  generation == encoderGeneration,
                  activeEncoderIdentity == ObjectIdentifier(encoder as AnyObject),
                  var pending = attempt.pendingSubmission,
                  pending.id == submissionID else {
                return
            }
            guard result == 0 else {
                cancelLocked(reason: "The downstream video encoder rejected a resume frame.")
                return
            }
            pending.encodeWasAccepted = true
            attempt.pendingSubmission = pending
            self.attempt = attempt
            finalizePendingCallbackIfReadyLocked()
        }
    }

    fileprivate func didEncode(
        _ image: LKRTCEncodedImage,
        encoder: any LKRTCVideoEncoder,
        ownership: ScreenVideoEncoderCallbackOwnership?
    ) {
        lock.withLock {
            guard var attempt else { return }
            guard let ownership else {
                cancelLocked(reason: "An untracked encoder produced a resume callback.")
                return
            }
            // The wrapper retains accepted submissions across cancellation and encoder release.
            // A late callback owned by attempt A is therefore harmless while retry B is active.
            guard ownership.attemptID == attempt.id else { return }
            guard ownership.encoderGeneration == encoderGeneration,
                  activeEncoderIdentity == ObjectIdentifier(encoder as AnyObject) else {
                cancelLocked(reason: "An untracked or retired encoder produced a resume callback.")
                return
            }
            let timestamp = image.timeStamp
            if attempt.abandonedCallbackTimestamps.contains(timestamp) {
                // This exact encoder generation accepted the key before a bounded >=1s
                // replacement won. Its late callback is neither proof nor a protocol error.
                return
            }
            guard !attempt.callbackTimestamps.contains(timestamp) else {
                cancelLocked(reason: "A duplicate encoded RTP callback crossed resume proof.")
                return
            }
            if let previous = attempt.lastCallbackTimestamp {
                guard Self.order(timestamp, relativeTo: previous) == .newer else {
                    cancelLocked(reason: "Encoded callbacks reordered or crossed RTP half-range.")
                    return
                }
            }
            guard var pending = attempt.pendingSubmission,
                  pending.id == ownership.submissionID,
                  pending.timestamp == timestamp,
                  pending.callback == nil else {
                cancelLocked(reason: "An untracked encoded callback crossed the marker boundary.")
                return
            }
            attempt.callbackTimestamps.insert(timestamp)
            attempt.lastCallbackTimestamp = timestamp
            pending.callback = EncodedCallback(
                timestamp: timestamp,
                frameType: image.frameType
            )
            attempt.pendingSubmission = pending
            self.attempt = attempt
            // A synchronous callback is recorded but cannot mint proof until encode() itself has
            // returned success. This closes the downstream-rejection race.
            finalizePendingCallbackIfReadyLocked()
        }
    }

    func drainEventsForTesting() -> [ScreenVideoEncoderResumeProbeEvent] {
        lock.withLock {
            defer { events.removeAll(keepingCapacity: true) }
            return events
        }
    }

    #if DEBUG
    func debugSnapshot() -> ScreenVideoEncoderResumeProbeDebugSnapshot {
        lock.withLock {
            let phase: String?
            if let attempt {
                switch attempt.phase {
                case .marker: phase = "marker"
                case .awaitingMarkerPresentation:
                    phase = "awaitingMarkerPresentation"
                case .awaitingReal: phase = "awaitingReal"
                case .awaitingRealPresentation:
                    phase = "awaitingRealPresentation"
                case .authorizationIssued: phase = "authorizationIssued"
                }
            } else {
                phase = nil
            }
            return ScreenVideoEncoderResumeProbeDebugSnapshot(
                attemptID: attempt?.id,
                phase: phase,
                encoderGeneration: encoderGeneration,
                willEncodeCount: debugWillEncodeCount,
                lastClassification: debugLastClassification,
                pendingSubmissionTimestamp: attempt?.pendingSubmission?.timestamp,
                admittedTimestampCount: attempt?.admittedTimestamps.count ?? 0,
                callbackTimestampCount: attempt?.callbackTimestamps.count ?? 0,
                realPendingReplacementCount:
                    attempt?.realPendingReplacementCount ?? 0,
                abandonedCallbackTimestampCount:
                    attempt?.abandonedCallbackTimestamps.count ?? 0
            )
        }
    }
    #endif

    private func cancelLocked(reason: String) {
        if let attempt {
            if case .authorizationIssued(let authorization) = attempt.phase {
                authorization.revoke()
            }
            recordEventLocked(.cancelled(attemptID: attempt.id, reason: reason))
        }
        attempt = nil
    }

    private func admitLocked(
        attempt: inout Attempt,
        kind: SubmittedKind,
        timestamp: UInt32,
        forceKeyFrame: Bool
    ) -> InputDisposition {
        guard !attempt.admittedTimestamps.contains(timestamp) else {
            cancelLocked(reason: "A duplicate RTP key was admitted during resume proof.")
            return .drop
        }
        let submissionID = nextSubmissionID
        nextSubmissionID &+= 1
        if nextSubmissionID == 0 { nextSubmissionID = 1 }
        attempt.admittedTimestamps.insert(timestamp)
        attempt.pendingSubmission = PendingSubmission(
            id: submissionID,
            kind: kind,
            timestamp: timestamp,
            encodeWasAccepted: nil,
            callback: nil
        )
        self.attempt = attempt
        return .encode(
            attemptID: attempt.id,
            submissionID: submissionID,
            timestamp: timestamp,
            generation: attempt.encoderGeneration,
            forceKeyFrame: forceKeyFrame
        )
    }

    private func finalizePendingCallbackIfReadyLocked() {
        guard var attempt,
              let pending = attempt.pendingSubmission,
              pending.encodeWasAccepted == true,
              let callback = pending.callback else {
            return
        }
        attempt.pendingSubmission = nil
        switch pending.kind {
        case .marker:
            guard case .marker = attempt.phase,
                  callback.frameType == .videoFrameKey else {
                cancelLocked(reason: "The marker callback was not the exact forced key frame.")
                return
            }
            let proof = ScreenVideoEncoderMarkerProof(
                attemptID: attempt.id,
                encoderGeneration: attempt.encoderGeneration,
                rtpTimestamp: callback.timestamp,
                boundaryRevision: attempt.boundaryRevision
            )
            attempt.markerProof = proof
            attempt.phase = .awaitingMarkerPresentation
            self.attempt = attempt
            recordEventLocked(.markerEncoded(proof))

        case .real:
            guard case .awaitingReal = attempt.phase,
                  let markerProof = attempt.markerProof,
                  let forwardDelta = Self.safeForwardDelta(
                    callback.timestamp,
                    from: markerProof.rtpTimestamp
                  ) else {
                cancelLocked(reason: "The real callback was stale or RTP-half-range ambiguous.")
                return
            }
            let proof = ScreenVideoEncoderRealFrameProof(
                attemptID: attempt.id,
                encoderGeneration: attempt.encoderGeneration,
                rtpTimestamp: callback.timestamp,
                forwardDeltaFromMarker: forwardDelta
            )
            attempt.realProof = proof
            attempt.phase = .awaitingRealPresentation
            self.attempt = attempt
            recordEventLocked(.realFrameEncoded(proof))

        case .postFloorReal:
            let phaseAllowsLaterReal: Bool
            switch attempt.phase {
            case .awaitingRealPresentation, .authorizationIssued:
                phaseAllowsLaterReal = true
            case .marker, .awaitingMarkerPresentation, .awaitingReal:
                phaseAllowsLaterReal = false
            }
            guard phaseAllowsLaterReal,
                  let realProof = attempt.realProof,
                  let markerProof = attempt.markerProof,
                  let forwardDelta = Self.safeForwardDelta(
                    callback.timestamp,
                    from: markerProof.rtpTimestamp
                  ), forwardDelta >= realProof.forwardDeltaFromMarker else {
                cancelLocked(reason: "A later real callback fell behind the encoded Rr floor.")
                return
            }
            self.attempt = attempt
        }
    }

    private func recordEventLocked(_ event: ScreenVideoEncoderResumeProbeEvent) {
        events.append(event)
        guard let eventHandler else { return }
        eventDeliveryQueue.async {
            eventHandler(event)
        }
    }

    private static func order(
        _ candidate: UInt32,
        relativeTo reference: UInt32
    ) -> RTPOrder {
        let delta = candidate &- reference
        if delta == 0 { return .same }
        if delta == 0x8000_0000 { return .ambiguous }
        return delta < 0x8000_0000 ? .newer : .older
    }

    private static func safeForwardDelta(
        _ candidate: UInt32,
        from reference: UInt32
    ) -> UInt32? {
        let delta = candidate &- reference
        guard delta != 0,
              delta != 0x8000_0000,
              delta < 0x8000_0000 else {
            return nil
        }
        return delta
    }

}

fileprivate struct ScreenVideoEncoderCallbackOwnership: Hashable {
    let attemptID: UUID
    let encoderGeneration: UInt64
    let submissionID: UInt64
}

/// Transparent encoder wrapper. Every required property/method is forwarded, the application
/// callback is preserved verbatim, and only an exact marker or the first exact real boundary
/// changes `frameTypes` to key.
final class ScreenVideoObservingEncoder: NSObject, LKRTCVideoEncoder {
    private let downstream: any LKRTCVideoEncoder
    private let probe: ScreenVideoEncoderResumeProbe
    private let stateLock = NSLock()
    private let callbackMutationLock = NSLock()
    private var generation: UInt64?
    private var callbackRegistrationID: UInt64 = 0
    private var callback:
        ((LKRTCEncodedImage, any LKRTCCodecSpecificInfo) -> Bool)?
    /// Only fence frames are registered. Entries survive attempt cancellation and encoder release,
    /// acting as bounded tombstones until the exact accepted callback arrives. Capacity failure or
    /// timestamp reuse rejects the new submission before it can reach the downstream encoder.
    private static let maximumCallbackOwnershipCount = 64
    private var callbackOwnerships: [UInt32: ScreenVideoEncoderCallbackOwnership] = [:]

    init(
        downstream: any LKRTCVideoEncoder,
        probe: ScreenVideoEncoderResumeProbe
    ) {
        self.downstream = downstream
        self.probe = probe
        super.init()
    }

    func setCallback(
        _ callback: ((LKRTCEncodedImage, any LKRTCCodecSpecificInfo) -> Bool)?
    ) {
        callbackMutationLock.lock()
        defer { callbackMutationLock.unlock() }
        let registrationID = stateLock.withLock { () -> UInt64 in
            callbackRegistrationID &+= 1
            if callbackRegistrationID == 0 { callbackRegistrationID = 1 }
            self.callback = callback
            return callbackRegistrationID
        }
        guard callback != nil else {
            // Preserve nil exactly. Installing an observing closure here would change the native
            // encoder's callback state and could keep a released pipeline alive.
            downstream.setCallback(nil)
            return
        }
        downstream.setCallback { [weak self] image, info in
            guard let self else { return false }
            let callbackOwnership = self.takeCallbackOwnership(
                for: image.timeStamp
            )
            self.probe.didEncode(
                image,
                encoder: self.downstream,
                ownership: callbackOwnership
            )
            let currentCallback = self.stateLock.withLock {
                self.callbackRegistrationID == registrationID
                    ? self.callback
                    : nil
            }
            return currentCallback?(image, info) ?? false
        }
    }

    func startEncode(
        with settings: LKRTCVideoEncoderSettings,
        numberOfCores: Int32
    ) -> Int {
        let result = downstream.startEncode(
            with: settings,
            numberOfCores: numberOfCores
        )
        if result == 0 {
            let nextGeneration = probe.encoderDidStart(downstream)
            stateLock.withLock {
                generation = nextGeneration
            }
        } else {
            let priorGeneration = stateLock.withLock { () -> UInt64? in
                defer { generation = nil }
                return generation
            }
            probe.encoderStartFailed(
                downstream,
                priorGeneration: priorGeneration
            )
        }
        return result
    }

    func release() -> Int {
        let retiredGeneration = stateLock.withLock { () -> UInt64? in
            defer { generation = nil }
            return generation
        }
        if let retiredGeneration {
            probe.encoderLifecycleWasReset(
                downstream,
                generation: retiredGeneration
            )
        }
        return downstream.release()
    }

    func encode(
        _ frame: LKRTCVideoFrame,
        codecSpecificInfo info: (any LKRTCCodecSpecificInfo)?,
        frameTypes: [NSNumber]
    ) -> Int {
        guard let generation = stateLock.withLock({ generation }) else {
            // A failed or not-yet-started wrapper must never create proof. Preserve native
            // behavior outside an active attempt by forwarding the frame unobserved.
            return downstream.encode(
                frame,
                codecSpecificInfo: info,
                frameTypes: frameTypes
            )
        }
        let disposition = probe.willEncode(
            frame,
            encoder: downstream,
            generation: generation
        )
        switch disposition {
        case .drop:
            // `1` is WEBRTC_VIDEO_CODEC_NO_OUTPUT. Returning OK (`0`) without invoking the
            // callback leaves VideoStreamEncoder waiting on an output that this fence deliberately
            // suppressed, and it can stop offering the later real boundary indefinitely.
            return 1
        case .passThrough:
            return downstream.encode(
                frame,
                codecSpecificInfo: info,
                frameTypes: frameTypes
            )
        case .encode(
            let attemptID,
            let submissionID,
            let timestamp,
            let submissionGeneration,
            let forceKeyFrame
        ):
            let ownership = ScreenVideoEncoderCallbackOwnership(
                attemptID: attemptID,
                encoderGeneration: submissionGeneration,
                submissionID: submissionID
            )
            guard registerCallbackOwnership(ownership, for: timestamp) else {
                probe.didReturnFromEncode(
                    submissionID: submissionID,
                    result: 1,
                    encoder: downstream,
                    generation: submissionGeneration
                )
                return 1
            }
            let forwardedFrameTypes = forceKeyFrame
                ? [NSNumber(value: LKRTCFrameType.videoFrameKey.rawValue)]
                : frameTypes
            let result = downstream.encode(
                frame,
                codecSpecificInfo: info,
                frameTypes: forwardedFrameTypes
            )
            if result != 0 {
                removeCallbackOwnership(
                    ownership,
                    for: timestamp
                )
            }
            probe.didReturnFromEncode(
                submissionID: submissionID,
                result: result,
                encoder: downstream,
                generation: submissionGeneration
            )
            return result
        }
    }

    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        downstream.setBitrate(bitrateKbit, framerate: framerate)
    }

    func implementationName() -> String { downstream.implementationName() }
    func scalingSettings() -> LKRTCVideoEncoderQpThresholds? {
        downstream.scalingSettings()
    }
    var resolutionAlignment: Int { downstream.resolutionAlignment }
    var applyAlignmentToAllSimulcastLayers: Bool {
        downstream.applyAlignmentToAllSimulcastLayers
    }
    var supportsNativeHandle: Bool { downstream.supportsNativeHandle }

    private func registerCallbackOwnership(
        _ ownership: ScreenVideoEncoderCallbackOwnership,
        for timestamp: UInt32
    ) -> Bool {
        stateLock.withLock {
            guard callbackOwnerships.count
                    < Self.maximumCallbackOwnershipCount,
                  callbackOwnerships[timestamp] == nil else {
                return false
            }
            callbackOwnerships[timestamp] = ownership
            return true
        }
    }

    private func removeCallbackOwnership(
        _ ownership: ScreenVideoEncoderCallbackOwnership,
        for timestamp: UInt32
    ) {
        stateLock.withLock {
            guard callbackOwnerships[timestamp] == ownership else {
                return
            }
            callbackOwnerships.removeValue(forKey: timestamp)
        }
    }

    private func takeCallbackOwnership(
        for timestamp: UInt32
    ) -> ScreenVideoEncoderCallbackOwnership? {
        stateLock.withLock {
            callbackOwnerships.removeValue(forKey: timestamp)
        }
    }

    #if DEBUG
    var callbackOwnershipCountForTesting: Int {
        stateLock.withLock { callbackOwnerships.count }
    }
    #endif
}

/// Transparent factory wrapper. Optional APIs are forwarded and `responds(to:)` mirrors the
/// downstream factory, so wrapping does not invent or remove codec-switch behavior.
final class ScreenVideoObservingEncoderFactory:
    NSObject,
    LKRTCVideoEncoderFactory
{
    private let downstream: any LKRTCVideoEncoderFactory
    private let probe: ScreenVideoEncoderResumeProbe

    init(
        downstream: any LKRTCVideoEncoderFactory,
        probe: ScreenVideoEncoderResumeProbe
    ) {
        self.downstream = downstream
        self.probe = probe
        super.init()
    }

    func createEncoder(
        _ info: LKRTCVideoCodecInfo
    ) -> (any LKRTCVideoEncoder)? {
        downstream.createEncoder(info).map {
            ScreenVideoObservingEncoder(downstream: $0, probe: probe)
        }
    }

    func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        downstream.supportedCodecs()
    }

    func implementations() -> [LKRTCVideoCodecInfo] {
        downstream.implementations?() ?? downstream.supportedCodecs()
    }

    func encoderSelector() -> (any LKRTCVideoEncoderSelector)? {
        downstream.encoderSelector?()
    }

    func queryCodecSupport(
        _ info: LKRTCVideoCodecInfo,
        scalabilityMode: String?
    ) -> LKRTCVideoEncoderCodecSupport {
        downstream.queryCodecSupport?(
            info,
            scalabilityMode: scalabilityMode
        ) ?? LKRTCVideoEncoderCodecSupport(supported: false)
    }

    override func responds(to selector: Selector!) -> Bool {
        switch NSStringFromSelector(selector) {
        case "implementations", "encoderSelector", "queryCodecSupport:scalabilityMode:":
            return (downstream as AnyObject).responds(to: selector)
        default:
            return super.responds(to: selector)
        }
    }
}
