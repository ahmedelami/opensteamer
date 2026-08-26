import CaptureCore
import CoreGraphics
import Darwin
import Foundation

enum ScreenVideoDisplayModeProbeParseResult: Equatable {
    case notRequested
    case malformed
    case request(ScreenVideoDisplayModeProbeRequest)
}

/// Private, exact request passed to a fresh CaptureServer process before normal startup begins.
struct ScreenVideoDisplayModeProbeRequest: Equatable, Sendable {
    static let flag = "--_opensteamer-display-mode-probe-v1"

    let displayID: UInt32
    let displayRequirement: ScreenVideoDisplayRequirement?

    static func arguments(
        displayID: UInt32,
        displayRequirement: ScreenVideoDisplayRequirement?
    ) -> [String] {
        let hasRequirement = displayRequirement != nil
        return [
            flag,
            String(displayID),
            hasRequirement ? "1" : "0",
            String(displayRequirement?.vendorID ?? 0),
            String(displayRequirement?.productID ?? 0),
            String(displayRequirement?.serialNumber ?? 0),
            displayRequirement?.requiresSoleMainDisplay == true ? "1" : "0",
        ]
    }

    static func parse(_ processArguments: [String]) -> ScreenVideoDisplayModeProbeParseResult {
        let suppliedArguments = Array(processArguments.dropFirst())
        guard suppliedArguments.contains(flag) else { return .notRequested }
        guard suppliedArguments.count == 7,
              suppliedArguments.first == flag,
              let displayID = UInt32(suppliedArguments[1]),
              let hasRequirement = parseBoolean(suppliedArguments[2]),
              let vendorID = UInt32(suppliedArguments[3]),
              let productID = UInt32(suppliedArguments[4]),
              let serialNumber = UInt32(suppliedArguments[5]),
              let requiresSoleMainDisplay = parseBoolean(suppliedArguments[6]) else {
            return .malformed
        }

        let requirement: ScreenVideoDisplayRequirement?
        if hasRequirement {
            guard vendorID > 0, productID > 0, serialNumber > 0 else {
                return .malformed
            }
            requirement = ScreenVideoDisplayRequirement(
                vendorID: vendorID,
                productID: productID,
                serialNumber: serialNumber,
                requiresSoleMainDisplay: requiresSoleMainDisplay
            )
        } else {
            guard vendorID == 0,
                  productID == 0,
                  serialNumber == 0,
                  !requiresSoleMainDisplay else {
                return .malformed
            }
            requirement = nil
        }

        return .request(
            ScreenVideoDisplayModeProbeRequest(
                displayID: displayID,
                displayRequirement: requirement
            )
        )
    }

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value {
        case "0": false
        case "1": true
        default: nil
        }
    }
}

struct ScreenVideoDisplayModeProbeExecution: Equatable, Sendable {
    let exitStatus: Int32
    let output: String?
}

/// Runs before option parsing, host locking, virtual-display creation, or service startup.
enum ScreenVideoDisplayModeProbeMode {
    typealias SnapshotReader =
        (ScreenVideoDisplayModeProbeRequest) -> ScreenVideoDisplayModeSnapshot?

    static let malformedRequestExitStatus: Int32 = 64
    static let snapshotUnavailableExitStatus: Int32 = 75
    static let outputPrefix = "opensteamer-display-mode-v1"

    static func executionIfRequested(
        _ arguments: [String],
        snapshotReader: SnapshotReader = readLiveSnapshot
    ) -> ScreenVideoDisplayModeProbeExecution? {
        switch ScreenVideoDisplayModeProbeRequest.parse(arguments) {
        case .notRequested:
            return nil
        case .malformed:
            return ScreenVideoDisplayModeProbeExecution(
                exitStatus: malformedRequestExitStatus,
                output: nil
            )
        case .request(let request):
            guard let snapshot = snapshotReader(request) else {
                return ScreenVideoDisplayModeProbeExecution(
                    exitStatus: snapshotUnavailableExitStatus,
                    output: nil
                )
            }
            return ScreenVideoDisplayModeProbeExecution(
                exitStatus: 0,
                output: render(snapshot, displayID: request.displayID)
            )
        }
    }

    static func parseOutput(
        _ output: String,
        expectedDisplayID: UInt32
    ) -> ScreenVideoDisplayModeSnapshot? {
        let fields = output.split(whereSeparator: \Character.isWhitespace)
        guard fields.count == 6,
              fields[0] == Substring(outputPrefix),
              UInt32(fields[1]) == expectedDisplayID,
              let logicalWidth = Int(fields[2]),
              let logicalHeight = Int(fields[3]),
              let pixelWidth = Int(fields[4]),
              let pixelHeight = Int(fields[5]),
              logicalWidth >= 2,
              logicalHeight >= 2,
              pixelWidth >= 2,
              pixelHeight >= 2 else {
            return nil
        }
        return ScreenVideoDisplayModeSnapshot(
            logicalDimensions: ScreenVideoPixelDimensions(
                width: logicalWidth,
                height: logicalHeight
            ),
            pixelDimensions: ScreenVideoPixelDimensions(
                width: pixelWidth,
                height: pixelHeight
            )
        )
    }

