import Foundation

/// Final counters and timing measurements for a live PCM streaming session.
public struct StreamingCaptureReport: Sendable {
    public let duration: TimeInterval
    public let streamFormat: StreamAudioFormat?
    public let callbackStatistics: CallbackStatistics
    public let metricSummary: MetricSummary
    public let framesStreamed: Int64
    public let bytesStreamed: Int64
    public let packetsStreamed: Int64

    /// Renders a human-readable operational summary without serializing payload data.
    public func render() -> String {
        var lines: [String] = []
        lines.append("")
        lines.append("Streaming capture report")
        lines.append("------------------------")
        lines.append("Duration: \(String(format: "%.2f", duration)) s")
        lines.append("Frames streamed: \(framesStreamed)")
        lines.append("Packets streamed: \(packetsStreamed)")
        lines.append("Bytes streamed: \(bytesStreamed)")

        if let streamFormat {
            lines.append("Sample rate: \(String(format: "%.1f", streamFormat.sampleRate)) Hz")
            lines.append("Channels: \(streamFormat.channelCount)")
            lines.append("Float: \(streamFormat.isFloat ? "yes" : "no")")
            lines.append("Interleaved: \(streamFormat.isInterleaved ? "yes" : "no")")
        }

        lines.append("Callbacks: \(callbackStatistics.count)")
        lines.append("Average callback interval: \(String(format: "%.4f", callbackStatistics.averageInterval)) s")
        lines.append("Min callback interval: \(String(format: "%.4f", callbackStatistics.minimumInterval ?? 0)) s")
        lines.append("Max callback interval: \(String(format: "%.4f", callbackStatistics.maximumInterval ?? 0)) s")
        if let presentationSpan = callbackStatistics.presentationSpan {
            lines.append("Presentation timestamp span: \(String(format: "%.4f", presentationSpan)) s")
        }
        lines.append("RMS range: \(String(format: "%.5f", metricSummary.minimumRMS ?? 0)) ... \(String(format: "%.5f", metricSummary.maximumRMS ?? 0))")
        lines.append("Peak range: \(String(format: "%.5f", metricSummary.minimumPeak ?? 0)) ... \(String(format: "%.5f", metricSummary.maximumPeak ?? 0))")
        return lines.joined(separator: "\n")
    }
}
