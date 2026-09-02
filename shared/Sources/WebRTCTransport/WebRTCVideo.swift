@preconcurrency import LiveKitWebRTC
import CoreMedia
import CoreVideo
import Foundation

/// Rotation metadata attached to an externally captured video frame.
public enum WebRTCVideoRotation: Int, Sendable {
    case zero = 0
    case ninety = 90
    case oneEighty = 180
    case twoSeventy = 270
}

/// Encoder-facing ceilings for the single host screen-video RTP encoding.
///
/// Resolution is scaled proportionally at the sender so the complete captured surface remains
/// visible. The ScreenCaptureKit source dimensions therefore stay authoritative for remote input.
public struct WebRTCScreenVideoEncodingLimits: Equatable, Sendable {
    public let maximumBitrateBps: Int
    public let maximumFramesPerSecond: Int
    public let scaleResolutionDownBy: Double
    /// Optional peer-wide RTP ceiling applied with this sender profile. Raising this native BWE
    /// ceiling uses WebRTC's no-ALR mid-call probe path; it includes the audio/control reserve.
    public let maximumTotalRTPBitrateBps: Int?

    public init(
        maximumBitrateBps: Int,
        maximumFramesPerSecond: Int,
        scaleResolutionDownBy: Double,
        maximumTotalRTPBitrateBps: Int? = nil
    ) {
        self.maximumBitrateBps = maximumBitrateBps
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.scaleResolutionDownBy = scaleResolutionDownBy
        self.maximumTotalRTPBitrateBps = maximumTotalRTPBitrateBps
    }
}

/// Opaque proof for reverting one sender update only while it remains the newest mutation.
public struct WebRTCScreenVideoEncodingUpdate: Sendable {
    let generation: UInt64
    let previousMaximumBitrateBps: Int?
    let previousMinimumBitrateBps: Int?
    let previousMaximumFramesPerSecond: Int?
    let previousScaleResolutionDownBy: Double?
    let previousMaximumTotalRTPBitrateBps: Int?
    let previousIsActive: [Bool]
    let appliedIsActive: [Bool]
    let appliedMaximumTotalRTPBitrateBps: Int?
    let appliedLimits: WebRTCScreenVideoEncodingLimits

    init(
        generation: UInt64,
        previousMaximumBitrateBps: Int?,
        previousMinimumBitrateBps: Int?,
        previousMaximumFramesPerSecond: Int?,
        previousScaleResolutionDownBy: Double?,
        previousMaximumTotalRTPBitrateBps: Int?,
        previousIsActive: [Bool],
        appliedIsActive: [Bool],
        appliedMaximumTotalRTPBitrateBps: Int?,
        appliedLimits: WebRTCScreenVideoEncodingLimits
    ) {
        self.generation = generation
        self.previousMaximumBitrateBps = previousMaximumBitrateBps
        self.previousMinimumBitrateBps = previousMinimumBitrateBps
        self.previousMaximumFramesPerSecond = previousMaximumFramesPerSecond
        self.previousScaleResolutionDownBy = previousScaleResolutionDownBy
        self.previousMaximumTotalRTPBitrateBps =
            previousMaximumTotalRTPBitrateBps
        self.previousIsActive = previousIsActive
        self.appliedIsActive = appliedIsActive
        self.appliedMaximumTotalRTPBitrateBps =
            appliedMaximumTotalRTPBitrateBps
        self.appliedLimits = appliedLimits
    }
}

/// Opaque proof for one all-encoding sender activity mutation. Its generation shares the same
/// transaction sequence as quality-limit updates, so a stale rollback can never overwrite either.
public struct WebRTCScreenVideoEncodingActivityUpdate: Sendable {
    let generation: UInt64
    let previousMaximumBitrateBps: Int?
    let previousMinimumBitrateBps: Int?
    let previousMaximumFramesPerSecond: Int?
    let previousScaleResolutionDownBy: Double?
    let previousIsActive: [Bool]
    let appliedIsActive: [Bool]

    init(
        generation: UInt64,
        previousMaximumBitrateBps: Int?,
        previousMinimumBitrateBps: Int?,
        previousMaximumFramesPerSecond: Int?,
        previousScaleResolutionDownBy: Double?,
        previousIsActive: [Bool],
        appliedIsActive: [Bool]
    ) {
        self.generation = generation
        self.previousMaximumBitrateBps = previousMaximumBitrateBps
        self.previousMinimumBitrateBps = previousMinimumBitrateBps
        self.previousMaximumFramesPerSecond = previousMaximumFramesPerSecond
        self.previousScaleResolutionDownBy = previousScaleResolutionDownBy
        self.previousIsActive = previousIsActive
        self.appliedIsActive = appliedIsActive
    }
}

