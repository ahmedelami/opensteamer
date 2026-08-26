#if os(iOS)
@preconcurrency import LiveKitWebRTC
import MetalKit
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

/// Preserves LiveKit's private MTKView delegate while exposing the public drawable-presentation
/// boundary. If LiveKit's view hierarchy ever stops containing that MTKView, video continues to
/// render through the native view but no presentation observation is emitted, keeping touch
/// fail-closed.
private final class ObservedMTKViewDelegateProxy: NSObject, MTKViewDelegate, @unchecked Sendable {
    typealias DrawHandler = (
        _ drawable: (any CAMetalDrawable)?,
        _ drawUsingLiveKit: () -> Void
    ) -> Void

    private weak var downstream: (any MTKViewDelegate)?
    private let lock = NSLock()
    private var drawHandler: DrawHandler?

    init(downstream: any MTKViewDelegate) {
        self.downstream = downstream
    }

    func installDrawHandler(_ drawHandler: DrawHandler?) {
        lock.withLock {
            self.drawHandler = drawHandler
        }
    }

    func draw(in view: MTKView) {
        guard let downstream else { return }
        let drawUsingLiveKit = {
            downstream.draw(in: view)
        }
        if let drawHandler = lock.withLock({ drawHandler }) {
            drawHandler(view.currentDrawable, drawUsingLiveKit)
        } else {
            drawUsingLiveKit()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        downstream?.mtkView(view, drawableSizeWillChange: size)
    }
}

/// Calls the public MTLDrawable presentation callback through Objective-C dispatch because the
/// pinned iOS SDK's Swift overlay omits the method even though the runtime protocol implements it.
private enum MTLDrawablePresentationObserver {
    private typealias PresentedHandler = @convention(block) (AnyObject) -> Void
    private typealias AddPresentedHandler = @convention(c) (
        AnyObject,
        Selector,
        PresentedHandler
    ) -> Void
    private static let selector = NSSelectorFromString("addPresentedHandler:")

    static func observe(
        _ drawable: any CAMetalDrawable,
        didPresent: @escaping @Sendable () -> Void
    ) -> Bool {
        let object = drawable as AnyObject
        guard object.responds(to: selector),
              let implementation = object.method(for: selector) else {
            return false
        }
        let handler: PresentedHandler = { _ in didPresent() }
        let addPresentedHandler = unsafeBitCast(
            implementation,
            to: AddPresentedHandler.self
        )
        addPresentedHandler(object, selector, handler)
        return true
    }
}

/// Forwards every decoded frame to the real Metal renderer while publishing a monotonic
/// observation only after Core Animation reports that the exact drawable was presented. Ordinary
/// observations are throttled, but a dimension change is published after its first presented
/// frame without delay. WebRTC and Metal callbacks can use different threads, so all state uses
/// one lock.
private final class ObservedVideoRenderer: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    private struct PendingFrame {
        let sequence: UInt64
        let dimensionGeneration: UInt64
        let frame: LKRTCVideoFrame
    }

    private static let minimumPublicationIntervalNanoseconds: UInt64 = 250_000_000

    private let downstream: LKRTCVideoRenderer
    private let publish: @Sendable (WebRTCVideoRenderObservation, UInt64) -> Void
    private let lock = NSLock()
    private let contentDigestSalt = UInt64.random(in: UInt64.min...UInt64.max)
    private var nextFrameSequence: UInt64 = 0
    private var dimensionGeneration: UInt64 = 0
    private var decodedSize = CGSize.zero
    private var pendingFrame: PendingFrame?
    private var lastSubmittedTimestampNanoseconds: Int64?
    private var lastPublishedFrameSequence: UInt64 = 0
    private var frameCount: UInt64 = 0
    private var lastPublicationNanoseconds: UInt64 = 0
    private var lastPublishedWidth = 0
    private var lastPublishedHeight = 0
    private var lastContentDigest: UInt64?
    private var contentSampleCount: UInt64 = 0
    private var contentChangeCount: UInt64 = 0
    private var isInvalidated = false

    init(
        downstream: LKRTCVideoRenderer,
        publish: @escaping @Sendable (WebRTCVideoRenderObservation, UInt64) -> Void
    ) {
        self.downstream = downstream
        self.publish = publish
        super.init()
    }

    func setSize(_ size: CGSize) {
        lock.withLock {
            guard !isInvalidated else { return }
            advanceDimensionGenerationIfNeeded(to: size)
            downstream.setSize(size)
        }
    }

