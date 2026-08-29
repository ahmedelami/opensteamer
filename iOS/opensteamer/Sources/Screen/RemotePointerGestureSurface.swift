import SwiftUI
import UIKit

/// Exact native-gesture ownership. Replacing any member cancels a gesture before new callbacks
/// are installed, so a touch cannot cross a session, presentation, track, or geometry boundary.
struct RemotePointerGestureConfiguration: Equatable {
    let presentationID: UUID
    let inputSessionID: UUID
    let trackIdentity: ObjectIdentifier
    let containerSize: CGSize
    let videoSize: CGSize
    let allowsPrimaryDrag: Bool
    let allowsScroll: Bool
}

enum RemotePointerGesturePhase: Equatable {
    case idle
    case tracking
    case scrolling
    case primaryDrag
    case suppressed
    case finished
    case cancelled
}

enum RemotePointerGestureEvent: Equatable {
    case tap(CGPoint)
    case scrollBegan(CGPoint)
    case scrollChanged(CGSize)
    case scrollEnded
    case scrollCancelled
    case primaryDragArmed(CGPoint)
    case primaryDrag(start: CGPoint, end: CGPoint)
}

/// The sole tap / scroll / drag classifier used by both production recognition and tests.
struct RemotePointerGestureStateMachine: Equatable {
    static let holdDuration: TimeInterval = 0.35
    static let movementThreshold: CGFloat = 12

    let allowsScroll: Bool
    let allowsPrimaryDrag: Bool

    private(set) var phase: RemotePointerGesturePhase = .idle
    private(set) var initialLocation: CGPoint?
    private(set) var currentLocation: CGPoint?
    private(set) var initialTimestamp: TimeInterval?
    private var previousScrollLocation: CGPoint?

    init(allowsScroll: Bool, allowsPrimaryDrag: Bool) {
        self.allowsScroll = allowsScroll
        self.allowsPrimaryDrag = allowsPrimaryDrag
    }

    var shouldScheduleHoldDeadline: Bool {
        phase == .tracking && allowsPrimaryDrag
    }

    mutating func begin(
        at location: CGPoint,
        timestamp: TimeInterval
    ) -> [RemotePointerGestureEvent] {
        guard phase == .idle,
              location.x.isFinite,
              location.y.isFinite,
              timestamp.isFinite else {
            phase = .suppressed
            return []
        }
        initialLocation = location
        currentLocation = location
        initialTimestamp = timestamp
        phase = .tracking
        return []
    }

    mutating func move(
        to location: CGPoint,
        timestamp: TimeInterval
    ) -> [RemotePointerGestureEvent] {
        guard location.x.isFinite,
              location.y.isFinite,
              timestamp.isFinite else {
            return suppressIfTracking()
        }

        switch phase {
        case .tracking:
            currentLocation = location
            if movementExceededThreshold(at: location) {
                guard allowsScroll else {
                    phase = .suppressed
                    return []
                }
                return beginScroll(at: location)
            }
            return advanceHoldDeadlineIfNeeded(timestamp: timestamp)

        case .scrolling:
            currentLocation = location
            guard let previousScrollLocation else { return [] }
            self.previousScrollLocation = location
            let delta = CGSize(
                width: location.x - previousScrollLocation.x,
                height: location.y - previousScrollLocation.y
            )
            return delta == .zero ? [] : [.scrollChanged(delta)]

        case .primaryDrag:
            currentLocation = location
            return []

        case .idle, .suppressed, .finished, .cancelled:
            return []
        }
    }

    mutating func holdDeadlineReached() -> [RemotePointerGestureEvent] {
        guard phase == .tracking,
              allowsPrimaryDrag,
              let initialLocation,
              let currentLocation,
              distance(from: initialLocation, to: currentLocation)
                < Self.movementThreshold else {
            return []
        }
        phase = .primaryDrag
        return [.primaryDragArmed(initialLocation)]
    }

