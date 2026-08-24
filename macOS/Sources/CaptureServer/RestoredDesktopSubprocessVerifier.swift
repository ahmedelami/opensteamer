import Darwin
import Foundation
import VirtualDisplayCore

enum RestoredDesktopProbeParseResult: Equatable {
    case notRequested
    case malformed
    case request(RestoredDesktopExpectation)
}

enum RestoredDesktopProbeRequest {
    static let flag = "--_opensteamer-restored-desktop-probe-v1"

    static func arguments(for expectation: RestoredDesktopExpectation) -> [String] {
        [
            flag,
            String(expectation.retiredVendorID),
            String(expectation.retiredProductID),
            String(expectation.retiredSerialNumber),
            String(expectation.logicalWidth),
            String(expectation.logicalHeight),
            String(expectation.pixelWidth),
            String(expectation.pixelHeight),
        ]
    }

    static func parse(_ processArguments: [String]) -> RestoredDesktopProbeParseResult {
        let suppliedArguments = Array(processArguments.dropFirst())
        guard suppliedArguments.contains(flag) else {
            return .notRequested
        }
        guard suppliedArguments.count == 8, suppliedArguments.first == flag else {
            return .malformed
        }
        let values = suppliedArguments.dropFirst().compactMap(UInt32.init)
        guard values.count == 7,
            let expectation = RestoredDesktopExpectation(
                retiredVendorID: values[0],
                retiredProductID: values[1],
                retiredSerialNumber: values[2],
                logicalWidth: values[3],
                logicalHeight: values[4],
                pixelWidth: values[5],
                pixelHeight: values[6]
            )
        else {
            return .malformed
        }
        return .request(expectation)
    }
}

enum RestoredDesktopProbeMode {
    static let malformedRequestExitStatus: Int32 = 64
    static let restorationUnconfirmedExitStatus: Int32 = 75

    static func exitStatusIfRequested(
        _ arguments: [String],
        verifier: (RestoredDesktopExpectation) -> Bool = {
            HeadlessDesktopReplacement.waitUntilRestored(expectation: $0)
        }
    ) -> Int32? {
        switch RestoredDesktopProbeRequest.parse(arguments) {
        case .notRequested:
            return nil
        case .malformed:
            return malformedRequestExitStatus
        case .request(let expectation):
            return verifier(expectation) ? 0 : restorationUnconfirmedExitStatus
        }
    }
}

struct RestoredDesktopSubprocessVerifier {
    typealias Runner = (URL, [String], TimeInterval) -> Bool

    static let timeout: TimeInterval = 12

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
            executableURL.path.hasPrefix("/")
        else {
            return nil
        }
        return Self(executableURL: executableURL)
    }

    func verify(_ expectation: RestoredDesktopExpectation) -> Bool {
        runner(
            executableURL,
            RestoredDesktopProbeRequest.arguments(for: expectation),
            Self.timeout
        )
    }

    private static func runBoundedProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) -> Bool {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return false
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            return false
        }
        return process.terminationReason == .exit && process.terminationStatus == 0
    }
}
