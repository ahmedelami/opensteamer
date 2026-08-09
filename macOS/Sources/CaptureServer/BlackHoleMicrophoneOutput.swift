import AudioToolbox
import CaptureCore
import Darwin
import Dispatch
import Foundation
import MacWebRTCAudioDeviceShim
import WebRTCTransport

struct BlackHoleMicrophoneOutputPCMChannelContentSnapshot:
    Equatable,
    Sendable
{
    let rms: Double
    let rmsDBFS: Double
    let peak: Double
    let peakDBFS: Double
    let dc: Double
    let zeroFraction: Double
    let clippingFraction: Double

    static let zero = Self(
        rms: 0,
        rmsDBFS: -160,
        peak: 0,
        peakDBFS: -160,
        dc: 0,
        zeroFraction: 0,
        clippingFraction: 0
    )
}

struct BlackHoleMicrophoneOutputPCMContentSnapshot:
    Equatable,
    Sendable
{
    static let minimumDBFS = -160.0

    let lifecycleGeneration: UInt64
    let windowSequence: UInt64
    let completedFrameCount: UInt64
    let sourceStartFrame: UInt64
    let sourceEndFrame: UInt64
    let windowFrameCount: UInt64
    /// Non-reversible process-local comparison evidence. Never log this value.
    let windowFingerprint: UInt64
    let left: BlackHoleMicrophoneOutputPCMChannelContentSnapshot
    let right: BlackHoleMicrophoneOutputPCMChannelContentSnapshot
    let leftRightCorrelationIsValid: Bool
    let leftRightCorrelation: Double
    let sumPower: Double
    let differencePower: Double
    let oneSidedFraction: Double

    var completedWindowCount: UInt64 { windowSequence }

    static let zero = Self(
        lifecycleGeneration: 0,
        windowSequence: 0,
        completedFrameCount: 0,
        sourceStartFrame: 0,
        sourceEndFrame: 0,
        windowFrameCount: 0,
        windowFingerprint: 0,
        left: .zero,
        right: .zero,
        leftRightCorrelationIsValid: false,
        leftRightCorrelation: 0,
        sumPower: 0,
        differencePower: 0,
        oneSidedFraction: 0
    )

    init(
        lifecycleGeneration: UInt64,
        windowSequence: UInt64,
        completedFrameCount: UInt64,
        sourceStartFrame: UInt64,
        sourceEndFrame: UInt64,
        windowFrameCount: UInt64,
        windowFingerprint: UInt64,
        left: BlackHoleMicrophoneOutputPCMChannelContentSnapshot,
        right: BlackHoleMicrophoneOutputPCMChannelContentSnapshot,
        leftRightCorrelationIsValid: Bool,
        leftRightCorrelation: Double,
        sumPower: Double,
        differencePower: Double,
        oneSidedFraction: Double
    ) {
        self.lifecycleGeneration = lifecycleGeneration
        self.windowSequence = windowSequence
        self.completedFrameCount = completedFrameCount
        self.sourceStartFrame = sourceStartFrame
        self.sourceEndFrame = sourceEndFrame
        self.windowFrameCount = windowFrameCount
        self.windowFingerprint = windowFingerprint
        self.left = left
        self.right = right
        self.leftRightCorrelationIsValid =
            leftRightCorrelationIsValid
        self.leftRightCorrelation = leftRightCorrelation
        self.sumPower = sumPower
        self.differencePower = differencePower
        self.oneSidedFraction = oneSidedFraction
    }

    fileprivate init(
        lifecycleGeneration: UInt64,
        windowSequence: UInt64,
        completedFrameCount: UInt64,
        raw: BlackHoleMicrophoneOutputPCMContentRawWindow
    ) {
        let frameCount = Double(raw.frameCount)
        guard frameCount > 0 else {
            self = .zero
            return
        }

        let fullScale = 32_768.0
        let fullScalePower = fullScale * fullScale
        let leftRMS = sqrt(
            Double(raw.leftSquareSum) / frameCount
        ) / fullScale
        let rightRMS = sqrt(
            Double(raw.rightSquareSum) / frameCount
        ) / fullScale
        let leftPeak = Double(raw.leftPeak) / fullScale
        let rightPeak = Double(raw.rightPeak) / fullScale
        let leftSum = Double(raw.leftSampleSum)
        let rightSum = Double(raw.rightSampleSum)
        let centeredLeftPower = max(
            0,
            Double(raw.leftSquareSum) - leftSum * leftSum / frameCount
        )
        let centeredRightPower = max(
            0,
            Double(raw.rightSquareSum) - rightSum * rightSum / frameCount
        )
        let centeredCrossPower =
            Double(raw.leftRightProductSum)
            - leftSum * rightSum / frameCount
        let correlationDenominator =
            sqrt(centeredLeftPower) * sqrt(centeredRightPower)
        let correlation = correlationDenominator > 0
            ? Self.clampedCorrelation(
                centeredCrossPower / correlationDenominator
            )
            : 0

        self.lifecycleGeneration = lifecycleGeneration
        self.windowSequence = windowSequence
        self.completedFrameCount = completedFrameCount
        sourceStartFrame = raw.sourceStartFrame
        sourceEndFrame = raw.sourceEndFrame
        windowFrameCount = raw.frameCount
        windowFingerprint = raw.windowFingerprint
        left = Self.channelSnapshot(
            rms: leftRMS,
            peak: leftPeak,
            sampleSum: raw.leftSampleSum,
            zeroCount: raw.leftZeroCount,
            clippingCount: raw.leftClippingCount,
            frameCount: frameCount,
            fullScale: fullScale
        )
        right = Self.channelSnapshot(
            rms: rightRMS,
            peak: rightPeak,
            sampleSum: raw.rightSampleSum,
            zeroCount: raw.rightZeroCount,
            clippingCount: raw.rightClippingCount,
            frameCount: frameCount,
            fullScale: fullScale
        )
        leftRightCorrelationIsValid = correlationDenominator > 0
        leftRightCorrelation = correlation
        sumPower = Double(raw.sumSquareSum)
            / (4 * frameCount * fullScalePower)
        differencePower = Double(raw.differenceSquareSum)
            / (4 * frameCount * fullScalePower)
        oneSidedFraction = Double(raw.oneSidedFrameCount)
            / frameCount
    }

    private static func channelSnapshot(
        rms: Double,
        peak: Double,
        sampleSum: Int64,
        zeroCount: UInt64,
        clippingCount: UInt64,
        frameCount: Double,
        fullScale: Double
    ) -> BlackHoleMicrophoneOutputPCMChannelContentSnapshot {
        BlackHoleMicrophoneOutputPCMChannelContentSnapshot(
            rms: rms,
            rmsDBFS: decibelsFullScale(rms),
            peak: peak,
            peakDBFS: decibelsFullScale(peak),
            dc: Double(sampleSum) / (frameCount * fullScale),
            zeroFraction: Double(zeroCount) / frameCount,
            clippingFraction: Double(clippingCount) / frameCount
        )
    }

    private static func decibelsFullScale(
        _ amplitude: Double
    ) -> Double {
        guard amplitude > 0 else { return minimumDBFS }
        return max(
            minimumDBFS,
            min(0, 20 * log10(amplitude))
        )
    }

    private static func clampedCorrelation(
        _ value: Double
    ) -> Double {
        max(-1, min(1, value))
    }
}