    /// Permanently retires this exact track binding and drains any frame already rendering.
    func invalidate() {
        lock.withLock {
            isInvalidated = true
        }
    }

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        lock.withLock {
            guard !isInvalidated else { return }
            if let frame {
                nextFrameSequence &+= 1
                if nextFrameSequence == 0 {
                    nextFrameSequence = 1
                }
                advanceDimensionGenerationIfNeeded(
                    to: CGSize(width: Int(frame.width), height: Int(frame.height))
                )
                pendingFrame = PendingFrame(
                    sequence: nextFrameSequence,
                    dimensionGeneration: dimensionGeneration,
                    frame: frame
                )
            } else {
                pendingFrame = nil
            }
            downstream.renderFrame(frame)
        }
    }

    /// The native adapter calls `setSize` immediately before the first frame of a new shape.
    /// Advancing there closes the interval in which an older drawable could otherwise publish
    /// after UIKit had already cleared touch for the new dimensions.
    private func advanceDimensionGenerationIfNeeded(to size: CGSize) {
        guard size != decodedSize else { return }
        dimensionGeneration &+= 1
        if dimensionGeneration == 0 {
            dimensionGeneration = 1
        }
        decodedSize = size
    }

    func isCurrentDimensionGeneration(_ generation: UInt64) -> Bool {
        lock.withLock {
            !isInvalidated && dimensionGeneration == generation
        }
    }

    /// Serializes native frame replacement with LiveKit's Metal draw and attaches the completion
    /// callback before LiveKit schedules that drawable for presentation.
    func draw(
        drawable: (any CAMetalDrawable)?,
        usingLiveKit drawUsingLiveKit: () -> Void
    ) {
        lock.withLock {
            guard !isInvalidated else {
                drawUsingLiveKit()
                return
            }
            guard let pendingFrame,
                  pendingFrame.frame.timeStampNs != lastSubmittedTimestampNanoseconds,
                  let drawable else {
                drawUsingLiveKit()
                return
            }
            let observesPresentation = MTLDrawablePresentationObserver.observe(
                drawable
            ) { [weak self] in
                self?.didPresent(pendingFrame)
            }
            drawUsingLiveKit()
            // LiveKit uses the same timestamp test to suppress duplicate MTKView draws.
            if observesPresentation {
                lastSubmittedTimestampNanoseconds = pendingFrame.frame.timeStampNs
            }
        }
    }

    private func didPresent(_ presentedFrame: PendingFrame) {
        let now = DispatchTime.now().uptimeNanoseconds
        let publication: (WebRTCVideoRenderObservation, UInt64)? = lock.withLock {
            guard !isInvalidated,
                  presentedFrame.dimensionGeneration == dimensionGeneration,
                  presentedFrame.sequence > lastPublishedFrameSequence else {
                return nil
            }
            lastPublishedFrameSequence = presentedFrame.sequence
            let frame = presentedFrame.frame
            frameCount &+= 1
            let width = Int(frame.width)
            let height = Int(frame.height)
            let dimensionsChanged = width != lastPublishedWidth
                || height != lastPublishedHeight
            guard frameCount == 1
                    || dimensionsChanged
                    || now &- lastPublicationNanoseconds
                        >= Self.minimumPublicationIntervalNanoseconds else {
                return nil
            }
            lastPublicationNanoseconds = now
            lastPublishedWidth = width
            lastPublishedHeight = height
            let contentDigest = WebRTCDecodedPixelDigest.digest(
                frame: frame,
                salt: contentDigestSalt
            )
            contentSampleCount &+= 1
            if let lastContentDigest, lastContentDigest != contentDigest {
                contentChangeCount &+= 1
            }
            lastContentDigest = contentDigest
            return (
                WebRTCVideoRenderObservation(
                    frameCount: frameCount,
                    timestampNanoseconds: frame.timeStampNs,
                    width: width,
                    height: height,
                    contentDigest: contentDigest,
                    contentSampleCount: contentSampleCount,
                    contentChangeCount: contentChangeCount
                ),
                presentedFrame.dimensionGeneration
            )
        }
        if let publication {
            publish(publication.0, publication.1)
        }
    }
}

