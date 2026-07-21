import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import XCTest

/// A deterministic, broadband, channel-distinct challenge signal for decoded-audio tests.
struct DeterministicStereoWaveform: Sendable {
    static let sampleRate = 48_000.0

    let left: [Double]
    let right: [Double]

    var frameCount: Int { left.count }

    var peakMagnitude: Double {
        max(
            left.reduce(0) { max($0, abs($1)) },
            right.reduce(0) { max($0, abs($1)) }
        )
    }

    init(frameCount: Int) {
        precondition(frameCount >= 19_200)
        var left = [Double]()
        var right = [Double]()
        left.reserveCapacity(frameCount)
        right.reserveCapacity(frameCount)

        for frame in 0..<frameCount {
            let time = Double(frame) / Self.sampleRate
            let normalizedPosition = Double(frame) / Double(max(1, frameCount - 1))
            // Exercise production PCM and Opus at both ordinary and music-like high levels. The
            // smooth envelope avoids introducing a synthetic boundary click, while its 2.55x
            // midpoint raises the waveform to roughly 0.7 full scale without clipping.
            let levelScale = 1 + 1.55 * pow(sin(.pi * normalizedPosition), 2)
            let leftEnvelope = 0.74
                + 0.16 * sin(2 * .pi * 3.7 * time)
                + 0.07 * sin(2 * .pi * 11.3 * time)
            let rightEnvelope = 0.71
                + 0.17 * sin(2 * .pi * 4.9 * time + 0.8)
                + 0.08 * sin(2 * .pi * 13.1 * time + 0.2)
            let leftChirpPhase = 2 * .pi * (337 * time + 0.5 * 820 * time * time)
            let rightChirpPhase = 2 * .pi * (613 * time + 0.5 * 1_070 * time * time)

            left.append(
                levelScale * (
                    leftEnvelope * 0.18 * sin(leftChirpPhase)
                        + 0.040 * sin(2 * .pi * 1_729 * time + 0.3)
                        + 0.035 * sin(2 * .pi * 4_003 * time + 0.6)
                        + 0.040 * sin(2 * .pi * 8_003 * time + 1.2)
                        + 0.030 * sin(2 * .pi * 12_011 * time + 0.1)
                )
            )
            right.append(
                levelScale * (
                    rightEnvelope * 0.17 * sin(rightChirpPhase)
                        + 0.045 * sin(2 * .pi * 2_117 * time + 1.1)
                        + 0.035 * sin(2 * .pi * 5_003 * time + 0.4)
                        + 0.040 * sin(2 * .pi * 11_003 * time + 1.5)
                        + 0.030 * sin(2 * .pi * 15_013 * time + 0.7)
                )
            )
        }

        self.left = left
        self.right = right
    }

    func spectralAmplitude(frequency: Double, leftChannel: Bool) -> Double {
        let samples = leftChannel ? left : right
        var sine = 0.0
        var cosine = 0.0
        for (frame, sample) in samples.enumerated() {
            let phase = 2 * .pi * frequency * Double(frame) / Self.sampleRate
            sine += sample * sin(phase)
            cosine += sample * cos(phase)
        }
        return 2 * hypot(sine, cosine) / Double(samples.count)
    }

    static func synchronizationPreamble(frameCount: Int = 4_800) -> Self {
        precondition(frameCount >= 2_400 && frameCount.isMultiple(of: 2))
        let half = frameCount / 2
        var left = [Double]()
        var right = [Double]()
        left.reserveCapacity(frameCount)
        right.reserveCapacity(frameCount)

        for frame in 0..<frameCount {
            let time = Double(frame) / sampleRate
            let inFirstHalf = frame < half
            let primaryPhase = 2 * .pi * (
                521 * time + 0.5 * 1_310 * time * time
            )
            let secondaryPhase = 2 * .pi * (
                1_237 * time + 0.5 * 730 * time * time
            )
            let primary = 0.52 * sin(primaryPhase) + 0.08 * sin(secondaryPhase + 0.4)
            let pilot = 0.025 * sin(2 * .pi * 2_311 * time + 0.9)
            left.append(inFirstHalf ? primary : pilot)
            right.append(inFirstHalf ? pilot : primary)
        }

        return Self(left: left, right: right)
    }

    private init(left: [Double], right: [Double]) {
        precondition(!left.isEmpty && left.count == right.count)
        self.left = left
        self.right = right
    }
}

/// A bounded unfiltered decoded-PCM capture on which corruption mutations and metrics operate.
struct DecodedAudioWindow: Sendable {
    let sampleRate: Double
    let channelCount: Int
    let left: [Double]
    let right: [Double]
    let invalidBatchCount: Int

    var frameCount: Int { min(left.count, right.count) }

