import CoreAudio
import Foundation

final class BlackHoleRouteManager: @unchecked Sendable {
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

    func prepareRoute() throws -> AudioRoute {
        let route = try findBlackHoleRoute()
        try applyDefaults(route: route, reason: "startup")
        expectedRoute = route
        logger.info("Routed Mac default output, system output, and input to \(route.name)")
        return route
    }

    func startMonitoring(expectedRoute: AudioRoute) throws {
        stopMonitoring()
        self.expectedRoute = expectedRoute

        for selector in Self.defaultDeviceSelectors {
            try addListener(selector: selector)
        }
    }

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

    private func shouldReassertRoute(now: Date = Date()) -> Bool {
        recentReassertions = recentReassertions.filter { now.timeIntervalSince($0) < 60 }
        guard recentReassertions.count < 3 else { return false }
        recentReassertions.append(now)
        return true
    }

    private func defaultDeviceDrift(expectedRoute: AudioRoute) throws -> [String] {
        try Self.defaultDeviceSelectors.compactMap { selector in
            let currentDevice = try Self.defaultDevice(selector: selector)
            guard currentDevice != expectedRoute.deviceID else { return nil }
            let name = Self.deviceName(currentDevice) ?? "unknown"
            return "\(Self.label(for: selector))=\(name)"
        }
    }

    private func findBlackHoleRoute() throws -> AudioRoute {
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

struct AudioRoute: Sendable {
    let deviceID: AudioDeviceID
    let name: String
    let uid: String?

    var isBlackHole: Bool {
        name.localizedCaseInsensitiveContains("BlackHole") ||
            (uid?.localizedCaseInsensitiveContains("BlackHole") ?? false)
    }
}
