import AVFoundation
import SwiftUI
import UIKit

/// UIKit host whose backing layer is AVFoundation's low-latency sample-buffer display layer.
/// A custom layer class is required here because SwiftUI has no equivalent renderer surface.
final class SampleBufferDisplayView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        sampleBufferDisplayLayer.backgroundColor = UIColor.black.cgColor
        sampleBufferDisplayLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// Narrow SwiftUI/UIKit bridge that attaches a `ScreenVideoRenderer` to a display layer.
/// The coordinator retains the exact renderer used during creation so teardown cannot detach a
/// replacement renderer supplied by a later SwiftUI update.
struct SampleBufferScreenView: UIViewRepresentable {
    let renderer: ScreenVideoRenderer

    final class Coordinator {
        let renderer: ScreenVideoRenderer

        init(renderer: ScreenVideoRenderer) {
            self.renderer = renderer
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer)
    }

    func makeUIView(context: Context) -> SampleBufferDisplayView {
        let view = SampleBufferDisplayView()
        context.coordinator.renderer.attach(
            to: view.sampleBufferDisplayLayer.sampleBufferRenderer
        )
        return view
    }

    func updateUIView(_ uiView: SampleBufferDisplayView, context: Context) {}

    static func dismantleUIView(_ uiView: SampleBufferDisplayView, coordinator: Coordinator) {
        // Detach before UIKit releases the layer; queued decoder output must not target a dead UI.
        coordinator.renderer.detach(
            from: uiView.sampleBufferDisplayLayer.sampleBufferRenderer,
            removeImage: true
        )
    }
}
