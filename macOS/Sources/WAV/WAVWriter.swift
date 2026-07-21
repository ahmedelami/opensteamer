import Foundation

/// Thread-safe writer for interleaved float samples stored as PCM16 RIFF/WAVE.
///
/// The lock owns the file handle, reusable conversion buffer, and counters. `start`,
/// append calls, and `finish` therefore form one serialized file lifecycle even if a
/// capture callback and teardown arrive on different queues.
public final class WAVWriter: @unchecked Sendable {
    private let url: URL
    private let sampleRate: Double
    private let channels: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    private var dataBytesWritten: UInt64 = 0
    private var framesWritten: Int64 = 0
    private var conversionBuffer = Data()

    /// Creates a writer configuration without touching the destination file.
    public init(url: URL, sampleRate: Double, channels: Int) {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// Creates/truncates the destination and writes a placeholder RIFF header.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        self.handle = handle
        try handle.write(contentsOf: WAVHeader.make(sampleRate: sampleRate, channels: channels, dataSize: 0))
    }

    /// Clips normalized float samples, converts them to little-endian PCM16, and appends.
    public func appendInterleavedFloat(_ samples: [Float]) throws {
        lock.lock()
        defer { lock.unlock() }

        let addedByteCount = UInt64(samples.count * MemoryLayout<Int16>.size)
        guard dataBytesWritten + addedByteCount <= UInt64(UInt32.max) else {
            throw WAVWriterError.fileTooLargeForPCM16WAV
        }

        conversionBuffer.removeAll(keepingCapacity: true)
        conversionBuffer.reserveCapacity(samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clipped = max(-1.0, min(1.0, sample))
            let value = Int16(clipped * Float(Int16.max))
            var littleEndian = value.littleEndian
            Swift.withUnsafeBytes(of: &littleEndian) { conversionBuffer.append(contentsOf: $0) }
        }

        guard let handle else {
            throw WAVWriterError.notStarted
        }
        try handle.write(contentsOf: conversionBuffer)
        dataBytesWritten += UInt64(conversionBuffer.count)
        if channels > 0 {
            framesWritten += Int64(samples.count / channels)
        }
    }

    /// Rewrites final chunk sizes, closes the file, and returns output counters.
    public func finish() throws -> WAVSummary {
        lock.lock()
        defer { lock.unlock() }

        guard let handle else {
            throw WAVWriterError.notStarted
        }

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WAVHeader.make(sampleRate: sampleRate, channels: channels, dataSize: UInt32(dataBytesWritten)))
        try handle.close()
        self.handle = nil

        return WAVSummary(url: url, framesWritten: framesWritten, bytesWritten: Int64(dataBytesWritten))
    }

    deinit {
        try? handle?.close()
    }
}

/// Final location and payload counts of a completed WAV file.
public struct WAVSummary: Sendable {
    public let url: URL
    public let framesWritten: Int64
    public let bytesWritten: Int64
}

/// Invalid writer lifecycle and RIFF size-limit failures.
public enum WAVWriterError: LocalizedError {
    case notStarted
    case fileTooLargeForPCM16WAV

    public var errorDescription: String? {
        switch self {
        case .notStarted:
            "WAVWriter was used before start()"
        case .fileTooLargeForPCM16WAV:
            "WAV data would exceed the 4 GB RIFF/WAVE limit"
        }
    }
}
