import Foundation

/// Describes the cadence and media-time coverage of capture callbacks.
///
/// Wall-clock intervals use monotonic uptime so clock corrections cannot skew
/// the result. Presentation timestamps remain in the source media timebase.
public struct CallbackStatistics: Sendable {
    public private(set) var count: Int = 0
    public private(set) var averageInterval: TimeInterval = 0
    public private(set) var minimumInterval: TimeInterval?
    public private(set) var maximumInterval: TimeInterval?
    public private(set) var firstPresentationTime: TimeInterval?
    public private(set) var lastPresentationTime: TimeInterval?

    private var previousUptime: UInt64?
    private var totalInterval: TimeInterval = 0

    /// Creates an empty accumulator.
    public init() {}

    /// The elapsed media time between the first and most recent valid timestamp.
    public var presentationSpan: TimeInterval? {
        guard let firstPresentationTime, let lastPresentationTime else {
            return nil
        }
        return lastPresentationTime - firstPresentationTime
    }

    /// Records one callback and, when supplied, its source presentation time.
    ///
    /// - Parameters:
    ///   - uptimeNanoseconds: Monotonic arrival time; injectable for deterministic tests.
    ///   - presentationTime: Optional media timestamp in seconds.
    public mutating func recordCallback(
        uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        presentationTime: TimeInterval? = nil
    ) {
        if let presentationTime, presentationTime.isFinite {
            if firstPresentationTime == nil {
                firstPresentationTime = presentationTime
            }
            lastPresentationTime = presentationTime
        }

        defer {
            previousUptime = uptimeNanoseconds
            count += 1
        }

        guard let previousUptime else { return }
        let interval = TimeInterval(uptimeNanoseconds - previousUptime) / 1_000_000_000
        totalInterval += interval
        let intervalCount = max(count, 1)
        averageInterval = totalInterval / TimeInterval(intervalCount)
        minimumInterval = min(minimumInterval ?? interval, interval)
        maximumInterval = max(maximumInterval ?? interval, interval)
    }
}
