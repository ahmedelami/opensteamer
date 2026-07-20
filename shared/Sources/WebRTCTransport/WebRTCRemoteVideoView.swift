#if os(iOS)
@preconcurrency import LiveKitWebRTC
import UIKit

/// Non-media evidence that a decoded video frame reached the renderer boundary. No pixels leave
/// the renderer: the physical gate receives only metadata plus a renderer-local salted digest of
/// a bounded sample grid.
public struct WebRTCVideoRenderObservation: Equatable, Sendable {
    public let frameCount: UInt64
    public let timestampNanoseconds: Int64
    public let width: Int
    public let height: Int
    /// A renderer-local, salted digest of a bounded grid of decoded pixels. It is useful only for
    /// comparing frames from this renderer instance; the salt prevents it from becoming a stable
    /// fingerprint of the user's screen across sessions.
    public let contentDigest: UInt64
    /// Number of decoded frames whose pixels have been sampled at this renderer boundary.
    public let contentSampleCount: UInt64
    /// Number of sampled frames whose digest differed from the preceding sampled frame.
    public let contentChangeCount: UInt64

    public init(
        frameCount: UInt64,
        timestampNanoseconds: Int64,
        width: Int,
        height: Int,
        contentDigest: UInt64,
        contentSampleCount: UInt64,
        contentChangeCount: UInt64
    ) {
        self.frameCount = frameCount
        self.timestampNanoseconds = timestampNanoseconds
        self.width = width
        self.height = height
        self.contentDigest = contentDigest
        self.contentSampleCount = contentSampleCount
        self.contentChangeCount = contentChangeCount
    }
}

/// Computes a bounded decoded-pixel observation without retaining or exporting pixel data.
/// Hardware-decoded CVPixelBuffers stay zero-copy; unusual buffer types use WebRTC's I420 view.
enum WebRTCDecodedPixelDigest {
    private static let columns = 16
    private static let rows = 9
    private static let fnvPrime: UInt64 = 1_099_511_628_211

    static func digest(frame: LKRTCVideoFrame, salt: UInt64) -> UInt64 {
        if let cvBuffer = frame.buffer as? LKRTCCVPixelBuffer {
            return digest(pixelBuffer: cvBuffer.pixelBuffer, salt: salt)
        }

        let i420 = frame.buffer.toI420()
        var hash = seededHash(salt: salt, width: Int(i420.width), height: Int(i420.height))
        samplePlane(
            i420.dataY,
            width: Int(i420.width),
            height: Int(i420.height),
            bytesPerRow: Int(i420.strideY),
            bytesPerPixel: 1,
            into: &hash
        )
        samplePlane(
            i420.dataU,
            width: Int(i420.chromaWidth),
            height: Int(i420.chromaHeight),
            bytesPerRow: Int(i420.strideU),
            bytesPerPixel: 1,
            into: &hash
        )
        samplePlane(
            i420.dataV,
            width: Int(i420.chromaWidth),
            height: Int(i420.chromaHeight),
            bytesPerRow: Int(i420.strideV),
            bytesPerPixel: 1,
            into: &hash
        )
        return hash
    }

    static func digest(pixelBuffer: CVPixelBuffer, salt: UInt64) -> UInt64 {
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            return seededHash(
                salt: salt,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var hash = seededHash(salt: salt, width: width, height: height)
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        if planeCount > 0 {
            for plane in 0..<planeCount {
                guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
                    continue
                }
                let planeWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
                let planeHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                let bytesPerPixel = max(1, min(4, bytesPerRow / max(1, planeWidth)))
                samplePlane(
                    baseAddress.assumingMemoryBound(to: UInt8.self),
                    width: planeWidth,
                    height: planeHeight,
                    bytesPerRow: bytesPerRow,
                    bytesPerPixel: bytesPerPixel,
                    into: &hash
                )
            }
        } else if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let bytesPerPixel = max(1, min(8, bytesPerRow / max(1, width)))
            samplePlane(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                bytesPerPixel: bytesPerPixel,
                into: &hash
            )
        }
        return hash
    }

    private static func seededHash(salt: UInt64, width: Int, height: Int) -> UInt64 {
        var hash = 14_695_981_039_346_656_037 ^ salt
        mix(UInt64(width), into: &hash)
        mix(UInt64(height), into: &hash)
        return hash
    }

    private static func samplePlane(
        _ baseAddress: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytesPerPixel: Int,
        into hash: inout UInt64
    ) {
        guard width > 0, height > 0, bytesPerRow > 0, bytesPerPixel > 0 else { return }
        mix(UInt64(width), into: &hash)
        mix(UInt64(height), into: &hash)
        for rowIndex in 0..<rows {
            let y = min(height - 1, ((rowIndex * 2 + 1) * height) / (rows * 2))
            let row = baseAddress.advanced(by: y * bytesPerRow)
            for columnIndex in 0..<columns {
                let x = min(width - 1, ((columnIndex * 2 + 1) * width) / (columns * 2))
                let pixel = row.advanced(by: x * bytesPerPixel)
                for component in 0..<bytesPerPixel {
                    mix(UInt64(pixel[component]), into: &hash)
                }
            }
        }
    }

    private static func mix(_ value: UInt64, into hash: inout UInt64) {
        var value = value
        for _ in 0..<8 {
            hash ^= value & 0xff
            hash &*= fnvPrime
            value >>= 8
        }
    }
}

