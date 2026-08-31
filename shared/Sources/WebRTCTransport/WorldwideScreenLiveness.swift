import Foundation

/// Closed, privacy-safe reasons why the iPhone renderer is intentionally covered.
public enum WorldwideScreenLivenessCoverState: String, Codable, Equatable, Sendable {
    case none
    case intentionalBandwidthPause
    case privacy
    case resuming
    case screenHidden

    public var statusText: String {
        switch self {
        case .none:
            "Not covered"
        case .intentionalBandwidthPause:
            "Screen paused to save bandwidth"
        case .privacy:
            "Screen paused for privacy"
        case .resuming:
            "Resuming screen"
        case .screenHidden:
            "Screen is not being presented"
        }
    }
}

/// Evidence-bounded client pipeline states. Unchanged rendered content is kept distinct from a
/// stalled presentation because a static desktop is valid screen content.
public enum WorldwideScreenLivenessState: String, Codable, CaseIterable, Equatable, Sendable {
    case intentionallyCovered
    case covered
    case trackMissing
    case awaitingEvidence
    case inboundRTPStalled
    case decodeStalled
    case presentationStalled
    case presentingUnchanged
    case presentingLive

    public var statusText: String {
        switch self {
        case .intentionallyCovered:
            WorldwideScreenLivenessCoverState.intentionalBandwidthPause.statusText
        case .covered:
            "Screen presentation is covered"
        case .trackMissing:
            "Waiting for the remote video track"
        case .awaitingEvidence:
            "Waiting for client screen evidence"
        case .inboundRTPStalled:
            "Inbound screen RTP is not advancing"
        case .decodeStalled:
            "Inbound screen video is not decoding"
        case .presentationStalled:
            "Decoded screen video is not presenting"
        case .presentingUnchanged:
            "Screen frames are presenting without content changes"
        case .presentingLive:
            "Screen frames are presenting and changing"
        }
    }
}

/// Why the classifier discarded its single retained comparison floor.
public enum WorldwideScreenLivenessResetReason: String, Codable, Equatable, Sendable {
    case none
    case initialSample
    case generationChanged
    case counterRegression
}

/// Content-free renderer totals copied from `WebRTCVideoRenderObservation` at MainActor receipt.
/// The renderer-local digest, RTP timestamp, and media timestamp are deliberately excluded.
public struct WorldwideScreenLivenessRenderObservation: Codable, Equatable, Sendable {
    public let presentedFrames: UInt64
    public let contentSamples: UInt64
    public let contentChanges: UInt64
    public let presentedAtUptimeNanoseconds: UInt64
    public let frameWidth: Int
    public let frameHeight: Int

    public init(
        presentedFrames: UInt64,
        contentSamples: UInt64,
        contentChanges: UInt64,
        presentedAtUptimeNanoseconds: UInt64,
        frameWidth: Int,
        frameHeight: Int
    ) {
        self.presentedFrames = presentedFrames
        self.contentSamples = contentSamples
        self.contentChanges = contentChanges
        self.presentedAtUptimeNanoseconds = presentedAtUptimeNanoseconds
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
    }
}

#if os(iOS)
public extension WorldwideScreenLivenessRenderObservation {
    init(
        _ observation: WebRTCVideoRenderObservation,
        presentedAtUptimeNanoseconds: UInt64
    ) {
        self.init(
            presentedFrames: observation.frameCount,
            contentSamples: observation.contentSampleCount,
            contentChanges: observation.contentChangeCount,
            presentedAtUptimeNanoseconds: presentedAtUptimeNanoseconds,
            frameWidth: observation.width,
            frameHeight: observation.height
        )
    }
}
#endif

/// One deterministic classifier input. `generation` is an ephemeral local counter rotated when
/// the session, remote track, or renderer counter domain changes.
public struct WorldwideScreenLivenessSample: Equatable, Sendable {
    public let generation: UInt64
    public let observedAtUptimeNanoseconds: UInt64
    public let hasRemoteVideoTrack: Bool
    public let coverState: WorldwideScreenLivenessCoverState
    public let inboundVideo: WebRTCVideoStatistics?
    public let renderObservation: WorldwideScreenLivenessRenderObservation?

