import CoreAudio
import Foundation

/// Finds BlackHole, assigns it to all relevant macOS defaults, and monitors route drift.
///
/// Core Audio delivers property notifications on `listenerQueue`. Host lifecycle calls
/// install and remove listeners; the unchecked conformance exists because Core Audio's
/// listener blocks are not modeled as `Sendable` by the SDK.
final class BlackHoleRouteManager: @unchecked Sendable {
    /// Retains the exact address/block pair required by Core Audio for deregistration.
    private struct Listener {
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private let logger: Logger
    private let listenerQueue = DispatchQueue(label: "MacCaptureVerifier.BlackHoleRouteManager")
    private var listeners: [Listener] = []
    private var expectedRoute: AudioRoute?
    private var isReassertingRoute = false
    private var recentReassertions: [Date] = []

    init(logger: Logger) {
        self.logger = logger
    }

    /// Resolves BlackHole and applies it as default output, system output, and input.
    func prepareRoute() throws -> AudioRoute {
        let route = try Self.findBlackHoleRoute()
        try applyDefaults(route: route, reason: "startup")
        expectedRoute = route
        logger.info("Routed Mac default output, system output, and input to \(route.name)")
        return route
    }

    /// Compares current defaults and the live capture queue with the prepared route.
    func health(captureDeviceUID: String?) throws -> BlackHoleRouteHealth {
        guard let expectedRoute else {
            throw CaptureError.audioRouteUnhealthy("No expected BlackHole route has been prepared")
        }
        return try Self.health(expectedRoute: expectedRoute, captureDeviceUID: captureDeviceUID)
    }

    /// Installs listeners that restore a prepared route after ordinary system changes.
    func startMonitoring(expectedRoute: AudioRoute) throws {
        stopMonitoring()
        self.expectedRoute = expectedRoute

        for selector in Self.defaultDeviceSelectors {
            try addListener(selector: selector)
        }
    }