struct BlackHoleMicrophoneOutputDecodedContentSnapshot:
    Equatable,
    Sendable
{
    let playoutGeneration: UInt64
    let renderCallCount: UInt64
    let nativeSuccessRenderCallCount: UInt64
    let nativeFailureRenderCallCount: UInt64
    let exactBufferContractCount: UInt64
    let bufferContractMismatchCount: UInt64
    let analyzedFrameCount: UInt64
    let droppedTelemetryRenderCallCount: UInt64
    let pendingWindowFrameCount: UInt64
    let latestRenderCall: UInt64
    let latestRenderStatus: OSStatus
    let latestBufferContractWasExact: Bool
    let hasCompletedWindow: Bool
    let windowSequence: UInt64
    let windowGeneration: UInt64
    let windowFirstRenderCall: UInt64
    let windowLastRenderCall: UInt64
    let windowRenderCallCount: UInt64
    let windowFrameCount: UInt64
    let windowSourceStartFrame: UInt64
    let windowSourceEndFrame: UInt64
    /// Non-reversible process-local comparison evidence. Never log this value.
    let windowFingerprint: UInt64
    let left: BlackHoleMicrophoneOutputPCMChannelContentSnapshot
    let right: BlackHoleMicrophoneOutputPCMChannelContentSnapshot
    let leftRightCorrelationIsValid: Bool
    let leftRightCorrelation: Double
    let sumPower: Double
    let differencePower: Double
    let oneSidedFraction: Double
    let windowIsAllZero: Bool
    let windowIsLeftOnly: Bool
    let windowIsRightOnly: Bool
    let frozenBlockCount: UInt64
    let longestFrozenBlockRun: UInt64

    static let zero = Self(ASMacDecodedPlayoutTelemetrySnapshot())

    init(_ native: ASMacDecodedPlayoutTelemetrySnapshot) {
        playoutGeneration = native.playoutGeneration
        renderCallCount = native.renderCallCount
        nativeSuccessRenderCallCount =
            native.nativeSuccessRenderCallCount
        nativeFailureRenderCallCount =
            native.nativeFailureRenderCallCount
        exactBufferContractCount = native.exactBufferContractCount
        bufferContractMismatchCount =
            native.bufferContractMismatchCount
        analyzedFrameCount = native.analyzedFrameCount
        droppedTelemetryRenderCallCount =
            native.droppedTelemetryRenderCallCount
        pendingWindowFrameCount = native.pendingWindowFrameCount
        latestRenderCall = native.latestRenderCall
        latestRenderStatus = native.latestRenderStatus
        latestBufferContractWasExact =
            native.latestBufferContractWasExact
        hasCompletedWindow = native.hasCompletedWindow
        windowSequence = native.completedWindowSequence
        windowGeneration = native.completedWindowGeneration
        windowFirstRenderCall = native.completedWindowFirstRenderCall
        windowLastRenderCall = native.completedWindowLastRenderCall
        windowRenderCallCount = native.completedWindowRenderCallCount
        windowFrameCount = native.completedWindowFrameCount
        windowSourceStartFrame = native.completedWindowSourceStartFrame
        windowSourceEndFrame = native.completedWindowSourceEndFrame
        windowFingerprint = native.completedWindowFingerprint
        if native.hasCompletedWindow {
            left = Self.channelSnapshot(
                rms: native.leftRMS,
                rmsDBFS: Self.boundedDBFS(native.leftRMSDecibelsFS),
                peak: native.leftPeak,
                peakDBFS: Self.boundedDBFS(native.leftPeakDecibelsFS),
                dc: native.leftDC,
                zeroFraction: native.leftZeroFraction,
                clippingFraction: native.leftClippingFraction
            )
            right = Self.channelSnapshot(
                rms: native.rightRMS,
                rmsDBFS: Self.boundedDBFS(native.rightRMSDecibelsFS),
                peak: native.rightPeak,
                peakDBFS: Self.boundedDBFS(native.rightPeakDecibelsFS),
                dc: native.rightDC,
                zeroFraction: native.rightZeroFraction,
                clippingFraction: native.rightClippingFraction
            )
        } else {
            left = .zero
            right = .zero
        }
        leftRightCorrelationIsValid =
            native.leftRightCorrelationIsValid
        leftRightCorrelation = native.leftRightCorrelation
        sumPower = native.sumPower
        differencePower = native.differencePower
        oneSidedFraction = native.oneSidedFraction
        windowIsAllZero = native.windowIsAllZero
        windowIsLeftOnly = native.windowIsLeftOnly
        windowIsRightOnly = native.windowIsRightOnly
        frozenBlockCount = native.frozenBlockCount
        longestFrozenBlockRun = native.longestFrozenBlockRun
    }

    private static func channelSnapshot(
        rms: Double,
        rmsDBFS: Double,
        peak: Double,
        peakDBFS: Double,
        dc: Double,
        zeroFraction: Double,
        clippingFraction: Double
    ) -> BlackHoleMicrophoneOutputPCMChannelContentSnapshot {
        BlackHoleMicrophoneOutputPCMChannelContentSnapshot(
            rms: rms,
            rmsDBFS: rmsDBFS,
            peak: peak,
            peakDBFS: peakDBFS,
            dc: dc,
            zeroFraction: zeroFraction,
            clippingFraction: clippingFraction
        )
    }

    private static func boundedDBFS(_ value: Double) -> Double {
        guard value.isFinite else {
            return BlackHoleMicrophoneOutputPCMContentSnapshot.minimumDBFS
        }
        return max(
            BlackHoleMicrophoneOutputPCMContentSnapshot.minimumDBFS,
            min(0, value)
        )
    }
}

struct BlackHoleMicrophoneOutputProgressSnapshot:
    Equatable,
    Sendable
{
    let queueRunning: Bool
    let postStartCallbackCount: UInt64
    let requestedFrameCount: UInt64
    let successfulPullCount: UInt64
    let successfulFrameCount: UInt64
    let silenceFallbackCount: UInt64
    let silenceFrameCount: UInt64
    let enqueueFailureCount: UInt64
    let lastEnqueueStatus: OSStatus
    let pcmContent: BlackHoleMicrophoneOutputPCMContentSnapshot
    let decodedContent:
        BlackHoleMicrophoneOutputDecodedContentSnapshot
    let boundDecodedPlayoutGeneration: UInt64
    let boundDecodedRenderCallFloor: UInt64

    var contentWindowsAlign: Bool {
        let pcm = pcmContent
        let decoded = decodedContent
        return queueRunning
            && pcm.lifecycleGeneration > 0
            && pcm.windowSequence > 0
            && decoded.hasCompletedWindow
            && boundDecodedPlayoutGeneration > 0
            && decoded.playoutGeneration
                == boundDecodedPlayoutGeneration
            && decoded.windowGeneration == decoded.playoutGeneration
            && decoded.windowFirstRenderCall
                > boundDecodedRenderCallFloor
            && silenceFallbackCount == 0
            && enqueueFailureCount == 0
            && pcm.windowFrameCount == 48_000
            && decoded.windowFrameCount == pcm.windowFrameCount
            && pcm.sourceStartFrame == decoded.windowSourceStartFrame
            && pcm.sourceEndFrame == decoded.windowSourceEndFrame
    }

    var alignedContentFingerprintsMatch: Bool {
        contentWindowsAlign
            && pcmContent.windowFingerprint
                == decodedContent.windowFingerprint
    }

    init(
        queueRunning: Bool,
        postStartCallbackCount: UInt64,
        requestedFrameCount: UInt64,
        successfulPullCount: UInt64,
        successfulFrameCount: UInt64,
        silenceFallbackCount: UInt64,
        silenceFrameCount: UInt64,
        enqueueFailureCount: UInt64,
        lastEnqueueStatus: OSStatus,
        pcmContent: BlackHoleMicrophoneOutputPCMContentSnapshot = .zero,
        decodedContent:
            BlackHoleMicrophoneOutputDecodedContentSnapshot = .zero,
        boundDecodedPlayoutGeneration: UInt64 = 0,
        boundDecodedRenderCallFloor: UInt64 = 0
    ) {
        self.queueRunning = queueRunning
        self.postStartCallbackCount = postStartCallbackCount
        self.requestedFrameCount = requestedFrameCount
        self.successfulPullCount = successfulPullCount
        self.successfulFrameCount = successfulFrameCount
        self.silenceFallbackCount = silenceFallbackCount
        self.silenceFrameCount = silenceFrameCount
        self.enqueueFailureCount = enqueueFailureCount
        self.lastEnqueueStatus = lastEnqueueStatus
        self.pcmContent = pcmContent
        self.decodedContent = decodedContent
        self.boundDecodedPlayoutGeneration =
            boundDecodedPlayoutGeneration
        self.boundDecodedRenderCallFloor =
            boundDecodedRenderCallFloor
    }

    static let zero = Self(
        queueRunning: false,
        postStartCallbackCount: 0,
        requestedFrameCount: 0,
        successfulPullCount: 0,
        successfulFrameCount: 0,
        silenceFallbackCount: 0,
        silenceFrameCount: 0,
        enqueueFailureCount: 0,
        lastEnqueueStatus: noErr,
        pcmContent: .zero,
        decodedContent: .zero,
        boundDecodedPlayoutGeneration: 0,
        boundDecodedRenderCallFloor: 0
    )

    fileprivate func includingDecodedContent(
        _ decodedContent:
            BlackHoleMicrophoneOutputDecodedContentSnapshot,
        boundDecodedPlayoutGeneration: UInt64,
        boundDecodedRenderCallFloor: UInt64
    ) -> Self {
        Self(
            queueRunning: queueRunning,
            postStartCallbackCount: postStartCallbackCount,
            requestedFrameCount: requestedFrameCount,
            successfulPullCount: successfulPullCount,
            successfulFrameCount: successfulFrameCount,
            silenceFallbackCount: silenceFallbackCount,
            silenceFrameCount: silenceFrameCount,
            enqueueFailureCount: enqueueFailureCount,
            lastEnqueueStatus: lastEnqueueStatus,
            pcmContent: pcmContent,
            decodedContent: decodedContent,
            boundDecodedPlayoutGeneration:
                boundDecodedPlayoutGeneration,
            boundDecodedRenderCallFloor:
                boundDecodedRenderCallFloor
        )
    }
}