    func criticalMutationCases(
        alignmentOffset: Int,
        expectedFrameCount: Int
    ) -> [AudioWaveformMutationCase] {
        precondition(alignmentOffset >= 0)
        precondition(expectedFrameCount > 0)
        precondition(alignmentOffset + expectedFrameCount <= frameCount)
        let stableInteriorStart = alignmentOffset + 4_800
        return [
            AudioWaveformMutationCase(
                name: "leading edge silence",
                window: insertingPeriodicSilence(
                    alignedStart: alignmentOffset,
                    blockFrames: 1_440,
                    intervalFrames: frameCount,
                    count: 1
                )
            ),
            AudioWaveformMutationCase(
                name: "trailing edge silence",
                window: insertingPeriodicSilence(
                    alignedStart: alignmentOffset + expectedFrameCount - 1_440,
                    blockFrames: 1_440,
                    intervalFrames: frameCount,
                    count: 1
                )
            ),
            AudioWaveformMutationCase(
                name: "periodic silence",
                window: insertingPeriodicSilence(
                    alignedStart: stableInteriorStart,
                    blockFrames: 480,
                    intervalFrames: 1_920,
                    count: 10
                )
            ),
            AudioWaveformMutationCase(
                name: "misaligned short dropout",
                window: insertingPeriodicSilence(
                    alignedStart: stableInteriorStart + 1_317,
                    blockFrames: 240,
                    intervalFrames: 9_600,
                    count: 1
                )
            ),
            AudioWaveformMutationCase(
                name: "repeated decoded blocks",
                window: repeatingPreviousBlocks(
                    alignedStart: stableInteriorStart + 960,
                    blockFrames: 480,
                    intervalFrames: 3_840,
                    count: 6
                )
            ),
            AudioWaveformMutationCase(
                name: "dropped decoded samples",
                window: droppingFrames(at: stableInteriorStart + 7_200, count: 480)
            ),
            AudioWaveformMutationCase(
                name: "misaligned corruption burst",
                window: invertingFrames(
                    at: stableInteriorStart + 2_053,
                    count: 240
                )
            ),
            AudioWaveformMutationCase(
                name: "moderate broadband distortion",
                window: addingDeterministicNoise(amplitude: 0.14)
            ),
            AudioWaveformMutationCase(
                name: "telephone-band low-pass",
                window: applyingTelephoneBandLowPass(cutoffFrequency: 3_400)
            ),
            AudioWaveformMutationCase(
                name: "linear gain distortion",
                window: applyingGainAndClipping(1.25)
            ),
            AudioWaveformMutationCase(
                name: "clipping",
                window: applyingGainAndClipping(6)
            ),
            AudioWaveformMutationCase(
                name: "dual-mono channel corruption",
                window: replacingRightChannelWithLeft()
            )
        ]
    }

    private func insertingPeriodicSilence(
        alignedStart: Int,
        blockFrames: Int,
        intervalFrames: Int,
        count: Int
    ) -> Self {
        var left = left
        var right = right
        for occurrence in 0..<count {
            let start = alignedStart + occurrence * intervalFrames
            let end = min(start + blockFrames, frameCount)
            guard start >= 0, start < end else { continue }
            left.replaceSubrange(start..<end, with: repeatElement(0, count: end - start))
            right.replaceSubrange(start..<end, with: repeatElement(0, count: end - start))
        }
        return replacingSamples(left: left, right: right)
    }

    private func repeatingPreviousBlocks(
        alignedStart: Int,
        blockFrames: Int,
        intervalFrames: Int,
        count: Int
    ) -> Self {
        var left = left
        var right = right
        for occurrence in 0..<count {
            let start = alignedStart + occurrence * intervalFrames
            let end = start + blockFrames
            let previousStart = start - blockFrames
            guard previousStart >= 0, end <= frameCount else { continue }
            left.replaceSubrange(start..<end, with: left[previousStart..<start])
            right.replaceSubrange(start..<end, with: right[previousStart..<start])
        }
        return replacingSamples(left: left, right: right)
    }

    private func droppingFrames(at start: Int, count: Int) -> Self {
        guard count > 0, start >= 0, start + count <= frameCount else { return self }
        var left = left
        var right = right
        left.removeSubrange(start..<(start + count))
        right.removeSubrange(start..<(start + count))
        left.append(contentsOf: repeatElement(0, count: count))
        right.append(contentsOf: repeatElement(0, count: count))
        return replacingSamples(left: left, right: right)
    }

    private func applyingGainAndClipping(_ gain: Double) -> Self {
        replacingSamples(
            left: left.map { min(1, max(-1, $0 * gain)) },
            right: right.map { min(1, max(-1, $0 * gain)) }
        )
    }

    private func invertingFrames(at start: Int, count: Int) -> Self {
        guard count > 0, start >= 0, start + count <= frameCount else { return self }
        var left = left
        var right = right
        for frame in start..<(start + count) {
            left[frame] = -left[frame]
            right[frame] = -right[frame]
        }
        return replacingSamples(left: left, right: right)
    }

