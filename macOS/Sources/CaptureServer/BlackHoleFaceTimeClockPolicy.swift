import AudioToolbox
import CoreAudio
import Darwin

struct BlackHoleFaceTimeClockObservation: Equatable, Sendable {
    let deviceSampleTime: Double
    let deviceHostTime: UInt64
    let deviceSampleRate: Double
    let projectedFaceTimeSampleTime: UInt64
}

enum BlackHoleFaceTimeClockRejection: Error, Equatable, Sendable {
    case coreAudioStatus(OSStatus)
    case sampleRateCoreAudioStatus(OSStatus)
    case missingRequiredTimestampFlags(actual: AudioTimeStampFlags)
    case nonFiniteDeviceSampleTime
    case negativeDeviceSampleTime
    case nonIntegralDeviceSampleTime
    case zeroDeviceHostTime
    case unexpectedDeviceSampleRate
    case projectedSampleTimeOverflow
    case deviceSampleTimeDidNotAdvance(previous: Double, current: Double)
    case deviceHostTimeDidNotAdvance(previous: UInt64, current: UInt64)
    case deviceClockRateMismatch(
        actualFrameDelta: Double,
        expectedFrameDelta: Double,
        toleranceFrames: Double,
        elapsedHostNanoseconds: UInt64
    )
    case startupClockContinuityTimedOut
    case insufficientSigned32Headroom(
        observation: BlackHoleFaceTimeClockObservation,
        maximumProjectedSampleTime: UInt64
    )

    var description: String {
        switch self {
        case .coreAudioStatus(let status):
            return "device-time read failed with Core Audio status \(status)"
        case .sampleRateCoreAudioStatus(let status):
            return "device sample-rate read failed with Core Audio status \(status)"
        case .missingRequiredTimestampFlags(let actual):
            return "device time omitted required sample/host flags (actual=\(actual))"
        case .nonFiniteDeviceSampleTime:
            return "device sample time was not finite"
        case .negativeDeviceSampleTime:
            return "device sample time was negative"
        case .nonIntegralDeviceSampleTime:
            return "device sample time was not an integral frame count"
        case .zeroDeviceHostTime:
            return "device host time was zero"
        case .unexpectedDeviceSampleRate:
            return "device sample rate was not the required 48000 Hz"
        case .projectedSampleTimeOverflow:
            return "the projected FaceTime sample time was not representable"
        case .deviceSampleTimeDidNotAdvance(let previous, let current):
            return "device sample time did not advance from \(previous) (current=\(current))"
        case .deviceHostTimeDidNotAdvance(let previous, let current):
            return "device host time did not advance from \(previous) (current=\(current))"
        case .deviceClockRateMismatch(
            let actualFrameDelta,
            let expectedFrameDelta,
            let toleranceFrames,
            let elapsedHostNanoseconds
        ):
            return "device clock advanced \(actualFrameDelta) frames over "
                + "\(elapsedHostNanoseconds) host nanoseconds; expected "
                + "\(expectedFrameDelta) +/- \(toleranceFrames) frames"
        case .startupClockContinuityTimedOut:
            return "device sample/host time did not provide two "
                + "advancing observations before the startup deadline"
        case .insufficientSigned32Headroom(
            let observation,
            let maximumProjectedSampleTime
        ):
            return "projected 24 kHz sample time "
                + "\(observation.projectedFaceTimeSampleTime) exceeds safe "
                + "signed-32 limit \(maximumProjectedSampleTime)"
        }
    }
}

/// Compatibility gate for FaceTime's observed signed-32 microphone timeline.
///
/// BlackHole's public device time is in the validated 48 kHz endpoint domain;
/// FaceTime's failing AUIO boundary advances at 24 kHz. Projection therefore
/// preserves elapsed time and rounds upward before reserving one minute for a
/// delayed watchdog tick and fail-closed teardown.
struct BlackHoleFaceTimeClockPolicy: Sendable {
    static let deviceSampleRate: UInt64 = 48_000
    static let faceTimeSampleRate: UInt64 = 24_000
    static let requiredHeadroomSeconds: UInt64 = 60
    static let requiredHeadroomFrames =
        faceTimeSampleRate * requiredHeadroomSeconds
    static let maximumProjectedSampleTime =
        UInt64(Int32.max) - requiredHeadroomFrames
    static let requiredTimestampFlags: AudioTimeStampFlags = [
        .sampleTimeValid,
        .hostTimeValid,
    ]

    /// BlackHole's optional adjustable clock is documented as +/-1%. The
    /// paired sample/host timestamps remove watchdog scheduling jitter, so a
    /// 2% envelope covers that full supported range plus conversion rounding
    /// while rejecting a clock that can unexpectedly consume the 60-second
    /// signed-32 teardown reserve. Two frames is the minimum rounding floor
    /// for very short observations.
    static let maximumClockRateErrorFraction = 0.02
    static let minimumClockRateToleranceFrames = 2.0