private struct BlackHoleMicrophoneOutputPCMContentRawWindow {
    static let fingerprintOffsetBasis: UInt64 =
        14_695_981_039_346_656_037
    static let fingerprintPrime: UInt64 = 1_099_511_628_211

    var sourceStartFrame: UInt64 = 0
    var sourceEndFrame: UInt64 = 0
    var frameCount: UInt64 = 0
    var leftSampleSum: Int64 = 0
    var rightSampleSum: Int64 = 0
    var leftSquareSum: UInt64 = 0
    var rightSquareSum: UInt64 = 0
    var leftRightProductSum: Int64 = 0
    var sumSquareSum: UInt64 = 0
    var differenceSquareSum: UInt64 = 0
    var leftPeak: UInt64 = 0
    var rightPeak: UInt64 = 0
    var leftZeroCount: UInt64 = 0
    var rightZeroCount: UInt64 = 0
    var leftClippingCount: UInt64 = 0
    var rightClippingCount: UInt64 = 0
    var oneSidedFrameCount: UInt64 = 0
    var windowFingerprint: UInt64 = fingerprintOffsetBasis
}

private final class BlackHoleMicrophoneOutputPCMContentStorage:
    @unchecked Sendable
{
    private let reference: ASMacAudioQueuePCMContentRef

    init?() {
        guard let reference = ASMacAudioQueuePCMContentCreate() else {
            return nil
        }
        self.reference = reference
    }

    deinit {
        ASMacAudioQueuePCMContentDestroy(reference)
    }

    func reset() {
        ASMacAudioQueuePCMContentReset(reference)
    }

    @inline(__always)
    func publish(
        _ window: BlackHoleMicrophoneOutputPCMContentRawWindow
    ) {
        var nativeWindow = ASMacAudioQueuePCMContentRawWindow()
        nativeWindow.sourceStartFrame = window.sourceStartFrame
        nativeWindow.sourceEndFrame = window.sourceEndFrame
        nativeWindow.frameCount = window.frameCount
        nativeWindow.leftSampleSum = window.leftSampleSum
        nativeWindow.rightSampleSum = window.rightSampleSum
        nativeWindow.leftSquareSum = window.leftSquareSum
        nativeWindow.rightSquareSum = window.rightSquareSum
        nativeWindow.leftRightProductSum = window.leftRightProductSum
        nativeWindow.sumSquareSum = window.sumSquareSum
        nativeWindow.differenceSquareSum = window.differenceSquareSum
        nativeWindow.leftPeak = window.leftPeak
        nativeWindow.rightPeak = window.rightPeak
        nativeWindow.leftZeroCount = window.leftZeroCount
        nativeWindow.rightZeroCount = window.rightZeroCount
        nativeWindow.leftClippingCount = window.leftClippingCount
        nativeWindow.rightClippingCount = window.rightClippingCount
        nativeWindow.oneSidedFrameCount = window.oneSidedFrameCount
        nativeWindow.windowFingerprint = window.windowFingerprint
        ASMacAudioQueuePCMContentPublish(reference, nativeWindow)
    }

    var snapshot: BlackHoleMicrophoneOutputPCMContentSnapshot {
        let native = ASMacAudioQueuePCMContentRead(reference)
        guard native.hasCompletedWindow else { return .zero }
        let window = native.window
        return BlackHoleMicrophoneOutputPCMContentSnapshot(
            lifecycleGeneration: native.lifecycleGeneration,
            windowSequence: native.windowSequence,
            completedFrameCount: native.completedFrameCount,
            raw: BlackHoleMicrophoneOutputPCMContentRawWindow(
                sourceStartFrame: window.sourceStartFrame,
                sourceEndFrame: window.sourceEndFrame,
                frameCount: window.frameCount,
                leftSampleSum: window.leftSampleSum,
                rightSampleSum: window.rightSampleSum,
                leftSquareSum: window.leftSquareSum,
                rightSquareSum: window.rightSquareSum,
                leftRightProductSum: window.leftRightProductSum,
                sumSquareSum: window.sumSquareSum,
                differenceSquareSum: window.differenceSquareSum,
                leftPeak: window.leftPeak,
                rightPeak: window.rightPeak,
                leftZeroCount: window.leftZeroCount,
                rightZeroCount: window.rightZeroCount,
                leftClippingCount: window.leftClippingCount,
                rightClippingCount: window.rightClippingCount,
                oneSidedFrameCount: window.oneSidedFrameCount,
                windowFingerprint: window.windowFingerprint
            )
        )
    }
}

private struct BlackHoleMicrophoneOutputPCMContentAccumulator {
    static let targetFrameCount: UInt64 = 48_000

    private var window =
        BlackHoleMicrophoneOutputPCMContentRawWindow()
    private var sourceFrame: UInt64 = 0

    @inline(__always)
    mutating func accumulate(
        interleavedStereo samples: UnsafePointer<Int16>,
        frameCount: Int,
        storage: BlackHoleMicrophoneOutputProgressStorage
    ) {
        var sourceFrameIndex = 0
        while sourceFrameIndex < frameCount {
            if window.frameCount == 0 {
                window.sourceStartFrame = sourceFrame
            }
            let remainingWindowFrames = Int(
                Self.targetFrameCount - window.frameCount
            )
            let consumedFrameCount = min(
                remainingWindowFrames,
                frameCount - sourceFrameIndex
            )
            let endFrameIndex = sourceFrameIndex + consumedFrameCount
            while sourceFrameIndex < endFrameIndex {
                let sampleIndex = sourceFrameIndex * 2
                accumulate(
                    left: Int64(samples[sampleIndex]),
                    right: Int64(samples[sampleIndex + 1])
                )
                sourceFrameIndex += 1
                sourceFrame &+= 1
            }
            window.frameCount += UInt64(consumedFrameCount)
            window.sourceEndFrame = sourceFrame
            if window.frameCount == Self.targetFrameCount {
                storage.publishPCMContent(window)
                window = BlackHoleMicrophoneOutputPCMContentRawWindow()
            }
        }
    }

    @inline(__always)
    private mutating func accumulate(
        left: Int64,
        right: Int64
    ) {
        let leftMagnitude = UInt64(left < 0 ? -left : left)
        let rightMagnitude = UInt64(right < 0 ? -right : right)
        let sum = left + right
        let difference = left - right

        window.leftSampleSum += left
        window.rightSampleSum += right
        window.leftSquareSum += UInt64(left * left)
        window.rightSquareSum += UInt64(right * right)
        window.leftRightProductSum += left * right
        window.sumSquareSum += UInt64(sum * sum)
        window.differenceSquareSum += UInt64(difference * difference)
        window.leftPeak = max(window.leftPeak, leftMagnitude)
        window.rightPeak = max(window.rightPeak, rightMagnitude)
        window.leftZeroCount += left == 0 ? 1 : 0
        window.rightZeroCount += right == 0 ? 1 : 0
        window.leftClippingCount += Self.isClipping(leftMagnitude) ? 1 : 0
        window.rightClippingCount += Self.isClipping(rightMagnitude) ? 1 : 0
        window.oneSidedFrameCount +=
            (leftMagnitude >= 128) != (rightMagnitude >= 128)
            ? 1
            : 0
        let leftBits = UInt16(bitPattern: Int16(left))
        window.windowFingerprint ^= UInt64(leftBits & 0x00ff)
        window.windowFingerprint &*=
            BlackHoleMicrophoneOutputPCMContentRawWindow
                .fingerprintPrime
        window.windowFingerprint ^= UInt64(leftBits >> 8)
        window.windowFingerprint &*=
            BlackHoleMicrophoneOutputPCMContentRawWindow
                .fingerprintPrime
        let rightBits = UInt16(bitPattern: Int16(right))
        window.windowFingerprint ^= UInt64(rightBits & 0x00ff)
        window.windowFingerprint &*=
            BlackHoleMicrophoneOutputPCMContentRawWindow
                .fingerprintPrime
        window.windowFingerprint ^= UInt64(rightBits >> 8)
        window.windowFingerprint &*=
            BlackHoleMicrophoneOutputPCMContentRawWindow
                .fingerprintPrime
    }