    private func addingDeterministicNoise(amplitude: Double) -> Self {
        var left = left
        var right = right
        for frame in 0..<frameCount {
            let time = Double(frame) / DeterministicStereoWaveform.sampleRate
            left[frame] += amplitude * (
                0.62 * sin(2 * .pi * 3_217 * time + 0.2)
                    + 0.38 * sin(2 * .pi * 4_421 * time + 1.1)
            )
            right[frame] += amplitude * (
                0.57 * sin(2 * .pi * 3_719 * time + 0.7)
                    + 0.43 * sin(2 * .pi * 4_603 * time + 1.6)
            )
        }
        return replacingSamples(left: left, right: right)
    }

    private func applyingTelephoneBandLowPass(cutoffFrequency: Double) -> Self {
        let radius = 32
        let sampleRate = DeterministicStereoWaveform.sampleRate
        var coefficients = (-radius...radius).map { offset -> Double in
            let ideal: Double
            if offset == 0 {
                ideal = 2 * cutoffFrequency / sampleRate
            } else {
                ideal = sin(2 * .pi * cutoffFrequency * Double(offset) / sampleRate)
                    / (.pi * Double(offset))
            }
            let windowPosition = Double(offset + radius) / Double(radius * 2)
            let hamming = 0.54 - 0.46 * cos(2 * .pi * windowPosition)
            return ideal * hamming
        }
        let normalization = coefficients.reduce(0, +)
        coefficients = coefficients.map { $0 / normalization }

        func filter(_ source: [Double]) -> [Double] {
            source.indices.map { frame in
                coefficients.enumerated().reduce(0.0) { sum, entry in
                    let offset = entry.offset - radius
                    let sourceFrame = min(max(0, frame + offset), source.count - 1)
                    return sum + source[sourceFrame] * entry.element
                }
            }
        }
        return replacingSamples(left: filter(left), right: filter(right))
    }

    private func replacingRightChannelWithLeft() -> Self {
        replacingSamples(left: left, right: left)
    }

    private func replacingSamples(left: [Double], right: [Double]) -> Self {
        Self(
            sampleRate: sampleRate,
            channelCount: channelCount,
            left: left,
            right: right,
            invalidBatchCount: invalidBatchCount
        )
    }
}

/// Names one deliberately corrupted window that the production-quality oracle must reject.
struct AudioWaveformMutationCase: Sendable {
    let name: String
    let window: DecodedAudioWindow
}

/// Thread-safe decoded-PCM sink that aligns evidence using a unique synchronization preamble.
final class UnfilteredDecodedAudioProbe: @unchecked Sendable {
    // The two-half, channel-swapping chirp is intentionally unlike every other probe. Native
    // Opus startup can attenuate its boundary, so recognition uses correlation rather than an
    // exact sample match while retaining ample separation from unrelated decoded audio.
    private static let synchronizationRecognitionCorrelation = 0.78

    let recognizedSynchronizationPreamble = XCTestExpectation(
        description: "viewer decoded the explicit stereo synchronization preamble"
    )
    let receivedWindow = XCTestExpectation(
        description: "viewer retained a bounded unfiltered decoded-audio window"
    )

    private let requiredEvidenceFrames: Int
    private let synchronizationPreamble: DeterministicStereoWaveform
    private let lock = NSLock()
    private var didFulfill = false
    private var didRecognizeSynchronizationPreamble = false
    private var isPostPreambleCaptureArmed = false
    private var callbackCount = 0
    private var evidenceCallbackCount = 0
    private var invalidBatchCount = 0
    private var bestSynchronizationCorrelation = -Double.infinity
    private var observedFormats: Set<String> = []
    private var synchronizationSearchLeft = [Double]()
    private var synchronizationSearchRight = [Double]()
    private var left = [Double]()
    private var right = [Double]()

    init(
        requiredEvidenceFrames: Int,
        synchronizationPreamble: DeterministicStereoWaveform
    ) {
        precondition(requiredEvidenceFrames > 0)
        self.requiredEvidenceFrames = requiredEvidenceFrames
        self.synchronizationPreamble = synchronizationPreamble
        synchronizationSearchLeft.reserveCapacity(synchronizationPreamble.frameCount * 2)
        synchronizationSearchRight.reserveCapacity(synchronizationPreamble.frameCount * 2)
        left.reserveCapacity(requiredEvidenceFrames)
        right.reserveCapacity(requiredEvidenceFrames)
    }

    /// Arms the evidence window only after the receiver has decoded the unique preamble. This
    /// prevents a delayed tail from an earlier probe from becoming frame zero of the waveform.
    @discardableResult
    func beginPostPreambleCapture() -> Bool {
        lock.withLock {
            guard didRecognizeSynchronizationPreamble else { return false }
            left.removeAll(keepingCapacity: true)
            right.removeAll(keepingCapacity: true)
            invalidBatchCount = 0
            evidenceCallbackCount = 0
            didFulfill = false
            isPostPreambleCaptureArmed = true
            return true
        }
    }