/// The narrow UIKit boundary used by the SwiftUI iPhone client to render a remote track.
@MainActor
public final class WebRTCRemoteVideoView: UIView, LKRTCVideoViewDelegate {
    private let renderer = LKRTCMTLVideoView(frame: .zero)
    private let presentationCover = UIView(frame: .zero)
    private var metalDelegateProxy: ObservedMTKViewDelegateProxy?
    private var observedRenderer: ObservedVideoRenderer?
    private var currentTrack: WebRTCRemoteVideoTrack?
    private var bindingGeneration: UInt64 = 0
    private var currentVideoSize = CGSize.zero

    /// Reports the decoded frame size used by the aspect-fit renderer.
    ///
    /// The SwiftUI owner uses this exact size to distinguish video pixels from the
    /// renderer's letterbox area before forwarding a remote-input coordinate.
    public var onVideoSizeChanged: ((CGSize) -> Void)?
    /// Reports decoded frames only after their Metal drawable has been presented.
    public var onVideoFrameRendered: ((WebRTCVideoRenderObservation) -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configureRenderer()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureRenderer()
    }

    /// Atomically detaches the previous renderer binding and attaches `track`.
    public func setTrack(_ track: WebRTCRemoteVideoTrack?) {
        guard currentTrack !== track else { return }
        bindingGeneration &+= 1
        let generation = bindingGeneration

        // Retire and drain the old renderer before attaching a new generation. Its already-
        // queued MainActor publication still carries the old generation and is rejected below.
        observedRenderer?.invalidate()
        if let observedRenderer {
            currentTrack?.removeRenderer(observedRenderer)
        }
        metalDelegateProxy?.installDrawHandler(nil)
        observedRenderer = nil
        presentationCover.isHidden = false
        currentVideoSize = .zero
        // A binding reset must not be deduplicated against LiveKit's asynchronous size callback.
        onVideoSizeChanged?(.zero)

        guard generation == bindingGeneration else { return }
        currentTrack = track
        guard let track else { return }
        if metalDelegateProxy == nil {
            // The native renderer remains usable if LiveKit changes its internal hierarchy, but
            // presentation cannot be proven and remote touch therefore remains disabled.
            presentationCover.isHidden = true
        }
        let observedRenderer = ObservedVideoRenderer(
            downstream: renderer,
            publish: { [weak self] observation, dimensionGeneration in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.bindingGeneration == generation,
                          self.currentTrack != nil,
                          self.observedRenderer?.isCurrentDimensionGeneration(
                              dimensionGeneration
                          ) == true else {
                        return
                    }
                    self.presentationCover.isHidden = true
                    self.onVideoFrameRendered?(observation)
                }
            }
        )
        self.observedRenderer = observedRenderer
        metalDelegateProxy?.installDrawHandler { [weak observedRenderer] drawable, draw in
            guard let observedRenderer else {
                draw()
                return
            }
            observedRenderer.draw(
                drawable: drawable,
                usingLiveKit: draw
            )
        }
        track.addRenderer(observedRenderer)
    }

    /// Removes the active track and clears the final rendered frame.
    public func detachTrack() {
        setTrack(nil)
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
        presentationCover.backgroundColor = .black
        presentationCover.isUserInteractionEnabled = false
        presentationCover.translatesAutoresizingMaskIntoConstraints = false
        addSubview(presentationCover)
        NSLayoutConstraint.activate([
            renderer.leadingAnchor.constraint(equalTo: leadingAnchor),
            renderer.trailingAnchor.constraint(equalTo: trailingAnchor),
            renderer.topAnchor.constraint(equalTo: topAnchor),
            renderer.bottomAnchor.constraint(equalTo: bottomAnchor),
            presentationCover.leadingAnchor.constraint(equalTo: leadingAnchor),
            presentationCover.trailingAnchor.constraint(equalTo: trailingAnchor),
            presentationCover.topAnchor.constraint(equalTo: topAnchor),
            presentationCover.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        if let metalView = renderer.subviews.compactMap({ $0 as? MTKView }).first,
           let downstream = metalView.delegate {
            let proxy = ObservedMTKViewDelegateProxy(downstream: downstream)
            metalDelegateProxy = proxy
            metalView.delegate = proxy
        } else {
            // Keep media visible on an unsupported future LiveKit hierarchy, but never claim a
            // presented-frame observation that could authorize touch.
            presentationCover.isHidden = true
        }
    }

    private func publishVideoSize(_ size: CGSize) {
        guard size != currentVideoSize else { return }
        currentVideoSize = size
        if metalDelegateProxy != nil {
            // Do not leave an old drawable visible while a new aspect is awaiting presentation.
            presentationCover.isHidden = false
        }
        onVideoSizeChanged?(size)
    }
}
#endif