    @inline(__always)
    private static func isClipping(
        _ magnitude: UInt64
    ) -> Bool {
        magnitude >= 32_760
    }
}

private final class BlackHoleMicrophoneOutputProgressStorage:
    @unchecked Sendable
{
    let reference: ASMacAudioQueueProgressRef
    private let pcmContentStorage:
        BlackHoleMicrophoneOutputPCMContentStorage

    init?() {
        guard let pcmContentStorage =
                BlackHoleMicrophoneOutputPCMContentStorage() else {
            return nil
        }
        guard let reference = ASMacAudioQueueProgressCreate() else {
            return nil
        }
        self.pcmContentStorage = pcmContentStorage
        self.reference = reference
    }

    deinit {
        ASMacAudioQueueProgressDestroy(reference)
    }

    func reset() {
        ASMacAudioQueueProgressReset(reference)
        pcmContentStorage.reset()
    }

    /// Must be called only after the callback lifetime has been closed and
    /// drained, so an outgoing queue cannot republish a retired window.
    func clearPCMContentAfterCallbackDrain() {
        pcmContentStorage.reset()
    }

    func setQueueRunning(_ queueRunning: Bool) {
        ASMacAudioQueueProgressSetQueueRunning(
            reference,
            queueRunning
        )
    }

    func publish(
        requestedFrameCount: UInt64,
        pullSucceeded: Bool,
        enqueueStatus: OSStatus
    ) {
        ASMacAudioQueueProgressPublish(
            reference,
            requestedFrameCount,
            pullSucceeded,
            enqueueStatus
        )
    }

    @inline(__always)
    func publishPCMContent(
        _ window: BlackHoleMicrophoneOutputPCMContentRawWindow
    ) {
        pcmContentStorage.publish(window)
    }

    var snapshot: BlackHoleMicrophoneOutputProgressSnapshot {
        let native = ASMacAudioQueueProgressRead(reference)
        return BlackHoleMicrophoneOutputProgressSnapshot(
            queueRunning: native.queueRunning,
            postStartCallbackCount:
                native.postStartCallbackCount,
            requestedFrameCount: native.requestedFrameCount,
            successfulPullCount: native.successfulPullCount,
            successfulFrameCount: native.successfulFrameCount,
            silenceFallbackCount: native.silenceFallbackCount,
            silenceFrameCount: native.silenceFrameCount,
            enqueueFailureCount: native.enqueueFailureCount,
            lastEnqueueStatus: native.lastEnqueueStatus,
            pcmContent: native.queueRunning
                ? pcmContentStorage.snapshot
                : .zero
        )
    }
}

struct BlackHoleMicrophoneOutputQueueDisposalRedriveResult:
    Equatable,
    Sendable
{
    let retainedCount: Int
    let lastFailureStatus: OSStatus?

    var permitsReplacement: Bool {
        retainedCount == 0
    }
}

/// Compatibility facade for older call sites. `AudioQueueDispose` is terminal in the
/// macOS 26 SDK regardless of its returned status, so queue disposal is no longer
/// retried or retained after the call returns.
final class BlackHoleMicrophoneOutputQueueDisposalRetainer:
    @unchecked Sendable
{
    static let shared =
        BlackHoleMicrophoneOutputQueueDisposalRetainer()

    @discardableResult
    func redriveRetained(
        maximumAttemptCount _: Int
    ) -> BlackHoleMicrophoneOutputQueueDisposalRedriveResult {
        BlackHoleMicrophoneOutputQueueDisposalRedriveResult(
            retainedCount: 0,
            lastFailureStatus: nil
        )
    }

    var retainedDisposalCount: Int { 0 }

    #if DEBUG
    var debugFirstCallbackContextPointerForTesting:
        UnsafeMutableRawPointer? {
        nil
    }
    #endif
}

/// Output-device-clock sink for the decoded `iphone-microphone` track.

///
/// Core Audio owns the fixed buffers. The realtime callback performs one
/// caller-owned WebRTC pull and re-enqueues the same buffer; unavailable data
/// stays zero-filled. Callback failures cross only a lock-free status latch.
final class BlackHoleMicrophoneOutput: @unchecked Sendable {
    typealias RuntimeFailureHandler = @Sendable (
        BlackHoleMicrophoneOutput,
        BlackHoleMicrophoneOutputError
    ) -> Void

    private static let createQueueOperation =
        "create BlackHole output queue"
    private static let createCallbackLifetimeOperation =
        "create BlackHole output callback lifetime"
    private static let selectDeviceOperation =
        "select BlackHole 2ch by UID"
    private static let allocateBufferOperation =
        "allocate BlackHole output buffer"
    private static let primeBufferOperation =
        "prime BlackHole output buffer"
    private static let startQueueOperation =
        "start BlackHole output queue"
    private static let disposeQueueOperation =
        "dispose BlackHole output queue"
    private static let runtimeEnqueueOperation =
        "re-enqueue BlackHole output buffer"
    private static let runtimeFailureReportingQueueKey =
        DispatchSpecificKey<UInt8>()
    private static let runtimeFailureReportingQueue: DispatchQueue = {
        let queue = DispatchQueue(
            label: "opensteamer.BlackHoleMicrophoneOutput.RuntimeFailure",
            qos: .utility
        )
        queue.setSpecific(
            key: runtimeFailureReportingQueueKey,
            value: 1
        )
        return queue
    }()
    private static let runtimeFailurePollInterval =
        DispatchTimeInterval.milliseconds(10)
    private static let runtimeFailureTimerLeeway =
        DispatchTimeInterval.milliseconds(2)
    private static let defaultProgressStallGraceNanoseconds: UInt64 =
        2_000_000_000

    private let source: WebRTCMacDecodedAudioSource?
    private let deviceUID: String
    private let runtimeFailureLatch: WebRTCMacAudioQueueRuntimeFailureLatch
    private let progressStorage: BlackHoleMicrophoneOutputProgressStorage
    private let runtimeFailureHandler: RuntimeFailureHandler
    private let automaticallyReportsRuntimeFailures: Bool
    private var audioQueue: AudioQueueRef?
    private var callbackContext: BlackHoleMicrophoneOutputCallbackContext?
    private var callbackContextPointer: UnsafeMutableRawPointer?
    private var buffers: [AudioQueueBufferRef] = []
    private var lastDisposeStatus: OSStatus?
    private var boundDecodedPlayoutGeneration: UInt64?
    private var boundDecodedRenderCallFloor: UInt64?
    private var runtimeFailureTimer: (any DispatchSourceTimer)?
    private var runtimeFailureGeneration: UInt64 = 0
    private var activeRuntimeFailureGeneration: UInt64?
    private var runtimeFailureMonitoringStartTime: UInt64?
    private var lastObservedPostStartCallbackCount: UInt64 = 0
    private var lastPostStartCallbackAdvanceTime: UInt64?
    private var lastObservedSuccessfulFrameCount: UInt64 = 0
    private var lastSuccessfulFrameAdvanceTime: UInt64?
    private var didReportRuntimeFailure = false
    private let runtimeFailureNow:
        @Sendable () -> UInt64
    private let progressStallGraceNanoseconds: UInt64
    private let framesPerBuffer: UInt32 = 480
    private let channelCount: UInt32 = 2

    #if DEBUG
    private let testingAudioQueueOperations:
        (any BlackHoleMicrophoneOutputAudioQueueOperations)?
    private let renderForTesting:
        ((UnsafeMutablePointer<Int16>, Int) -> Bool)?
    private let deinitForTesting: (@Sendable () -> Void)?
    private let callbackContextDeinitForTesting:
        (@Sendable () -> Void)?
    private let runtimeEnqueueFailurePublicationInterlockForTesting:
        BlackHoleMicrophoneOutputRuntimeEnqueueFailurePublicationInterlock?
    private let decodedPlayoutBindingForTesting:
        (() -> (generation: UInt64, renderCallCount: UInt64))?
    #endif