    var window: DecodedAudioWindow {
        lock.withLock {
            DecodedAudioWindow(
                sampleRate: DeterministicStereoWaveform.sampleRate,
                channelCount: 2,
                left: left,
                right: right,
                invalidBatchCount: invalidBatchCount
            )
        }
    }

    var diagnosticSummary: String {
        lock.withLock {
            "callbacks=\(callbackCount) evidenceCallbacks=\(evidenceCallbackCount) "
                + "preambleRecognized=\(didRecognizeSynchronizationPreamble) "
                + "preambleCorrelation=\(bestSynchronizationCorrelation) "
                + "formats=\(observedFormats.sorted()) retainedFrames=\(left.count) "
                + "invalidEvidenceBatches=\(invalidBatchCount)"
        }
    }

    func observe(_ buffer: AVAudioPCMBuffer) {
        let format = "\(buffer.format.sampleRate)/\(buffer.format.channelCount)ch/"
            + "\(buffer.format.commonFormat.rawValue)/interleaved=\(buffer.format.isInterleaved)"
        let decodedBatch = Self.decode(buffer)
        var shouldFulfillPreamble = false
        var shouldFulfillWindow = false

        lock.withLock {
            callbackCount += 1
            observedFormats.insert(format)

            if !isPostPreambleCaptureArmed {
                if !didRecognizeSynchronizationPreamble, let decodedBatch {
                    appendToSynchronizationSearch(decodedBatch)
                    if synchronizationPreambleIsPresent() {
                        didRecognizeSynchronizationPreamble = true
                        shouldFulfillPreamble = true
                    }
                }
                return
            }

            evidenceCallbackCount += 1
            let availableFrames = max(0, requiredEvidenceFrames - left.count)
            if availableFrames > 0 {
                let retainedFrames = min(availableFrames, Int(buffer.frameLength))
                if retainedFrames > 0 {
                    if let decodedBatch {
                        left.append(contentsOf: decodedBatch.left.prefix(retainedFrames))
                        right.append(contentsOf: decodedBatch.right.prefix(retainedFrames))
                    } else {
                        // Preserve the callback's duration in the evidence window. Substituting
                        // silence makes malformed post-preamble PCM fail closed rather than
                        // silently collapsing time.
                        invalidBatchCount += 1
                        left.append(contentsOf: repeatElement(0, count: retainedFrames))
                        right.append(contentsOf: repeatElement(0, count: retainedFrames))
                    }
                } else {
                    invalidBatchCount += 1
                }

                if !didFulfill, left.count == requiredEvidenceFrames {
                    didFulfill = true
                    shouldFulfillWindow = true
                }
            }
        }

        if shouldFulfillPreamble {
            recognizedSynchronizationPreamble.fulfill()
        }
        if shouldFulfillWindow {
            receivedWindow.fulfill()
        }
    }

    private func appendToSynchronizationSearch(_ batch: Batch) {
        synchronizationSearchLeft.append(contentsOf: batch.left)
        synchronizationSearchRight.append(contentsOf: batch.right)
        let maximumSearchFrames = synchronizationPreamble.frameCount * 3
        let excessFrames = synchronizationSearchLeft.count - maximumSearchFrames
        if excessFrames > 0 {
            synchronizationSearchLeft.removeFirst(excessFrames)
            synchronizationSearchRight.removeFirst(excessFrames)
        }
    }

    private func synchronizationPreambleIsPresent() -> Bool {
        let preambleFrames = synchronizationPreamble.frameCount
        guard synchronizationSearchLeft.count >= preambleFrames else { return false }

        let latestCandidateStart = synchronizationSearchLeft.count - preambleFrames
        let earliestCandidateStart = max(0, latestCandidateStart - 960)
        var strongestCandidateStart = earliestCandidateStart
        var strongestCandidateCorrelation = -Double.infinity
        var candidateStart = earliestCandidateStart
        while candidateStart <= latestCandidateStart {
            let correlation = Self.combinedCorrelation(
                expected: synchronizationPreamble,
                actualLeft: synchronizationSearchLeft,
                actualRight: synchronizationSearchRight,
                start: candidateStart
            )
            bestSynchronizationCorrelation = max(bestSynchronizationCorrelation, correlation)
            if correlation > strongestCandidateCorrelation {
                strongestCandidateCorrelation = correlation
                strongestCandidateStart = candidateStart
            }
            candidateStart += 24
        }

        let refinementStart = max(earliestCandidateStart, strongestCandidateStart - 23)
        let refinementEnd = min(latestCandidateStart, strongestCandidateStart + 23)
        if refinementStart <= refinementEnd {
            for refinedStart in refinementStart...refinementEnd {
                let correlation = Self.combinedCorrelation(
                    expected: synchronizationPreamble,
                    actualLeft: synchronizationSearchLeft,
                    actualRight: synchronizationSearchRight,
                    start: refinedStart
                )
                bestSynchronizationCorrelation = max(
                    bestSynchronizationCorrelation,
                    correlation
                )
            }
        }
        return bestSynchronizationCorrelation >= Self.synchronizationRecognitionCorrelation
    }

