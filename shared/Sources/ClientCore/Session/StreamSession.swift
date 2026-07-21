import Foundation
import Network
import Streaming
import Utilities

/// Coordinates one legacy PCM connection, jitter buffer, and audio renderer.
///
/// State snapshots and renderer ownership use separate locks because the network receive loop and
/// app lifecycle callbacks may access them from different executors.
public final class StreamSession: @unchecked Sendable {
    private let snapshotLock = NSLock()
    private let rendererLock = NSLock()
    private var storedState: StreamState = .idle
    private var storedMetrics = StreamMetrics()
    private let readerQueue = DispatchQueue(label: "MacCaptureVerifier.ClientCore.StreamSession.reader")
    private var currentReader: (any StreamPacketReading)?
    private var currentRenderer: AudioRenderer?

    public init() {}

    /// The most recently published connection or playback state.
    public var state: StreamState {
        snapshotLock.withLock {
            storedState
        }
    }

    /// The most recently published stream metrics.
    public var metrics: StreamMetrics {
        snapshot()
    }

    /// Returns a lock-consistent metrics snapshot.
    public func snapshot() -> StreamMetrics {
        snapshotLock.withLock {
            storedMetrics
        }
    }

    /// Cancels the active packet reader, causing the receive loop to unwind.
    public func disconnect() {
        let reader = readerQueue.sync {
            let reader = currentReader
            currentReader = nil
            return reader
        }
        reader?.cancel()
    }

    /// Pauses audio output without terminating the network session.
    public func pauseRendering() {
        let renderer = rendererLock.withLock { currentRenderer }
        renderer?.pause()
    }

    /// Resumes the existing output graph after a temporary interruption.
    public func resumeRendering() throws {
        let renderer = rendererLock.withLock { currentRenderer }
        try renderer?.start()
    }

    /// Rebuilds the output graph after an audio route or media-services reset.
    public func restartRendering() throws {
        let renderer = rendererLock.withLock { currentRenderer }
        try renderer?.restart()
    }

    /// A stable diagnostic description of the current renderer lifecycle.
    public var rendererStateDescription: String {
        let renderer = rendererLock.withLock { currentRenderer }
        return renderer?.stateDescription ?? "Unavailable"
    }

    /// Runs a TCP stream until its duration or packet limit is reached.
    public func run(
        host: String,
        port: UInt16,
        authToken: String? = nil,
        duration: TimeInterval?,
        latencyMilliseconds: Double,
        maxPackets: Int?
    ) async throws -> StreamSessionReport {
        let reader = try PacketReader(host: host, port: port, authToken: authToken)
        return try await run(
            reader: reader,
            duration: duration,
            latencyMilliseconds: latencyMilliseconds,
            maxPackets: maxPackets
        )
    }

    /// Runs a stream from an already-discovered Network framework endpoint.
    public func run(
        endpoint: NWEndpoint,
        authToken: String? = nil,
        duration: TimeInterval?,
        latencyMilliseconds: Double,
        maxPackets: Int?
    ) async throws -> StreamSessionReport {
        let reader = PacketReader(endpoint: endpoint, authToken: authToken)
        return try await run(
            reader: reader,
            duration: duration,
            latencyMilliseconds: latencyMilliseconds,
            maxPackets: maxPackets
        )
    }

    /// Runs a WebSocket-carried legacy PCM stream.
    public func run(
        webSocketURL: URL,
        authToken: String? = nil,
        duration: TimeInterval?,
        latencyMilliseconds: Double,
        maxPackets: Int?
    ) async throws -> StreamSessionReport {
        let reader = WebSocketPacketReader(url: webSocketURL, authToken: authToken)
        return try await run(
            reader: reader,
            duration: duration,
            latencyMilliseconds: latencyMilliseconds,
            maxPackets: maxPackets
        )
    }