    private static let firstUnrepresentableUInt64AsDouble =
        18_446_744_073_709_551_616.0

    static func projectedFaceTimeSampleTime(
        sampleTime: Double,
        sampleRate: Double
    ) -> Result<UInt64, BlackHoleFaceTimeClockRejection> {
        guard sampleTime.isFinite else {
            return .failure(.nonFiniteDeviceSampleTime)
        }
        guard sampleTime >= 0 else {
            return .failure(.negativeDeviceSampleTime)
        }
        guard sampleTime.rounded(.towardZero) == sampleTime else {
            return .failure(.nonIntegralDeviceSampleTime)
        }
        guard sampleRate.isFinite, sampleRate > 0 else {
            return .failure(.unexpectedDeviceSampleRate)
        }

        let projected = ceil(
            sampleTime / sampleRate
                * Double(faceTimeSampleRate)
        )
        guard projected.isFinite,
              projected >= 0,
              projected < firstUnrepresentableUInt64AsDouble else {
            return .failure(.projectedSampleTimeOverflow)
        }
        return .success(UInt64(projected))
    }

    func evaluate(
        status: OSStatus,
        timestamp: AudioTimeStamp,
        deviceSampleRate: Double = Double(Self.deviceSampleRate),
        previous: BlackHoleFaceTimeClockObservation? = nil
    ) -> Result<
        BlackHoleFaceTimeClockObservation,
        BlackHoleFaceTimeClockRejection
    > {
        guard status == noErr else {
            return .failure(.coreAudioStatus(status))
        }
        guard timestamp.mFlags.contains(
            Self.requiredTimestampFlags
        ) else {
            return .failure(
                .missingRequiredTimestampFlags(
                    actual: timestamp.mFlags
                )
            )
        }
        guard timestamp.mHostTime > 0 else {
            return .failure(.zeroDeviceHostTime)
        }
        guard deviceSampleRate == Double(Self.deviceSampleRate) else {
            return .failure(.unexpectedDeviceSampleRate)
        }

        let projected: UInt64
        switch Self.projectedFaceTimeSampleTime(
            sampleTime: timestamp.mSampleTime,
            sampleRate: deviceSampleRate
        ) {
        case .success(let value):
            projected = value
        case .failure(let rejection):
            return .failure(rejection)
        }

        let observation = BlackHoleFaceTimeClockObservation(
            deviceSampleTime: timestamp.mSampleTime,
            deviceHostTime: timestamp.mHostTime,
            deviceSampleRate: deviceSampleRate,
            projectedFaceTimeSampleTime: projected
        )
        if let previous {
            guard observation.deviceSampleTime
                    > previous.deviceSampleTime else {
                return .failure(
                    .deviceSampleTimeDidNotAdvance(
                        previous: previous.deviceSampleTime,
                        current: observation.deviceSampleTime
                    )
                )
            }
            guard observation.deviceHostTime
                    > previous.deviceHostTime else {
                return .failure(
                    .deviceHostTimeDidNotAdvance(
                        previous: previous.deviceHostTime,
                        current: observation.deviceHostTime
                    )
                )
            }
        }
        guard projected <= Self.maximumProjectedSampleTime else {
            return .failure(
                .insufficientSigned32Headroom(
                    observation: observation,
                    maximumProjectedSampleTime:
                        Self.maximumProjectedSampleTime
                )
            )
        }
        if let previous {
            let hostDelta = observation.deviceHostTime
                - previous.deviceHostTime
            let elapsedHostNanoseconds =
                AudioConvertHostTimeToNanos(hostDelta)
            let expectedFrameDelta =
                Double(elapsedHostNanoseconds)
                * deviceSampleRate
                / 1_000_000_000
            let actualFrameDelta =
                observation.deviceSampleTime
                - previous.deviceSampleTime
            let toleranceFrames = max(
                Self.minimumClockRateToleranceFrames,
                expectedFrameDelta
                    * Self.maximumClockRateErrorFraction
            )
            guard expectedFrameDelta.isFinite,
                  abs(actualFrameDelta - expectedFrameDelta)
                    <= toleranceFrames else {
                return .failure(
                    .deviceClockRateMismatch(
                        actualFrameDelta: actualFrameDelta,
                        expectedFrameDelta: expectedFrameDelta,
                        toleranceFrames: toleranceFrames,
                        elapsedHostNanoseconds:
                            elapsedHostNanoseconds
                    )
                )
            }
        }
        return .success(observation)
    }
}
