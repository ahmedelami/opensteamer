import Foundation

struct CLIOptions {
    var duration: TimeInterval = 10
    var outputURL: URL?
    var listDisplays = false
    var listApps = false
    var displayID: UInt32?
    var verbose = false
    var showHelp = false

    static let usage = """
    Usage:
      swift run CaptureCLI --duration 10 --output capture.wav [--verbose]
      swift run CaptureCLI --list-displays
      swift run CaptureCLI --list-apps

    Options:
      --duration <seconds>   Capture duration. Defaults to 10.
      --output <path>        WAV output path. Defaults to capture-YYYYMMDD-HHMMSS.wav.
      --display-id <id>      Capture a specific display ID. Defaults to the first display.
      --list-displays        Print displays visible to ScreenCaptureKit.
      --list-apps            Print running apps visible to ScreenCaptureKit.
      --verbose              Print per-second metrics while capturing.
      --help                 Print this help.
    """

    static func parse(_ arguments: [String]) throws -> CLIOptions {
        var options = CLIOptions()
        var index = 1

        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--duration":
                index += 1
                guard index < arguments.count, let value = TimeInterval(arguments[index]), value > 0 else {
                    throw CLIError.invalidArgument("--duration requires a positive number")
                }
                options.duration = value
            case "--output":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("--output requires a path")
                }
                options.outputURL = URL(fileURLWithPath: arguments[index])
            case "--display-id":
                index += 1
                guard index < arguments.count, let value = UInt32(arguments[index]) else {
                    throw CLIError.invalidArgument("--display-id requires an unsigned integer")
                }
                options.displayID = value
            case "--list-displays":
                options.listDisplays = true
            case "--list-apps":
                options.listApps = true
            case "--verbose":
                options.verbose = true
            case "--help", "-h":
                options.showHelp = true
            default:
                throw CLIError.invalidArgument("unknown argument: \(arg)")
            }
            index += 1
        }

        return options
    }
}

enum CLIError: LocalizedError {
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message):
            message
        }
    }
}