    mutating func end(
        at location: CGPoint,
        timestamp: TimeInterval
    ) -> [RemotePointerGestureEvent] {
        var events = move(to: location, timestamp: timestamp)
        switch phase {
        case .tracking:
            currentLocation = location
            phase = .finished
            events.append(.tap(location))

        case .scrolling:
            phase = .finished
            events.append(.scrollEnded)

        case .primaryDrag:
            currentLocation = location
            phase = .finished
            if let initialLocation {
                events.append(.primaryDrag(start: initialLocation, end: location))
            }

        case .suppressed:
            phase = .finished

        case .idle, .finished, .cancelled:
            break
        }
        return events
    }

    mutating func cancel() -> [RemotePointerGestureEvent] {
        let events: [RemotePointerGestureEvent]
        if phase == .scrolling {
            events = [.scrollCancelled]
        } else {
            events = []
        }
        if phase != .finished {
            phase = .cancelled
        }
        return events
    }

    private mutating func advanceHoldDeadlineIfNeeded(
        timestamp: TimeInterval
    ) -> [RemotePointerGestureEvent] {
        guard allowsPrimaryDrag,
              let initialTimestamp,
              max(0, timestamp - initialTimestamp) >= Self.holdDuration else {
            return []
        }
        return holdDeadlineReached()
    }

    private mutating func beginScroll(
        at location: CGPoint
    ) -> [RemotePointerGestureEvent] {
        guard let initialLocation else { return [] }
        phase = .scrolling
        previousScrollLocation = location
        let delta = CGSize(
            width: location.x - initialLocation.x,
            height: location.y - initialLocation.y
        )
        var events: [RemotePointerGestureEvent] = [.scrollBegan(initialLocation)]
        if delta != .zero {
            events.append(.scrollChanged(delta))
        }
        return events
    }

    private mutating func suppressIfTracking() -> [RemotePointerGestureEvent] {
        if phase == .tracking {
            phase = .suppressed
        }
        return []
    }

    private func movementExceededThreshold(at location: CGPoint) -> Bool {
        guard let initialLocation else { return false }
        return distance(from: initialLocation, to: location) >= Self.movementThreshold
    }

    private func distance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }
}

struct RemotePointerGestureRecognizerDebugSnapshot: Equatable {
    let recognizerCount: Int
    let movementThreshold: CGFloat
    let holdDuration: TimeInterval
    let allowsScroll: Bool
    let allowsPrimaryDrag: Bool
}

/// A narrow UIKit bridge because SwiftUI cannot provide one deterministic raw-touch classifier.
struct RemotePointerGestureSurface: UIViewRepresentable {
    let configuration: RemotePointerGestureConfiguration
    let onTap: @MainActor (CGPoint) -> Void
    let onScrollBegan: @MainActor (CGPoint) -> UUID?
    let onScrollChanged: @MainActor (UUID, CGSize) -> Void
    let onScrollEnded: @MainActor (UUID) -> Void
    let onScrollCancelled: @MainActor (UUID) -> Void
    let onPrimaryDrag: @MainActor (CGPoint, CGPoint) -> Void
    let onConfigurationInvalidated: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(surface: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isMultipleTouchEnabled = false
        view.isAccessibilityElement = false
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(from: self)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.invalidateConfiguration()
    }

    @MainActor
    final class Coordinator: NSObject {
        private var configuration: RemotePointerGestureConfiguration
        private var onTap: @MainActor (CGPoint) -> Void
        private var onScrollBegan: @MainActor (CGPoint) -> UUID?
        private var onScrollChanged: @MainActor (UUID, CGSize) -> Void
        private var onScrollEnded: @MainActor (UUID) -> Void
        private var onScrollCancelled: @MainActor (UUID) -> Void
        private var onPrimaryDrag: @MainActor (CGPoint, CGPoint) -> Void
        private var onConfigurationInvalidated: @MainActor () -> Void
        private weak var installedView: UIView?
        private var activeScrollID: UUID?

        private lazy var gestureRecognizer = UnifiedRemotePointerGestureRecognizer(
            allowsScroll: configuration.allowsScroll,
            allowsPrimaryDrag: configuration.allowsPrimaryDrag
        ) { [weak self] events in
            self?.handle(events)
        }