    /// Removes every installed listener using its original registration identity.
    func stopMonitoring() {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                listenerQueue,
                listener.block
            )
        }
        listeners.removeAll()
    }

    /// Registers one system-object listener on the dedicated callback queue.
    private func addListener(selector: AudioObjectPropertySelector) throws {
        var address = Self.propertyAddress(selector: selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultDeviceChanged()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            block
        )
        guard status == noErr else {
            throw CaptureError.audioDeviceConfiguration("monitor \(Self.label(for: selector))", status)
        }
        listeners.append(Listener(address: address, block: block))
    }

    /// Verifies a device-change notification and performs a bounded route repair.
    private func handleDefaultDeviceChanged() {
        guard let expectedRoute else { return }
        guard !isReassertingRoute else {
            logger.debug("Ignoring route notification while BlackHole route is being reapplied")
            return
        }

        do {
            let drift = try defaultDeviceDrift(expectedRoute: expectedRoute)
            guard !drift.isEmpty else {
                logger.debug("Mac audio defaults still routed to \(expectedRoute.name)")
                return
            }

            guard shouldReassertRoute() else {
                logger.error(
                    "Mac audio default route is repeatedly changing away from \(expectedRoute.name); " +
                    "leaving current route in place after observed drift: \(drift.joined(separator: ", "))"
                )
                return
            }

            logger.info(
                "Observed Mac audio route drift from expected \(expectedRoute.name): " +
                "\(drift.joined(separator: ", "))"
            )
            isReassertingRoute = true
            defer { isReassertingRoute = false }

            try applyDefaults(route: expectedRoute, reason: "route-change")
            let remainingDrift = try defaultDeviceDrift(expectedRoute: expectedRoute)
            if remainingDrift.isEmpty {
                logger.info("Verified Mac audio defaults restored to \(expectedRoute.name)")
            } else {
                logger.error(
                    "BlackHole route restore did not stick; current drift: " +
                    "\(remainingDrift.joined(separator: ", "))"
                )
            }
        } catch {
            logger.error("Failed to verify or reapply BlackHole route: \(error.localizedDescription)")
        }
    }

    /// Rate-limits route writes to avoid fighting a user's repeated manual selection.
    private func shouldReassertRoute(now: Date = Date()) -> Bool {
        recentReassertions = recentReassertions.filter { now.timeIntervalSince($0) < 60 }
        guard recentReassertions.count < 3 else { return false }
        recentReassertions.append(now)
        return true
    }

    /// Returns operator-readable differences from the prepared default devices.
    private func defaultDeviceDrift(expectedRoute: AudioRoute) throws -> [String] {
        try Self.defaultDeviceSelectors.compactMap { selector in
            let currentDevice = try Self.defaultDevice(selector: selector)
            guard currentDevice != expectedRoute.deviceID else { return nil }
            let name = Self.deviceName(currentDevice) ?? "unknown"
            return "\(Self.label(for: selector))=\(name)"
        }
    }

    /// Verifies an already configured BlackHole route without changing system state.
    static func verifyCurrentRoute() throws -> BlackHoleRouteHealth {
        let route = try findBlackHoleRoute()
        return try health(expectedRoute: route, captureDeviceUID: route.uid)
    }

    /// Builds a complete route snapshot against an explicit expected device.
    private static func health(expectedRoute: AudioRoute, captureDeviceUID: String?) throws -> BlackHoleRouteHealth {
        // Verifies normal CoreAudio defaults, not apps that deliberately open a physical output directly.
        let expectedUID = expectedRoute.uid ?? ""
        let output = try endpointHealth(
            label: "Default Output",
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            expectedUID: expectedUID
        )
        let systemOutput = try endpointHealth(
            label: "Default System Output",
            selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            expectedUID: expectedUID
        )
        let input = try endpointHealth(
            label: "Default Input",
            selector: kAudioHardwarePropertyDefaultInputDevice,
            expectedUID: expectedUID
        )
        let capture = BlackHoleRouteEndpointHealth(
            label: "Capture Device",
            name: captureDeviceUID == nil ? "Unknown" : expectedRoute.name,
            uid: captureDeviceUID ?? "Unknown",
            matchesExpected: captureDeviceUID == expectedRoute.uid && expectedRoute.uid != nil
        )
        return BlackHoleRouteHealth(
            expectedName: expectedRoute.name,
            expectedUID: expectedUID.isEmpty ? "Unknown" : expectedUID,
            defaultOutput: output,
            defaultSystemOutput: systemOutput,
            defaultInput: input,
            captureDevice: capture
        )
    }

    /// Reads one Core Audio default endpoint and compares its stable UID.
    private static func endpointHealth(
        label: String,
        selector: AudioObjectPropertySelector,
        expectedUID: String
    ) throws -> BlackHoleRouteEndpointHealth {
        let deviceID = try defaultDevice(selector: selector)
        let uid = deviceUID(deviceID) ?? "Unknown"
        return BlackHoleRouteEndpointHealth(
            label: label,
            name: deviceName(deviceID) ?? "unknown",
            uid: uid,
            matchesExpected: !expectedUID.isEmpty && uid == expectedUID
        )
    }

    /// Locates the first installed route whose name or UID identifies BlackHole.
    private static func findBlackHoleRoute() throws -> AudioRoute {
        let routes = try Self.allDevices().map {
            AudioRoute(
                deviceID: $0,
                name: Self.deviceName($0) ?? "unknown",
                uid: Self.deviceUID($0)
            )
        }

        guard let route = routes.first(where: { $0.isBlackHole }) else {
            let names = routes.map(\.name).sorted().joined(separator: ", ")
            throw CaptureError.audioDeviceNotFound("BlackHole 2ch is required. Available devices: \(names)")
        }

        return route
    }

    /// Writes all three defaults; partial failure is surfaced to the caller.
    private func applyDefaults(route: AudioRoute, reason: String) throws {
        for selector in Self.defaultDeviceSelectors {
            try Self.setDefaultDevice(
                route.deviceID,
                selector: selector,
                label: Self.label(for: selector)
            )
        }
        logger.debug("Applied BlackHole route for \(reason): \(route.name)")
    }

    private static var defaultDeviceSelectors: [AudioObjectPropertySelector] {
        [
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice
        ]
    }

    /// Reads the variable-length Core Audio device list from the system object.
    private static func allDevices() throws -> [AudioDeviceID] {
        var address = propertyAddress(selector: kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        )
        guard status == noErr else {
            throw CaptureError.audioDeviceConfiguration("read device-list size", status)
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var devices = Array(repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &devices
        )
        guard status == noErr else {
            throw CaptureError.audioDeviceConfiguration("read device list", status)
        }
        return devices.filter { $0 != kAudioObjectUnknown }
    }

    /// Resolves one default-device selector to its current object identifier.
    private static func defaultDevice(selector: AudioObjectPropertySelector) throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = propertyAddress(selector: selector)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw CaptureError.audioDeviceConfiguration("read \(label(for: selector))", status)
        }
        return deviceID
    }

    /// Assigns one default-device selector and preserves its OSStatus on failure.
    private static func setDefaultDevice(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        label: String
    ) throws {
        var deviceID = deviceID
        var address = propertyAddress(selector: selector)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )
        guard status == noErr else {
            throw CaptureError.audioDeviceConfiguration("set \(label)", status)
        }
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, selector: kAudioObjectPropertyName)
    }

    private static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    /// Reads a Core Foundation string property from a Core Audio device.
    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String
    }

    private static func propertyAddress(selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func label(for selector: AudioObjectPropertySelector) -> String {
        switch selector {
        case kAudioHardwarePropertyDefaultOutputDevice:
            "default output"
        case kAudioHardwarePropertyDefaultSystemOutputDevice:
            "system output"
        case kAudioHardwarePropertyDefaultInputDevice:
            "default input"
        default:
            "audio device"
        }
    }
}

