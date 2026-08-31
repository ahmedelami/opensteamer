@testable import WebRTCTransport
import XCTest

final class WorldwideScreenLivenessClassifierTests: XCTestCase {
    func testCoverTrackAndAwaitingBranchesHaveClosedEvidenceStates() {
        var classifier = WorldwideScreenLivenessClassifier()

        let intentional = classifier.observe(
            sample(
                generation: 1,
                now: 1,
                trackAttached: true,
                cover: .intentionalBandwidthPause
            )
        )
        XCTAssertEqual(intentional.state, .intentionallyCovered)
        XCTAssertEqual(
            intentional.statusText,
            "Screen paused to save bandwidth"
        )

        classifier.reset()
        let privacy = classifier.observe(
            sample(
                generation: 1,
                now: 1,
                trackAttached: true,
                cover: .privacy
            )
        )
        XCTAssertEqual(privacy.state, .covered)
        XCTAssertEqual(privacy.statusText, "Screen paused for privacy")

        classifier.reset()
        XCTAssertEqual(
            classifier.observe(
                sample(generation: 1, now: 1, trackAttached: false)
            ).state,
            .trackMissing
        )

        classifier.reset()
        let awaiting = classifier.observe(
            sample(generation: 1, now: 1, trackAttached: true)
        )
        XCTAssertEqual(awaiting.state, .awaitingEvidence)
        XCTAssertEqual(awaiting.resetReason, .initialSample)
    }

    func testInboundDecodeAndPresentationStallBranchesUseOrderedCounterEvidence() {
        var classifier = WorldwideScreenLivenessClassifier()
        _ = classifier.observe(
            sample(
                generation: 1,
                now: 1_000_000_000,
                inboundBytes: 100,
                inboundPackets: 10,
                decodedFrames: 4
            )
        )
        let inboundStalled = classifier.observe(
            sample(
                generation: 1,
                now: 2_000_000_000,
                inboundBytes: 100,
                inboundPackets: 10,
                decodedFrames: 4
            )
        )
        XCTAssertEqual(inboundStalled.state, .inboundRTPStalled)
        XCTAssertEqual(inboundStalled.inboundByteDelta, 0)
        XCTAssertEqual(inboundStalled.inboundPacketDelta, 0)

        classifier.reset()
        _ = classifier.observe(
            sample(
                generation: 1,
                now: 1_000_000_000,
                inboundBytes: 100,
                inboundPackets: 10,
                decodedFrames: 4
            )
        )
        let decodeStalled = classifier.observe(
            sample(
                generation: 1,
                now: 2_000_000_000,
                inboundBytes: 200,
                inboundPackets: 20,
                decodedFrames: 4
            )
        )
        XCTAssertEqual(decodeStalled.state, .decodeStalled)
        XCTAssertEqual(decodeStalled.decodedFrameDelta, 0)

        classifier.reset()
        _ = classifier.observe(
            sample(
                generation: 1,
                now: 1_000_000_000,
                inboundBytes: 100,
                inboundPackets: 10,
                decodedFrames: 4
            )
        )
        let presentationStalled = classifier.observe(
            sample(
                generation: 1,
                now: 2_000_000_000,
                inboundBytes: 200,
                inboundPackets: 20,
                decodedFrames: 8
            )
        )
        XCTAssertEqual(presentationStalled.state, .presentationStalled)
        XCTAssertEqual(presentationStalled.decodedFrameDelta, 4)
    }

    func testPresentedFramesDistinguishUnchangedContentFromChangingContent() {
        var classifier = WorldwideScreenLivenessClassifier()
        _ = classifier.observe(
            sample(
                generation: 1,
                now: 1_000_000_000,
                inboundBytes: 100,
                inboundPackets: 10,
                decodedFrames: 4,
                presentedFrames: 4,
                contentSamples: 4,
                contentChanges: 1
            )
        )
        let unchanged = classifier.observe(
            sample(
                generation: 1,
                now: 2_000_000_000,
                inboundBytes: 200,
                inboundPackets: 20,
                decodedFrames: 8,
                presentedFrames: 8,
                contentSamples: 8,
                contentChanges: 1
            )
        )
        XCTAssertEqual(unchanged.state, .presentingUnchanged)
        XCTAssertEqual(unchanged.presentedFrameDelta, 4)
        XCTAssertEqual(unchanged.contentChangeDelta, 0)

        let live = classifier.observe(
            sample(
                generation: 1,
                now: 3_000_000_000,
                inboundBytes: 300,
                inboundPackets: 30,
                decodedFrames: 12,
                presentedFrames: 12,
                contentSamples: 12,
                contentChanges: 3
            )
        )
        XCTAssertEqual(live.state, .presentingLive)
        XCTAssertEqual(live.contentChangeDelta, 2)
        XCTAssertEqual(live.lastPresentationAgeMilliseconds, 0)
    }

