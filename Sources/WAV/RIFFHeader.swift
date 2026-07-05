import Foundation

enum WAVHeader {
    static func make(sampleRate: Double, channels: Int, dataSize: UInt32) -> Data {
        let bitsPerSample: UInt16 = 16
        let channelCount = UInt16(channels)
        let sampleRateUInt = UInt32(sampleRate.rounded())
        let byteRate = sampleRateUInt * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let blockAlign = channelCount * (bitsPerSample / 8)
        let riffSize = UInt32(36) + dataSize

        var data = Data()
        data.appendASCII("RIFF")
        data.appendLE(riffSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(channelCount)
        data.appendLE(sampleRateUInt)
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(bitsPerSample)
        data.appendASCII("data")
        data.appendLE(dataSize)
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ text: String) {
        append(contentsOf: text.utf8)
    }

    mutating func appendLE(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