    init?(
        source: WebRTCMacDecodedAudioSource,
        deviceUID: String,
        runtimeFailureHandler: @escaping RuntimeFailureHandler
    ) {
        guard !deviceUID.isEmpty else {
            return nil
        }
        guard let runtimeFailureLatch =
                WebRTCMacAudioQueueRuntimeFailureLatch() else {
            return nil
        }
        guard let progressStorage =
                BlackHoleMicrophoneOutputProgressStorage() else {
            return nil
        }

        self.source = source
        self.deviceUID = deviceUID
        self.runtimeFailureLatch = runtimeFailureLatch
        self.progressStorage = progressStorage
        self.runtimeFailureHandler = runtimeFailureHandler
        automaticallyReportsRuntimeFailures = true
        runtimeFailureNow = { DispatchTime.now().uptimeNanoseconds }
        progressStallGraceNanoseconds = Self.defaultProgressStallGraceNanoseconds
        #if DEBUG
        testingAudioQueueOperations = nil
        renderForTesting = nil
        deinitForTesting = nil
        callbackContextDeinitForTesting = nil
        runtimeEnqueueFailurePublicationInterlockForTesting =
            nil
        decodedPlayoutBindingForTesting = nil
        #endif
    }

    #if DEBUG
    init?(
        testingAudioQueueOperations:
            any BlackHoleMicrophoneOutputAudioQueueOperations,
        deviceUID: String = "BlackHole2ch_UID",
        automaticallyReportsRuntimeFailures: Bool = false,
        runtimeFailureNow: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        progressStallGraceNanoseconds: UInt64 = 2_000_000_000,
        runtimeEnqueueFailurePublicationInterlockForTesting:
            BlackHoleMicrophoneOutputRuntimeEnqueueFailurePublicationInterlock? = nil,
        renderForTesting: @escaping (
            UnsafeMutablePointer<Int16>,
            Int
        ) -> Bool = { _, _ in false },
        decodedPlayoutBindingForTesting:
            (() -> (generation: UInt64, renderCallCount: UInt64))? = nil,
        queueDisposalRetainer:
            BlackHoleMicrophoneOutputQueueDisposalRetainer =
                .shared,
        maximumQueueDisposalAttemptCountPerEpisode:
            Int = 3,
        callbackContextDeinitForTesting: (@Sendable () -> Void)? = nil,
        deinitForTesting: (@Sendable () -> Void)? = nil,
        runtimeFailureHandler: @escaping RuntimeFailureHandler
    ) {
        guard !deviceUID.isEmpty else {
            return nil
        }
        guard let runtimeFailureLatch =
                WebRTCMacAudioQueueRuntimeFailureLatch() else {
            return nil
        }
        guard let progressStorage =
                BlackHoleMicrophoneOutputProgressStorage() else {
            return nil
        }

        source = nil
        self.deviceUID = deviceUID
        self.runtimeFailureLatch = runtimeFailureLatch
        self.progressStorage = progressStorage
        self.runtimeFailureHandler = runtimeFailureHandler
        self.automaticallyReportsRuntimeFailures =
            automaticallyReportsRuntimeFailures
        self.runtimeFailureNow = runtimeFailureNow
        self.progressStallGraceNanoseconds = progressStallGraceNanoseconds
        _ = queueDisposalRetainer
        _ = maximumQueueDisposalAttemptCountPerEpisode
        self.testingAudioQueueOperations = testingAudioQueueOperations
        self.renderForTesting = renderForTesting
        self.deinitForTesting = deinitForTesting
        self.callbackContextDeinitForTesting =
            callbackContextDeinitForTesting
        self.runtimeEnqueueFailurePublicationInterlockForTesting =
            runtimeEnqueueFailurePublicationInterlockForTesting
        self.decodedPlayoutBindingForTesting =
            decodedPlayoutBindingForTesting
    }
    #endif

    deinit {
        stop()
        #if DEBUG
        deinitForTesting?()
        #endif
    }


    var forwardingProgressSnapshot:
        BlackHoleMicrophoneOutputProgressSnapshot {
        let progress = progressStorage.snapshot
        guard progress.queueRunning, let source else { return progress }
        // Both native snapshot reads and all floating-point derivation happen
        // on the service/watchdog side, never in the AudioQueue callback.
        return progress.includingDecodedContent(
            BlackHoleMicrophoneOutputDecodedContentSnapshot(
                source.decodedContentTelemetry
            ),
            boundDecodedPlayoutGeneration:
                boundDecodedPlayoutGeneration ?? 0,
            boundDecodedRenderCallFloor:
                boundDecodedRenderCallFloor ?? 0
        )
    }

    private var currentDecodedPlayoutBinding:
        (generation: UInt64, renderCallCount: UInt64) {
        #if DEBUG
        if let decodedPlayoutBindingForTesting {
            return decodedPlayoutBindingForTesting()
        }
        #endif
        guard let telemetry = source?.decodedContentTelemetry else {
            return (0, 0)
        }
        return (
            telemetry.playoutGeneration,
            telemetry.renderCallCount
        )
    }

    #if DEBUG
    var boundDecodedPlayoutGenerationForTesting: UInt64 {
        boundDecodedPlayoutGeneration ?? 0
    }

    var boundDecodedRenderCallFloorForTesting: UInt64 {
        boundDecodedRenderCallFloor ?? 0
    }
    #endif

