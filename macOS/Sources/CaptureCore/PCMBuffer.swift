import Foundation

/// Decoded, interleaved floating-point samples plus their source format.
///
/// This internal value keeps buffer ownership independent of CoreMedia after a
/// capture callback returns.
struct PCMBuffer {
    let samples: [Float]
    let frameCount: Int
    let channels: Int
    let format: StreamAudioFormat
}
