import Foundation

public struct LevelSnapshot {
    public let rmsDBFS: Double
    public let peakDBFS: Double
    public let frames: UInt64
    public let age: TimeInterval
}

/// Late callbacks from a disposed capture cannot repopulate a newer route's meter.
public final class LevelAccumulator {
    private let lock = NSLock()
    private var generation: UUID?
    private var sumSquares = 0.0
    private var sampleCount = 0
    private var peak = 0.0
    private var frames: UInt64 = 0
    private var lastSampleAt: TimeInterval?

    public init() {}

    public func reset(to generation: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.generation = generation
        sumSquares = 0; sampleCount = 0; peak = 0; frames = 0; lastSampleAt = nil
    }

    public func add(_ samples: UnsafeBufferPointer<Float>, frames: UInt32,
                    generation: UUID, now: TimeInterval) {
        var sum = 0.0
        var maximum = 0.0
        for sample in samples {
            guard sample.isFinite else { return }
            let value = Double(sample)
            sum += value * value
            maximum = max(maximum, abs(value))
        }
        guard lock.try() else { return }
        defer { lock.unlock() }
        guard self.generation == generation else { return }
        sumSquares += sum; sampleCount += samples.count
        peak = max(peak, maximum); self.frames += UInt64(frames); lastSampleAt = now
    }

    public func snapshotAndReset(now: TimeInterval) -> LevelSnapshot? {
        lock.lock(); defer { lock.unlock() }
        defer { sumSquares = 0; sampleCount = 0; peak = 0; frames = 0 }
        guard generation != nil, sampleCount > 0, let lastSampleAt,
              now >= lastSampleAt, now - lastSampleAt <= 2 else { return nil }
        return LevelSnapshot(
            rmsDBFS: 20 * log10(max(sqrt(sumSquares / Double(sampleCount)), 1e-12)),
            peakDBFS: 20 * log10(max(peak, 1e-12)), frames: frames,
            age: now - lastSampleAt
        )
    }
}