    func start() throws {
        guard audioQueue == nil else { return }

        boundDecodedPlayoutGeneration = nil
        boundDecodedRenderCallFloor = nil
        runtimeFailureLatch.reset()
        progressStorage.reset()
        var format = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channelCount * UInt32(MemoryLayout<Int16>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: channelCount * UInt32(MemoryLayout<Int16>.size),
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        guard let callbackLifetime =
                ASMacAudioQueueCallbackLifetimeCreate() else {
            throw BlackHoleMicrophoneOutputError.operation(
                Self.createCallbackLifetimeOperation,
                kAudio_MemFullError
            )
        }

        let callbackContext: BlackHoleMicrophoneOutputCallbackContext
        #if DEBUG
        callbackContext = BlackHoleMicrophoneOutputCallbackContext(
            callbackLifetime: callbackLifetime,
            source: source,
            runtimeFailureLatch: runtimeFailureLatch,
            channelCount: channelCount,
            progressStorage: progressStorage,
            testingAudioQueueOperations: testingAudioQueueOperations,
            renderForTesting: renderForTesting,
            runtimeEnqueueFailurePublicationInterlockForTesting:
                runtimeEnqueueFailurePublicationInterlockForTesting,
            deinitForTesting:
                callbackContextDeinitForTesting
        )
        #else
        callbackContext = BlackHoleMicrophoneOutputCallbackContext(
            callbackLifetime: callbackLifetime,
            source: source,
            runtimeFailureLatch: runtimeFailureLatch,
            channelCount: channelCount,
            progressStorage: progressStorage
        )
        #endif
        let callbackContextPointer = Unmanaged
            .passRetained(callbackContext)
            .toOpaque()
        let creation = createOutputQueue(
            format: &format,
            context: callbackContextPointer
        )
        guard creation.status == noErr else {
            cleanupCreatedQueue(
                creation.queue,
                callbackContext: callbackContext,
                callbackContextPointer: callbackContextPointer,
                didAttemptStart: false
            )
            throw BlackHoleMicrophoneOutputError.operation(
                Self.createQueueOperation,
                creation.status
            )
        }
        guard let queue = creation.queue else {
            cleanupCreatedQueue(
                nil,
                callbackContext: callbackContext,
                callbackContextPointer: callbackContextPointer,
                didAttemptStart: false
            )
            throw BlackHoleMicrophoneOutputError.operation(
                Self.createQueueOperation,
                kAudio_ParamError
            )
        }

        var createdBuffers: [AudioQueueBufferRef] = []
        createdBuffers.reserveCapacity(3)
        var didAttemptStart = false
        var startupCommitted = false
        defer {
            if !startupCommitted {
                cleanupCreatedQueue(
                    queue,
                    callbackContext: callbackContext,
                    callbackContextPointer: callbackContextPointer,
                    didAttemptStart: didAttemptStart
                )
            }
        }

        let deviceStatus = setCurrentDevice(deviceUID, on: queue)
        guard deviceStatus == noErr else {
            throw BlackHoleMicrophoneOutputError.operation(
                Self.selectDeviceOperation,
                deviceStatus
            )
        }

        let byteCount = framesPerBuffer
            * channelCount
            * UInt32(MemoryLayout<Int16>.size)
        let decodedBindingBeforePriming =
            currentDecodedPlayoutBinding
        var allPrimingPullsSucceeded = true
        for _ in 0..<3 {
            let allocation = allocateBuffer(
                on: queue,
                byteCount: byteCount
            )
            guard allocation.status == noErr else {
                if let buffer = allocation.buffer {
                    createdBuffers.append(buffer)
                }
                throw BlackHoleMicrophoneOutputError.operation(
                    Self.allocateBufferOperation,
                    allocation.status
                )
            }
            guard let buffer = allocation.buffer else {
                throw BlackHoleMicrophoneOutputError.operation(
                    Self.allocateBufferOperation,
                    kAudio_ParamError
                )
            }

            createdBuffers.append(buffer)
            let primingResult = callbackContext.fillAndEnqueue(
                queue: queue,
                buffer: buffer
            )
            allPrimingPullsSucceeded =
                allPrimingPullsSucceeded
                && primingResult.pullSucceeded
            guard primingResult.enqueueStatus == noErr else {
                throw BlackHoleMicrophoneOutputError.operation(
                    Self.primeBufferOperation,
                    primingResult.enqueueStatus
                )
            }
        }

        didAttemptStart = true
        let startStatus = startQueue(queue)
        guard startStatus == noErr else {
            throw BlackHoleMicrophoneOutputError.operation(
                Self.startQueueOperation,
                startStatus
            )
        }

        let decodedBindingAfterStart =
            currentDecodedPlayoutBinding
        let minimumRenderCallCount =
            decodedBindingBeforePriming.renderCallCount
                .addingReportingOverflow(
                    UInt64(createdBuffers.count)
                )
        if allPrimingPullsSucceeded,
           !minimumRenderCallCount.overflow,
           decodedBindingBeforePriming.generation > 0,
           decodedBindingAfterStart.generation
            == decodedBindingBeforePriming.generation,
           decodedBindingAfterStart.renderCallCount
            >= minimumRenderCallCount.partialValue {
            boundDecodedPlayoutGeneration =
                decodedBindingBeforePriming.generation
            boundDecodedRenderCallFloor =
                decodedBindingBeforePriming.renderCallCount
        } else {
            boundDecodedPlayoutGeneration = nil
            boundDecodedRenderCallFloor = nil
        }

        audioQueue = queue
        self.callbackContext = callbackContext
        self.callbackContextPointer = callbackContextPointer
        buffers = createdBuffers
        progressStorage.setQueueRunning(true)
        startupCommitted = true
        startRuntimeFailureMonitoring(
            scheduleTimer: automaticallyReportsRuntimeFailures
        )
    }

    func stop() {
        stopRuntimeFailureMonitoring()
        boundDecodedPlayoutGeneration = nil
        boundDecodedRenderCallFloor = nil
        guard let queue = audioQueue,
              let callbackContext,
              let callbackContextPointer else {
            return
        }

        audioQueue = nil
        self.callbackContext = nil
        self.callbackContextPointer = nil
        buffers.removeAll(keepingCapacity: false)

        closeStopDisposeAndRelease(
            queue: queue,
            callbackContext: callbackContext,
            callbackContextPointer: callbackContextPointer,
            didAttemptStart: true
        )
    }

    private func cleanupCreatedQueue(
        _ queue: AudioQueueRef?,
        callbackContext: BlackHoleMicrophoneOutputCallbackContext,
        callbackContextPointer: UnsafeMutableRawPointer,
        didAttemptStart: Bool
    ) {
        guard let queue else {
            callbackContext.closeCallbacks()
            callbackContext.waitForCallbacks()
            progressStorage.clearPCMContentAfterCallbackDrain()
            Unmanaged<BlackHoleMicrophoneOutputCallbackContext>
                .fromOpaque(callbackContextPointer)
                .release()
            return
        }

        closeStopDisposeAndRelease(
            queue: queue,
            callbackContext: callbackContext,
            callbackContextPointer: callbackContextPointer,
            didAttemptStart: didAttemptStart
        )
    }

    private func closeStopDisposeAndRelease(
        queue: AudioQueueRef,
        callbackContext: BlackHoleMicrophoneOutputCallbackContext,
        callbackContextPointer: UnsafeMutableRawPointer,
        didAttemptStart: Bool
    ) {
        callbackContext.closeCallbacks()
        if didAttemptStart {
            _ = stopQueue(queue, immediate: true)
        }
        callbackContext.waitForCallbacks()
        progressStorage.clearPCMContentAfterCallbackDrain()
        let status = disposeQueue(queue, immediate: true)
        lastDisposeStatus = status
        Unmanaged<BlackHoleMicrophoneOutputCallbackContext>
            .fromOpaque(callbackContextPointer)
            .release()
    }

    private func startRuntimeFailureMonitoring(

        scheduleTimer: Bool
    ) {
        withRuntimeFailureReportingQueue {
            guard activeRuntimeFailureGeneration == nil else {
                return
            }

            runtimeFailureGeneration = Self.nextNonzero(
                runtimeFailureGeneration
            )
            let generation = runtimeFailureGeneration
            activeRuntimeFailureGeneration = generation
            runtimeFailureMonitoringStartTime =
                runtimeFailureNow()
            lastObservedPostStartCallbackCount = 0
            lastPostStartCallbackAdvanceTime = nil
            lastObservedSuccessfulFrameCount = 0
            lastSuccessfulFrameAdvanceTime = nil
            didReportRuntimeFailure = false

            guard scheduleTimer else { return }
            let timer = DispatchSource.makeTimerSource(
                queue: Self.runtimeFailureReportingQueue
            )
            timer.schedule(
                deadline: .now()
                    + Self.runtimeFailurePollInterval,
                repeating: Self.runtimeFailurePollInterval,
                leeway: Self.runtimeFailureTimerLeeway
            )
            timer.setEventHandler { [weak self] in
                self?.pollRuntimeFailureMonitoring(
                    generation: generation
                )
            }
            runtimeFailureTimer = timer
            timer.activate()
        }
    }

    private func stopRuntimeFailureMonitoring() {
        withRuntimeFailureReportingQueue {
            progressStorage.setQueueRunning(false)
            activeRuntimeFailureGeneration = nil
            runtimeFailureGeneration = Self.nextNonzero(
                runtimeFailureGeneration
            )
            runtimeFailureMonitoringStartTime = nil
            lastObservedPostStartCallbackCount = 0
            lastPostStartCallbackAdvanceTime = nil
            lastObservedSuccessfulFrameCount = 0
            lastSuccessfulFrameAdvanceTime = nil
            didReportRuntimeFailure = false

            let timer = runtimeFailureTimer
            runtimeFailureTimer = nil
            timer?.setEventHandler {}
            timer?.cancel()
        }
    }

    private func pollRuntimeFailureMonitoring(
        generation: UInt64
    ) {
        withRuntimeFailureReportingQueue {
            guard activeRuntimeFailureGeneration == generation,
                  !didReportRuntimeFailure else {
                return
            }

            let progress = progressStorage.snapshot
            guard progress.queueRunning else { return }

            let now = runtimeFailureNow()
            var shouldReportProgressStall = false
            let successfulFrameCount =
                progress.successfulFrameCount
            if successfulFrameCount > 0 {
                if successfulFrameCount
                        > lastObservedSuccessfulFrameCount {
                    lastObservedSuccessfulFrameCount =
                        successfulFrameCount
                    lastSuccessfulFrameAdvanceTime = now
                } else if let lastSuccessfulFrameAdvanceTime,
                          now >= lastSuccessfulFrameAdvanceTime,
                          now - lastSuccessfulFrameAdvanceTime
                            >= progressStallGraceNanoseconds {
                    shouldReportProgressStall = true
                }
            } else {
                let callbackCount =
                    progress.postStartCallbackCount
                if callbackCount
                        > lastObservedPostStartCallbackCount {
                    lastObservedPostStartCallbackCount =
                        callbackCount
                    lastPostStartCallbackAdvanceTime = now
                } else if callbackCount == 0,
                          let runtimeFailureMonitoringStartTime,
                          now >= runtimeFailureMonitoringStartTime,
                          now - runtimeFailureMonitoringStartTime
                            >= progressStallGraceNanoseconds {
                    shouldReportProgressStall = true
                } else if callbackCount > 0,
                          let lastPostStartCallbackAdvanceTime,
                          now >= lastPostStartCallbackAdvanceTime,
                          now - lastPostStartCallbackAdvanceTime
                            >= progressStallGraceNanoseconds {
                    shouldReportProgressStall = true
                }
            }

            if let status = runtimeFailureLatch.take() {
                didReportRuntimeFailure = true
                runtimeFailureHandler(
                    self,
                    .operation(
                        Self.runtimeEnqueueOperation,
                        status
                    )
                )
                return
            }

            guard shouldReportProgressStall else {
                return
            }

            didReportRuntimeFailure = true
            runtimeFailureHandler(
                self,
                .progressStalled
            )
        }
    }

    private func withRuntimeFailureReportingQueue<T>(
        _ body: () -> T
    ) -> T {
        if DispatchQueue.getSpecific(
            key: Self.runtimeFailureReportingQueueKey
        ) != nil {
            return body()
        }
        return Self.runtimeFailureReportingQueue.sync(
            execute: body
        )
    }

    private static func nextNonzero(
        _ value: UInt64
    ) -> UInt64 {
        let next = value &+ 1
        return next == 0 ? 1 : next
    }

    private func createOutputQueue(
        format: inout AudioStreamBasicDescription,
        context: UnsafeMutableRawPointer
    ) -> (status: OSStatus, queue: AudioQueueRef?) {
        #if DEBUG
        if let testingAudioQueueOperations {
            return testingAudioQueueOperations.createOutputQueue()
        }
        #endif

        var queue: AudioQueueRef?
        let status = AudioQueueNewOutput(
            &format,
            blackHoleMicrophoneOutputCallback,
            context,
            nil,
            nil,
            0,
            &queue
        )
        return (status, queue)
    }

    private func setCurrentDevice(
        _ uid: String,
        on queue: AudioQueueRef
    ) -> OSStatus {
        #if DEBUG
        if let testingAudioQueueOperations {
            return testingAudioQueueOperations
                .setCurrentDevice(uid, on: queue)
        }
        #endif

        var value = uid as CFString
        return withUnsafePointer(to: &value) {
            AudioQueueSetProperty(
                queue,
                kAudioQueueProperty_CurrentDevice,
                $0,
                UInt32(MemoryLayout<CFString>.size)
            )
        }
    }

    private func allocateBuffer(
        on queue: AudioQueueRef,
        byteCount: UInt32
    ) -> (status: OSStatus, buffer: AudioQueueBufferRef?) {
        #if DEBUG
        if let testingAudioQueueOperations {
            return testingAudioQueueOperations.allocateBuffer(
                on: queue,
                byteCount: byteCount
            )
        }
        #endif

        var buffer: AudioQueueBufferRef?
        let status = AudioQueueAllocateBuffer(
            queue,
            byteCount,
            &buffer
        )
        return (status, buffer)
    }

    @inline(__always)
    private func enqueueBuffer(
        _ buffer: AudioQueueBufferRef,
        on queue: AudioQueueRef
    ) -> OSStatus {
        #if DEBUG
        if let testingAudioQueueOperations {
            return testingAudioQueueOperations.enqueueBuffer(
                buffer,
                on: queue
            )
        }
        #endif
        return AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    private func startQueue(_ queue: AudioQueueRef) -> OSStatus {
        #if DEBUG
        if let testingAudioQueueOperations {
            return testingAudioQueueOperations.startQueue(queue)
        }
        #endif
        return AudioQueueStart(queue, nil)
    }

    private func stopQueue(
        _ queue: AudioQueueRef,
        immediate: Bool
    ) -> OSStatus {
        #if DEBUG
        if let testingAudioQueueOperations {
            return testingAudioQueueOperations.stopQueue(
                queue,
                immediate: immediate
            )
        }
        #endif
        return AudioQueueStop(queue, immediate)
    }

    private func freeBuffer(
        _ buffer: AudioQueueBufferRef,
        from queue: AudioQueueRef
    ) -> OSStatus {
        #if DEBUG
        if let testingAudioQueueOperations {
            return testingAudioQueueOperations.freeBuffer(
                buffer,
                from: queue
            )
        }
        #endif
        return AudioQueueFreeBuffer(queue, buffer)
    }

    private func disposeQueue(
        _ queue: AudioQueueRef,
        immediate: Bool
    ) -> OSStatus {
        #if DEBUG
        if let testingAudioQueueOperations {
            return testingAudioQueueOperations.disposeQueue(
                queue,
                immediate: immediate
            )
        }
        #endif
        return AudioQueueDispose(queue, immediate)
    }

    #if DEBUG
    func debugInvokeRealtimeCallbackForTesting(
        queue: AudioQueueRef,
        buffer: AudioQueueBufferRef
    ) {
        guard let callbackContextPointer else { return }
        blackHoleMicrophoneOutputCallback(
            callbackContextPointer,
            queue,
            buffer
        )
    }

    func debugRealtimeCallbackContextForTesting()
        -> UnsafeMutableRawPointer? {
        callbackContextPointer
    }

    var debugHasPendingQueueDisposalForTesting: Bool {
        false
    }

    var debugLastDisposeStatusForTesting: OSStatus? {
        lastDisposeStatus
    }

    static func debugInvokeRealtimeCallbackWithContextForTesting(
        context: UnsafeMutableRawPointer,
        queue: AudioQueueRef,
        buffer: AudioQueueBufferRef
    ) {
        blackHoleMicrophoneOutputCallback(
            context,
            queue,
            buffer
        )
    }

    func debugReportLatchedRuntimeFailureForTesting() {
        guard let generation =
                debugRuntimeFailureMonitoringGenerationForTesting() else {
            return
        }
        debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
    }

    func debugRuntimeFailureMonitoringGenerationForTesting()
        -> UInt64? {
        withRuntimeFailureReportingQueue {
            activeRuntimeFailureGeneration
        }
    }

    func debugPollRuntimeFailureMonitoringForTesting(
        generation: UInt64
    ) {
        pollRuntimeFailureMonitoring(generation: generation)
    }
    #endif
}

private struct BlackHoleMicrophoneOutputCallbackResult {
    let requestedFrameCount: UInt64
    let pullSucceeded: Bool
    let enqueueStatus: OSStatus
}

#if DEBUG
/// DEBUG-only AudioQueue replacement used by deterministic tests.
///
/// All references to this protocol and its dynamic dispatch are compiled out
/// of Release, leaving direct Core Audio calls on the production callback path.
protocol BlackHoleMicrophoneOutputAudioQueueOperations:
    AnyObject,
    Sendable
{
    func createOutputQueue() -> (
        status: OSStatus,
        queue: AudioQueueRef?
    )

    func setCurrentDevice(
        _ uid: String,
        on queue: AudioQueueRef
    ) -> OSStatus

    func allocateBuffer(
        on queue: AudioQueueRef,
        byteCount: UInt32
    ) -> (
        status: OSStatus,
        buffer: AudioQueueBufferRef?
    )

    func enqueueBuffer(
        _ buffer: AudioQueueBufferRef,
        on queue: AudioQueueRef
    ) -> OSStatus

    func startQueue(_ queue: AudioQueueRef) -> OSStatus

    func stopQueue(
        _ queue: AudioQueueRef,
        immediate: Bool
    ) -> OSStatus

    func freeBuffer(
        _ buffer: AudioQueueBufferRef,
        from queue: AudioQueueRef
    ) -> OSStatus

    func disposeQueue(
        _ queue: AudioQueueRef,
        immediate: Bool
    ) -> OSStatus
}
#endif

#if DEBUG
final class BlackHoleMicrophoneOutputRuntimeEnqueueFailurePublicationInterlock:
    @unchecked Sendable
{
    private enum State {
        case disarmed
        case armed
        case paused
        case released
    }

    private let lock = NSLock()
    private let publicationReached = DispatchSemaphore(value: 0)
    private let callbackRelease = DispatchSemaphore(value: 0)
    private var state = State.disarmed

    func armNextFailureCallback() {
        lock.lock()
        defer { lock.unlock() }
        guard case .disarmed = state else {
            preconditionFailure(
                "Runtime enqueue failure interlock is already armed."
            )
        }
        state = .armed
    }

    fileprivate func pauseCallbackAfterPublication() {
        lock.lock()
        guard case .armed = state else {
            lock.unlock()
            return
        }
        state = .paused
        lock.unlock()

        publicationReached.signal()
        callbackRelease.wait()

        lock.lock()
        state = .disarmed
        lock.unlock()
    }

    func waitUntilCallbackPaused(
        timeout: DispatchTime
    ) -> DispatchTimeoutResult {
        return publicationReached.wait(timeout: timeout)
    }

    func releaseCallback() {
        lock.lock()
        switch state {
        case .armed:
            state = .disarmed
            lock.unlock()
        case .paused:
            state = .released
            lock.unlock()
            callbackRelease.signal()
        case .disarmed, .released:
            lock.unlock()
        }
    }
}
#endif

private final class BlackHoleMicrophoneOutputCallbackContext:
    @unchecked Sendable
{
    private let callbackLifetime: UnsafeMutableRawPointer
    private let source: WebRTCMacDecodedAudioSource?
    private let runtimeFailureLatch: WebRTCMacAudioQueueRuntimeFailureLatch
    private let channelCount: UInt32
    private let progressStorage: BlackHoleMicrophoneOutputProgressStorage
    private var pcmContentAccumulator =
        BlackHoleMicrophoneOutputPCMContentAccumulator()

    #if DEBUG
    private let testingAudioQueueOperations:
        (any BlackHoleMicrophoneOutputAudioQueueOperations)?
    private let renderForTesting:
        ((UnsafeMutablePointer<Int16>, Int) -> Bool)?
    private let runtimeEnqueueFailurePublicationInterlockForTesting:
        BlackHoleMicrophoneOutputRuntimeEnqueueFailurePublicationInterlock?
    private let deinitForTesting:
        (@Sendable () -> Void)?
    #endif

    #if DEBUG
    init(
        callbackLifetime: UnsafeMutableRawPointer,
        source: WebRTCMacDecodedAudioSource?,
        runtimeFailureLatch: WebRTCMacAudioQueueRuntimeFailureLatch,
        channelCount: UInt32,
        progressStorage: BlackHoleMicrophoneOutputProgressStorage,
        testingAudioQueueOperations:
            (any BlackHoleMicrophoneOutputAudioQueueOperations)?,
        renderForTesting:
            ((UnsafeMutablePointer<Int16>, Int) -> Bool)?,
        runtimeEnqueueFailurePublicationInterlockForTesting:
            BlackHoleMicrophoneOutputRuntimeEnqueueFailurePublicationInterlock?,
        deinitForTesting:
            (@Sendable () -> Void)?
    ) {
        self.callbackLifetime = callbackLifetime
        self.source = source
        self.runtimeFailureLatch = runtimeFailureLatch
        self.channelCount = channelCount
        self.progressStorage = progressStorage
        self.testingAudioQueueOperations = testingAudioQueueOperations
        self.renderForTesting = renderForTesting
        self.runtimeEnqueueFailurePublicationInterlockForTesting =
            runtimeEnqueueFailurePublicationInterlockForTesting
        self.deinitForTesting = deinitForTesting
    }
    #else
    init(
        callbackLifetime: UnsafeMutableRawPointer,
        source: WebRTCMacDecodedAudioSource?,
        runtimeFailureLatch: WebRTCMacAudioQueueRuntimeFailureLatch,
        channelCount: UInt32,
        progressStorage: BlackHoleMicrophoneOutputProgressStorage
    ) {
        self.callbackLifetime = callbackLifetime
        self.source = source
        self.runtimeFailureLatch = runtimeFailureLatch
        self.channelCount = channelCount
        self.progressStorage = progressStorage
    }
    #endif

    deinit {
        ASMacAudioQueueCallbackLifetimeDestroy(callbackLifetime)
        #if DEBUG
        deinitForTesting?()
        #endif
    }

    @inline(__always)
    fileprivate func tryEnterCallback() -> Bool {
        ASMacAudioQueueCallbackLifetimeTryEnter(callbackLifetime)
    }

    @inline(__always)
    fileprivate func leaveCallback() {
        ASMacAudioQueueCallbackLifetimeLeave(callbackLifetime)
    }

    fileprivate func closeCallbacks() {
        ASMacAudioQueueCallbackLifetimeClose(callbackLifetime)
    }

    fileprivate func waitForCallbacks() {
        ASMacAudioQueueCallbackLifetimeWaitForCallbacks(
            callbackLifetime
        )
    }

    #if DEBUG
    @inline(__always)
    fileprivate func pauseRuntimeEnqueueFailurePublicationForTesting() {
        runtimeEnqueueFailurePublicationInterlockForTesting?
            .pauseCallbackAfterPublication()
    }
    #endif

    @inline(__always)
    fileprivate func fillAndEnqueue(
        queue: AudioQueueRef,
        buffer: AudioQueueBufferRef
    ) -> BlackHoleMicrophoneOutputCallbackResult {
        let frameBytes = Int(channelCount) * MemoryLayout<Int16>.size
        let capacity = Int(buffer.pointee.mAudioDataBytesCapacity)
        let frameCount = capacity / frameBytes
        guard frameCount > 0 else {
            buffer.pointee.mAudioDataByteSize = 0
            return BlackHoleMicrophoneOutputCallbackResult(
                requestedFrameCount: 0,
                pullSucceeded: false,
                enqueueStatus: enqueueBuffer(
                    buffer,
                    on: queue
                )
            )
        }

        let rawData = buffer.pointee.mAudioData
        memset(rawData, 0, capacity)
        let samples = rawData.assumingMemoryBound(to: Int16.self)
        let pullSucceeded: Bool
        #if DEBUG
        if let renderForTesting {
            pullSucceeded = renderForTesting(samples, frameCount)
        } else if let source {
            pullSucceeded = source.renderInterleavedStereoInt16(
                into: samples,
                frameCount: frameCount
            )
        } else {
            pullSucceeded = false
        }
        #else
        if let source {
            pullSucceeded = source.renderInterleavedStereoInt16(
                into: samples,
                frameCount: frameCount
            )
        } else {
            pullSucceeded = false
        }
        #endif

        if !pullSucceeded {
            // A failed native renderer may have partially dirtied caller-owned
            // memory. Re-zero the full capacity before publishing silence.
            memset(rawData, 0, capacity)
        }

        buffer.pointee.mAudioDataByteSize =
            UInt32(frameCount * frameBytes)
        pcmContentAccumulator.accumulate(
            interleavedStereo: UnsafePointer(samples),
            frameCount: frameCount,
            storage: progressStorage
        )
        return BlackHoleMicrophoneOutputCallbackResult(
            requestedFrameCount: UInt64(frameCount),
            pullSucceeded: pullSucceeded,
            enqueueStatus: enqueueBuffer(buffer, on: queue)
        )
    }

    @inline(__always)
    fileprivate func publishProgress(
        _ result: BlackHoleMicrophoneOutputCallbackResult
    ) {
        progressStorage.publish(
            requestedFrameCount: result.requestedFrameCount,
            pullSucceeded: result.pullSucceeded,
            enqueueStatus: result.enqueueStatus
        )
    }

    @inline(__always)
    fileprivate func publishRuntimeEnqueueFailure(_ status: OSStatus) {
        runtimeFailureLatch.publish(status)
    }

    @inline(__always)
    private func enqueueBuffer(
        _ buffer: AudioQueueBufferRef,
        on queue: AudioQueueRef
    ) -> OSStatus {
        #if DEBUG
        if let testingAudioQueueOperations {
            return testingAudioQueueOperations.enqueueBuffer(
                buffer,
                on: queue
            )
        }
        #endif
        return AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
}

private func blackHoleMicrophoneOutputCallback(
    _ userData: UnsafeMutableRawPointer?,
    _ queue: AudioQueueRef,
    _ buffer: AudioQueueBufferRef
) {
    guard let userData else { return }
    let callbackContext =
        Unmanaged<BlackHoleMicrophoneOutputCallbackContext>
        .fromOpaque(userData)
        .takeUnretainedValue()
    guard callbackContext.tryEnterCallback() else { return }
    defer { callbackContext.leaveCallback() }

    let result = callbackContext.fillAndEnqueue(
        queue: queue,
        buffer: buffer
    )
    if result.enqueueStatus != noErr {
        // Publish the first-status latch before the multi-field progress
        // snapshot. A watchdog poll interleaved between these publications
        // must therefore select the enqueue failure.
        callbackContext.publishRuntimeEnqueueFailure(
            result.enqueueStatus
        )
        #if DEBUG
        callbackContext.pauseRuntimeEnqueueFailurePublicationForTesting()
        #endif
    }
    callbackContext.publishProgress(result)
}

enum BlackHoleMicrophoneOutputError:
    LocalizedError,
    Equatable,
    Sendable
{
    case operation(String, OSStatus)
    case progressStalled

    var errorDescription: String? {
        switch self {
        case .operation(let operation, let status):
            return "\(operation) failed with Core Audio status \(status)."
        case .progressStalled:
            return "BlackHole audio callback or decoded-frame progress " +
                "stalled while iPhone microphone forwarding was active."
        }
    }
}
