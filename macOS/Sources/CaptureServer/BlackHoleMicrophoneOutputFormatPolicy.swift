import AudioToolbox
import CoreAudio

struct BlackHoleMicrophoneOutputFormatEvidence {
    var streamDescriptionStatus: OSStatus
    var streamDescription: AudioStreamBasicDescription
    var deviceSampleRateStatus: OSStatus
    var deviceSampleRate: Double
    var deviceChannelCountStatus: OSStatus
    var deviceChannelCount: UInt32
    var converterErrorReadStatus: OSStatus
    var converterError: UInt32
}

struct BlackHoleMicrophoneOutputFormatObservation:
    Equatable,
    Sendable
{
    let sampleRate: Double
    let formatID: AudioFormatID
    let formatFlags: AudioFormatFlags
    let bytesPerPacket: UInt32
    let framesPerPacket: UInt32
    let bytesPerFrame: UInt32
    let channelsPerFrame: UInt32
    let bitsPerChannel: UInt32
    let reserved: UInt32
    let deviceSampleRate: Double
    let deviceChannelCount: UInt32
    let converterError: UInt32
}

enum BlackHoleMicrophoneOutputFormatRejection:
    Error,
    Equatable,
    Sendable
{
    case streamDescriptionCoreAudioStatus(OSStatus)
    case deviceSampleRateCoreAudioStatus(OSStatus)
    case deviceChannelCountCoreAudioStatus(OSStatus)
    case converterErrorCoreAudioStatus(OSStatus)
    case unexpectedStreamSampleRate(actual: Double)
    case unexpectedStreamFormatID(actual: AudioFormatID)
    case unexpectedStreamFormatFlags(actual: AudioFormatFlags)
    case unexpectedStreamBytesPerPacket(actual: UInt32)
    case unexpectedStreamFramesPerPacket(actual: UInt32)
    case unexpectedStreamBytesPerFrame(actual: UInt32)
    case unexpectedStreamChannelsPerFrame(actual: UInt32)
    case unexpectedStreamBitsPerChannel(actual: UInt32)
    case unexpectedStreamReserved(actual: UInt32)
    case unexpectedDeviceSampleRate(actual: Double)
    case unexpectedDeviceChannelCount(actual: UInt32)
    case converterError(actual: UInt32)

    var coreAudioStatus: OSStatus {
        switch self {
        case .streamDescriptionCoreAudioStatus(let status),
             .deviceSampleRateCoreAudioStatus(let status),
             .deviceChannelCountCoreAudioStatus(let status),
             .converterErrorCoreAudioStatus(let status):
            return status
        case .unexpectedStreamSampleRate,
             .unexpectedStreamFormatID,
             .unexpectedStreamFormatFlags,
             .unexpectedStreamBytesPerPacket,
             .unexpectedStreamFramesPerPacket,
             .unexpectedStreamBytesPerFrame,
             .unexpectedStreamChannelsPerFrame,
             .unexpectedStreamBitsPerChannel,
             .unexpectedStreamReserved,
             .unexpectedDeviceSampleRate,
             .unexpectedDeviceChannelCount,
             .converterError:
            return kAudio_ParamError
        }
    }

    var description: String {
        switch self {
        case .streamDescriptionCoreAudioStatus(let status):
            return "queue stream-description read failed with Core Audio status \(status)"
        case .deviceSampleRateCoreAudioStatus(let status):
            return "queue device sample-rate read failed with Core Audio status \(status)"
        case .deviceChannelCountCoreAudioStatus(let status):
            return "queue device channel-count read failed with Core Audio status \(status)"
        case .converterErrorCoreAudioStatus(let status):
            return "queue converter-error read failed with Core Audio status \(status)"
        case .unexpectedStreamSampleRate(let actual):
            return "queue stream sample rate was \(actual), expected 48000"
        case .unexpectedStreamFormatID(let actual):
            return "queue stream format ID was \(actual), expected linear PCM"
        case .unexpectedStreamFormatFlags(let actual):
            return "queue stream format flags were \(actual), expected "
                + "signed packed interleaved Int16"
        case .unexpectedStreamBytesPerPacket(let actual):
            return "queue stream bytes per packet were \(actual), expected 2"
        case .unexpectedStreamFramesPerPacket(let actual):
            return "queue stream frames per packet were \(actual), expected 1"
        case .unexpectedStreamBytesPerFrame(let actual):
            return "queue stream bytes per frame were \(actual), expected 2"
        case .unexpectedStreamChannelsPerFrame(let actual):
            return "queue stream channel count was \(actual), expected 1"
        case .unexpectedStreamBitsPerChannel(let actual):
            return "queue stream bits per channel were \(actual), expected 16"
        case .unexpectedStreamReserved(let actual):
            return "queue stream reserved field was \(actual), expected 0"
        case .unexpectedDeviceSampleRate(let actual):
            return "queue device sample rate was \(actual), expected 48000"
        case .unexpectedDeviceChannelCount(let actual):
            return "queue device channel count was \(actual), expected 1"
        case .converterError(let actual):
            return "queue converter error was nonzero (actual=\(actual))"
        }
    }
}