    private static func combinedCorrelation(
        expected: DeterministicStereoWaveform,
        actualLeft: [Double],
        actualRight: [Double],
        start: Int
    ) -> Double {
        var dot = 0.0
        var expectedEnergy = 0.0
        var actualEnergy = 0.0
        for frame in 0..<expected.frameCount {
            let expectedLeft = expected.left[frame]
            let expectedRight = expected.right[frame]
            let actualLeft = actualLeft[start + frame]
            let actualRight = actualRight[start + frame]
            dot += expectedLeft * actualLeft + expectedRight * actualRight
            expectedEnergy += expectedLeft * expectedLeft + expectedRight * expectedRight
            actualEnergy += actualLeft * actualLeft + actualRight * actualRight
        }
        return dot / max(0.000_000_001, sqrt(expectedEnergy * actualEnergy))
    }

    /// One decoded callback projected into normalized left/right samples.
    private struct Batch {
        let left: [Double]
        let right: [Double]
    }

    private static func decode(_ buffer: AVAudioPCMBuffer) -> Batch? {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0,
              buffer.format.sampleRate == DeterministicStereoWaveform.sampleRate,
              buffer.format.channelCount == 2 else {
            return nil
        }

        var left = [Double]()
        var right = [Double]()
        left.reserveCapacity(frameCount)
        right.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            guard let leftSample = sample(buffer, frame: frame, channel: 0),
                  let rightSample = sample(buffer, frame: frame, channel: 1) else {
                return nil
            }
            left.append(leftSample)
            right.append(rightSample)
        }
        return Batch(left: left, right: right)
    }

    private static func sample(
        _ buffer: AVAudioPCMBuffer,
        frame: Int,
        channel: Int
    ) -> Double? {
        let channelCount = Int(buffer.format.channelCount)
        let sampleIndex = buffer.format.isInterleaved
            ? frame * channelCount + channel
            : frame
        let dataIndex = buffer.format.isInterleaved ? 0 : channel

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return nil }
            return Double(data[dataIndex][sampleIndex])
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return nil }
            return Double(data[dataIndex][sampleIndex]) / Double(Int16.max)
        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else { return nil }
            return Double(data[dataIndex][sampleIndex]) / Double(Int32.max)
        default:
            return nil
        }
    }
}

/// Independent failure dimensions reported by the waveform oracle.
enum AudioWaveformViolation: String, Hashable, Sendable {
    case insufficientEvidence
    case invalidDecodedFormat
    case alignment
    case fidelity
    case dropout
    case temporalDiscontinuity
    case gainDistortion
    case clipping
    case channelCorruption
}

/// Measurements, thresholds, and violations produced for one decoded evidence window.
struct AudioWaveformOracleReport: CustomStringConvertible, Sendable {
    let violations: Set<AudioWaveformViolation>
    let alignmentOffsetFrames: Int
    let alignmentCorrelation: Double
    let leftCorrelation: Double
    let rightCorrelation: Double
    let leftGain: Double
    let rightGain: Double
    let leftNormalizedError: Double
    let rightNormalizedError: Double
    let minimumWindowCorrelation: Double
    let minimumWindowEnergyRatio: Double
    let dropoutBlockCount: Int
    let mismatchedBlockCount: Int
    let repeatedBlockCount: Int
    let clippedSampleFraction: Double

    var description: String {
        let labels = violations.map(\.rawValue).sorted().joined(separator: ",")
        return "violations=[\(labels)] alignment=\(alignmentOffsetFrames) "
            + "alignmentCorrelation=\(alignmentCorrelation) "
            + "channelCorrelation=\(leftCorrelation)/\(rightCorrelation) "
            + "gain=\(leftGain)/\(rightGain) "
            + "normalizedError=\(leftNormalizedError)/\(rightNormalizedError) "
            + "minimumWindowCorrelation=\(minimumWindowCorrelation) "
            + "minimumWindowEnergyRatio=\(minimumWindowEnergyRatio) "
            + "dropoutBlocks=\(dropoutBlockCount) "
            + "mismatchedBlocks=\(mismatchedBlockCount) "
            + "repeatedBlocks=\(repeatedBlockCount) "
            + "clippedFraction=\(clippedSampleFraction)"
    }
}