    public init(
        generation: UInt64,
        observedAtUptimeNanoseconds: UInt64,
        hasRemoteVideoTrack: Bool,
        coverState: WorldwideScreenLivenessCoverState,
        inboundVideo: WebRTCVideoStatistics?,
        renderObservation: WorldwideScreenLivenessRenderObservation?
    ) {
        self.generation = generation
        self.observedAtUptimeNanoseconds = observedAtUptimeNanoseconds
        self.hasRemoteVideoTrack = hasRemoteVideoTrack
        self.coverState = coverState
        self.inboundVideo = inboundVideo
        self.renderObservation = renderObservation
    }
}

/// A bounded, privacy-safe projection suitable for local UI and conversion to a wire heartbeat.
/// It retains no pixels, content digest, receiver identity, SSRC, track ID, or session UUID.
public struct WorldwideScreenLivenessDiagnosticSnapshot: Codable, Equatable, Sendable {
    public static let maximumPresentationAgeMilliseconds: UInt64 = 86_400_000

    public let state: WorldwideScreenLivenessState
    public let resetReason: WorldwideScreenLivenessResetReason
    public let generation: UInt64
    public let trackAttached: Bool
    public let coverState: WorldwideScreenLivenessCoverState
    public let inboundBytes: UInt64?
    public let inboundByteDelta: UInt64?
    public let inboundPackets: UInt64?
    public let inboundPacketDelta: UInt64?
    public let decodedFrames: UInt64?
    public let decodedFrameDelta: UInt64?
    public let presentedFrames: UInt64?
    public let presentedFrameDelta: UInt64?
    public let contentSamples: UInt64?
    public let contentSampleDelta: UInt64?
    public let contentChanges: UInt64?
    public let contentChangeDelta: UInt64?
    public let lastPresentationAgeMilliseconds: UInt64?
    public let frameWidth: Int?
    public let frameHeight: Int?
    public let framesPerSecond: Double?

    public var statusText: String {
        switch state {
        case .intentionallyCovered:
            WorldwideScreenLivenessCoverState.intentionalBandwidthPause.statusText
        case .covered:
            coverState.statusText
        default:
            state.statusText
        }
    }

    public static var unobserved: Self {
        Self(
            state: .trackMissing,
            resetReason: .initialSample,
            generation: 0,
            trackAttached: false,
            coverState: .screenHidden,
            inboundBytes: nil,
            inboundByteDelta: nil,
            inboundPackets: nil,
            inboundPacketDelta: nil,
            decodedFrames: nil,
            decodedFrameDelta: nil,
            presentedFrames: nil,
            presentedFrameDelta: nil,
            contentSamples: nil,
            contentSampleDelta: nil,
            contentChanges: nil,
            contentChangeDelta: nil,
            lastPresentationAgeMilliseconds: nil,
            frameWidth: nil,
            frameHeight: nil,
            framesPerSecond: nil
        )
    }

    init(
        state: WorldwideScreenLivenessState,
        resetReason: WorldwideScreenLivenessResetReason,
        generation: UInt64,
        trackAttached: Bool,
        coverState: WorldwideScreenLivenessCoverState,
        inboundBytes: UInt64?,
        inboundByteDelta: UInt64?,
        inboundPackets: UInt64?,
        inboundPacketDelta: UInt64?,
        decodedFrames: UInt64?,
        decodedFrameDelta: UInt64?,
        presentedFrames: UInt64?,
        presentedFrameDelta: UInt64?,
        contentSamples: UInt64?,
        contentSampleDelta: UInt64?,
        contentChanges: UInt64?,
        contentChangeDelta: UInt64?,
        lastPresentationAgeMilliseconds: UInt64?,
        frameWidth: Int?,
        frameHeight: Int?,
        framesPerSecond: Double?
    ) {
        self.state = state
        self.resetReason = resetReason
        self.generation = generation
        self.trackAttached = trackAttached
        self.coverState = coverState
        self.inboundBytes = inboundBytes
        self.inboundByteDelta = inboundByteDelta
        self.inboundPackets = inboundPackets
        self.inboundPacketDelta = inboundPacketDelta
        self.decodedFrames = decodedFrames
        self.decodedFrameDelta = decodedFrameDelta
        self.presentedFrames = presentedFrames
        self.presentedFrameDelta = presentedFrameDelta
        self.contentSamples = contentSamples
        self.contentSampleDelta = contentSampleDelta
        self.contentChanges = contentChanges
        self.contentChangeDelta = contentChangeDelta
        self.lastPresentationAgeMilliseconds = lastPresentationAgeMilliseconds
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.framesPerSecond = framesPerSecond
    }
}

