@testable import WebRTCTransport
import AVFoundation
import XCTest

#if os(macOS)
final class ManualAudioRenderingContinuityTests: XCTestCase {
    func testMeasuredCaptureJitterExtendsManualPlayerTimelineWithoutInteriorSilence() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let downmixer = AVAudioMixerNode()
        let stereoFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )
        )
        let monoFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )

        engine.attach(player)
        engine.attach(downmixer)
        engine.connect(player, to: downmixer, format: stereoFormat)
        engine.connect(downmixer, to: engine.mainMixerNode, format: monoFormat)
        downmixer.outputVolume = Float(1.0 / sqrt(2.0))
        try engine.enableManualRenderingMode(
            .offline,
            format: monoFormat,
            maximumFrameCount: 4_096
        )
        try engine.start()
        defer { engine.stop() }

        let renderedCallbacks = XCTestExpectation(
            description: "manual player reports each PCM buffer rendered"
        )
        renderedCallbacks.expectedFulfillmentCount = 4
        let callbackCounter = RenderedCallbackCounter()
        for bufferIndex in 0..<3 {
            player.scheduleBuffer(
                try makeContinuousStereoTone(
                    startingFrame: bufferIndex * 960,
                    frameCount: 960,
                    format: stereoFormat
                ),
                completionCallbackType: .dataRendered
            ) { _ in
                callbackCounter.increment()
                renderedCallbacks.fulfill()
            }
        }
        player.play()

        var renderedSamples: [Float] = []
        renderedSamples += try render(
            frameCount: 480,
            engine: engine,
            format: monoFormat
        )
        XCTAssertEqual(callbackCounter.value, 0)
        renderedSamples += try render(
            frameCount: 480,
            engine: engine,
            format: monoFormat
        )
        XCTAssertTrue(callbackCounter.wait(for: 1, timeout: 0.25))
        XCTAssertEqual(callbackCounter.value, 1)
        renderedSamples += try render(
            frameCount: 480,
            engine: engine,
            format: monoFormat
        )
        XCTAssertEqual(callbackCounter.value, 1)
        renderedSamples += try render(
            frameCount: 91,
            engine: engine,
            format: monoFormat
        )
        XCTAssertEqual(callbackCounter.value, 1)
        let observedFrame = MacExternalAudioCapturer.renderedSampleTime(
            from: player.lastRenderTime
        ) { player.playerTime(forNodeTime: $0) }
        XCTAssertEqual(observedFrame, 1_531)

        // 1,531 frames is the measured 31.9 ms callback delay. The original 60 ms prebuffer
        // still has 1,349 frames available, so appending the next 20 ms buffer must be gapless.
        player.scheduleBuffer(
            try makeContinuousStereoTone(
                startingFrame: 2_880,
                frameCount: 960,
                format: stereoFormat
            ),
            completionCallbackType: .dataRendered
        ) { _ in
            callbackCounter.increment()
            renderedCallbacks.fulfill()
        }
        renderedSamples += try render(
            frameCount: 389,
            engine: engine,
            format: monoFormat
        )
        XCTAssertTrue(callbackCounter.wait(for: 2, timeout: 0.25))
        XCTAssertEqual(callbackCounter.value, 2)
        renderedSamples += try render(
            frameCount: 480,
            engine: engine,
            format: monoFormat
        )
        XCTAssertEqual(callbackCounter.value, 2)
        renderedSamples += try render(
            frameCount: 480,
            engine: engine,
            format: monoFormat
        )
        XCTAssertTrue(callbackCounter.wait(for: 3, timeout: 0.25))
        XCTAssertEqual(callbackCounter.value, 3)
        renderedSamples += try render(
            frameCount: 480,
            engine: engine,
            format: monoFormat
        )
        XCTAssertEqual(callbackCounter.value, 3)
        renderedSamples += try render(
            frameCount: 480,
            engine: engine,
            format: monoFormat
        )
        XCTAssertTrue(callbackCounter.wait(for: 4, timeout: 0.25))
        XCTAssertEqual(callbackCounter.value, 4)

        wait(for: [renderedCallbacks], timeout: 1)
        XCTAssertEqual(renderedSamples.count, 3_840)
        var peak = 0.0
        var signalEnergy = 0.0
        var referenceEnergy = 0.0
        var dotProduct = 0.0
        var longestZeroRun = 0
        var currentZeroRun = 0
        for (frame, sample) in renderedSamples.enumerated() {
            let value = Double(sample)
            let reference = sin(
                2 * Double.pi * 997 * Double(frame) / monoFormat.sampleRate
            ) * 0.25
            peak = max(peak, abs(value))
            signalEnergy += value * value
            referenceEnergy += reference * reference
            dotProduct += value * reference
            if sample == 0 {
                currentZeroRun += 1
                longestZeroRun = max(longestZeroRun, currentZeroRun)
            } else {
                currentZeroRun = 0
            }
        }
        let correlation = dotProduct / sqrt(signalEnergy * referenceEnergy)
        XCTAssertGreaterThanOrEqual(correlation, 0.9999)
        XCTAssertLessThanOrEqual(longestZeroRun, 1)
        XCTAssertGreaterThan(peak, 0.24)
        XCTAssertLessThan(peak, 0.26)
        for start in stride(from: 0, to: renderedSamples.count, by: 480) {
            let end = min(start + 480, renderedSamples.count)
            let window = renderedSamples[start..<end]
            let rms = sqrt(
                window.reduce(0.0) { $0 + Double($1 * $1) }
                    / Double(window.count)
            )
            XCTAssertGreaterThan(
                rms,
                0.15,
                "Manual render produced an interior silent 10 ms window at frame \(start)"
            )
        }
    }

    private func render(
        frameCount: AVAudioFrameCount,
        engine: AVAudioEngine,
        format: AVAudioFormat
    ) throws -> [Float] {
        let output = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        let status = try engine.renderOffline(frameCount, to: output)
        XCTAssertEqual(status, .success)
        XCTAssertEqual(output.frameLength, frameCount)
        let samples = try XCTUnwrap(output.floatChannelData)
        return Array(UnsafeBufferPointer(start: samples[0], count: Int(output.frameLength)))
    }

    private func makeContinuousStereoTone(
        startingFrame: Int,
        frameCount: AVAudioFrameCount,
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(frameCount) {
            let phase = 2 * Double.pi * 997
                * Double(startingFrame + frame) / format.sampleRate
            let sample = Float(sin(phase) * 0.25)
            channels[0][frame] = sample
            channels[1][frame] = sample
        }
        return buffer
    }
}

private final class RenderedCallbackCounter: @unchecked Sendable {
    private let condition = NSCondition()
    private var count = 0

    var value: Int {
        condition.withLock { count }
    }

    func increment() {
        condition.withLock {
            count += 1
            condition.broadcast()
        }
    }

    func wait(for expectedCount: Int, timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while count < expectedCount {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }
}
#endif