/// Forwards every decoded frame to the real Metal renderer while publishing a throttled monotonic
/// observation. WebRTC invokes renderers off the main thread, so the counters, sampled digest, and
/// publication cadence are protected by one lock.
private final class ObservedVideoRenderer: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    private static let minimumPublicationIntervalNanoseconds: UInt64 = 250_000_000

    private let downstream: LKRTCVideoRenderer
    private let publish: @Sendable (WebRTCVideoRenderObservation) -> Void
    private let lock = NSLock()
    private let contentDigestSalt = UInt64.random(in: UInt64.min...UInt64.max)
    private var frameCount: UInt64 = 0
    private var lastPublicationNanoseconds: UInt64 = 0
    private var lastContentDigest: UInt64?
    private var contentSampleCount: UInt64 = 0
    private var contentChangeCount: UInt64 = 0

    init(
        downstream: LKRTCVideoRenderer,
        publish: @escaping @Sendable (WebRTCVideoRenderObservation) -> Void
    ) {
        self.downstream = downstream
        self.publish = publish
        super.init()
    }

    func setSize(_ size: CGSize) {
        downstream.setSize(size)
    }

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        downstream.renderFrame(frame)
        guard let frame else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        let observation: WebRTCVideoRenderObservation? = lock.withLock {
            frameCount &+= 1
            guard frameCount == 1
                    || now &- lastPublicationNanoseconds
                        >= Self.minimumPublicationIntervalNanoseconds else {
                return nil
            }
            lastPublicationNanoseconds = now
            let contentDigest = WebRTCDecodedPixelDigest.digest(
                frame: frame,
                salt: contentDigestSalt
            )
            contentSampleCount &+= 1
            if let lastContentDigest, lastContentDigest != contentDigest {
                contentChangeCount &+= 1
            }
            lastContentDigest = contentDigest
            return WebRTCVideoRenderObservation(
                frameCount: frameCount,
                timestampNanoseconds: frame.timeStampNs,
                width: Int(frame.width),
                height: Int(frame.height),
                contentDigest: contentDigest,
                contentSampleCount: contentSampleCount,
                contentChangeCount: contentChangeCount
            )
        }
        if let observation {
            publish(observation)
        }
    }
}

/// The narrow UIKit boundary used by the SwiftUI iPhone client to render a remote track.
@MainActor
public final class WebRTCRemoteVideoView: UIView, LKRTCVideoViewDelegate {
    private let renderer = LKRTCMTLVideoView(frame: .zero)
    private lazy var observedRenderer = ObservedVideoRenderer(
        downstream: renderer,
        publish: { [weak self] observation in
            Task { @MainActor [weak self] in
                self?.onVideoFrameRendered?(observation)
            }
        }
    )
    private var currentTrack: WebRTCRemoteVideoTrack?
    private var bindingGeneration: UInt64 = 0
    private var currentVideoSize = CGSize.zero

    /// Reports the decoded frame size used by the aspect-fit renderer.
    ///
    /// The SwiftUI owner uses this exact size to distinguish video pixels from the
    /// renderer's letterbox area before forwarding a remote-input coordinate.
    public var onVideoSizeChanged: ((CGSize) -> Void)?
    /// Reports decoded frames only after they have been forwarded to the real Metal renderer.
    public var onVideoFrameRendered: ((WebRTCVideoRenderObservation) -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configureRenderer()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureRenderer()
    }

    public func setTrack(_ track: WebRTCRemoteVideoTrack?) {
        guard currentTrack !== track else { return }
        bindingGeneration &+= 1
        let generation = bindingGeneration

        publishVideoSize(.zero)

        // These mutations are synchronous on MainActor. The generation guard documents and
        // enforces last-bind-wins if this boundary later gains an asynchronous preparation step.
        currentTrack?.removeRenderer(observedRenderer)
        guard generation == bindingGeneration else { return }
        currentTrack = track
        track?.addRenderer(observedRenderer)
    }

    public func detachTrack() {
        setTrack(nil)
        renderer.renderFrame(nil)
    }

    nonisolated public func videoView(
        _ videoView: LKRTCVideoRenderer,
        didChangeVideoSize size: CGSize
    ) {
        Task { @MainActor [weak self] in
            self?.publishVideoSize(size)
        }
    }

    private func configureRenderer() {
        backgroundColor = .black
        renderer.backgroundColor = .black
        renderer.videoContentMode = .scaleAspectFit
        renderer.delegate = self
        renderer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(renderer)
        NSLayoutConstraint.activate([
            renderer.leadingAnchor.constraint(equalTo: leadingAnchor),
            renderer.trailingAnchor.constraint(equalTo: trailingAnchor),
            renderer.topAnchor.constraint(equalTo: topAnchor),
            renderer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func publishVideoSize(_ size: CGSize) {
        guard size != currentVideoSize else { return }
        currentVideoSize = size
        onVideoSizeChanged?(size)
    }
}
#endif
