import AppKit
import Foundation

/// A nonsecret, driver-only visual challenge. The physical release driver launches this tiny
/// accessory process so a static desktop cannot make a correct decoded-pixel freshness oracle
/// fail. It never accepts input and is terminated by the driver cleanup trap.
@MainActor
private final class ChallengeView: NSView {
    var counter: UInt64 = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let hue = CGFloat((counter &* 47) % 360) / 360
        NSColor(calibratedHue: hue, saturation: 0.92, brightness: 0.92, alpha: 1).setFill()
        bounds.fill()

        let cellWidth = bounds.width / 8
        let cellHeight = bounds.height / 6
        for row in 0..<6 {
            for column in 0..<8 where (UInt64(row * 8 + column) + counter).isMultiple(of: 3) {
                NSColor(
                    calibratedWhite: (row + column).isMultiple(of: 2) ? 0.05 : 0.95,
                    alpha: 1
                ).setFill()
                NSRect(
                    x: CGFloat(column) * cellWidth,
                    y: CGFloat(row) * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                ).fill()
            }
        }

        let text = "AudioStreamer pixel freshness \(counter)" as NSString
        text.draw(
            at: NSPoint(x: 18, y: 18),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .bold),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.75),
            ]
        )
    }
}

@main
@MainActor
private struct PhysicalScreenOracleChallenge {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(
                Data("usage: physical-screen-oracle-challenge heartbeat-path\n".utf8)
            )
            exit(64)
        }
        let heartbeatURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        var windows: [NSWindow] = []
        var views: [ChallengeView] = []
        for screen in NSScreen.screens {
            let size = NSSize(width: 480, height: 360)
            let frame = NSRect(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            let window = NSWindow(
                contentRect: frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            let view = ChallengeView(frame: NSRect(origin: .zero, size: size))
            window.contentView = view
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.ignoresMouseEvents = true
            window.isOpaque = true
            window.hasShadow = false
            window.orderFrontRegardless()
            windows.append(window)
            views.append(view)
        }
        guard !windows.isEmpty else { exit(65) }

        var counter: UInt64 = 0
        func publishChallenge() {
            counter &+= 1
            for view in views {
                view.counter = counter
            }
            do {
                try Data("counter=\(counter)\n".utf8).write(to: heartbeatURL, options: .atomic)
            } catch {
                FileHandle.standardError.write(
                    Data("heartbeat write failed: \(error)\n".utf8)
                )
                application.terminate(nil)
            }
        }
        publishChallenge()
        Timer.scheduledTimer(withTimeInterval: 0.17, repeats: true) { _ in
            MainActor.assumeIsolated { publishChallenge() }
        }
        application.run()
        _ = windows
    }
}
