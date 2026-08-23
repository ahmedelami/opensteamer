import CaptureCore
import Foundation

/// Parsed configuration for trusted-LAN and worldwide host modes.
///
/// Worldwide mode disables plaintext LAN listeners unless `--with-lan` is explicit.
/// Authentication values may come from CLI or process environment, remain in memory,
/// and are not persisted by this options layer.
struct CaptureServerOptions {
    var host = "0.0.0.0"
    var port: UInt16 = 9000
    var screenPort: UInt16 = 9001
    var screenEnabled = true
    var screenFramesPerSecond = 60
    var screenMaximumWidth = 1_920
    var screenBitrate: UInt32 = 12_000_000
    var lanEnabled = true
    var worldwideEnabled = false
    var resetWorldwidePairing = false
    var allowRemoteControl = false
    var rendezvousURL: URL?
    var forceRelay = false
    var duration: TimeInterval? = 30
    var displayID: UInt32?
    var captureMode: AudioCaptureMode = .blackHoleInput
    var bonjourName: String? = Host.current().localizedName ?? "opensteamer"
    var authToken = ProcessInfo.processInfo.environment["MCAP_TOKEN"]?.nilIfEmpty
    var verbose = false
    var listDisplays = false
    var verifyRouting = false
    var showHelp = false

    /// LAN coexistence suppresses decoded forwarding and automatic input selection.
    var iPhoneMicrophoneForwardingPolicy:
        WorldwideIPhoneMicrophoneForwardingPolicy {
        lanEnabled
            ? .suppressedForLANCoexistence
            : .enabled
    }

    static let usage = """
    Usage:
      swift run CaptureServer --port 9000 --duration 30 --verbose
      swift run CaptureServer --list-displays

    Options:
      --host <host>          Host label for diagnostics. Listener binds all interfaces.
      --port <port>          TCP port. Defaults to 9000.
      --screen-port <port>   Screen video port; must equal --port + 1. Normally derived automatically.
      --screen-fps <fps>     Screen frame rate from 1 through 60. Defaults to 60.
      --screen-max-width <n> Maximum encoded screen width. Defaults to 1920.
      --screen-bitrate <bps> H.264 target bitrate. Defaults to 12000000.
      --no-screen            Disable the screen video service.
      --worldwide            Enable one-code WebRTC access using the explicitly configured endpoint.
      --reset-worldwide-pairing
                             Forget the paired iPhone before starting worldwide mode.
      --allow-remote-control Allow pointer and keyboard input for the active worldwide screen session.
                             Disabled by default; requires macOS Accessibility permission.
      --rendezvous-url <url> Enable worldwide access with this wss:// endpoint (ws:// loopback for tests).
      --force-relay          Require TURN for a worldwide acceptance test instead of preferring direct ICE.
      --with-lan             Also start legacy plaintext LAN listeners; trusted networks only.
                             Suppresses microphone forwarding and automatic default-input selection.
      --no-lan               Disable legacy TCP audio/screen listeners and capture.
      --duration <seconds>   Run duration. Defaults to 30 for LAN-only and indefinite for worldwide. Use 0 for indefinite.
      --capture-mode <mode>  blackhole-input or screen. Defaults to blackhole-input.
      --display-id <id>      Capture a specific display ID.
      --bonjour-name <name>  Bonjour name for _mcap._tcp. Defaults to host name.
      --no-bonjour           Disable Bonjour advertisement.
      --token <token>        Require this client token. Defaults to MCAP_TOKEN if set.
      --list-displays        Print displays visible to ScreenCaptureKit.
      --verify-routing       Verify default output/system/input route to BlackHole and exit.
      --verbose              Print verbose logs.
      --help                 Print this help.
    """