        init(surface: RemotePointerGestureSurface) {
            configuration = surface.configuration
            onTap = surface.onTap
            onScrollBegan = surface.onScrollBegan
            onScrollChanged = surface.onScrollChanged
            onScrollEnded = surface.onScrollEnded
            onScrollCancelled = surface.onScrollCancelled
            onPrimaryDrag = surface.onPrimaryDrag
            onConfigurationInvalidated = surface.onConfigurationInvalidated
        }

        func install(on view: UIView) {
            installedView = view
            view.addGestureRecognizer(gestureRecognizer)
        }

        var debugRecognizerConfiguration: RemotePointerGestureRecognizerDebugSnapshot {
            RemotePointerGestureRecognizerDebugSnapshot(
                recognizerCount: installedView?.gestureRecognizers?.count ?? 0,
                movementThreshold: RemotePointerGestureStateMachine.movementThreshold,
                holdDuration: RemotePointerGestureStateMachine.holdDuration,
                allowsScroll: gestureRecognizer.allowsScroll,
                allowsPrimaryDrag: gestureRecognizer.allowsPrimaryDrag
            )
        }

        func update(from surface: RemotePointerGestureSurface) {
            if configuration != surface.configuration {
                invalidateConfiguration()
                configuration = surface.configuration
                gestureRecognizer.replaceCapabilities(
                    allowsScroll: surface.configuration.allowsScroll,
                    allowsPrimaryDrag: surface.configuration.allowsPrimaryDrag
                )
            } else {
                configuration = surface.configuration
            }
            onTap = surface.onTap
            onScrollBegan = surface.onScrollBegan
            onScrollChanged = surface.onScrollChanged
            onScrollEnded = surface.onScrollEnded
            onScrollCancelled = surface.onScrollCancelled
            onPrimaryDrag = surface.onPrimaryDrag
            onConfigurationInvalidated = surface.onConfigurationInvalidated
        }

        func invalidateConfiguration() {
            gestureRecognizer.cancelForConfigurationChange()
            cancelActiveScrollIfNeeded()
            onConfigurationInvalidated()
        }

        private func handle(_ events: [RemotePointerGestureEvent]) {
            for event in events {
                switch event {
                case .tap(let location):
                    onTap(location)

                case .scrollBegan(let anchor):
                    activeScrollID = onScrollBegan(anchor)

                case .scrollChanged(let delta):
                    if let activeScrollID {
                        onScrollChanged(activeScrollID, delta)
                    }

                case .scrollEnded:
                    if let activeScrollID {
                        self.activeScrollID = nil
                        onScrollEnded(activeScrollID)
                    }

                case .scrollCancelled:
                    cancelActiveScrollIfNeeded()

                case .primaryDragArmed:
                    break

                case .primaryDrag(let start, let end):
                    onPrimaryDrag(start, end)
                }
            }
        }

        private func cancelActiveScrollIfNeeded() {
            guard let activeScrollID else { return }
            self.activeScrollID = nil
            onScrollCancelled(activeScrollID)
        }
    }
}

/// One continuous recognizer owns raw touch delivery and the hold deadline. It forwards the
/// state machine's semantic events directly, so an end-only threshold crossing cannot lose the
/// began/changed portion through UIKit state-transition coalescing.
@MainActor
private final class UnifiedRemotePointerGestureRecognizer: UIGestureRecognizer {
    private(set) var allowsScroll: Bool
    private(set) var allowsPrimaryDrag: Bool

    private var machine: RemotePointerGestureStateMachine
    private var trackedTouch: UITouch?
    private var holdTimer: Timer?
    private let eventHandler: @MainActor ([RemotePointerGestureEvent]) -> Void