/// A sendable lifetime wrapper around LiveKit's thread-safe Objective-C video track.
///
/// LiveKit's track is thread-safe but has no Swift concurrency annotations.
public struct WebRTCRemoteVideoSourceSnapshot: Equatable, Sendable {
    public let receiverID: String
    public let sourceIDs: [UInt32]
    public let rtpTimestamps: [UInt32]

    public init(
        receiverID: String,
        sourceIDs: [UInt32],
        rtpTimestamps: [UInt32]
    ) {
        self.receiverID = receiverID
        self.sourceIDs = sourceIDs
        self.rtpTimestamps = rtpTimestamps
    }
}

public final class WebRTCRemoteVideoTrack: @unchecked Sendable {
    private let nativeTrack: LKRTCVideoTrack
    private let nativeReceiver: LKRTCRtpReceiver
    public let trackID: String
    public let receiverID: String

    init(
        _ nativeTrack: LKRTCVideoTrack,
        receiver: LKRTCRtpReceiver
    ) {
        self.nativeTrack = nativeTrack
        nativeReceiver = receiver
        trackID = nativeTrack.trackId as String
        receiverID = receiver.receiverId as String
    }

    /// Returns the recent primary SSRC observations for this exact receiver. Resume proof owners
    /// require one stable source across marker and real-frame presentation; CSRCs are excluded.
    public func sourceSnapshot() -> WebRTCRemoteVideoSourceSnapshot {
        let primarySources = nativeReceiver.sources.filter {
            $0.sourceType.rawValue == 0
        }
        return WebRTCRemoteVideoSourceSnapshot(
            receiverID: receiverID,
            sourceIDs: primarySources.map(\.sourceId),
            rtpTimestamps: primarySources.map(\.rtpTimestamp)
        )
    }

    /// Native renderer mutation is intentionally module-internal and MainActor-owned.
    @MainActor
    func addRenderer(_ renderer: any LKRTCVideoRenderer) {
        nativeTrack.add(renderer)
    }

    @MainActor
    func removeRenderer(_ renderer: any LKRTCVideoRenderer) {
        nativeTrack.remove(renderer)
    }
}

/// Bridges ScreenCaptureKit pixel buffers into LiveKit's synchronized external video source.
///
/// ScreenCaptureKit delivers buffers off-actor; LiveKit synchronizes source ingestion internally.
public final class MacExternalVideoCapturer: @unchecked Sendable {
    private let source: LKRTCVideoSource
    private let capturer: LKRTCVideoCapturer

    init(source: LKRTCVideoSource) {
        self.source = source
        capturer = LKRTCVideoCapturer(delegate: source)
    }

    /// Updates the native source's encoder-facing dimensions and frame-rate target.
    public func adaptOutput(width: Int32, height: Int32, framesPerSecond: Int32) {
        source.adaptOutputFormat(toWidth: width, height: height, fps: framesPerSecond)
    }

    /// Captures a frame using a Core Media timestamp.
    public func capture(
        pixelBuffer: CVPixelBuffer,
        timestamp: CMTime,
        rotation: WebRTCVideoRotation = .zero
    ) {
        let converted = CMTimeConvertScale(timestamp, timescale: 1_000_000_000, method: .default)
        capture(
            pixelBuffer: pixelBuffer,
            timestampNanoseconds: converted.value,
            rotation: rotation
        )
    }

    /// Captures a frame using an already-normalized monotonic nanosecond timestamp.
    public func capture(
        pixelBuffer: CVPixelBuffer,
        timestampNanoseconds: Int64,
        rotation: WebRTCVideoRotation = .zero
    ) {
        let buffer = LKRTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = LKRTCVideoFrame(
            buffer: buffer,
            rotation: rotation.nativeValue,
            timeStampNs: timestampNanoseconds
        )

        // The Obj-C source accepts frames from the ScreenCaptureKit callback queue.
        source.capturer(capturer, didCapture: frame)
    }
}

private extension WebRTCVideoRotation {
    var nativeValue: LKRTCVideoRotation {
        switch self {
        case .zero: ._0
        case .ninety: ._90
        case .oneEighty: ._180
        case .twoSeventy: ._270
        }
    }
}
