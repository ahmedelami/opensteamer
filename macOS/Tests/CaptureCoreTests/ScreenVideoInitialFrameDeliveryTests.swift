import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import XCTest
@testable import CaptureCore

final class ScreenVideoInitialFrameDeliveryTests: XCTestCase {
    func testLatestStartupFrameReplaysBeforeLiveForwarding() {
        var state = ScreenVideoInitialFrameDeliveryState()

        XCTAssertEqual(state.receiveFrame(), .storeLatest)
        XCTAssertEqual(state.receiveFrame(), .storeLatest)
        XCTAssertEqual(state.beginDelivery(), .replayLatest)
        XCTAssertEqual(state.receiveFrame(), .forward)
        XCTAssertEqual(state.beginDelivery(), .open)
    }

    func testRevocationDropsPendingAndFutureFrames() {
        var state = ScreenVideoInitialFrameDeliveryState()

        XCTAssertEqual(state.receiveFrame(), .storeLatest)
        state.revoke()

        XCTAssertEqual(state.beginDelivery(), .reject)
        XCTAssertEqual(state.receiveFrame(), .drop)
    }

    func testStartedAndCompleteAreTheOnlyAdmittedImageStatuses() {
        XCTAssertTrue(ScreenVideoFrameStatusPolicy.admitsImageFrame(.started))
        XCTAssertTrue(ScreenVideoFrameStatusPolicy.admitsImageFrame(.complete))
        XCTAssertFalse(ScreenVideoFrameStatusPolicy.admitsImageFrame(.idle))
        XCTAssertFalse(ScreenVideoFrameStatusPolicy.admitsImageFrame(.blank))
        XCTAssertFalse(ScreenVideoFrameStatusPolicy.admitsImageFrame(.suspended))
        XCTAssertFalse(ScreenVideoFrameStatusPolicy.admitsImageFrame(.stopped))
    }

    func testNativeStartedSamplesReplayLatestOnceWithParsedGeometry() throws {
        let consumer = RecordingScreenVideoSampleConsumer()
        let output = ScreenVideoStreamOutput(consumer: consumer)
        let first = try makeScreenSample(
            presentationValue: 1,
            status: .started,
            contentRect: CGRect(x: 10, y: 5, width: 300, height: 170),
            contentScale: 0.75,
            scaleFactor: 2
        )
        let latest = try makeScreenSample(
            presentationValue: 2,
            status: .started,
            contentRect: CGRect(x: 12, y: 6, width: 296, height: 168),
            contentScale: 0.8,
            scaleFactor: 2
        )

        output.consumeScreenSample(first)
        output.consumeScreenSample(latest)

        XCTAssertTrue(output.beginDelivery())
        var records = consumer.records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(
            CMSampleBufferGetPresentationTimeStamp(records[0].sampleBuffer),
            CMTime(value: 2, timescale: 60)
        )
        XCTAssertEqual(
            records[0].geometry,
            ScreenVideoFrameGeometry(
                surfaceWidth: 640,
                surfaceHeight: 360,
                contentRect: CGRect(x: 12, y: 6, width: 296, height: 168),
                contentScale: 0.8,
                scaleFactor: 2
            )
        )

        XCTAssertTrue(output.beginDelivery())
        XCTAssertEqual(consumer.records.count, 1)

        let live = try makeScreenSample(
            presentationValue: 3,
            status: .complete,
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            contentScale: 1,
            scaleFactor: 2
        )
        output.consumeScreenSample(live)

        records = consumer.records
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(
            CMSampleBufferGetPresentationTimeStamp(records[1].sampleBuffer),
            CMTime(value: 3, timescale: 60)
        )
    }

    func testNativeGeometryParserDistinguishesAbsentFromInvalidMetadata() throws {
        let consumer = RecordingScreenVideoSampleConsumer()
        let output = ScreenVideoStreamOutput(consumer: consumer)
        XCTAssertTrue(output.beginDelivery())
        let absent = try makeScreenSample(
            presentationValue: 1,
            status: .complete,
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            contentScale: 1,
            scaleFactor: 2
        )
        try frameAttachments(in: absent).removeObject(
            forKey: SCStreamFrameInfo.contentScale
        )
        let invalid = try makeScreenSample(
            presentationValue: 2,
            status: .complete,
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            contentScale: 1,
            scaleFactor: 2
        )
        try frameAttachments(in: invalid).addEntries(
            from: [SCStreamFrameInfo.scaleFactor: "unexpected"]
        )
        let mixedMissingAndMalformed = try makeScreenSample(
            presentationValue: 3,
            status: .complete,
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            contentScale: 1,
            scaleFactor: 2
        )
        let mixedAttachments = try frameAttachments(in: mixedMissingAndMalformed)
        mixedAttachments.removeObject(forKey: SCStreamFrameInfo.contentScale)
        mixedAttachments.addEntries(
            from: [SCStreamFrameInfo.scaleFactor: "unexpected"]
        )
        let mixedMissingAndOutOfSurface = try makeScreenSample(
            presentationValue: 4,
            status: .complete,
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            contentScale: 1,
            scaleFactor: 2
        )
        let outOfSurfaceAttachments = try frameAttachments(
            in: mixedMissingAndOutOfSurface
        )
        outOfSurfaceAttachments.removeObject(forKey: SCStreamFrameInfo.contentScale)
        outOfSurfaceAttachments.addEntries(
            from: [
                SCStreamFrameInfo.contentRect:
                    CGRect(x: 0, y: 0, width: 400, height: 180)
                        .dictionaryRepresentation,
            ]
        )

        output.consumeScreenSample(absent)
        output.consumeScreenSample(invalid)
        output.consumeScreenSample(mixedMissingAndMalformed)
        output.consumeScreenSample(mixedMissingAndOutOfSurface)

        XCTAssertEqual(
            consumer.records.map(\.geometryObservation),
            [.absent, .invalid, .invalid, .invalid]
        )
    }

