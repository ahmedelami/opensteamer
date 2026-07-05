import CaptureCore
import Foundation

struct CaptureServerOptions {
    var host = "0.0.0.0"
    var port: UInt16 = 9000
    var duration: TimeInterval? = 30
    var displayID: UInt32?
    var captureMode: AudioCaptureMode = .blackHoleInput
    var bonjourName: String? = Host.current().localizedName ?? "MacCapture"
    var authToken = ProcessInfo.processInfo.environment["MCAP_TOKEN"]?.nilIfEmpty
    var verbose = false
    var listDisplays = false
    var showHelp = false

    static let usage = """
    Usage:
      swift run CaptureServer --port 9000 --duration 30 --verbose
      swift run CaptureServer --list-displays

    Options:
      --host <host>          Host label for diagnostics. Listener binds all interfaces.
      --port <port>          TCP port. Defaults to 9000.
      --duration <seconds>   Capture duration. Defaults to 30. Use 0 for indefinite.
      --capture-mode <mode>  blackhole-input or screen. Defaults to blackhole-input.
      --display-id <id>      Capture a specific display ID.
      --bonjour-name <name>  Bonjour name for _mcap._tcp. Defaults to host name.
      --no-bonjour           Disable Bonjour advertisement.
      --token <token>        Require this client token. Defaults to MCAP_TOKEN if set.
      --list-displays        Print displays visible to ScreenCaptureKit.
      --verbose              Print verbose logs.
      --help                 Print this help.
    """

    static func parse(_ arguments: [String]) throws -> CaptureServerOptions {
        var options = CaptureServerOptions()
        var index = 1

        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--host":
                index += 1
                guard index < arguments.count else {
                    throw CaptureServerOptionError.invalid("--host requires a value")
                }
                options.host = arguments[index]
            case "--port":
                index += 1
                guard index < arguments.count, let value = UInt16(arguments[index]) else {
                    throw CaptureServerOptionError.invalid("--port requires a valid UInt16")
                }
                options.port = value
            case "--duration":
                index += 1
                guard index < arguments.count, let value = TimeInterval(arguments[index]), value >= 0 else {
                    throw CaptureServerOptionError.invalid("--duration requires a non-negative number")
                }
                options.duration = value == 0 ? nil : value
            case "--capture-mode":
                index += 1
                guard index < arguments.count, let value = AudioCaptureMode(rawValue: arguments[index]) else {
                    throw CaptureServerOptionError.invalid("--capture-mode must be blackhole-input or screen")
                }
                options.captureMode = value
            case "--display-id":
                index += 1
                guard index < arguments.count, let value = UInt32(arguments[index]) else {
                    throw CaptureServerOptionError.invalid("--display-id requires an unsigned integer")
                }
                options.displayID = value
            case "--bonjour-name":
                index += 1
                guard index < arguments.count else {
                    throw CaptureServerOptionError.invalid("--bonjour-name requires a value")
                }
                options.bonjourName = arguments[index]
            case "--no-bonjour":
                options.bonjourName = nil
            case "--token":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw CaptureServerOptionError.invalid("--token requires a non-empty value")
                }
                options.authToken = arguments[index]
            case "--list-displays":
                options.listDisplays = true
            case "--verbose":
                options.verbose = true
            case "--help", "-h":
                options.showHelp = true
            default:
                throw CaptureServerOptionError.invalid("unknown argument: \(arg)")
            }
            index += 1
        }

        return options
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

enum CaptureServerOptionError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            message
        }
    }
}