    /// Parses command-line options, derives paired ports, and enforces safe mode combinations.
    static func parse(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> CaptureServerOptions {
        var options = CaptureServerOptions()
        let rendezvousURLText = environment["OPENSTEAMER_RENDEZVOUS_URL"]?.nilIfEmpty
        options.rendezvousURL = rendezvousURLText.flatMap(URL.init(string:))
        var index = 1
        var screenPortWasExplicit = false
        var lanModeWasExplicit = false
        var durationWasExplicit = false

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
            case "--screen-port":
                index += 1
                guard index < arguments.count, let value = UInt16(arguments[index]) else {
                    throw CaptureServerOptionError.invalid("--screen-port requires a valid UInt16")
                }
                options.screenPort = value
                screenPortWasExplicit = true
            case "--screen-fps":
                index += 1
                guard index < arguments.count,
                      let value = Int(arguments[index]),
                      (1...60).contains(value) else {
                    throw CaptureServerOptionError.invalid("--screen-fps must be from 1 through 60")
                }
                options.screenFramesPerSecond = value
            case "--screen-max-width":
                index += 1
                guard index < arguments.count,
                      let value = Int(arguments[index]),
                      value >= 320,
                      value <= 7_680 else {
                    throw CaptureServerOptionError.invalid("--screen-max-width must be from 320 through 7680")
                }
                options.screenMaximumWidth = value
            case "--screen-bitrate":
                index += 1
                guard index < arguments.count,
                      let value = UInt32(arguments[index]),
                      value >= 250_000,
                      value <= UInt32(Int32.max) else {
                    throw CaptureServerOptionError.invalid(
                        "--screen-bitrate must be from 250000 through \(Int32.max)"
                    )
                }
                options.screenBitrate = value
            case "--no-screen":
                options.screenEnabled = false
            case "--worldwide":
                options.worldwideEnabled = true
            case "--reset-worldwide-pairing":
                options.resetWorldwidePairing = true
            case "--allow-remote-control":
                options.allowRemoteControl = true
            case "--rendezvous-url":
                index += 1
                guard index < arguments.count,
                      let value = URL(string: arguments[index]) else {
                    throw CaptureServerOptionError.invalid("--rendezvous-url requires a valid URL")
                }
                options.rendezvousURL = value
                options.worldwideEnabled = true
            case "--force-relay":
                options.forceRelay = true
            case "--with-lan":
                options.lanEnabled = true
                lanModeWasExplicit = true
            case "--no-lan":
                options.lanEnabled = false
                lanModeWasExplicit = true
            case "--duration":
                index += 1
                guard index < arguments.count, let value = TimeInterval(arguments[index]), value >= 0 else {
                    throw CaptureServerOptionError.invalid("--duration requires a non-negative number")
                }
                options.duration = value == 0 ? nil : value
                durationWasExplicit = true
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
            case "--verify-routing":
                options.verifyRouting = true
            case "--verbose":
                options.verbose = true
            case "--help", "-h":
                options.showHelp = true
            default:
                throw CaptureServerOptionError.invalid("unknown argument: \(arg)")
            }
            index += 1
        }

        // Worldwide mode must not silently expose the legacy plaintext listeners on an
        // untrusted Wi-Fi network. LAN coexistence therefore requires explicit opt-in.
        if options.worldwideEnabled, !lanModeWasExplicit {
            options.lanEnabled = false
        }
        if options.worldwideEnabled, !durationWasExplicit {
            options.duration = nil
        }

        if options.lanEnabled, options.screenEnabled {
            guard options.port < UInt16.max else {
                throw CaptureServerOptionError.invalid(
                    "--port must be below 65535 when screen video is enabled"
                )
            }
            let derivedScreenPort = options.port + 1
            if screenPortWasExplicit, options.screenPort != derivedScreenPort {
                throw CaptureServerOptionError.invalid(
                    "--screen-port must equal --port + 1 (\(derivedScreenPort))"
                )
            }
            options.screenPort = derivedScreenPort
        }

        if options.worldwideEnabled {
            guard options.screenEnabled else {
                throw CaptureServerOptionError.invalid(
                    "--worldwide cannot be combined with --no-screen"
                )
            }
            guard options.rendezvousURL != nil else {
                throw CaptureServerOptionError.invalid(
                    "--worldwide requires --rendezvous-url or OPENSTEAMER_RENDEZVOUS_URL"
                )
            }
        } else if options.resetWorldwidePairing {
            throw CaptureServerOptionError.invalid(
                "--reset-worldwide-pairing requires --worldwide"
            )
        } else if options.forceRelay {
            throw CaptureServerOptionError.invalid("--force-relay requires --worldwide")
        } else if options.allowRemoteControl {
            throw CaptureServerOptionError.invalid("--allow-remote-control requires --worldwide")
        }

        if !options.lanEnabled, !options.worldwideEnabled {
            throw CaptureServerOptionError.invalid("--no-lan requires --worldwide")
        }

        return options
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

/// User-correctable configuration failures detected before host startup.
enum CaptureServerOptionError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            message
        }
    }
}
