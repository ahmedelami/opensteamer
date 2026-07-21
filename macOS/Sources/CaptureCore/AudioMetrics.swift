import Foundation

/// Level measurements calculated for one decoded PCM buffer.
///
/// RMS describes average signal energy and `peak` records the largest absolute
/// sample. Both values use normalized floating-point PCM units.
public struct AudioMetrics: Sendable {
    public let rms: Float
    public let peak: Float
    public let frameCount: Int
    public let channels: Int
}

/// Accumulates the observed range of audio levels for a capture session.
public struct MetricSummary: Sendable {
    public private(set) var minimumRMS: Float?
    public private(set) var maximumRMS: Float?
    public private(set) var minimumPeak: Float?
    public private(set) var maximumPeak: Float?

    /// Creates an empty summary whose bounds become available after the first sample.
    public init() {}

    /// Expands every stored bound to include `metrics`.
    public mutating func record(_ metrics: AudioMetrics) {
        minimumRMS = min(minimumRMS ?? metrics.rms, metrics.rms)
        maximumRMS = max(maximumRMS ?? metrics.rms, metrics.rms)
        minimumPeak = min(minimumPeak ?? metrics.peak, metrics.peak)
        maximumPeak = max(maximumPeak ?? metrics.peak, metrics.peak)
    }
}