    private func run(
        reader: any StreamPacketReading,
        duration: TimeInterval?,
        latencyMilliseconds: Double,
        maxPackets: Int?
    ) async throws -> StreamSessionReport {
        updateState(.connecting)
        readerQueue.sync {
            currentReader = reader
        }

        do {
            try await reader.start()
            try await reader.authenticateIfNeeded()
            defer {
                reader.cancel()
                readerQueue.sync {
                    if currentReader === reader {
                        currentReader = nil
                    }
                }
                updateState(.disconnected)
            }

            let startedAt = Date()
            let header = try await reader.readHeader()
            let sampleRate = Double(header.sampleRate)
            let targetFrames = max(1, Int(sampleRate * latencyMilliseconds / 1_000))
            let jitterBuffer = PCMJitterBuffer(
                channels: Int(header.channels),
                sampleRate: sampleRate,
                capacityFrames: Int(sampleRate * 2)
            )
            let renderer = try AudioRenderer(header: header, provider: jitterBuffer)
            rendererLock.withLock {
                currentRenderer = renderer
            }
            defer {
                rendererLock.withLock {
                    if currentRenderer === renderer {
                        currentRenderer = nil
                    }
                }
                renderer.stop()
            }

            updateState(.buffering(bufferedFrames: 0, targetFrames: targetFrames))
            // Starting now lets iOS keep the playback session active while the jitter target fills.
            try renderer.start()
            let rendererStarted = true
            var playbackMarkedPlaying = false
            var lastSequence: UInt32?
            var lastTimestamp: UInt64?
            var lastArrivalNanoseconds: UInt64?
            var networkJitterEstimate: TimeInterval = 0
            var packets: UInt64 = 0
            var bytes: UInt64 = 0
            var sequenceErrors: UInt64 = 0
            var timestampErrors: UInt64 = 0
            var audioRMS: Float = 0
            var audioPeak: Float = 0

            while !Task.isCancelled {
                if let duration, Date().timeIntervalSince(startedAt) >= duration {
                    break
                }

                if let maxPackets, packets >= UInt64(maxPackets) {
                    break
                }

                let frame = try await reader.readFrame(header: header)
                let arrivalNanoseconds = DispatchTime.now().uptimeNanoseconds
                let audioLevel = Self.audioLevel(pcm16LE: frame.pcmBytes)
                audioRMS = audioLevel.rms
                audioPeak = audioLevel.peak
                _ = jitterBuffer.appendPCM16LE(frame.pcmBytes)

                if let lastSequence, frame.metadata.sequence != lastSequence &+ 1 {
                    sequenceErrors += 1
                }

                if let lastTimestamp, frame.metadata.presentationTimestampNanoseconds < lastTimestamp {
                    timestampErrors += 1
                }

                if let lastArrivalNanoseconds,
                   let lastTimestamp,
                   arrivalNanoseconds >= lastArrivalNanoseconds,
                   frame.metadata.presentationTimestampNanoseconds >= lastTimestamp {
                    let arrivalDelta = arrivalNanoseconds - lastArrivalNanoseconds
                    let presentationDelta = frame.metadata.presentationTimestampNanoseconds - lastTimestamp
                    let jitterNanoseconds = arrivalDelta > presentationDelta
                        ? arrivalDelta - presentationDelta
                        : presentationDelta - arrivalDelta
                    let jitterSeconds = Double(jitterNanoseconds) / 1_000_000_000
                    networkJitterEstimate = packets <= 1
                        ? jitterSeconds
                        : (networkJitterEstimate * 0.9) + (jitterSeconds * 0.1)
                }

                if !playbackMarkedPlaying, jitterBuffer.bufferedFrames >= targetFrames {
                    updateState(.playing)
                    playbackMarkedPlaying = true
                } else if !playbackMarkedPlaying {
                    updateState(.buffering(
                        bufferedFrames: jitterBuffer.bufferedFrames,
                        targetFrames: targetFrames
                    ))
                }

                lastSequence = frame.metadata.sequence
                lastTimestamp = frame.metadata.presentationTimestampNanoseconds
                lastArrivalNanoseconds = arrivalNanoseconds
                packets += 1
                bytes += UInt64(frame.packetLength)
                let playbackLevel = jitterBuffer.renderLevel
                updateMetrics(StreamMetrics(
                    packetsReceived: packets,
                    sequenceErrors: sequenceErrors,
                    timestampErrors: timestampErrors,
                    queueDepthFrames: jitterBuffer.bufferedFrames,
                    underruns: UInt64(jitterBuffer.underrunFrames),
                    droppedFrames: UInt64(jitterBuffer.droppedFrames),
                    bytesReceived: bytes,
                    latencyEstimate: jitterBuffer.bufferedDuration,
                    networkJitterEstimate: networkJitterEstimate,
                    audioRMS: audioRMS,
                    audioPeak: audioPeak,
                    playbackRMS: playbackLevel.rms,
                    playbackPeak: playbackLevel.peak
                ))
            }

            if !playbackMarkedPlaying, jitterBuffer.bufferedFrames > 0 {
                updateState(.playing)
            }

            let playbackLevel = jitterBuffer.renderLevel
            updateMetrics(StreamMetrics(
                packetsReceived: packets,
                sequenceErrors: sequenceErrors,
                timestampErrors: timestampErrors,
                queueDepthFrames: jitterBuffer.bufferedFrames,
                underruns: UInt64(jitterBuffer.underrunFrames),
                droppedFrames: UInt64(jitterBuffer.droppedFrames),
                bytesReceived: bytes,
                latencyEstimate: jitterBuffer.bufferedDuration,
                networkJitterEstimate: networkJitterEstimate,
                audioRMS: audioRMS,
                audioPeak: audioPeak,
                playbackRMS: playbackLevel.rms,
                playbackPeak: playbackLevel.peak
            ))

            return StreamSessionReport(
                sampleRate: header.sampleRate,
                channels: header.channels,
                duration: Date().timeIntervalSince(startedAt),
                rendererStarted: rendererStarted,
                metrics: metrics
            )
        } catch {
            updateState(.failed(error.localizedDescription))
            throw error
        }
    }

