import AppKit
import AVFoundation
import Foundation
import MicDbMenuCore

// Preserve the existing menu extra and status-level overlay. Only capture
// ownership changes; this utility does not select or repair system audio routes.
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let accumulator = LevelAccumulator()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var deviceItem: NSMenuItem!
    private var levelItem: NSMenuItem!
    private var stateItem: NSMenuItem!
    private var overlayWindow: NSPanel!
    private var overlayLabel: NSTextField!
    private var monitor: InputMonitor!
    private var restart: DispatchWorkItem?
    private var lastObserved: InputIdentity?
    private var lastReadFailed = true
    private var requestingPermission = false
    private var retryPolicy = CaptureRetryPolicy()
    private var emptyTicks = 0
    private var freshTicks = 0
    private lazy var controller = CaptureController(observe: { [weak self] in
        guard self?.monitor.healthy == true else { throw AudioFailure.unavailable("Input monitoring unavailable") }
        return try CoreAudioInput.defaultIdentity()
    }, makeCapture: { [weak self] target, generation in
        guard let self, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioFailure.unavailable("Microphone permission denied")
        }
        try self.monitor.watch(target.id)
        return try PinnedHALCapture(target: target, accumulator: self.accumulator, generation: generation)
    }, clearLevels: { [weak self] in self?.clearLevels() })

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenuBarItem()
        buildOverlayReadout()
        monitor = InputMonitor { [weak self] in self?.inputChanged() }
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateDisplay),
                                    userInfo: nil, repeats: true)
        inputChanged()
    }

    func applicationWillTerminate(_ notification: Notification) {
        restart?.cancel(); timer?.invalidate(); controller.invalidate(); monitor = nil
    }

    private func inputChanged(resetRetry: Bool = true) {
        if resetRetry { retryPolicy.reset() }
        emptyTicks = 0; freshTicks = 0
        restart?.cancel()
        let ticket = controller.invalidate()
        try? monitor.watch(nil)
        stateItem.title = "Checking input"
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                self.lastObserved = try CoreAudioInput.defaultIdentity()
                self.lastReadFailed = false
            } catch { self.lastObserved = nil; self.lastReadFailed = true }
            if let input = self.lastObserved, input.permitsCapture,
               AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined,
               !self.requestingPermission {
                self.requestingPermission = true
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.requestingPermission = false
                        self?.inputChanged()
                    }
                }
            }
            self.controller.reconcile(ticket)
            self.showState()
        }
        restart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func clearLevels() {
        accumulator.reset()
        setReadout("-- dB")
        levelItem?.title = "RMS: -- dBFS | Peak: -- dBFS"
    }

    private func showState() {
        switch controller.state {
        case .waiting: stateItem.title = "Checking input"
        case .running(let input):
            deviceItem.title = "Input: \(input.name)"
            stateItem.title = "Running at \(Int(input.sampleRate)) Hz, \(input.channels) ch"
        case .inactive(let input):
            deviceItem.title = "Input: \(input?.name ?? "unavailable")"
            let virtual = input?.transport == .virtual || input?.transport == .aggregate
            setReadout(virtual ? "Virtual" : "No Mic")
            stateItem.title = virtual ? "Virtual input — level unavailable; capture released" : "No verified physical microphone"
        case .failed(let reason):
            deviceItem.title = "Input: unverified"
            setReadout("-- dB")
            stateItem.title = reason
        }
    }

    @objc private func updateDisplay() {
        positionOverlayReadout()
        overlayWindow.orderFrontRegardless()
        do {
            let observed = try CoreAudioInput.defaultIdentity()
            let changed = lastReadFailed || observed != lastObserved || controller.needsReconcile(observed: observed)
            lastObserved = observed; lastReadFailed = false
            if changed { inputChanged(); return }
        } catch {
            if !lastReadFailed { inputChanged() }
            lastObserved = nil; lastReadFailed = true
            controller.invalidate()
            stateItem.title = "Input unavailable; capture released"
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if case .failed = controller.state {
            if retryPolicy.shouldRetry(now: now) { inputChanged(resetRetry: false) }
            return
        }
        guard case .running = controller.state else { return }
        guard let snapshot = accumulator.snapshotAndReset(now: now) else {
            emptyTicks += 1; freshTicks = 0
            setReadout("-- dB")
            levelItem.title = "RMS: -- dBFS | Peak: -- dBFS"
            stateItem.title = "Waiting for fresh samples"
            if emptyTicks >= 3, retryPolicy.shouldRetry(now: now) { inputChanged(resetRetry: false) }
            return
        }
        emptyTicks = 0; freshTicks += 1
        if freshTicks >= 5 { retryPolicy.reset() }
        setReadout(String(format: "%.0f dB", snapshot.rmsDBFS))
        levelItem.title = String(format: "RMS: %.1f dBFS | Peak: %.1f dBFS", snapshot.rmsDBFS, snapshot.peakDBFS)
        stateItem.title = "Updated each second | \(snapshot.frames) frames | age \(Int(snapshot.age * 1000)) ms"
    }

    private func buildMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 82)
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.title = "-- dB"
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Mic")
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            button.toolTip = "Physical microphone dBFS"
        }
        let menu = NSMenu()
        deviceItem = NSMenuItem(title: "Input: detecting", action: nil, keyEquivalent: "")
        levelItem = NSMenuItem(title: "RMS: -- dBFS | Peak: -- dBFS", action: nil, keyEquivalent: "")
        stateItem = NSMenuItem(title: "Starting", action: nil, keyEquivalent: "")
        for item in [deviceItem!, levelItem!, stateItem!] { item.isEnabled = false; menu.addItem(item) }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Restart Audio", action: #selector(restartAudio), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Open Microphone Privacy", action: #selector(openMicrophonePrivacy), keyEquivalent: ""))
        statusItem.menu = menu
    }

    private func buildOverlayReadout() {
        overlayWindow = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 96, height: 24),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlayWindow.level = .statusBar
        overlayWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        overlayWindow.backgroundColor = .clear
        overlayWindow.isOpaque = false; overlayWindow.hasShadow = false; overlayWindow.ignoresMouseEvents = true
        overlayLabel = NSTextField(labelWithString: "-- dB")
        overlayLabel.frame = NSRect(x: 0, y: 0, width: 96, height: 24)
        overlayLabel.alignment = .center
        overlayLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        overlayLabel.textColor = .white
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 2; shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        overlayLabel.shadow = shadow
        overlayWindow.contentView = overlayLabel
        positionOverlayReadout()
        overlayWindow.orderFrontRegardless()
    }

    private func positionOverlayReadout() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        overlayWindow.setFrame(NSRect(x: screen.frame.maxX - 168, y: screen.frame.maxY - 24,
                                     width: 96, height: 24), display: true)
    }

    @objc private func restartAudio() { inputChanged() }
    @objc private func screenParametersChanged() { positionOverlayReadout() }
    @objc private func openMicrophonePrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
    private func setReadout(_ title: String) {
        statusItem.button?.title = title
        overlayLabel?.stringValue = title
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