/// Evaluates continuity, fidelity, stereo separation, and clipping from actual decoded PCM.
///
/// Its mutation suite is a meta-oracle: every known dropout or distortion must independently
/// cause a violation, preventing a permissive threshold change from making the main test vacuous.
enum AudioWaveformOracle {
    // Alignment deliberately ignores the first and last 100 ms so ordinary Opus startup/tail
    // settling cannot move the entire waveform. Once that stable offset is known, however, every
    // expected frame is evaluated. The decoded probe carries a trailing guard so alignment delay
    // cannot make the last source frames disappear outside the retained window.
    private static let alignmentTrimFrames = 4_800
    private static let maximumAlignmentOffsetFrames = 2_400
    // Five-millisecond windows stepped every 2.5 ms prevent an audible gap from hiding by
    // straddling a fixed 10 ms boundary.
    private static let analysisWindowFrames = 240
    private static let analysisWindowStepFrames = 120
    private static let repeatedBlockFrames = 480

    static func evaluate(
        expected: DeterministicStereoWaveform,
        decoded: DecodedAudioWindow
    ) -> AudioWaveformOracleReport {
        var violations = Set<AudioWaveformViolation>()
        if decoded.invalidBatchCount > 0
            || decoded.sampleRate != DeterministicStereoWaveform.sampleRate
            || decoded.channelCount != 2 {
            violations.insert(.invalidDecodedFormat)
        }

        let alignmentRange = alignmentTrimFrames..<(expected.frameCount - alignmentTrimFrames)
        guard expected.frameCount > alignmentTrimFrames * 2,
              decoded.frameCount >= alignmentRange.count else {
            violations.insert(.insufficientEvidence)
            return emptyReport(violations: violations)
        }

        let lowerOffset = max(
            -maximumAlignmentOffsetFrames,
            -alignmentRange.lowerBound
        )
        let upperOffset = min(
            maximumAlignmentOffsetFrames,
            decoded.frameCount - alignmentRange.upperBound
        )
        guard lowerOffset <= upperOffset else {
            violations.insert(.insufficientEvidence)
            return emptyReport(violations: violations)
        }

        var bestOffset = lowerOffset
        var bestAlignmentCorrelation = -Double.infinity
        var offset = lowerOffset
        while offset <= upperOffset {
            let correlation = combinedCorrelation(
                expected: expected,
                decoded: decoded,
                range: alignmentRange,
                offset: offset,
                sampleStride: 8
            )
            if correlation > bestAlignmentCorrelation {
                bestAlignmentCorrelation = correlation
                bestOffset = offset
            }
            offset += 8
        }
        for candidate in max(lowerOffset, bestOffset - 8)...min(upperOffset, bestOffset + 8) {
            let correlation = combinedCorrelation(
                expected: expected,
                decoded: decoded,
                range: alignmentRange,
                offset: candidate,
                sampleStride: 1
            )
            if correlation > bestAlignmentCorrelation {
                bestAlignmentCorrelation = correlation
                bestOffset = candidate
            }
        }

        // Repeated native 192 kbps Opus baselines are above 0.999 correlation with roughly 0.01
        // normalized error. These limits retain broad codec/runner headroom while rejecting the
        // plainly audible distortion that the previous 0.82/0.55 limits admitted.
        if bestAlignmentCorrelation < 0.95 {
            violations.insert(.alignment)
        }

        let evaluationRange = 0..<expected.frameCount
        guard evaluationRange.lowerBound + bestOffset >= 0,
              evaluationRange.upperBound + bestOffset <= decoded.frameCount else {
            violations.insert(.insufficientEvidence)
            // A decoded window that aligns only by moving a source edge outside retained PCM has
            // dropped time, not merely supplied too few arbitrary samples. Keep the fail-closed
            // evidence label while also classifying the observable media defect correctly.
            violations.insert(.temporalDiscontinuity)
            return emptyReport(violations: violations)
        }

        let left = channelStatistics(
            expected: expected.left,
            actual: decoded.left,
            range: evaluationRange,
            offset: bestOffset
        )
        let right = channelStatistics(
            expected: expected.right,
            actual: decoded.right,
            range: evaluationRange,
            offset: bestOffset
        )
        let leftAgainstRight = correlation(
            expected: expected.right,
            actual: decoded.left,
            range: evaluationRange,
            offset: bestOffset
        )
        let rightAgainstLeft = correlation(
            expected: expected.left,
            actual: decoded.right,
            range: evaluationRange,
            offset: bestOffset
        )

        if left.correlation < 0.96
            || right.correlation < 0.96
            || left.normalizedError > 0.20
            || right.normalizedError > 0.20 {
            violations.insert(.fidelity)
        }
        if left.gain < 0.85 || left.gain > 1.15
            || right.gain < 0.85 || right.gain > 1.15 {
            violations.insert(.gainDistortion)
        }
        let gainRatio = left.gain / max(right.gain, 0.000_001)
        if left.correlation < 0.90
            || right.correlation < 0.90
            || left.correlation - abs(leftAgainstRight) < 0.30
            || right.correlation - abs(rightAgainstLeft) < 0.30
            || gainRatio < 0.85
            || gainRatio > 1.18 {
            violations.insert(.channelCorruption)
        }

        var dropoutBlockCount = 0
        var mismatchedBlockCount = 0
        var repeatedBlockCount = 0
        var minimumWindowCorrelation = Double.infinity
        var minimumWindowEnergyRatio = Double.infinity
        var blockStart = evaluationRange.lowerBound
        while blockStart + analysisWindowFrames <= evaluationRange.upperBound {
            let blockRange = blockStart..<(blockStart + analysisWindowFrames)
            let blockCorrelation = combinedCorrelation(
                expected: expected,
                decoded: decoded,
                range: blockRange,
                offset: bestOffset,
                sampleStride: 1
            )
            let expectedEnergy = combinedEnergy(
                left: expected.left,
                right: expected.right,
                range: blockRange,
                offset: 0
            )
            let actualEnergy = combinedEnergy(
                left: decoded.left,
                right: decoded.right,
                range: blockRange,
                offset: bestOffset
            )
            let energyRatio = actualEnergy / max(0.000_000_001, expectedEnergy)
            minimumWindowCorrelation = min(minimumWindowCorrelation, blockCorrelation)
            minimumWindowEnergyRatio = min(minimumWindowEnergyRatio, energyRatio)
            if energyRatio < 0.25 {
                dropoutBlockCount += 1
            }
            if blockCorrelation < 0.90 {
                mismatchedBlockCount += 1
            }

            let actualStart = blockStart + bestOffset
            if actualStart - repeatedBlockFrames >= 0,
               blocksAreExactlyEqual(
                   decoded: decoded,
                   firstStart: actualStart - repeatedBlockFrames,
                   secondStart: actualStart,
                   count: repeatedBlockFrames
               ) {
                repeatedBlockCount += 1
            }
            blockStart += analysisWindowStepFrames
        }
        if dropoutBlockCount > 0 {
            violations.insert(.dropout)
        }
        if repeatedBlockCount > 0 || mismatchedBlockCount > 0 {
            violations.insert(.temporalDiscontinuity)
        }

        var clippedSampleCount = 0
        var evaluatedSampleCount = 0
        for frame in evaluationRange {
            let actualFrame = frame + bestOffset
            for sample in [decoded.left[actualFrame], decoded.right[actualFrame]] {
                evaluatedSampleCount += 1
                if abs(sample) >= 0.98 {
                    clippedSampleCount += 1
                }
            }
        }
        let clippedSampleFraction = Double(clippedSampleCount)
            / Double(max(1, evaluatedSampleCount))
        if clippedSampleFraction > 0.000_5 {
            violations.insert(.clipping)
        }

        return AudioWaveformOracleReport(
            violations: violations,
            alignmentOffsetFrames: bestOffset,
            alignmentCorrelation: bestAlignmentCorrelation,
            leftCorrelation: left.correlation,
            rightCorrelation: right.correlation,
            leftGain: left.gain,
            rightGain: right.gain,
            leftNormalizedError: left.normalizedError,
            rightNormalizedError: right.normalizedError,
            minimumWindowCorrelation: minimumWindowCorrelation,
            minimumWindowEnergyRatio: minimumWindowEnergyRatio,
            dropoutBlockCount: dropoutBlockCount,
            mismatchedBlockCount: mismatchedBlockCount,
            repeatedBlockCount: repeatedBlockCount,
            clippedSampleFraction: clippedSampleFraction
        )
    }