    private func updateState(_ state: StreamState) {
        snapshotLock.withLock {
            storedState = state
        }
    }

    private func updateMetrics(_ metrics: StreamMetrics) {
        snapshotLock.withLock {
            storedMetrics = metrics
        }
    }

    private static func audioLevel(pcm16LE data: Data) -> (rms: Float, peak: Float) {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return (0, 0) }

        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var sumSquares = 0.0
            var peak: Float = 0

            for sampleIndex in 0..<sampleCount {
                let byteOffset = sampleIndex * 2
                let raw = UInt16(bytes[byteOffset]) | (UInt16(bytes[byteOffset + 1]) << 8)
                let value = Int16(bitPattern: raw)
                let normalized = Float(value) / 32_768
                let absolute = abs(normalized)
                peak = max(peak, absolute)
                sumSquares += Double(normalized * normalized)
            }

            return (Float(sqrt(sumSquares / Double(sampleCount))), peak)
        }
    }
}

/// The common packet-source contract used to keep session accounting transport-independent.
private protocol StreamPacketReading: AnyObject, Sendable {
    func start() async throws
    func cancel()
    func authenticateIfNeeded() async throws
    func readHeader() async throws -> PCMStreamHeader
    func readFrame(header: PCMStreamHeader) async throws -> PCMFrame
}

extension PacketReader: StreamPacketReading {}
extension WebSocketPacketReader: StreamPacketReading {}

/// Immutable results from a completed legacy PCM validation session.
public struct StreamSessionReport: Sendable {
    public let sampleRate: UInt32
    public let channels: UInt16
    public let duration: TimeInterval
    public let rendererStarted: Bool
    public let metrics: StreamMetrics

    /// Formats the report for command-line diagnostics.
    public func render() -> String {
        var lines: [String] = []
        lines.append("PCM player report")
        lines.append("-----------------")
        lines.append("Sample rate: \(sampleRate)")
        lines.append("Channels: \(channels)")
        lines.append("Packets: \(metrics.packetsReceived)")
        lines.append("Bytes: \(metrics.bytesReceived)")
        lines.append("Duration: \(String(format: "%.2f", duration)) s")
        lines.append("Approx throughput: \(String(format: "%.0f", Double(metrics.bytesReceived) / max(duration, 0.001))) bytes/s")
        lines.append("Renderer started: \(rendererStarted ? "yes" : "no")")
        lines.append("Receive RMS: \(String(format: "%.5f", metrics.audioRMS))")
        lines.append("Receive peak: \(String(format: "%.5f", metrics.audioPeak))")
        lines.append("Playback RMS: \(String(format: "%.5f", metrics.playbackRMS))")
        lines.append("Playback peak: \(String(format: "%.5f", metrics.playbackPeak))")
        lines.append("Buffered frames: \(metrics.queueDepthFrames)")
        lines.append("Latency estimate: \(String(format: "%.3f", metrics.latencyEstimate)) s")
        lines.append("Network jitter estimate: \(String(format: "%.3f", metrics.networkJitterEstimate)) s")
        lines.append("Dropped frames: \(metrics.droppedFrames)")
        lines.append("Underrun frames: \(metrics.underruns)")
        lines.append("Framing errors: \(metrics.framingErrors)")
        lines.append("Sequence errors: \(metrics.sequenceErrors)")
        lines.append("Timestamp errors: \(metrics.timestampErrors)")
        return lines.joined(separator: "\n")
    }
}
