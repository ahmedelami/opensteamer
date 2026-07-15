import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

private func screenVideoCompressionOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let outputCallbackRefCon else { return }
    let encoder = Unmanaged<H264ScreenVideoEncoder>
        .fromOpaque(outputCallbackRefCon)
        .takeUnretainedValue()
    encoder.didEncode(status: status, infoFlags: infoFlags, sampleBuffer: sampleBuffer)
}

public final class H264ScreenVideoEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var frameInFlight = false
    private var forceNextKeyFrame = true
    private var lastSubmittedTimestamp = CMTime.invalid
    private let callback: @Sendable (Result<EncodedScreenVideoFrame, Error>) -> Void

    public init(
        width: Int32,
        height: Int32,
        framesPerSecond: Int32,
        bitrate: Int32,
        callback: @escaping @Sendable (Result<EncodedScreenVideoFrame, Error>) -> Void
    ) throws {
        self.callback = callback

        let encoderSpecification = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ] as CFDictionary
        var newSession: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: screenVideoCompressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &newSession
        )
        guard createStatus == noErr, let newSession else {
            throw H264ScreenVideoEncoderError.couldNotCreateSession(createStatus)
        }
        session = newSession

        do {
            try Self.set(newSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
            try Self.set(newSession, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
            try Self.set(newSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
            try Self.set(
                newSession,
                kVTCompressionPropertyKey_ExpectedFrameRate,
                NSNumber(value: framesPerSecond)
            )
            try Self.set(
                newSession,
                kVTCompressionPropertyKey_MaxKeyFrameInterval,
                NSNumber(value: framesPerSecond * 2)
            )
            try Self.set(
                newSession,
                kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                NSNumber(value: 2.0)
            )
            try Self.set(
                newSession,
                kVTCompressionPropertyKey_AverageBitRate,
                NSNumber(value: bitrate)
            )
            try Self.set(
                newSession,
                kVTCompressionPropertyKey_DataRateLimits,
                [NSNumber(value: bitrate / 8 * 2), NSNumber(value: 2)] as CFArray
            )
            let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(newSession)
            guard prepareStatus == noErr else {
                throw H264ScreenVideoEncoderError.couldNotPrepareSession(prepareStatus)
            }
        } catch {
            VTCompressionSessionInvalidate(newSession)
            session = nil
            throw error
        }
    }

    deinit {
        finish()
    }

    public func requestKeyFrame() {
        lock.lock()
        forceNextKeyFrame = true
        lock.unlock()
    }

    @discardableResult
    public func encodeIfAvailable(_ sampleBuffer: CMSampleBuffer) throws -> Bool {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return false
        }
        let presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTimestamp.isValid, presentationTimestamp.isNumeric else {
            return false
        }

        lock.lock()
        guard let session, !frameInFlight else {
            lock.unlock()
            return false
        }
        if lastSubmittedTimestamp.isValid,
           CMTimeCompare(presentationTimestamp, lastSubmittedTimestamp) <= 0 {
            lock.unlock()
            return false
        }
        let forceKeyFrame = forceNextKeyFrame
        forceNextKeyFrame = false
        frameInFlight = true
        lastSubmittedTimestamp = presentationTimestamp
        lock.unlock()

        let frameProperties: CFDictionary? = forceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        var infoFlags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimestamp,
            duration: CMSampleBufferGetDuration(sampleBuffer),
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        guard status == noErr, !infoFlags.contains(.frameDropped) else {
            clearInFlightFrame()
            requestKeyFrame()
            if status != noErr {
                throw H264ScreenVideoEncoderError.couldNotEncodeFrame(status)
            }
            return false
        }
        return true
    }

    public func finish() {
        lock.lock()
        guard let session else {
            lock.unlock()
            return
        }
        self.session = nil
        lock.unlock()

        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    fileprivate func didEncode(
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?
    ) {
        clearInFlightFrame()

        guard status == noErr else {
            requestKeyFrame()
            callback(.failure(H264ScreenVideoEncoderError.couldNotEncodeFrame(status)))
            return
        }
        guard !infoFlags.contains(.frameDropped),
              let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            requestKeyFrame()
            callback(.failure(H264ScreenVideoEncoderError.encoderDroppedFrame))
            return
        }

        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        var bytes = Data(count: byteCount)
        let copyStatus = bytes.withUnsafeMutableBytes { storage in
            guard let baseAddress = storage.baseAddress else { return noErr }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: byteCount,
                destination: baseAddress
            )
        }
        guard copyStatus == noErr else {
            callback(.failure(H264ScreenVideoEncoderError.couldNotCopyFrame(copyStatus)))
            return
        }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]]
        let isKeyFrame = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let parameterSetResult = parameterSets(from: sampleBuffer, isKeyFrame: isKeyFrame)
        guard case .success(let parameterSetDescription) = parameterSetResult else {
            if case .failure(let error) = parameterSetResult {
                callback(.failure(error))
            }
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let scaledTimestamp = CMTimeConvertScale(
            timestamp,
            timescale: 1_000_000_000,
            method: .default
        )
        guard scaledTimestamp.isValid, scaledTimestamp.value >= 0 else {
            callback(.failure(H264ScreenVideoEncoderError.invalidPresentationTimestamp))
            return
        }

        callback(.success(EncodedScreenVideoFrame(
            bytes: bytes,
            presentationTimestampNanoseconds: UInt64(scaledTimestamp.value),
            isKeyFrame: isKeyFrame,
            parameterSets: parameterSetDescription.parameterSets,
            nalUnitHeaderLength: parameterSetDescription.nalUnitHeaderLength
        )))
    }

    private func parameterSets(
        from sampleBuffer: CMSampleBuffer,
        isKeyFrame: Bool
    ) -> Result<(parameterSets: [Data], nalUnitHeaderLength: Int), Error> {
        guard isKeyFrame else {
            return .success(([], 4))
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return .failure(H264ScreenVideoEncoderError.missingFormatDescription)
        }

        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0
        let countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        guard countStatus == noErr, parameterSetCount > 0 else {
            return .failure(H264ScreenVideoEncoderError.couldNotReadParameterSets(countStatus))
        }

        var parameterSets: [Data] = []
        parameterSets.reserveCapacity(parameterSetCount)
        for index in 0..<parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var byteCount = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &byteCount,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, byteCount > 0 else {
                return .failure(H264ScreenVideoEncoderError.couldNotReadParameterSets(status))
            }
            parameterSets.append(Data(bytes: pointer, count: byteCount))
        }

        return .success((parameterSets, Int(nalUnitHeaderLength)))
    }

    private func clearInFlightFrame() {
        lock.lock()
        frameInFlight = false
        lock.unlock()
    }

    private static func set(
        _ session: VTCompressionSession,
        _ key: CFString,
        _ value: CFTypeRef
    ) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else {
            throw H264ScreenVideoEncoderError.couldNotSetProperty(key as String, status)
        }
    }
}