    func testNativePendingSampleCannotReplayAfterRevocation() throws {
        let consumer = RecordingScreenVideoSampleConsumer()
        let output = ScreenVideoStreamOutput(consumer: consumer)
        let pending = try makeScreenSample(
            presentationValue: 1,
            status: .started,
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            contentScale: 1,
            scaleFactor: 2
        )

        output.consumeScreenSample(pending)
        output.revoke()

        XCTAssertFalse(output.beginDelivery())
        XCTAssertTrue(consumer.records.isEmpty)

        let later = try makeScreenSample(
            presentationValue: 2,
            status: .complete,
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            contentScale: 1,
            scaleFactor: 2
        )
        output.consumeScreenSample(later)
        XCTAssertTrue(consumer.records.isEmpty)
    }
}

private final class RecordingScreenVideoSampleConsumer: ScreenVideoSampleConsumer,
    @unchecked Sendable
{
    struct Record {
        let sampleBuffer: CMSampleBuffer
        let geometryObservation: ScreenVideoFrameGeometryObservation

        var geometry: ScreenVideoFrameGeometry? {
            geometryObservation.geometry
        }
    }

    private let lock = NSLock()
    private var storedRecords: [Record] = []

    var records: [Record] {
        lock.withLock { storedRecords }
    }

    func consumeScreenVideoSample(_ sampleBuffer: CMSampleBuffer) {
        consumeScreenVideoSample(sampleBuffer, frameGeometry: nil)
    }

    func consumeScreenVideoSample(
        _ sampleBuffer: CMSampleBuffer,
        frameGeometry: ScreenVideoFrameGeometry?
    ) {
        consumeScreenVideoSample(
            sampleBuffer,
            frameGeometryObservation:
                frameGeometry.map(ScreenVideoFrameGeometryObservation.valid) ?? .absent
        )
    }

    func consumeScreenVideoSample(
        _ sampleBuffer: CMSampleBuffer,
        frameGeometryObservation: ScreenVideoFrameGeometryObservation
    ) {
        lock.withLock {
            storedRecords.append(
                Record(
                    sampleBuffer: sampleBuffer,
                    geometryObservation: frameGeometryObservation
                )
            )
        }
    }

    func screenVideoCaptureSource(
        _: ScreenVideoCaptureSource,
        didStopWithErrorDescription _: String
    ) {}
}

private enum ScreenSampleFixtureError: Error {
    case pixelBuffer(OSStatus)
    case formatDescription(OSStatus)
    case sampleBuffer(OSStatus)
    case attachmentsUnavailable
}

private func frameAttachments(
    in sampleBuffer: CMSampleBuffer
) throws -> NSMutableDictionary {
    guard let attachmentArray = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer,
        createIfNecessary: false
    ) else {
        throw ScreenSampleFixtureError.attachmentsUnavailable
    }
    let attachments = attachmentArray as NSArray
    guard let frameAttachments = attachments.firstObject as? NSMutableDictionary else {
        throw ScreenSampleFixtureError.attachmentsUnavailable
    }
    return frameAttachments
}

private func makeScreenSample(
    presentationValue: CMTimeValue,
    status: SCFrameStatus,
    contentRect: CGRect,
    contentScale: CGFloat,
    scaleFactor: CGFloat
) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    var result = CVPixelBufferCreate(
        kCFAllocatorDefault,
        640,
        360,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
    )
    guard result == kCVReturnSuccess, let pixelBuffer else {
        throw ScreenSampleFixtureError.pixelBuffer(result)
    }

    var formatDescription: CMVideoFormatDescription?
    result = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
    )
    guard result == noErr, let formatDescription else {
        throw ScreenSampleFixtureError.formatDescription(result)
    }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 60),
        presentationTimeStamp: CMTime(value: presentationValue, timescale: 60),
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    result = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: formatDescription,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    )
    guard result == noErr, let sampleBuffer else {
        throw ScreenSampleFixtureError.sampleBuffer(result)
    }

    guard let attachmentArray = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer,
        createIfNecessary: true
    ) else {
        throw ScreenSampleFixtureError.attachmentsUnavailable
    }
    let attachments = attachmentArray as NSArray
    guard let frameAttachments = attachments.firstObject as? NSMutableDictionary else {
        throw ScreenSampleFixtureError.attachmentsUnavailable
    }
    frameAttachments.addEntries(from: [
        SCStreamFrameInfo.status: status.rawValue,
        SCStreamFrameInfo.contentRect: contentRect.dictionaryRepresentation,
        SCStreamFrameInfo.contentScale: NSNumber(value: Double(contentScale)),
        SCStreamFrameInfo.scaleFactor: NSNumber(value: Double(scaleFactor))
    ])
    return sampleBuffer
}