    func testFreshPresentationSurvivesAnInterleavedStatisticsOnlyObservation() {
        var classifier = WorldwideScreenLivenessClassifier()
        _ = classifier.observe(
            sample(
                generation: 1,
                now: 1_000_000_000,
                inboundBytes: 100,
                inboundPackets: 10,
                decodedFrames: 4,
                presentedFrames: 4,
                contentSamples: 4,
                contentChanges: 1
            )
        )
        _ = classifier.observe(
            sample(
                generation: 1,
                now: 2_000_000_000,
                inboundBytes: 100,
                inboundPackets: 10,
                decodedFrames: 4,
                presentedFrames: 8,
                contentSamples: 8,
                contentChanges: 2
            )
        )
        let statisticsOnly = classifier.observe(
            sample(
                generation: 1,
                now: 3_000_000_000,
                inboundBytes: 200,
                inboundPackets: 20,
                decodedFrames: 8,
                presentedFrames: 8,
                contentSamples: 8,
                contentChanges: 2,
                presentationTime: 2_000_000_000
            )
        )

        XCTAssertEqual(statisticsOnly.state, .presentingLive)
        XCTAssertEqual(statisticsOnly.lastPresentationAgeMilliseconds, 1_000)
    }

    func testGenerationChangeResetsEveryDeltaBeforeNewEvidenceIsCompared() {
        var classifier = WorldwideScreenLivenessClassifier()
        _ = classifier.observe(
            sample(
                generation: 1,
                now: 1_000_000_000,
                inboundBytes: 100,
                inboundPackets: 10,
                decodedFrames: 4,
                presentedFrames: 4,
                contentSamples: 4,
                contentChanges: 1
            )
        )
        let reset = classifier.observe(
            sample(
                generation: 2,
                now: 2_000_000_000,
                inboundBytes: 1,
                inboundPackets: 1,
                decodedFrames: 1,
                presentedFrames: 1,
                contentSamples: 1,
                contentChanges: 0
            )
        )

        XCTAssertEqual(reset.state, .awaitingEvidence)
        XCTAssertEqual(reset.resetReason, .generationChanged)
        XCTAssertNil(reset.inboundByteDelta)
        XCTAssertNil(reset.decodedFrameDelta)
        XCTAssertNil(reset.presentedFrameDelta)
        XCTAssertNil(reset.contentChangeDelta)

        let next = classifier.observe(
            sample(
                generation: 2,
                now: 3_000_000_000,
                inboundBytes: 2,
                inboundPackets: 2,
                decodedFrames: 2,
                presentedFrames: 2,
                contentSamples: 2,
                contentChanges: 1
            )
        )
        XCTAssertEqual(next.state, .presentingLive)
        XCTAssertEqual(next.inboundByteDelta, 1)
        XCTAssertEqual(next.presentedFrameDelta, 1)
    }

    func testCounterRegressionResetsTheWholeComparisonFloorWithoutUnsignedWrap() {
        var classifier = WorldwideScreenLivenessClassifier()
        _ = classifier.observe(
            sample(
                generation: 1,
                now: 1_000_000_000,
                inboundBytes: 100,
                inboundPackets: 10,
                decodedFrames: 4,
                presentedFrames: 4,
                contentSamples: 4,
                contentChanges: 2
            )
        )
        let reset = classifier.observe(
            sample(
                generation: 1,
                now: 2_000_000_000,
                inboundBytes: 1,
                inboundPackets: 1,
                decodedFrames: 1,
                presentedFrames: 1,
                contentSamples: 1,
                contentChanges: 0
            )
        )

        XCTAssertEqual(reset.state, .awaitingEvidence)
        XCTAssertEqual(reset.resetReason, .counterRegression)
        XCTAssertNil(reset.inboundByteDelta)
        XCTAssertNil(reset.decodedFrameDelta)
        XCTAssertNil(reset.presentedFrameDelta)
        XCTAssertNil(reset.contentChangeDelta)
    }

    func testSnapshotBoundsAgeDimensionsAndFrameRateWithoutContentIdentity() {
        var classifier = WorldwideScreenLivenessClassifier()
        let snapshot = classifier.observe(
            sample(
                generation: 1,
                now: 200_000_000_000_000,
                inboundBytes: 1,
                inboundPackets: 1,
                decodedFrames: 1,
                presentedFrames: 1,
                contentSamples: 1,
                contentChanges: 0,
                presentationTime: 1,
                frameWidth: 40_000,
                frameHeight: -1,
                framesPerSecond: .infinity
            )
        )

        XCTAssertEqual(
            snapshot.lastPresentationAgeMilliseconds,
            WorldwideScreenLivenessDiagnosticSnapshot
                .maximumPresentationAgeMilliseconds
        )
        XCTAssertNil(snapshot.frameWidth)
        XCTAssertNil(snapshot.frameHeight)
        XCTAssertNil(snapshot.framesPerSecond)
    }

