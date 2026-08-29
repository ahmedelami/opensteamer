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

    public init(
        maximumBitrateBps: Int,
        maximumFramesPerSecond: Int,
        scaleResolutionDownBy: Double
    ) {
        self.maximumBitrateBps = maximumBitrateBps
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.scaleResolutionDownBy = scaleResolutionDownBy
    }
}

/// Opaque proof for reverting one sender update only while it remains the newest mutation.
public struct WebRTCScreenVideoEncodingUpdate: Sendable {
    let generation: UInt64
    let previousMaximumBitrateBps: Int?
    let previousMinimumBitrateBps: Int?
    let previousMaximumFramesPerSecond: Int?
    let previousScaleResolutionDownBy: Double?
    let appliedLimits: WebRTCScreenVideoEncodingLimits

    init(
        generation: UInt64,
        previousMaximumBitrateBps: Int?,
        previousMinimumBitrateBps: Int?,
        previousMaximumFramesPerSecond: Int?,
        previousScaleResolutionDownBy: Double?,
        appliedLimits: WebRTCScreenVideoEncodingLimits
    ) {
        self.generation = generation
        self.previousMaximumBitrateBps = previousMaximumBitrateBps
        self.previousMinimumBitrateBps = previousMinimumBitrateBps
        self.previousMaximumFramesPerSecond = previousMaximumFramesPerSecond
        self.previousScaleResolutionDownBy = previousScaleResolutionDownBy
        self.appliedLimits = appliedLimits
    }
}

/// A sendable lifetime wrapper around LiveKit's thread-safe Objective-C video track.
///
/// LiveKit's track is thread-safe but has no Swift concurrency annotations.
public final class WebRTCRemoteVideoTrack: @unchecked Sendable {
    private let nativeTrack: LKRTCVideoTrack
    public let trackID: String

    init(_ nativeTrack: LKRTCVideoTrack) {
        self.nativeTrack = nativeTrack
        trackID = nativeTrack.trackId as String
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