    /// Per-channel measurements used by the waveform thresholds and failure report.
    private struct ChannelStatistics {
        let correlation: Double
        let gain: Double
        let normalizedError: Double
    }

    private static func channelStatistics(
        expected: [Double],
        actual: [Double],
        range: Range<Int>,
        offset: Int
    ) -> ChannelStatistics {
        var dot = 0.0
        var expectedEnergy = 0.0
        var actualEnergy = 0.0
        for frame in range {
            let expectedSample = expected[frame]
            let actualSample = actual[frame + offset]
            dot += expectedSample * actualSample
            expectedEnergy += expectedSample * expectedSample
            actualEnergy += actualSample * actualSample
        }
        let correlation = dot / max(0.000_000_001, sqrt(expectedEnergy * actualEnergy))
        let gain = dot / max(0.000_000_001, expectedEnergy)
        var errorEnergy = 0.0
        for frame in range {
            let error = actual[frame + offset] - gain * expected[frame]
            errorEnergy += error * error
        }
        let normalizedError = sqrt(
            errorEnergy / max(0.000_000_001, gain * gain * expectedEnergy)
        )
        return ChannelStatistics(
            correlation: correlation,
            gain: gain,
            normalizedError: normalizedError
        )
    }

    private static func combinedCorrelation(
        expected: DeterministicStereoWaveform,
        decoded: DecodedAudioWindow,
        range: Range<Int>,
        offset: Int,
        sampleStride: Int
    ) -> Double {
        var dot = 0.0
        var expectedEnergy = 0.0
        var actualEnergy = 0.0
        var frame = range.lowerBound
        while frame < range.upperBound {
            let actualFrame = frame + offset
            let expectedLeft = expected.left[frame]
            let expectedRight = expected.right[frame]
            let actualLeft = decoded.left[actualFrame]
            let actualRight = decoded.right[actualFrame]
            dot += expectedLeft * actualLeft + expectedRight * actualRight
            expectedEnergy += expectedLeft * expectedLeft + expectedRight * expectedRight
            actualEnergy += actualLeft * actualLeft + actualRight * actualRight
            frame += sampleStride
        }
        return dot / max(0.000_000_001, sqrt(expectedEnergy * actualEnergy))
    }

