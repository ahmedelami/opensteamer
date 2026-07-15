@preconcurrency import LiveKitWebRTC
import CoreMedia
import CoreVideo
import Foundation

public enum WebRTCVideoRotation: Int, Sendable {
    case zero = 0
    case ninety = 90
    case oneEighty = 180
    case twoSeventy = 270
}

// LiveKit's Obj-C track is thread-safe but has no Swift concurrency annotations.
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

// ScreenCaptureKit delivers buffers off-actor; LiveKit synchronizes source ingestion internally.
public final class MacExternalVideoCapturer: @unchecked Sendable {
    private let source: LKRTCVideoSource
    private let capturer: LKRTCVideoCapturer

    init(source: LKRTCVideoSource) {
        self.source = source
        capturer = LKRTCVideoCapturer(delegate: source)
    }

    public func adaptOutput(width: Int32, height: Int32, framesPerSecond: Int32) {
        source.adaptOutputFormat(toWidth: width, height: height, fps: framesPerSecond)
    }

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
