import CoreVideo
import XCTest
@testable import AudioStreamer
@testable import WebRTCTransport

final class PhysicalOracleEvaluatorTests: XCTestCase {
    private let session = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let renderer = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testProductionAudioAccessibilityContractRoundTrips() throws {
        let production = WorldwideAudioPlayoutOracleSnapshot(
            sessionGeneration: session,
            callbackCount: 41,
            frameCount: 19_680,
            failureCount: 0,
            pcmSampleCount: 39_360,
            pcmNonzeroSampleCount: 38_000,
            pcmAbsoluteSampleSum: 38_000_000,
            pcmLeftAbsoluteSampleSum: 19_000_000,
            pcmRightAbsoluteSampleSum: 19_000_000,
            pcmStereoDifferenceAbsoluteSampleSum: 9_000_000,
            pcmEnvelopeTransitionCount: 3,
            pcmShapeAnomalyCallbackCount: 1,
            pcmBoundaryDiscontinuityCallbackCount: 1,
            lastCallbackMeanMagnitude: 1_250,
            lastPeakMagnitude: 8_000,
            inboundAudioEnergy: 2.5,
            inboundSamplesDuration: 0.41,
            fullQualityInvariantsHold: true
        )

        let parsed = try XCTUnwrap(
            PhysicalAudioPlayoutSnapshot(
                accessibilityValue: production.accessibilityValue
            )
        )
        XCTAssertEqual(parsed.sessionGeneration, session)
        XCTAssertEqual(parsed.callbackCount, 41)
        XCTAssertEqual(parsed.frameCount, 19_680)
        XCTAssertEqual(parsed.failureCount, 0)
        XCTAssertEqual(parsed.pcmSampleCount, 39_360)
        XCTAssertEqual(parsed.pcmNonzeroSampleCount, 38_000)
        XCTAssertEqual(parsed.pcmAbsoluteSampleSum, 38_000_000)
        XCTAssertEqual(parsed.pcmLeftAbsoluteSampleSum, 19_000_000)
        XCTAssertEqual(parsed.pcmRightAbsoluteSampleSum, 19_000_000)
        XCTAssertEqual(parsed.pcmStereoDifferenceAbsoluteSampleSum, 9_000_000)
        XCTAssertEqual(parsed.pcmEnvelopeTransitionCount, 3)
        XCTAssertEqual(parsed.pcmShapeAnomalyCallbackCount, 1)
        XCTAssertEqual(parsed.pcmBoundaryDiscontinuityCallbackCount, 1)
        XCTAssertEqual(parsed.lastCallbackMeanMagnitude, 1_250)
        XCTAssertEqual(parsed.lastPeakMagnitude, 8_000)
        XCTAssertEqual(parsed.inboundAudioEnergy, 2.5)
        XCTAssertEqual(parsed.inboundSamplesDuration, 0.41)
        XCTAssertTrue(parsed.fullQualityInvariantsHold)
    }