/// Identity of a concrete Core Audio route selected for loopback capture.
struct AudioRoute: Sendable {
    let deviceID: AudioDeviceID
    let name: String
    let uid: String?

    /// Whether the human-readable name or stable UID identifies BlackHole.
    var isBlackHole: Bool {
        name.localizedCaseInsensitiveContains("BlackHole") ||
            (uid?.localizedCaseInsensitiveContains("BlackHole") ?? false)
    }
}

/// Read-only public entry point for diagnosing an existing BlackHole route.
public enum BlackHoleRouteVerifier {
    /// Returns current route health without reconfiguring macOS audio defaults.
    public static func verifyCurrentRoute() throws -> BlackHoleRouteHealth {
        try BlackHoleRouteManager.verifyCurrentRoute()
    }
}

/// Aggregate comparison of every endpoint required by BlackHole capture.
public struct BlackHoleRouteHealth: Sendable, Equatable {
    public let expectedName: String
    public let expectedUID: String
    public let defaultOutput: BlackHoleRouteEndpointHealth
    public let defaultSystemOutput: BlackHoleRouteEndpointHealth
    public let defaultInput: BlackHoleRouteEndpointHealth
    public let captureDevice: BlackHoleRouteEndpointHealth

    /// `true` only when defaults and the capture queue all use the expected UID.
    public var isHealthy: Bool {
        defaultOutput.matchesExpected &&
            defaultSystemOutput.matchesExpected &&
            defaultInput.matchesExpected &&
            captureDevice.matchesExpected
    }

    /// Renders an operator-oriented route diagnostic.
    public func render() -> String {
        [
            "BlackHole route health",
            "----------------------",
            "Expected: \(expectedName) (\(expectedUID))",
            defaultOutput.render(),
            defaultSystemOutput.render(),
            defaultInput.render(),
            captureDevice.render(),
            "Overall: \(isHealthy ? "HEALTHY" : "UNHEALTHY")"
        ].joined(separator: "\n")
    }
}

/// Health of one named Core Audio endpoint relative to the expected route.
public struct BlackHoleRouteEndpointHealth: Sendable, Equatable {
    public let label: String
    public let name: String
    public let uid: String
    public let matchesExpected: Bool

    fileprivate func render() -> String {
        let marker = matchesExpected ? "OK" : "MISMATCH"
        return "\(label): \(name) (\(uid)) [\(marker)]"
    }
}
