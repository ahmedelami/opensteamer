@preconcurrency import CoreMedia
import Foundation

enum H264SampleBuilderError: LocalizedError {
    case missingParameterSet
    case invalidNALUnitHeaderLength(Int)
    case formatDescription(OSStatus)
    case blockBuffer(OSStatus)
    case copyFrame(OSStatus)
    case sampleBuffer(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingParameterSet:
            "The H.264 configuration is missing SPS or PPS"
        case .invalidNALUnitHeaderLength(let length):
            "The H.264 NAL-unit header length \(length) is invalid"
        case .formatDescription(let status):
            "Could not create an H.264 format description (\(status))"
        case .blockBuffer(let status):
            "Could not allocate an H.264 block buffer (\(status))"
        case .copyFrame(let status):
            "Could not copy an H.264 access unit (\(status))"
        case .sampleBuffer(let status):
            "Could not create an H.264 sample buffer (\(status))"
        }
    }
}

struct H264SampleBuilder {
    let formatDescription: CMVideoFormatDescription

    init(parameterSets: [Data], nalUnitHeaderLength: Int) throws {
        guard parameterSets.count >= 2, parameterSets.allSatisfy({ !$0.isEmpty }) else {
            throw H264SampleBuilderError.missingParameterSet
        }
        guard [1, 2, 4].contains(nalUnitHeaderLength) else {
            throw H264SampleBuilderError.invalidNALUnitHeaderLength(nalUnitHeaderLength)
        }

        var result: CMFormatDescription?
        let status = parameterSets.withUnsafeH264ParameterSetPointers { pointers, sizes in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers.baseAddress!,
                parameterSetSizes: sizes.baseAddress!,
                nalUnitHeaderLength: Int32(nalUnitHeaderLength),
                formatDescriptionOut: &result
            )
        }
        guard status == noErr, let result else {
            throw H264SampleBuilderError.formatDescription(status)
        }
        formatDescription = result
    }

    func makeSampleBuffer(
        avccAccessUnit: Data,
        presentationTimeStamp: CMTime,
        isKeyFrame: Bool
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avccAccessUnit.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccAccessUnit.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw H264SampleBuilderError.blockBuffer(status)
        }

        status = avccAccessUnit.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return noErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: bytes.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw H264SampleBuilderError.copyFrame(status)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleSize = avccAccessUnit.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw H264SampleBuilderError.sampleBuffer(status)
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) {
            let rawDictionary = CFArrayGetValueAtIndex(attachments, 0)
            let dictionary = Unmanaged<CFMutableDictionary>
                .fromOpaque(rawDictionary!)
                .takeUnretainedValue()
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            if !isKeyFrame {
                CFDictionarySetValue(
                    dictionary,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }
        return sampleBuffer
    }
}

private extension Array where Element == Data {
    func withUnsafeH264ParameterSetPointers<R>(
        _ body: (
            UnsafeBufferPointer<UnsafePointer<UInt8>>,
            UnsafeBufferPointer<Int>
        ) throws -> R
    ) rethrows -> R {
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        pointers.reserveCapacity(count)
        sizes.reserveCapacity(count)

        func visit(_ index: Int) throws -> R {
            if index == count {
                return try pointers.withUnsafeBufferPointer { pointerBuffer in
                    try sizes.withUnsafeBufferPointer { sizeBuffer in
                        try body(pointerBuffer, sizeBuffer)
                    }
                }
            }
            return try self[index].withUnsafeBytes { rawBytes in
                let bytes = rawBytes.bindMemory(to: UInt8.self)
                pointers.append(bytes.baseAddress!)
                sizes.append(bytes.count)
                defer {
                    pointers.removeLast()
                    sizes.removeLast()
                }
                return try visit(index + 1)
            }
        }

        return try visit(0)
    }
}
