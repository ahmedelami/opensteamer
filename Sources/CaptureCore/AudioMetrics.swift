import Foundation

public struct AudioMetrics: Sendable {
    public let rms: Float
    public let peak: Float
    public let frameCount: Int
    public let channels: Int
}

public struct MetricSummary: Sendable {
    public private(set) var minimumRMS: Float?
    public private(set) var maximumRMS: Float?
    public private(set) var minimumPeak: Float?
    public private(set) var maximumPeak: Float?

    public init() {}

    public mutating func record(_ metrics: AudioMetrics) {
        minimumRMS = min(minimumRMS ?? metrics.rms, metrics.rms)
        maximumRMS = max(maximumRMS ?? metrics.rms, metrics.rms)
        minimumPeak = min(minimumPeak ?? metrics.peak, metrics.peak)
        maximumPeak = max(maximumPeak ?? metrics.peak, metrics.peak)
    }
}