    private static func correlation(
        expected: [Double],
        actual: [Double],
        range: Range<Int>,
        offset: Int
    ) -> Double {
        var dot = 0.0
        var expectedEnergy = 0.0
        var actualEnergy = 0.0
        for frame in range {
            let expectedSample = expected[frame]
            let actualSample = actual[frame + offset]
            dot += expectedSample * actualSample
            expectedEnergy += expectedSample * expectedSample
            actualEnergy += actualSample * actualSample
        }
        return dot / max(0.000_000_001, sqrt(expectedEnergy * actualEnergy))
    }

    private static func combinedEnergy(
        left: [Double],
        right: [Double],
        range: Range<Int>,
        offset: Int
    ) -> Double {
        var energy = 0.0
        for frame in range {
            let index = frame + offset
            energy += left[index] * left[index] + right[index] * right[index]
        }
        return energy
    }

    private static func blocksAreExactlyEqual(
        decoded: DecodedAudioWindow,
        firstStart: Int,
        secondStart: Int,
        count: Int
    ) -> Bool {
        for index in 0..<count {
            if decoded.left[firstStart + index] != decoded.left[secondStart + index]
                || decoded.right[firstStart + index] != decoded.right[secondStart + index] {
                return false
            }
        }
        return true
    }

    private static func emptyReport(
        violations: Set<AudioWaveformViolation>
    ) -> AudioWaveformOracleReport {
        AudioWaveformOracleReport(
            violations: violations,
            alignmentOffsetFrames: 0,
            alignmentCorrelation: 0,
            leftCorrelation: 0,
            rightCorrelation: 0,
            leftGain: 0,
            rightGain: 0,
            leftNormalizedError: .infinity,
            rightNormalizedError: .infinity,
            minimumWindowCorrelation: 0,
            minimumWindowEnergyRatio: 0,
            dropoutBlockCount: 0,
            mismatchedBlockCount: 0,
            repeatedBlockCount: 0,
            clippedSampleFraction: 0
        )
    }
}

func makeStereoOracleSampleBuffer(
    waveform: DeterministicStereoWaveform,
    range: Range<Int>
) throws -> CMSampleBuffer {
    precondition(range.lowerBound >= 0 && range.upperBound <= waveform.frameCount)
    var samples = [Int16](repeating: 0, count: range.count * 2)
    for (outputFrame, sourceFrame) in range.enumerated() {
        samples[outputFrame * 2] = Int16(
            (waveform.left[sourceFrame] * Double(Int16.max)).rounded()
        )
        samples[outputFrame * 2 + 1] = Int16(
            (waveform.right[sourceFrame] * Double(Int16.max)).rounded()
        )
    }

    let byteCount = samples.count * MemoryLayout<Int16>.size
    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: byteCount,
        flags: 0,
        blockBufferOut: &blockBuffer
    )
    guard status == kCMBlockBufferNoErr, let blockBuffer else {
        throw AudioWaveformSampleBufferTestError.blockBufferCreationFailed(status)
    }
    status = samples.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else {
            return kCMBlockBufferBadLengthParameterErr
        }
        return CMBlockBufferReplaceDataBytes(
            with: baseAddress,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
    }
    guard status == kCMBlockBufferNoErr else {
        throw AudioWaveformSampleBufferTestError.blockBufferCopyFailed(status)
    }

    var streamDescription = AudioStreamBasicDescription(
        mSampleRate: DeterministicStereoWaveform.sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 16,
        mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    status = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &streamDescription,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    )
    guard status == noErr, let formatDescription else {
        throw AudioWaveformSampleBufferTestError.formatDescriptionCreationFailed(status)
    }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: CMTime(value: Int64(range.lowerBound), timescale: 48_000),
        decodeTimeStamp: .invalid
    )
    var sampleSize = 4
    var sampleBuffer: CMSampleBuffer?
    status = CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: range.count,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sampleBuffer else {
        throw AudioWaveformSampleBufferTestError.sampleBufferCreationFailed(status)
    }
    return sampleBuffer
}


/// Construction failures for synthetic audio sample buffers used by the physical oracle.
enum AudioWaveformSampleBufferTestError: Error {
    case blockBufferCreationFailed(OSStatus)
    case blockBufferCopyFailed(OSStatus)
    case formatDescriptionCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
}
