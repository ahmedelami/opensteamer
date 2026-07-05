import Foundation

public struct PCM16Converter {
    private var bytes = Data()

    public init() {}

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
