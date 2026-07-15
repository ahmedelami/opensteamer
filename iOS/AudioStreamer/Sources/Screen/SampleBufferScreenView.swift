import AVFoundation
import SwiftUI
import UIKit

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
        coordinator.renderer.detach(
            from: uiView.sampleBufferDisplayLayer.sampleBufferRenderer,
            removeImage: true
        )
    }
}