    private static func render(
        _ snapshot: ScreenVideoDisplayModeSnapshot,
        displayID: UInt32
    ) -> String {
        "\(outputPrefix) \(displayID) "
            + "\(snapshot.logicalDimensions.width) \(snapshot.logicalDimensions.height) "
            + "\(snapshot.pixelDimensions.width) \(snapshot.pixelDimensions.height)\n"
    }

    private static func readLiveSnapshot(
        _ request: ScreenVideoDisplayModeProbeRequest
    ) -> ScreenVideoDisplayModeSnapshot? {
        let displayID = request.displayID
        guard CGDisplayIsOnline(displayID) != 0,
              CGDisplayIsActive(displayID) != 0 else {
            return nil
        }
        if let requirement = request.displayRequirement {
            guard CGDisplayVendorNumber(displayID) == requirement.vendorID,
                  CGDisplayModelNumber(displayID) == requirement.productID,
                  CGDisplaySerialNumber(displayID) == requirement.serialNumber else {
                return nil
            }
            if requirement.requiresSoleMainDisplay {
                var onlineDisplayIDs = [CGDirectDisplayID](repeating: 0, count: 2)
                var onlineDisplayCount: UInt32 = 0
                guard CGMainDisplayID() == displayID,
                      CGGetOnlineDisplayList(
                          UInt32(onlineDisplayIDs.count),
                          &onlineDisplayIDs,
                          &onlineDisplayCount
                      ) == .success,
                      onlineDisplayCount == 1,
                      onlineDisplayIDs[0] == displayID else {
                    return nil
                }
            }
        }
        guard let mode = CGDisplayCopyDisplayMode(displayID),
              mode.width >= 2,
              mode.height >= 2,
              mode.pixelWidth >= 2,
              mode.pixelHeight >= 2 else {
            return nil
        }
        return ScreenVideoDisplayModeSnapshot(
            logicalDimensions: ScreenVideoPixelDimensions(
                width: mode.width,
                height: mode.height
            ),
            pixelDimensions: ScreenVideoPixelDimensions(
                width: mode.pixelWidth,
                height: mode.pixelHeight
            )
        )
    }
}

/// Reads the current mode through a fresh CoreGraphics connection with a bounded helper process.
struct ScreenVideoDisplayModeSubprocessResolver: Sendable {
    typealias Runner = @Sendable (URL, [String], TimeInterval) -> String?

    static let timeout: TimeInterval = 3
    private static let maximumOutputBytes = 4 * 1_024

    let executableURL: URL
    let runner: Runner

    init(
        executableURL: URL,
        runner: @escaping Runner = Self.runBoundedProcess
    ) {
        self.executableURL = executableURL
        self.runner = runner
    }

    static func live() -> Self? {
        guard let executableURL = Bundle.main.executableURL,
              executableURL.isFileURL,
              executableURL.path.hasPrefix("/") else {
            return nil
        }
        return Self(executableURL: executableURL)
    }

    static func resolveLive(
        _ displayID: UInt32,
        displayRequirement: ScreenVideoDisplayRequirement?
    ) async throws -> ScreenVideoDisplayModeSnapshot {
        guard let resolver = live() else {
            throw ScreenVideoDisplayModeSubprocessResolverError.executableUnavailable
        }
        return try await resolver.resolve(
            displayID,
            displayRequirement: displayRequirement
        )
    }

    func resolve(
        _ displayID: UInt32,
        displayRequirement: ScreenVideoDisplayRequirement?
    ) async throws -> ScreenVideoDisplayModeSnapshot {
        let arguments = ScreenVideoDisplayModeProbeRequest.arguments(
            displayID: displayID,
            displayRequirement: displayRequirement
        )
        let executableURL = executableURL
        let runner = runner
        let output = await Task.detached(priority: .userInitiated) {
            runner(executableURL, arguments, Self.timeout)
        }.value
        guard let output else {
            throw ScreenVideoDisplayModeSubprocessResolverError.probeFailed(displayID)
        }
        guard let snapshot = ScreenVideoDisplayModeProbeMode.parseOutput(
            output,
            expectedDisplayID: displayID
        ) else {
            throw ScreenVideoDisplayModeSubprocessResolverError.snapshotUnavailable(displayID)
        }
        return snapshot
    }

    static func runBoundedProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            return nil
        }
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            return nil
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard output.count <= Self.maximumOutputBytes else { return nil }
        return String(data: output, encoding: .utf8)
    }
}

enum ScreenVideoDisplayModeSubprocessResolverError: LocalizedError, Equatable {
    case executableUnavailable
    case probeFailed(UInt32)
    case snapshotUnavailable(UInt32)

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            "The current host executable is unavailable for a fresh display-mode check"
        case .probeFailed(let displayID):
            "The fresh display-mode check failed for display \(displayID)"
        case .snapshotUnavailable(let displayID):
            "The fresh display-mode check did not return display \(displayID)"
        }
    }
}