    init(
        allowsScroll: Bool,
        allowsPrimaryDrag: Bool,
        eventHandler: @escaping @MainActor ([RemotePointerGestureEvent]) -> Void
    ) {
        self.allowsScroll = allowsScroll
        self.allowsPrimaryDrag = allowsPrimaryDrag
        machine = RemotePointerGestureStateMachine(
            allowsScroll: allowsScroll,
            allowsPrimaryDrag: allowsPrimaryDrag
        )
        self.eventHandler = eventHandler
        super.init(target: nil, action: nil)
        cancelsTouchesInView = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, touches.count == 1, let touch = touches.first else {
            failWithoutAction()
            return
        }
        trackedTouch = touch
        deliver(
            machine.begin(
                at: touch.location(in: view),
                timestamp: touch.timestamp
            )
        )
        scheduleHoldTimerIfNeeded()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch(in: touches) else { return }
        let events = machine.move(
            to: touch.location(in: view),
            timestamp: touch.timestamp
        )
        updateTimerForCurrentPhase()
        deliver(events)
        updateContinuousRecognizerState()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch(in: touches) else {
            failWithoutAction()
            return
        }
        let events = machine.end(
            at: touch.location(in: view),
            timestamp: touch.timestamp
        )
        invalidateHoldTimer()
        trackedTouch = nil
        deliver(events)

        if state == .began || state == .changed {
            state = .ended
        } else if state == .possible {
            state = events.isEmpty ? .failed : .ended
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        cancelCurrentTouch()
    }

    override func reset() {
        super.reset()
        invalidateHoldTimer()
        trackedTouch = nil
        machine = RemotePointerGestureStateMachine(
            allowsScroll: allowsScroll,
            allowsPrimaryDrag: allowsPrimaryDrag
        )
    }

    func cancelForConfigurationChange() {
        cancelCurrentTouch()
    }

    func replaceCapabilities(
        allowsScroll: Bool,
        allowsPrimaryDrag: Bool
    ) {
        isEnabled = false
        self.allowsScroll = allowsScroll
        self.allowsPrimaryDrag = allowsPrimaryDrag
        machine = RemotePointerGestureStateMachine(
            allowsScroll: allowsScroll,
            allowsPrimaryDrag: allowsPrimaryDrag
        )
        isEnabled = true
    }

    @objc
    private func holdDeadlineFired(_ timer: Timer) {
        guard timer === holdTimer else { return }
        holdTimer = nil
        let events = machine.holdDeadlineReached()
        deliver(events)
        updateContinuousRecognizerState()
    }

    private func scheduleHoldTimerIfNeeded() {
        guard machine.shouldScheduleHoldDeadline else { return }
        let timer = Timer(
            timeInterval: RemotePointerGestureStateMachine.holdDuration,
            target: self,
            selector: #selector(holdDeadlineFired(_:)),
            userInfo: nil,
            repeats: false
        )
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateTimerForCurrentPhase() {
        if !machine.shouldScheduleHoldDeadline {
            invalidateHoldTimer()
        }
    }

    private func updateContinuousRecognizerState() {
        switch machine.phase {
        case .scrolling, .primaryDrag:
            if state == .possible {
                state = .began
            } else if state == .began || state == .changed {
                state = .changed
            }

        case .suppressed:
            if state == .possible {
                state = .failed
            }

        case .idle, .tracking, .finished, .cancelled:
            break
        }
    }

    private func cancelCurrentTouch() {
        invalidateHoldTimer()
        trackedTouch = nil
        deliver(machine.cancel())
        if state == .began || state == .changed {
            state = .cancelled
        } else if state == .possible {
            state = .failed
        }
    }

    private func failWithoutAction() {
        invalidateHoldTimer()
        trackedTouch = nil
        deliver(machine.cancel())
        if state == .began || state == .changed {
            state = .cancelled
        } else if state == .possible {
            state = .failed
        }
    }

    private func trackedTouch(in touches: Set<UITouch>) -> UITouch? {
        guard let trackedTouch else { return nil }
        return touches.first(where: { $0 === trackedTouch })
    }

    private func invalidateHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func deliver(_ events: [RemotePointerGestureEvent]) {
        guard !events.isEmpty else { return }
        eventHandler(events)
    }
}
