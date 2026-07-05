import Foundation

struct PCMBuffer {
    let samples: [Float]
    let frameCount: Int
    let channels: Int
    let format: StreamAudioFormat
}