struct BlackHoleMicrophoneOutputFormatPolicy: Sendable {
    static let requiredSampleRate = 48_000.0
    static let requiredChannelCount: UInt32 = 1
    static let requiredFormatFlags: AudioFormatFlags =
        kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked

    static var requiredStreamDescription:
        AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: requiredSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: requiredFormatFlags,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: requiredChannelCount,
            mBitsPerChannel: 16,
            mReserved: 0
        )
    }

    static var validEvidence: BlackHoleMicrophoneOutputFormatEvidence {
        BlackHoleMicrophoneOutputFormatEvidence(
            streamDescriptionStatus: noErr,
            streamDescription: requiredStreamDescription,
            deviceSampleRateStatus: noErr,
            deviceSampleRate: requiredSampleRate,
            deviceChannelCountStatus: noErr,
            deviceChannelCount: requiredChannelCount,
            converterErrorReadStatus: noErr,
            converterError: 0
        )
    }

    func evaluate(
        _ evidence: BlackHoleMicrophoneOutputFormatEvidence
    ) -> Result<
        BlackHoleMicrophoneOutputFormatObservation,
        BlackHoleMicrophoneOutputFormatRejection
    > {
        guard evidence.streamDescriptionStatus == noErr else {
            return .failure(
                .streamDescriptionCoreAudioStatus(
                    evidence.streamDescriptionStatus
                )
            )
        }
        guard evidence.deviceSampleRateStatus == noErr else {
            return .failure(
                .deviceSampleRateCoreAudioStatus(
                    evidence.deviceSampleRateStatus
                )
            )
        }
        guard evidence.deviceChannelCountStatus == noErr else {
            return .failure(
                .deviceChannelCountCoreAudioStatus(
                    evidence.deviceChannelCountStatus
                )
            )
        }
        guard evidence.converterErrorReadStatus == noErr else {
            return .failure(
                .converterErrorCoreAudioStatus(
                    evidence.converterErrorReadStatus
                )
            )
        }

        let stream = evidence.streamDescription
        guard stream.mSampleRate == Self.requiredSampleRate else {
            return .failure(
                .unexpectedStreamSampleRate(
                    actual: stream.mSampleRate
                )
            )
        }
        guard stream.mFormatID == kAudioFormatLinearPCM else {
            return .failure(
                .unexpectedStreamFormatID(actual: stream.mFormatID)
            )
        }
        guard stream.mFormatFlags == Self.requiredFormatFlags else {
            return .failure(
                .unexpectedStreamFormatFlags(
                    actual: stream.mFormatFlags
                )
            )
        }
        guard stream.mBytesPerPacket == 2 else {
            return .failure(
                .unexpectedStreamBytesPerPacket(
                    actual: stream.mBytesPerPacket
                )
            )
        }
        guard stream.mFramesPerPacket == 1 else {
            return .failure(
                .unexpectedStreamFramesPerPacket(
                    actual: stream.mFramesPerPacket
                )
            )
        }
        guard stream.mBytesPerFrame == 2 else {
            return .failure(
                .unexpectedStreamBytesPerFrame(
                    actual: stream.mBytesPerFrame
                )
            )
        }
        guard stream.mChannelsPerFrame == Self.requiredChannelCount else {
            return .failure(
                .unexpectedStreamChannelsPerFrame(
                    actual: stream.mChannelsPerFrame
                )
            )
        }
        guard stream.mBitsPerChannel == 16 else {
            return .failure(
                .unexpectedStreamBitsPerChannel(
                    actual: stream.mBitsPerChannel
                )
            )
        }
        guard stream.mReserved == 0 else {
            return .failure(
                .unexpectedStreamReserved(actual: stream.mReserved)
            )
        }
        guard evidence.deviceSampleRate == Self.requiredSampleRate else {
            return .failure(
                .unexpectedDeviceSampleRate(
                    actual: evidence.deviceSampleRate
                )
            )
        }
        guard evidence.deviceChannelCount == Self.requiredChannelCount else {
            return .failure(
                .unexpectedDeviceChannelCount(
                    actual: evidence.deviceChannelCount
                )
            )
        }
        guard evidence.converterError == 0 else {
            return .failure(
                .converterError(actual: evidence.converterError)
            )
        }

        return .success(
            BlackHoleMicrophoneOutputFormatObservation(
                sampleRate: stream.mSampleRate,
                formatID: stream.mFormatID,
                formatFlags: stream.mFormatFlags,
                bytesPerPacket: stream.mBytesPerPacket,
                framesPerPacket: stream.mFramesPerPacket,
                bytesPerFrame: stream.mBytesPerFrame,
                channelsPerFrame: stream.mChannelsPerFrame,
                bitsPerChannel: stream.mBitsPerChannel,
                reserved: stream.mReserved,
                deviceSampleRate: evidence.deviceSampleRate,
                deviceChannelCount: evidence.deviceChannelCount,
                converterError: evidence.converterError
            )
        )
    }
}