public enum H264ScreenVideoEncoderError: LocalizedError {
    case couldNotCreateSession(OSStatus)
    case couldNotSetProperty(String, OSStatus)
    case couldNotPrepareSession(OSStatus)
    case couldNotEncodeFrame(OSStatus)
    case couldNotCopyFrame(OSStatus)
    case couldNotReadParameterSets(OSStatus)
    case missingFormatDescription
    case invalidPresentationTimestamp
    case encoderDroppedFrame

    public var errorDescription: String? {
        switch self {
        case .couldNotCreateSession(let status):
            "Could not create the H.264 encoder (\(status))"
        case .couldNotSetProperty(let property, let status):
            "Could not configure H.264 property \(property) (\(status))"
        case .couldNotPrepareSession(let status):
            "Could not prepare the H.264 encoder (\(status))"
        case .couldNotEncodeFrame(let status):
            "Could not encode a screen frame (\(status))"
        case .couldNotCopyFrame(let status):
            "Could not copy an encoded screen frame (\(status))"
        case .couldNotReadParameterSets(let status):
            "Could not read H.264 parameter sets (\(status))"
        case .missingFormatDescription:
            "The H.264 key frame has no format description"
        case .invalidPresentationTimestamp:
            "The encoded screen frame has an invalid timestamp"
        case .encoderDroppedFrame:
            "The H.264 encoder dropped a screen frame"
        }
    }
}