/// Constant-space liveness classifier. It retains only the preceding sample and the time of the
/// latest observed pixel-content change; all output is deterministic from explicit inputs.
public struct WorldwideScreenLivenessClassifier: Sendable {
    public static let freshPresentationWindowNanoseconds: UInt64 = 2_500_000_000

    private var previousSample: WorldwideScreenLivenessSample?
    private var lastContentChangeUptimeNanoseconds: UInt64?

    public init() {}

    public mutating func reset() {
        previousSample = nil
        lastContentChangeUptimeNanoseconds = nil
    }

    public mutating func observe(
        _ sample: WorldwideScreenLivenessSample
    ) -> WorldwideScreenLivenessDiagnosticSnapshot {
        let resetReason = resetReason(for: sample)
        let comparison = resetReason == .none ? previousSample : nil
        let deltas = Deltas(current: sample, previous: comparison)

        if resetReason != .none {
            lastContentChangeUptimeNanoseconds = nil
        } else if deltas.contentChanges.map({ $0 > 0 }) == true {
            lastContentChangeUptimeNanoseconds = sample.observedAtUptimeNanoseconds
        }

        let presentationAge = Self.presentationAgeMilliseconds(
            now: sample.observedAtUptimeNanoseconds,
            presentedAt: sample.renderObservation?.presentedAtUptimeNanoseconds
        )
        let state = classify(
            sample,
            resetReason: resetReason,
            deltas: deltas,
            presentationAgeMilliseconds: presentationAge
        )
        let inbound = sample.inboundVideo
        let render = sample.renderObservation
        let snapshot = WorldwideScreenLivenessDiagnosticSnapshot(
            state: state,
            resetReason: resetReason,
            generation: sample.generation,
            trackAttached: sample.hasRemoteVideoTrack,
            coverState: sample.coverState,
            inboundBytes: inbound?.bytes,
            inboundByteDelta: deltas.inboundBytes,
            inboundPackets: inbound?.packets,
            inboundPacketDelta: deltas.inboundPackets,
            decodedFrames: inbound?.framesEncodedOrDecoded,
            decodedFrameDelta: deltas.decodedFrames,
            presentedFrames: render?.presentedFrames,
            presentedFrameDelta: deltas.presentedFrames,
            contentSamples: render?.contentSamples,
            contentSampleDelta: deltas.contentSamples,
            contentChanges: render?.contentChanges,
            contentChangeDelta: deltas.contentChanges,
            lastPresentationAgeMilliseconds: presentationAge,
            frameWidth: Self.validDimension(render?.frameWidth) ?? Self.validDimension(inbound?.frameWidth),
            frameHeight: Self.validDimension(render?.frameHeight) ?? Self.validDimension(inbound?.frameHeight),
            framesPerSecond: Self.validFramesPerSecond(inbound?.framesPerSecond)
        )
        previousSample = sample
        return snapshot
    }

    private mutating func classify(
        _ sample: WorldwideScreenLivenessSample,
        resetReason: WorldwideScreenLivenessResetReason,
        deltas: Deltas,
        presentationAgeMilliseconds: UInt64?
    ) -> WorldwideScreenLivenessState {
        if sample.coverState == .intentionalBandwidthPause {
            return .intentionallyCovered
        }
        if sample.coverState != .none {
            return .covered
        }
        guard sample.hasRemoteVideoTrack else {
            return .trackMissing
        }
        guard resetReason == .none else {
            return .awaitingEvidence
        }

        let presentationIsFresh = presentationAgeMilliseconds.map {
            $0 <= Self.freshPresentationWindowNanoseconds / 1_000_000
        } == true
        let contentChangeIsFresh = lastContentChangeUptimeNanoseconds.map {
            sample.observedAtUptimeNanoseconds >= $0
                && sample.observedAtUptimeNanoseconds - $0
                    <= Self.freshPresentationWindowNanoseconds
        } == true

        if deltas.presentedFrames.map({ $0 > 0 }) == true {
            return deltas.contentChanges.map({ $0 > 0 }) == true
                ? .presentingLive
                : .presentingUnchanged
        }
        if presentationIsFresh,
           sample.renderObservation?.contentSamples ?? 0 > 0 {
            return contentChangeIsFresh ? .presentingLive : .presentingUnchanged
        }

        let inboundDeltas = [deltas.inboundBytes, deltas.inboundPackets]
            .compactMap { $0 }
        if !inboundDeltas.isEmpty,
           inboundDeltas.allSatisfy({ $0 == 0 }) {
            return .inboundRTPStalled
        }
        if inboundDeltas.contains(where: { $0 > 0 }) {
            if let decodedFrames = deltas.decodedFrames {
                return decodedFrames > 0 ? .presentationStalled : .decodeStalled
            }
            return .awaitingEvidence
        }
        if deltas.decodedFrames.map({ $0 > 0 }) == true {
            return .presentationStalled
        }
        return .awaitingEvidence
    }

