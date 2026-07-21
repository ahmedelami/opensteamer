import Foundation

/// Converts normalized interleaved floating-point samples to signed 16-bit little-endian PCM.
public struct PCM16Converter {
    private var bytes = Data()

    public init() {}

    /// Clips each sample to the representable range and reuses internal storage across calls.
    public mutating func convertInterleavedFloat(_ samples: [Float]) -> Data {
        bytes.removeAll(keepingCapacity: true)
        bytes.reserveCapacity(samples.count * MemoryLayout<Int16>.size)

        for sample in samples {
            let clipped = max(-1.0, min(1.0, sample))
            let value = Int16(clipped * Float(Int16.max))
            var little = value.littleEndian
            Swift.withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }

        return bytes
    }
}
