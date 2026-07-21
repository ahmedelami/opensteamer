import Foundation

/// Final measurements and output location for a file-backed capture session.
public struct CaptureReport: Sendable {
    public var duration: TimeInterval
    public var outputURL: URL
    public var streamFormat: StreamAudioFormat?
    public var callbackStatistics: CallbackStatistics
    public var metricSummary: MetricSummary
    public var framesWritten: Int64
    public var bytesWritten: Int64

    /// Renders a stable, human-readable summary for command-line diagnostics.
    public func render() -> String {
        var lines: [String] = []
        lines.append("")
        lines.append("Capture report")
        lines.append("--------------")
        lines.append("Duration: \(String(format: "%.2f", duration)) s")
        lines.append("WAV path: \(outputURL.path)")
        lines.append("Frames written: \(framesWritten)")
        lines.append("Bytes written: \(bytesWritten)")

        if let streamFormat {
            lines.append("Sample rate: \(String(format: "%.1f", streamFormat.sampleRate)) Hz")
            lines.append("Channels: \(streamFormat.channelCount)")
            lines.append("Format flags: \(streamFormat.formatFlags)")
            lines.append("Bits/channel: \(streamFormat.bitsPerChannel)")
            lines.append("Interleaved: \(streamFormat.isInterleaved ? "yes" : "no")")
            lines.append("Float: \(streamFormat.isFloat ? "yes" : "no")")
        } else {
            lines.append("Stream format: unavailable")
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