    private func resetReason(
        for sample: WorldwideScreenLivenessSample
    ) -> WorldwideScreenLivenessResetReason {
        guard let previousSample else { return .initialSample }
        guard previousSample.generation == sample.generation else {
            return .generationChanged
        }
        return Self.counterRegressed(current: sample, previous: previousSample)
            ? .counterRegression
            : .none
    }

    private static func counterRegressed(
        current: WorldwideScreenLivenessSample,
        previous: WorldwideScreenLivenessSample
    ) -> Bool {
        let pairs: [(UInt64?, UInt64?)] = [
            (current.inboundVideo?.bytes, previous.inboundVideo?.bytes),
            (current.inboundVideo?.packets, previous.inboundVideo?.packets),
            (
                current.inboundVideo?.framesEncodedOrDecoded,
                previous.inboundVideo?.framesEncodedOrDecoded
            ),
            (
                current.renderObservation?.presentedFrames,
                previous.renderObservation?.presentedFrames
            ),
            (
                current.renderObservation?.contentSamples,
                previous.renderObservation?.contentSamples
            ),
            (
                current.renderObservation?.contentChanges,
                previous.renderObservation?.contentChanges
            ),
        ]
        return pairs.contains { current, previous in
            guard let current, let previous else { return false }
            return current < previous
        }
    }

    private static func presentationAgeMilliseconds(
        now: UInt64,
        presentedAt: UInt64?
    ) -> UInt64? {
        guard let presentedAt else { return nil }
        let nanoseconds = now >= presentedAt ? now - presentedAt : 0
        return min(
            nanoseconds / 1_000_000,
            WorldwideScreenLivenessDiagnosticSnapshot
                .maximumPresentationAgeMilliseconds
        )
    }

    private static func validDimension(_ value: Int?) -> Int? {
        guard let value, (1 ... 32_768).contains(value) else { return nil }
        return value
    }

    private static func validFramesPerSecond(_ value: Double?) -> Double? {
        guard let value,
              value.isFinite,
              (0 ... 1_000).contains(value) else { return nil }
        return value
    }

    private struct Deltas {
        let inboundBytes: UInt64?
        let inboundPackets: UInt64?
        let decodedFrames: UInt64?
        let presentedFrames: UInt64?
        let contentSamples: UInt64?
        let contentChanges: UInt64?

        init(
            current: WorldwideScreenLivenessSample,
            previous: WorldwideScreenLivenessSample?
        ) {
            inboundBytes = Self.delta(
                current.inboundVideo?.bytes,
                previous?.inboundVideo?.bytes
            )
            inboundPackets = Self.delta(
                current.inboundVideo?.packets,
                previous?.inboundVideo?.packets
            )
            decodedFrames = Self.delta(
                current.inboundVideo?.framesEncodedOrDecoded,
                previous?.inboundVideo?.framesEncodedOrDecoded
            )
            presentedFrames = Self.delta(
                current.renderObservation?.presentedFrames,
                previous?.renderObservation?.presentedFrames
            )
            contentSamples = Self.delta(
                current.renderObservation?.contentSamples,
                previous?.renderObservation?.contentSamples
            )
            contentChanges = Self.delta(
                current.renderObservation?.contentChanges,
                previous?.renderObservation?.contentChanges
            )
        }

        private static func delta(_ current: UInt64?, _ previous: UInt64?) -> UInt64? {
            guard let current, let previous, current >= previous else { return nil }
            return current - previous
        }
    }
}
