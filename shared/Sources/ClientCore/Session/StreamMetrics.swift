import Foundation

public struct StreamMetrics: Sendable, Equatable {
    public let packetsReceived: UInt64
    public let sequenceErrors: UInt64
    public let timestampErrors: UInt64
    public let framingErrors: UInt64
    public let queueDepthFrames: Int
    public let underruns: UInt64
    public let droppedFrames: UInt64
    public let bytesReceived: UInt64
    public let latencyEstimate: TimeInterval
    public let networkJitterEstimate: TimeInterval
    public let audioRMS: Float
    public let audioPeak: Float
    public let playbackRMS: Float
    public let playbackPeak: Float

    public init(
        packetsReceived: UInt64 = 0,
        sequenceErrors: UInt64 = 0,
        timestampErrors: UInt64 = 0,
        framingErrors: UInt64 = 0,
        queueDepthFrames: Int = 0,
        underruns: UInt64 = 0,
        droppedFrames: UInt64 = 0,
        bytesReceived: UInt64 = 0,
        latencyEstimate: TimeInterval = 0,
        networkJitterEstimate: TimeInterval = 0,
        audioRMS: Float = 0,
        audioPeak: Float = 0,
        playbackRMS: Float = 0,
        playbackPeak: Float = 0
    ) {
        self.packetsReceived = packetsReceived
        self.sequenceErrors = sequenceErrors
        self.timestampErrors = timestampErrors
        self.framingErrors = framingErrors
        self.queueDepthFrames = queueDepthFrames
        self.underruns = underruns
        self.droppedFrames = droppedFrames
        self.bytesReceived = bytesReceived
        self.latencyEstimate = latencyEstimate
        self.networkJitterEstimate = networkJitterEstimate
        self.audioRMS = audioRMS
        self.audioPeak = audioPeak
        self.playbackRMS = playbackRMS
        self.playbackPeak = playbackPeak
    }
}