    func testAudioEvaluatorAcceptsOnlyFreshFailureFreeFullQualityProgress() {
        let previous = audio(callbacks: 10, frames: 4_800, failures: 0)
        let current = audio(callbacks: 20, frames: 9_600, failures: 0)

        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(previous: previous, current: current),
            .advancing
        )
    }

    func testAudioEvaluatorRejectsOneShotOrStalledEvidence() {
        let oneShot = audio(callbacks: 1, frames: 480, failures: 0)
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(previous: oneShot, current: oneShot),
            .callbackCounterStalled
        )

        let callbackOnly = audio(callbacks: 2, frames: 480, failures: 0)
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: oneShot,
                current: callbackOnly
            ),
            .frameCounterStalled
        )
    }

    func testAudioEvaluatorRejectsFailureIncrementAndLostQuality() {
        let previous = audio(callbacks: 10, frames: 4_800, failures: 0)
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(callbacks: 20, frames: 9_600, failures: 1)
            ),
            .failureCounterChanged
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    fullQuality: false
                )
            ),
            .fullQualityMissing
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: audio(callbacks: 10, frames: 4_800, failures: 3),
                current: audio(callbacks: 20, frames: 9_600, failures: 3)
            ),
            .renderFailurePresent,
            "A failure before the observation window must not become an accepted baseline."
        )
    }

    func testAudioEvaluatorRejectsStructurallyImpossibleCounterSnapshots() {
        let previous = audio(callbacks: 10, frames: 4_800, failures: 0)
        let impossible: [(String, PhysicalAudioPlayoutSnapshot, PhysicalAudioPlayoutDelta)] = [
            (
                "nonzero exceeds samples",
                audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    pcmNonzero: 19_201
                ),
                .invalidPCMStructure
            ),
            (
                "channel sums disagree with total",
                audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    pcmLeftAbsolute: 15_000_000,
                    pcmRightAbsolute: 15_000_000
                ),
                .invalidPCMStructure
            ),
            (
                "stereo difference exceeds total magnitude",
                audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    pcmStereoDifferenceAbsolute: 30_000_000
                ),
                .invalidPCMStructure
            ),
            (
                "peak exceeds signed-16-bit magnitude",
                audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    peak: 32_769
                ),
                .invalidPCMStructure
            ),
            (
                "maximum callback gap is not reflected in its violation counter",
                audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    gapViolations: 0,
                    maximumGapNanoseconds: 300_000_000
                ),
                .invalidPCMStructure
            ),
            (
                "callback gap violation has no corresponding over-threshold gap",
                audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    gapViolations: 1,
                    maximumGapNanoseconds: 25_000_000
                ),
                .invalidPCMStructure
            ),
            (
                "inbound normalized energy exceeds duration",
                audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    inboundEnergy: 10,
                    inboundDuration: 0.2
                ),
                .invalidInboundStructure
            ),
        ]
        for (name, mutant, expected) in impossible {
            XCTAssertEqual(
                PhysicalAudioPlayoutEvaluator.evaluate(
                    previous: previous,
                    current: mutant
                ),
                expected,
                name
            )
        }
    }

    func testAudioEvaluatorRejectsSilentMonoClippedAndMissingInboundContent() {
        let previous = audio(callbacks: 10, frames: 4_800, failures: 0)
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    pcmNonzero: previous.pcmNonzeroSampleCount,
                    pcmAbsolute: previous.pcmAbsoluteSampleSum,
                    pcmLeftAbsolute: previous.pcmLeftAbsoluteSampleSum,
                    pcmRightAbsolute: previous.pcmRightAbsoluteSampleSum,
                    pcmStereoDifferenceAbsolute:
                        previous.pcmStereoDifferenceAbsoluteSampleSum,
                    peak: 0
                )
            ),
            .pcmContentStalled
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    pcmStereoDifferenceAbsolute:
                        previous.pcmStereoDifferenceAbsoluteSampleSum
                )
            ),
            .pcmContentStalled
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    clipped: 1
                )
            ),
            .clippedSamplesPresent
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    inboundEnergy: previous.inboundAudioEnergy,
                    inboundDuration: previous.inboundSamplesDuration
                )
            ),
            .inboundContentStalled
        )

        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    silenceCallbacks: 1
                )
            ),
            .explicitSilencePresent
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    gapViolations: 1,
                    maximumGapNanoseconds: 300_000_000
                )
            ),
            .callbackGapDetected
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    nearSilenceCallbacks: 1,
                    currentNearSilenceFrames: 480,
                    maximumNearSilenceFrames: 480
                )
            ),
            .nearSilenceDetected
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    recoveryRebuilds: 1
                )
            ),
            .audioUnitRebuilt
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    peak: 0
                )
            ),
            .peakMissing
        )
    }

    func testAudioEvaluatorRejectsPCMAndInboundCounterRegressionDirectly() {
        let previous = audio(callbacks: 10, frames: 4_800, failures: 0)
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    pcmAbsolute: previous.pcmAbsoluteSampleSum - 1
                )
            ),
            .pcmCounterRegressed
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    callbacks: 20,
                    frames: 9_600,
                    failures: 0,
                    inboundEnergy: previous.inboundAudioEnergy - 0.001,
                    inboundDuration: previous.inboundSamplesDuration - 0.001
                )
            ),
            .inboundCounterRegressed
        )
    }

    func testAudioContinuityWindowRejectsLateSingleIncrementAndLowRealtimeCoverage() {
        let start: TimeInterval = 10_000
        var late = PhysicalAudioContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 2.5
        )
        XCTAssertEqual(
            late.observe(audio(callbacks: 10, frames: 4_800, failures: 0), at: start),
            .waiting
        )
        XCTAssertEqual(
            late.observe(
                audio(callbacks: 11, frames: 5_280, failures: 0),
                at: start + 2.1
            ),
            .waiting,
            "The first late increment starts the window; it must not complete it."
        )

        var burst = PhysicalAudioContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 2.5
        )
        _ = burst.observe(audio(callbacks: 10, frames: 4_800, failures: 0), at: start)
        _ = burst.observe(
            audio(callbacks: 20, frames: 9_600, failures: 0),
            at: start + 0.1
        )
        _ = burst.observe(
            audio(callbacks: 21, frames: 10_080, failures: 0),
            at: start + 1.1
        )
        XCTAssertEqual(
            burst.observe(
                audio(callbacks: 22, frames: 10_560, failures: 0),
                at: start + 2.2
            ),
            .waiting,
            "Sparse counter bumps cannot cover a real two-second 48 kHz interval."
        )
    }

    func testElapsedAudioOracleRejectsMostlySilentHalfStereoLowLevelAndOvercountedMutants() {
        let previous = audio(callbacks: 10, frames: 48_000, failures: 0)
        let healthy = audio(callbacks: 110, frames: 144_000, failures: 0)
        XCTAssertTrue(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: healthy,
                elapsed: 2
            )
        )

        let frameDelta: UInt64 = 96_000
        let sampleDelta = frameDelta * 2
        let previousSamples = previous.pcmSampleCount
        let previousNonzero = previous.pcmNonzeroSampleCount
        let previousAbsolute = previous.pcmAbsoluteSampleSum
        let previousLeft = previous.pcmLeftAbsoluteSampleSum
        let previousRight = previous.pcmRightAbsoluteSampleSum
        let previousStereoDifference = previous.pcmStereoDifferenceAbsoluteSampleSum
        let inboundEnergy = previous.inboundAudioEnergy + 0.5
        let inboundDuration = previous.inboundSamplesDuration + 2

        let mostlySilent = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            pcmSamples: previousSamples + sampleDelta,
            pcmNonzero: previousNonzero + sampleDelta / 10,
            pcmAbsolute: previousAbsolute + sampleDelta * 1_000,
            pcmLeftAbsolute: previousLeft + sampleDelta * 500,
            pcmRightAbsolute: previousRight + sampleDelta * 500,
            pcmStereoDifferenceAbsolute: previousStereoDifference + sampleDelta * 300,
            inboundEnergy: inboundEnergy,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: mostlySilent,
                elapsed: 2
            ),
            "Ten percent nonzero PCM must not prove continuous audible output."
        )

        let halfStereo = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            pcmSamples: previousSamples + sampleDelta,
            pcmNonzero: previousNonzero + sampleDelta,
            pcmAbsolute: previousAbsolute + sampleDelta * 1_000,
            pcmLeftAbsolute: previousLeft + sampleDelta * 990,
            pcmRightAbsolute: previousRight + sampleDelta * 10,
            pcmStereoDifferenceAbsolute: previousStereoDifference + sampleDelta * 400,
            inboundEnergy: inboundEnergy,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: halfStereo,
                elapsed: 2
            ),
            "A nearly missing channel must not satisfy the deterministic stereo-tone oracle."
        )

        let epsilonInboundEnergy = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            inboundEnergy: previous.inboundAudioEnergy + 0.000_001,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: epsilonInboundEnergy,
                elapsed: 2
            ),
            "A numerically positive but inaudible inbound-energy delta must not pass."
        )

        let swappedToneChannels = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            leftCrossings: previous.pcmLeftZeroCrossingCount + 2 * 12_502,
            rightCrossings: previous.pcmRightZeroCrossingCount + 2 * 9_000,
            inboundEnergy: inboundEnergy,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: swappedToneChannels,
                elapsed: 2
            ),
            "Per-channel tone frequencies must bind evidence to the generated source."
        )

        let frozenChallenge = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            envelopeTransitions: previous.pcmEnvelopeTransitionCount,
            inboundEnergy: inboundEnergy,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: frozenChallenge,
                elapsed: 2
            ),
            "Repeating one stationary callback must not satisfy the coded source challenge."
        )

        let rapidGainFlicker = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            envelopeTransitions: previous.pcmEnvelopeTransitionCount + 100,
            inboundEnergy: inboundEnergy,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: rapidGainFlicker,
                elapsed: 2
            ),
            "Alternating callback gain must fail the bounded envelope-transition rate."
        )

        let nearMono = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            pcmSamples: previousSamples + sampleDelta,
            pcmNonzero: previousNonzero + sampleDelta,
            pcmAbsolute: previousAbsolute + sampleDelta * 1_000,
            pcmLeftAbsolute: previousLeft + sampleDelta * 500,
            pcmRightAbsolute: previousRight + sampleDelta * 500,
            pcmStereoDifferenceAbsolute: previousStereoDifference + sampleDelta * 5,
            inboundEnergy: inboundEnergy,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: nearMono,
                elapsed: 2
            ),
            "Merely nonzero channel differences must not let near-mono output pass."
        )

        let lowLevelNoise = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            pcmSamples: previousSamples + sampleDelta,
            pcmNonzero: previousNonzero + sampleDelta,
            pcmAbsolute: previousAbsolute + sampleDelta * 2,
            pcmLeftAbsolute: previousLeft + sampleDelta,
            pcmRightAbsolute: previousRight + sampleDelta,
            pcmStereoDifferenceAbsolute: previousStereoDifference + sampleDelta,
            inboundEnergy: inboundEnergy,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: lowLevelNoise,
                elapsed: 2
            ),
            "Tiny nonzero noise must not stand in for the deterministic audible source."
        )

        let overcountedPCM = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            pcmSamples: previousSamples + sampleDelta * 2,
            pcmNonzero: previousNonzero + sampleDelta * 2,
            pcmAbsolute: previousAbsolute + sampleDelta * 2_000,
            pcmLeftAbsolute: previousLeft + sampleDelta * 1_000,
            pcmRightAbsolute: previousRight + sampleDelta * 1_000,
            pcmStereoDifferenceAbsolute: previousStereoDifference + sampleDelta * 600,
            inboundEnergy: inboundEnergy,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: overcountedPCM,
                elapsed: 2
            ),
            "Duplicated PCM accounting must not prove one rendered sample per stereo frame."
        )

        let flattenedIntervalWithHealthyEndpoint = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            shapeAnomalies: previous.pcmShapeAnomalyCallbackCount + 20,
            callbackMean: 5_100,
            peak: 8_000,
            inboundEnergy: inboundEnergy,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: flattenedIntervalWithHealthyEndpoint,
                elapsed: 2
            ),
            "One healthy final callback cannot erase flattened PCM earlier in the interval."
        )

        let phaseResetIntervalWithHealthyEndpoint = audio(
            callbacks: 110,
            frames: 144_000,
            failures: 0,
            boundaryDiscontinuities:
                previous.pcmBoundaryDiscontinuityCallbackCount + 20,
            callbackMean: 5_100,
            peak: 8_000,
            inboundEnergy: inboundEnergy,
            inboundDuration: inboundDuration
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: phaseResetIntervalWithHealthyEndpoint,
                elapsed: 2
            ),
            "Repeated 10 ms phase resets cannot be hidden by a healthy final callback."
        )
    }

    func testAudioContinuityRejectsOneCorruptPublicationWithoutLaterDilution() {
        let start: TimeInterval = 50_000
        var tracker = PhysicalAudioContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 1.5
        )
        let baseline = audio(callbacks: 10, frames: 4_800, failures: 0)
        XCTAssertEqual(tracker.observe(baseline, at: start), .waiting)
        XCTAssertEqual(
            tracker.observe(
                audio(
                    callbacks: 110,
                    frames: 52_800,
                    failures: 0,
                    shapeAnomalies: 20,
                    boundaryDiscontinuities: 20
                ),
                at: start + 1
            ),
            .rejected,
            "A corrupt second cannot be diluted by later healthy callbacks in the proof window."
        )
    }

    func testCumulativeWaveformAnomalyRateHasAnExactThreePercentBoundary() {
        let previous = audio(callbacks: 10, frames: 48_000, failures: 0)
        XCTAssertTrue(
            PhysicalAudioPlayoutEvaluator.waveformAnomalyRatesAreAcceptable(
                previous: previous,
                current: audio(
                    callbacks: 110,
                    frames: 96_000,
                    failures: 0,
                    shapeAnomalies: 3,
                    boundaryDiscontinuities: 3
                )
            ),
            "The coded challenge's bounded transition callbacks must remain admissible."
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.waveformAnomalyRatesAreAcceptable(
                previous: previous,
                current: audio(
                    callbacks: 110,
                    frames: 96_000,
                    failures: 0,
                    shapeAnomalies: 4,
                    boundaryDiscontinuities: 3
                )
            )
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.waveformAnomalyRatesAreAcceptable(
                previous: previous,
                current: audio(
                    callbacks: 110,
                    frames: 96_000,
                    failures: 0,
                    shapeAnomalies: 3,
                    boundaryDiscontinuities: 4
                )
            )
        )
    }

    func testCallbackGapStructureBindsThe25MillisecondThreshold() {
        XCTAssertTrue(
            PhysicalAudioPlayoutEvaluator.hasValidStructure(
                audio(
                    callbacks: 10,
                    frames: 4_800,
                    failures: 0,
                    maximumGapNanoseconds: 25_000_000
                )
            ),
            "The exact permitted boundary is not a violation."
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.hasValidStructure(
                audio(
                    callbacks: 10,
                    frames: 4_800,
                    failures: 0,
                    maximumGapNanoseconds: 25_000_001
                )
            ),
            "An over-threshold native gap cannot claim zero violations."
        )
        XCTAssertTrue(
            PhysicalAudioPlayoutEvaluator.hasValidStructure(
                audio(
                    callbacks: 10,
                    frames: 4_800,
                    failures: 0,
                    gapViolations: 1,
                    maximumGapNanoseconds: 25_000_001
                )
            )
        )
    }

    func testElapsedAudioOracleRejectsImpossibleFrameAndInboundRates() {
        let previous = audio(callbacks: 10, frames: 48_000, failures: 0)
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: audio(callbacks: 210, frames: 248_000, failures: 0),
                elapsed: 2
            ),
            "A huge batched counter leap is not real-time continuity."
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: audio(
                    callbacks: 110,
                    frames: 144_000,
                    failures: 0,
                    inboundDuration: previous.inboundSamplesDuration + 8
                ),
                elapsed: 2
            ),
            "Inbound duration cannot advance four times faster than wall clock."
        )
    }

    func testElapsedAudioOracleRejectsBackgroundStopResumeAndShortFlicker() {
        let previous = audio(callbacks: 1_000, frames: 480_000, failures: 0)
        let elapsed: TimeInterval = 43
        let finalFrames = previous.frameCount + UInt64(elapsed * 48_000)
        let resumedAfterStall = audio(
            callbacks: 5_300,
            frames: finalFrames,
            failures: 0,
            gapViolations: previous.callbackGapViolationCount + 1,
            maximumGapNanoseconds: 15_000_000_000,
            inboundEnergy: previous.inboundAudioEnergy + elapsed * 0.25,
            inboundDuration: previous.inboundSamplesDuration + elapsed
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: resumedAfterStall,
                elapsed: elapsed,
                minimumRealtimeCoverage: 0.90
            ),
            "Catching counters up after a background stall must not erase the native gap."
        )

        let oneFlickeringCallback = audio(
            callbacks: 5_300,
            frames: finalFrames,
            failures: 0,
            nearSilenceCallbacks: previous.nearSilenceCallbackCount + 1,
            maximumNearSilenceFrames: 480,
            inboundEnergy: previous.inboundAudioEnergy + elapsed * 0.25,
            inboundDuration: previous.inboundSamplesDuration + elapsed
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: oneFlickeringCallback,
                elapsed: elapsed,
                minimumRealtimeCoverage: 0.90
            ),
            "A short near-silent callback must not disappear inside healthy aggregate ratios."
        )
    }

    func testElapsedAudioOracleRejectsMalformedDeltaHiddenByLargeHealthyHistory() {
        let previous = audio(
            callbacks: 1_000_000,
            frames: 480_000_000,
            failures: 0,
            pcmNonzero: 950_400_000
        )
        let frameDelta: UInt64 = 96_000
        let sampleDelta = frameDelta * 2
        let malformed = audio(
            callbacks: 1_000_200,
            frames: previous.frameCount + frameDelta,
            failures: 0,
            pcmSamples: previous.pcmSampleCount + sampleDelta,
            pcmNonzero: previous.pcmNonzeroSampleCount + sampleDelta + 1,
            pcmAbsolute: previous.pcmAbsoluteSampleSum + sampleDelta * 1_000,
            pcmLeftAbsolute: previous.pcmLeftAbsoluteSampleSum + sampleDelta * 900,
            pcmRightAbsolute: previous.pcmRightAbsoluteSampleSum + sampleDelta * 900,
            pcmStereoDifferenceAbsolute:
                previous.pcmStereoDifferenceAbsoluteSampleSum + sampleDelta * 600,
            inboundEnergy: previous.inboundAudioEnergy + 3,
            inboundDuration: previous.inboundSamplesDuration + 2
        )
        XCTAssertTrue(
            PhysicalAudioPlayoutEvaluator.hasValidStructure(malformed),
            "The large lifetime baseline intentionally masks the malformed interval."
        )
        XCTAssertFalse(
            PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: previous,
                current: malformed,
                elapsed: 2
            ),
            "Interval-local accounting must fail even when lifetime ratios look healthy."
        )
    }

    func testAudioContinuityWindowRequiresMultipleRealtimeContentAdvances() {
        let start: TimeInterval = 20_000
        var tracker = PhysicalAudioContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 1.5
        )
        XCTAssertEqual(
            tracker.observe(audio(callbacks: 10, frames: 4_800, failures: 0), at: start),
            .waiting
        )
        XCTAssertEqual(
            tracker.observe(
                audio(callbacks: 110, frames: 52_800, failures: 0),
                at: start + 1
            ),
            .waiting
        )
        XCTAssertEqual(
            tracker.observe(
                audio(callbacks: 210, frames: 100_800, failures: 0),
                at: start + 2
            ),
            .waiting
        )
        XCTAssertEqual(
            tracker.observe(
                audio(callbacks: 310, frames: 148_800, failures: 0),
                at: start + 3
            ),
            .satisfied,
            "The gate must accept the production one-second statistics publication cadence."
        )
    }

    func testAudioContinuityTrackerRejectsExpectedSessionAndResetsAfterProgressGap() {
        let start: TimeInterval = 40_000
        var wrongSession = PhysicalAudioContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 2.5,
            expectedSessionGeneration: UUID()
        )
        XCTAssertEqual(
            wrongSession.observe(
                audio(callbacks: 10, frames: 4_800, failures: 0),
                at: start
            ),
            .rejected
        )

        var gap = PhysicalAudioContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 1.5
        )
        XCTAssertEqual(
            gap.observe(audio(callbacks: 10, frames: 4_800, failures: 0), at: start),
            .waiting
        )
        XCTAssertEqual(
            gap.observe(
                audio(callbacks: 110, frames: 52_800, failures: 0),
                at: start + 1
            ),
            .waiting
        )
        XCTAssertEqual(
            gap.observe(
                audio(callbacks: 310, frames: 148_800, failures: 0),
                at: start + 3
            ),
            .waiting,
            "A gap beyond the monotonic progress budget must restart the evidence window."
        )
        XCTAssertEqual(
            gap.observe(
                audio(callbacks: 410, frames: 196_800, failures: 0),
                at: start + 4
            ),
            .waiting
        )
    }

    func testAudioEvaluatorRejectsCounterRegressionAndSessionReplacement() {
        let previous = audio(callbacks: 10, frames: 4_800, failures: 0)
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(callbacks: 9, frames: 5_280, failures: 0)
            ),
            .callbackCounterRegressed
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(callbacks: 11, frames: 4_700, failures: 0)
            ),
            .frameCounterRegressed
        )
        XCTAssertEqual(
            PhysicalAudioPlayoutEvaluator.evaluate(
                previous: previous,
                current: audio(
                    session: UUID(),
                    callbacks: 11,
                    frames: 5_280,
                    failures: 0
                )
            ),
            .sessionChanged
        )
    }

    func testProductionVideoAccessibilityContractRoundTrips() throws {
        let production = WorldwideVideoRenderOracleSnapshot(
            rendererID: renderer,
            frameCount: 12,
            timestampNanoseconds: 900_000_000,
            width: 1_920,
            height: 1_080,
            contentDigest: 0x1234,
            contentSampleCount: 4,
            contentChangeCount: 3
        )

        let parsed = try XCTUnwrap(
            PhysicalVideoRenderSnapshot(
                accessibilityValue: production.accessibilityValue
            )
        )
        XCTAssertEqual(parsed.rendererID, renderer)
        XCTAssertEqual(parsed.frameCount, 12)
        XCTAssertEqual(parsed.timestampNanoseconds, 900_000_000)
        XCTAssertEqual(parsed.width, 1_920)
        XCTAssertEqual(parsed.height, 1_080)
        XCTAssertEqual(parsed.contentDigest, 0x1234)
        XCTAssertEqual(parsed.contentSampleCount, 4)
        XCTAssertEqual(parsed.contentChangeCount, 3)
    }

    func testVideoEvaluatorRequiresNewDecodedFramesAndTimestamps() {
        let previous = video(frames: 10, timestamp: 1_000)
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(frames: 11, timestamp: 2_000)
            ),
            .advancing
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(previous: previous, current: previous),
            .frameCounterStalled
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(frames: 11, timestamp: 1_000)
            ),
            .timestampStalled
        )
    }

    func testVideoEvaluatorDistinguishesChangingPixelsFromFreshFrozenFrames() {
        let previous = video(
            frames: 10,
            timestamp: 1_000,
            contentDigest: 111,
            contentSamples: 10,
            contentChanges: 9
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(
                    frames: 11,
                    timestamp: 2_000,
                    contentDigest: 222,
                    contentSamples: 11,
                    contentChanges: 10
                )
            ),
            .advancing,
            "A genuinely distinct decoded frame must advance the pixel oracle."
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(
                    frames: 11,
                    timestamp: 2_000,
                    contentDigest: 111,
                    contentSamples: 11,
                    contentChanges: 9
                )
            ),
            .contentUnchanged,
            "Fresh RTP timestamps over identical decoded pixels must not count as fresh content."
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(
                    frames: 11,
                    timestamp: 2_000,
                    contentDigest: 222,
                    contentSamples: 11,
                    contentChanges: 9
                )
            ),
            .contentDigestChangeUnaccounted
        )
    }

    func testDecodedPixelDigestIsStableForIdenticalPixelsAndChangesWithContent() throws {
        func pixelBuffer(filledWith byte: UInt8) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(
                CVPixelBufferCreate(
                    kCFAllocatorDefault,
                    64,
                    64,
                    kCVPixelFormatType_32BGRA,
                    nil,
                    &buffer
                ),
                kCVReturnSuccess
            )
            let unwrapped = try XCTUnwrap(buffer)
            XCTAssertEqual(CVPixelBufferLockBaseAddress(unwrapped, []), kCVReturnSuccess)
            defer { CVPixelBufferUnlockBaseAddress(unwrapped, []) }
            memset(
                CVPixelBufferGetBaseAddress(unwrapped),
                Int32(byte),
                CVPixelBufferGetDataSize(unwrapped)
            )
            return unwrapped
        }

        let blackA = try pixelBuffer(filledWith: 0)
        let blackB = try pixelBuffer(filledWith: 0)
        let white = try pixelBuffer(filledWith: 255)
        let salt: UInt64 = 0x55aa
        let blackDigest = WebRTCDecodedPixelDigest.digest(pixelBuffer: blackA, salt: salt)
        XCTAssertEqual(
            blackDigest,
            WebRTCDecodedPixelDigest.digest(pixelBuffer: blackB, salt: salt)
        )
        XCTAssertNotEqual(
            blackDigest,
            WebRTCDecodedPixelDigest.digest(pixelBuffer: white, salt: salt)
        )
        XCTAssertNotEqual(
            blackDigest,
            WebRTCDecodedPixelDigest.digest(pixelBuffer: blackA, salt: salt + 1),
            "Renderer-local salt must prevent a stable cross-session screen fingerprint."
        )
    }

    func testVideoContinuityNeverAcceptsFrozenPixelsWithAdvancingFrameMetadata() {
        let start: TimeInterval = 50_000
        var frozen = PhysicalVideoContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 2.5
        )
        for second in 0...4 {
            let result = frozen.observe(
                video(
                    frames: UInt64(10 + second * 15),
                    timestamp: Int64(second) * 1_000_000_000 + 1,
                    contentDigest: 777,
                    contentSamples: UInt64(10 + second * 15),
                    contentChanges: 9
                ),
                at: start + Double(second)
            )
            XCTAssertNotEqual(result, .satisfied)
        }
    }

    func testVideoEvaluatorRejectsImpossiblePixelEvidenceCounters() {
        let previous = video(
            frames: 20,
            timestamp: 1_000,
            contentDigest: 1,
            contentSamples: 10,
            contentChanges: 8
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(
                    frames: 21,
                    timestamp: 2_000,
                    contentDigest: 2,
                    contentSamples: 9,
                    contentChanges: 8
                )
            ),
            .contentSampleCounterRegressed
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(
                    frames: 21,
                    timestamp: 2_000,
                    contentDigest: 1,
                    contentSamples: 10,
                    contentChanges: 8
                )
            ),
            .contentSampleCounterStalled
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(
                    frames: 21,
                    timestamp: 2_000,
                    contentDigest: 2,
                    contentSamples: 11,
                    contentChanges: 7
                )
            ),
            .contentChangeCounterRegressed
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(
                    frames: 21,
                    timestamp: 2_000,
                    contentDigest: 1,
                    contentSamples: 11,
                    contentChanges: 9
                )
            ),
            .contentChangeCounterImpossible,
            "Equal endpoint digests cannot be explained by exactly one sampled change."
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(
                    frames: 21,
                    timestamp: 2_000,
                    contentDigest: 2,
                    contentSamples: 22,
                    contentChanges: 9
                )
            ),
            .invalidContentEvidence
        )
    }

    func testVideoEvaluatorRejectsRegressionsInvalidFramesAndRendererReplacement() {
        let previous = video(frames: 10, timestamp: 1_000)
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(frames: 9, timestamp: 2_000)
            ),
            .frameCounterRegressed
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(frames: 11, timestamp: 999)
            ),
            .timestampRegressed
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(frames: 11, timestamp: 2_000, width: 1)
            ),
            .invalidDimensions
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(frames: 11, timestamp: 2_000, width: 1_280)
            ),
            .dimensionsChanged
        )
        XCTAssertEqual(
            PhysicalVideoRenderEvaluator.evaluate(
                previous: previous,
                current: video(
                    renderer: UUID(),
                    frames: 11,
                    timestamp: 2_000
                )
            ),
            .rendererChanged
        )
    }

    func testVideoContinuityWindowRejectsLateSingleFrameAndRequiresCadence() {
        let start: TimeInterval = 30_000
        var late = PhysicalVideoContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 2.5
        )
        XCTAssertEqual(late.observe(video(frames: 10, timestamp: 1_000), at: start), .waiting)
        XCTAssertEqual(
            late.observe(
                video(frames: 11, timestamp: 2_100_000_000),
                at: start + 2.1
            ),
            .waiting
        )

        var healthy = PhysicalVideoContinuityTracker(
            requiredDuration: 2,
            maximumProgressGap: 2.5
        )
        _ = healthy.observe(video(frames: 10, timestamp: 1_000), at: start)
        _ = healthy.observe(
            video(frames: 25, timestamp: 1_000_001_000),
            at: start + 1
        )
        _ = healthy.observe(
            video(frames: 40, timestamp: 2_000_001_000),
            at: start + 2
        )
        XCTAssertEqual(
            healthy.observe(
                video(frames: 55, timestamp: 3_000_001_000),
                at: start + 3
            ),
            .satisfied
        )

        XCTAssertFalse(
            PhysicalVideoRenderEvaluator.coversElapsedInterval(
                previous: video(frames: 10, timestamp: 1_000),
                current: video(frames: 1_010, timestamp: 2_000_001_000),
                elapsed: 2
            ),
            "An impossible frame-count leap must not stand in for continuous rendering."
        )
        XCTAssertFalse(
            PhysicalVideoRenderEvaluator.coversElapsedInterval(
                previous: video(frames: 10, timestamp: 1_000),
                current: video(frames: 40, timestamp: 20_000_001_000),
                elapsed: 2
            ),
            "A corrupt RTP timestamp leap must not stand in for elapsed continuity."
        )
        XCTAssertFalse(
            PhysicalVideoRenderEvaluator.coversElapsedInterval(
                previous: video(frames: 10, timestamp: 1_000),
                current: video(
                    frames: 18,
                    timestamp: 2_000_001_000,
                    contentSamples: 18,
                    contentChanges: 7
                ),
                elapsed: 2
            ),
            "A four-frame-per-second slideshow is not acceptable screen streaming."
        )
        XCTAssertFalse(
            PhysicalVideoRenderEvaluator.coversElapsedInterval(
                previous: video(
                    frames: 10,
                    timestamp: 1_000,
                    contentSamples: 10,
                    contentChanges: 9
                ),
                current: video(
                    frames: 130,
                    timestamp: 2_000_001_000,
                    contentSamples: 14,
                    contentChanges: 12
                ),
                elapsed: 2
            ),
            "Sixty decoded frames per second cannot hide pixels changing like a slideshow."
        )
    }

    func testProductionScreenAcknowledgementAccessibilityContractRoundTrips() throws {
        let production = WorldwideScreenAcknowledgementOracleSnapshot(
            sessionGeneration: session,
            requestID: 91,
            command: .hide,
            state: .inactive
        )

        let parsed = try XCTUnwrap(
            PhysicalScreenAcknowledgementSnapshot(
                accessibilityValue: production.accessibilityValue
            )
        )
        XCTAssertEqual(parsed.sessionGeneration, session)
        XCTAssertEqual(parsed.requestID, 91)
        XCTAssertEqual(parsed.command, .hide)
        XCTAssertEqual(parsed.state, .inactive)
    }

    func testAccessibilityParsersRejectMissingDuplicateAndUnknownFields() {
        XCTAssertNil(PhysicalAudioPlayoutSnapshot(accessibilityValue: "v=1"))
        XCTAssertNil(
            PhysicalAudioPlayoutSnapshot(
                accessibilityValue: "v=1|session=\(session)|callbacks=1|callbacks=2|frames=480|failures=0|fullQuality=1"
            )
        )
        XCTAssertNil(
            PhysicalVideoRenderSnapshot(
                accessibilityValue: "v=1|renderer=\(renderer)|frames=1|timestampNs=1|width=10|height=10|pixels=secret"
            )
        )
        XCTAssertNil(
            PhysicalScreenAcknowledgementSnapshot(
                accessibilityValue: "v=1|session=\(session)|request=1|command=show|state=unknown"
            )
        )
    }

    private func audio(
        session: UUID? = nil,
        callbacks: UInt64,
        frames: UInt64,
        failures: UInt64,
        pcmSamples: UInt64? = nil,
        pcmNonzero: UInt64? = nil,
        pcmAbsolute: UInt64? = nil,
        pcmLeftAbsolute: UInt64? = nil,
        pcmRightAbsolute: UInt64? = nil,
        pcmStereoDifferenceAbsolute: UInt64? = nil,
        clipped: UInt64 = 0,
        silenceCallbacks: UInt64 = 0,
        gapViolations: UInt64 = 0,
        maximumGapNanoseconds: UInt64 = 10_000_000,
        nearSilenceCallbacks: UInt64 = 0,
        currentNearSilenceFrames: UInt64 = 0,
        maximumNearSilenceFrames: UInt64 = 0,
        leftCrossings: UInt64? = nil,
        rightCrossings: UInt64? = nil,
        envelopeTransitions: UInt64? = nil,
        shapeAnomalies: UInt64 = 0,
        boundaryDiscontinuities: UInt64 = 0,
        callbackMean: UInt32? = nil,
        recoveryRebuilds: UInt64 = 0,
        peak: UInt32? = nil,
        inboundEnergy: Double? = nil,
        inboundDuration: Double? = nil,
        fullQuality: Bool = true
    ) -> PhysicalAudioPlayoutSnapshot {
        let samples = pcmSamples ?? frames * 2
        let nonzero = pcmNonzero ?? samples
        let absolute = pcmAbsolute ?? nonzero * 1_000
        let leftAbsolute = pcmLeftAbsolute ?? absolute / 2
        let rightAbsolute = pcmRightAbsolute ?? absolute - leftAbsolute
        return PhysicalAudioPlayoutSnapshot(
            accessibilityValue: WorldwideAudioPlayoutOracleSnapshot(
                sessionGeneration: session ?? self.session,
                callbackCount: callbacks,
                frameCount: frames,
                failureCount: failures,
                pcmSampleCount: samples,
                pcmNonzeroSampleCount: nonzero,
                pcmAbsoluteSampleSum: absolute,
                pcmLeftAbsoluteSampleSum: leftAbsolute,
                pcmRightAbsoluteSampleSum: rightAbsolute,
                pcmStereoDifferenceAbsoluteSampleSum:
                    pcmStereoDifferenceAbsolute ?? absolute * 3 / 5,
                pcmClippedSampleCount: clipped,
                explicitSilenceCallbackCount: silenceCallbacks,
                callbackGapViolationCount: gapViolations,
                maximumCallbackGapNanoseconds: maximumGapNanoseconds,
                nearSilenceCallbackCount: nearSilenceCallbacks,
                currentConsecutiveNearSilenceFrameCount: currentNearSilenceFrames,
                maximumConsecutiveNearSilenceFrameCount: maximumNearSilenceFrames,
                pcmLeftZeroCrossingCount:
                    leftCrossings ?? frames * 9_000 / 48_000,
                pcmRightZeroCrossingCount:
                    rightCrossings ?? frames * 12_502 / 48_000,
                pcmEnvelopeTransitionCount:
                    envelopeTransitions ?? frames / 24_000,
                pcmShapeAnomalyCallbackCount: shapeAnomalies,
                pcmBoundaryDiscontinuityCallbackCount: boundaryDiscontinuities,
                lastCallbackMeanMagnitude:
                    callbackMean ?? (nonzero == 0 ? 0 : 5_100),
                recoveryRebuildCount: recoveryRebuilds,
                lastPeakMagnitude: peak ?? (nonzero == 0 ? 0 : 8_000),
                inboundAudioEnergy:
                    inboundEnergy ?? Double(frames) / 48_000 * 0.25,
                inboundSamplesDuration:
                    inboundDuration ?? Double(frames) / 48_000,
                fullQualityInvariantsHold: fullQuality
            ).accessibilityValue
        )!
    }

    private func video(
        renderer: UUID? = nil,
        frames: UInt64,
        timestamp: Int64,
        width: Int = 1_920,
        height: Int = 1_080,
        contentDigest: UInt64? = nil,
        contentSamples: UInt64? = nil,
        contentChanges: UInt64? = nil
    ) -> PhysicalVideoRenderSnapshot {
        let samples = contentSamples ?? frames
        return PhysicalVideoRenderSnapshot(
            accessibilityValue: WorldwideVideoRenderOracleSnapshot(
                rendererID: renderer ?? self.renderer,
                frameCount: frames,
                timestampNanoseconds: timestamp,
                width: width,
                height: height,
                contentDigest: contentDigest ?? frames,
                contentSampleCount: samples,
                contentChangeCount: contentChanges ?? (samples > 0 ? samples - 1 : 0)
            ).accessibilityValue
        )!
    }
}
