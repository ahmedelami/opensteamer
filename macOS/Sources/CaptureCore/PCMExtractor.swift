import CoreMedia
import Foundation

/// Converts CoreMedia audio buffers into owned, interleaved floating-point PCM.
enum PCMExtractor {
    /// Extracts one sample buffer, reusing caller-owned storage to limit callback churn.
    ///
    /// The returned `PCMBuffer` owns its Swift samples and therefore remains valid
    /// after CoreMedia releases the source buffer.
    static func extract(_ sampleBuffer: CMSampleBuffer, reusing storage: inout [Float]) throws -> PCMBuffer {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw CaptureError.missingAudioFormat
        }

        let asbd = asbdPointer.pointee
        let format = StreamAudioFormat(asbd)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else {
            throw CaptureError.emptyAudioBuffer
        }
        guard format.channelCount > 0 else {
            throw CaptureError.unsupportedAudioFormat("channel count is zero")
        }

        var sizeNeeded = 0
        var sizingBlockBuffer: CMBlockBuffer?
        let sizingStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &sizingBlockBuffer
        )

        guard sizingStatus == noErr, sizeNeeded > 0 else {
            throw CaptureError.audioBufferListFailure(sizingStatus)
        }

        // CoreMedia first reports the exact variable-length AudioBufferList size.
        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: sizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            rawBufferList.deallocate()
        }

        let audioBufferList = rawBufferList.assumingMemoryBound(to: AudioBufferList.self)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            throw CaptureError.audioBufferListFailure(status)
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard !buffers.isEmpty else {
            throw CaptureError.emptyAudioBuffer
        }

        if format.isFloat {
            return try extractFloat(buffers: buffers, format: format, frameCount: frameCount, storage: &storage)
        }

        if format.bitsPerChannel == 16 {
            return try extractInt16(buffers: buffers, format: format, frameCount: frameCount, storage: &storage)
        }

        throw CaptureError.unsupportedAudioFormat("unsupported non-float format with \(format.bitsPerChannel) bits/channel")
    }

    /// Copies native float PCM, interleaving planar channels when necessary.
    private static func extractFloat(
        buffers: UnsafeMutableAudioBufferListPointer,
        format: StreamAudioFormat,
        frameCount: Int,
        storage: inout [Float]
    ) throws -> PCMBuffer {
        storage.removeAll(keepingCapacity: true)

        if format.isInterleaved {
            guard let buffer = buffers.first,
                  let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                throw CaptureError.emptyAudioBuffer
            }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            storage.append(contentsOf: UnsafeBufferPointer(start: data, count: sampleCount))
        } else {
            storage.reserveCapacity(frameCount * format.channelCount)
            for frame in 0..<frameCount {
                for channel in 0..<min(format.channelCount, buffers.count) {
                    guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else {
                        throw CaptureError.emptyAudioBuffer
                    }
                    storage.append(data[frame])
                }
            }
        }

        return PCMBuffer(samples: storage, frameCount: frameCount, channels: format.channelCount, format: format)
    }

    /// Normalizes signed 16-bit PCM into the same float representation as other inputs.
    private static func extractInt16(
        buffers: UnsafeMutableAudioBufferListPointer,
        format: StreamAudioFormat,
        frameCount: Int,
        storage: inout [Float]
    ) throws -> PCMBuffer {
        storage.removeAll(keepingCapacity: true)

        if format.isInterleaved {
            guard let buffer = buffers.first,
                  let data = buffer.mData?.assumingMemoryBound(to: Int16.self) else {
                throw CaptureError.emptyAudioBuffer
            }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
            storage.reserveCapacity(sampleCount)
            for value in UnsafeBufferPointer(start: data, count: sampleCount) {
                storage.append(Float(value) / Float(Int16.max))
            }
        } else {
            storage.reserveCapacity(frameCount * format.channelCount)
            for frame in 0..<frameCount {
                for channel in 0..<min(format.channelCount, buffers.count) {
                    guard let data = buffers[channel].mData?.assumingMemoryBound(to: Int16.self) else {
                        throw CaptureError.emptyAudioBuffer
                    }
                    storage.append(Float(data[frame]) / Float(Int16.max))
                }
            }
        }

        return PCMBuffer(samples: storage, frameCount: frameCount, channels: format.channelCount, format: format)
    }
}
