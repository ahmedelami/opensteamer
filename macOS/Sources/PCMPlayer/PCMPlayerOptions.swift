import Foundation

struct PCMPlayerOptions {
    var host = "127.0.0.1"
    var port: UInt16 = 9000
    var duration: TimeInterval = 10
    var latencyMilliseconds: Double = 80
    var maxPackets: Int?
    var authToken = ProcessInfo.processInfo.environment["MCAP_TOKEN"]?.nilIfEmpty
    var showHelp = false

    static let usage = """
    Usage:
      swift run PCMPlayer --host 127.0.0.1 --port 9000 --duration 10 --latency-ms 80

    Options:
      --host <host>          CaptureServer host. Defaults to 127.0.0.1.
      --port <port>          CaptureServer TCP port. Defaults to 9000.
      --duration <seconds>   Playback duration after connection. Defaults to 10.
      --latency-ms <ms>      Target jitter buffer before starting audio. Defaults to 80.
      --packets <count>      Optional max packet count instead of only duration.
      --token <token>        Client token. Defaults to MCAP_TOKEN if set.
      --help                 Print this help.
    """

    static func parse(_ arguments: [String]) throws -> PCMPlayerOptions {
        var options = PCMPlayerOptions()
        var index = 1

        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--host":
                index += 1
                guard index < arguments.count else {
                    throw PCMPlayerOptionError.invalid("--host requires a value")
                }
                options.host = arguments[index]
            case "--port":
                index += 1
                guard index < arguments.count, let value = UInt16(arguments[index]) else {
                    throw PCMPlayerOptionError.invalid("--port requires a valid UInt16")
                }
                options.port = value
            case "--duration":
                index += 1
                guard index < arguments.count, let value = TimeInterval(arguments[index]), value > 0 else {
                    throw PCMPlayerOptionError.invalid("--duration requires a positive number")
                }
                options.duration = value
            case "--latency-ms":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]), value >= 20 else {
                    throw PCMPlayerOptionError.invalid("--latency-ms requires a number >= 20")
                }
                options.latencyMilliseconds = value
            case "--packets":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    throw PCMPlayerOptionError.invalid("--packets requires a positive integer")
                }
                options.maxPackets = value
            case "--token":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw PCMPlayerOptionError.invalid("--token requires a non-empty value")
                }
                options.authToken = arguments[index]
            case "--help", "-h":
                options.showHelp = true
            default:
                throw PCMPlayerOptionError.invalid("unknown argument: \(arg)")
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

enum PCMPlayerOptionError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            message
        }
    }
}