    func testAllClassifierStatesAreCoveredByDeterministicBranchFixtures() {
        var observed: Set<WorldwideScreenLivenessState> = []

        for cover in [
            WorldwideScreenLivenessCoverState.intentionalBandwidthPause,
            .privacy,
        ] {
            var classifier = WorldwideScreenLivenessClassifier()
            observed.insert(
                classifier.observe(
                    sample(
                        generation: 1,
                        now: 1,
                        trackAttached: true,
                        cover: cover
                    )
                ).state
            )
        }
        do {
            var classifier = WorldwideScreenLivenessClassifier()
            observed.insert(
                classifier.observe(
                    sample(generation: 1, now: 1, trackAttached: false)
                ).state
            )
            observed.insert(
                classifier.observe(
                    sample(generation: 2, now: 2, trackAttached: true)
                ).state
            )
        }
        for second in [
            sample(
                generation: 1,
                now: 2_000_000_000,
                inboundBytes: 100,
                inboundPackets: 10,
                decodedFrames: 4
            ),
            sample(
                generation: 1,
                now: 2_000_000_000,
                inboundBytes: 200,
                inboundPackets: 20,
                decodedFrames: 4
            ),
            sample(
                generation: 1,
                now: 2_000_000_000,
                inboundBytes: 200,
                inboundPackets: 20,
                decodedFrames: 8
            ),
            sample(
                generation: 1,
                now: 2_000_000_000,
                inboundBytes: 200,
                inboundPackets: 20,
                decodedFrames: 8,
                presentedFrames: 8,
                contentSamples: 8,
                contentChanges: 1
            ),
            sample(
                generation: 1,
                now: 2_000_000_000,
                inboundBytes: 200,
                inboundPackets: 20,
                decodedFrames: 8,
                presentedFrames: 8,
                contentSamples: 8,
                contentChanges: 2
            ),
        ] {
            var classifier = WorldwideScreenLivenessClassifier()
            _ = classifier.observe(
                sample(
                    generation: 1,
                    now: 1_000_000_000,
                    inboundBytes: 100,
                    inboundPackets: 10,
                    decodedFrames: 4,
                    presentedFrames: second.renderObservation == nil ? nil : 4,
                    contentSamples: second.renderObservation == nil ? nil : 4,
                    contentChanges: second.renderObservation == nil ? nil : 1
                )
            )
            observed.insert(classifier.observe(second).state)
        }

        XCTAssertEqual(observed, Set(WorldwideScreenLivenessState.allCases))
    }

    private func sample(
        generation: UInt64,
        now: UInt64,
        trackAttached: Bool = true,
        cover: WorldwideScreenLivenessCoverState = .none,
        inboundBytes: UInt64? = nil,
        inboundPackets: UInt64? = nil,
        decodedFrames: UInt64? = nil,
        presentedFrames: UInt64? = nil,
        contentSamples: UInt64? = nil,
        contentChanges: UInt64? = nil,
        presentationTime: UInt64? = nil,
        frameWidth: Int = 1_280,
        frameHeight: Int = 832,
        framesPerSecond: Double? = 30
    ) -> WorldwideScreenLivenessSample {
        let inboundVideo: WebRTCVideoStatistics? = if inboundBytes != nil
            || inboundPackets != nil
            || decodedFrames != nil {
            WebRTCVideoStatistics(
                bytes: inboundBytes,
                packets: inboundPackets,
                framesPerSecond: framesPerSecond,
                frameWidth: frameWidth,
                frameHeight: frameHeight,
                framesEncodedOrDecoded: decodedFrames
            )
        } else {
            nil
        }
        let render: WorldwideScreenLivenessRenderObservation? = if let presentedFrames,
                                                                    let contentSamples,
                                                                    let contentChanges {
            WorldwideScreenLivenessRenderObservation(
                presentedFrames: presentedFrames,
                contentSamples: contentSamples,
                contentChanges: contentChanges,
                presentedAtUptimeNanoseconds: presentationTime ?? now,
                frameWidth: frameWidth,
                frameHeight: frameHeight
            )
        } else {
            nil
        }
        return WorldwideScreenLivenessSample(
            generation: generation,
            observedAtUptimeNanoseconds: now,
            hasRemoteVideoTrack: trackAttached,
            coverState: cover,
            inboundVideo: inboundVideo,
            renderObservation: render
        )
    }
}
