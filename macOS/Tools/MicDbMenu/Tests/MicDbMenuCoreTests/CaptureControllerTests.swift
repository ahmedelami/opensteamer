import Foundation
import Testing
@testable import MicDbMenuCore

private let physical = InputIdentity(id: 10, uid: "usb-mic", name: "USB Mic", transport: .physical)
private let virtual = InputIdentity(id: 20, uid: "com.elamin.opensteamer.virtual-microphone.input",
                                    name: "opensteamer Virtual Microphone", transport: .virtual)

private final class FakeCapture: MeterCapture {
    var identity: InputIdentity
    var starts = 0
    var stops = 0
    var startAction: (() -> Void)?
    var readFails = false
    var stopSucceeds = true
    init(_ identity: InputIdentity) { self.identity = identity }
    func currentIdentity() throws -> InputIdentity {
        if readFails { throw CaptureController.CaptureError.changed }
        return identity
    }
    func start() throws { starts += 1; startAction?() }
    @discardableResult func stop() -> Bool { stops += 1; return stopSucceeds }
}

private final class Harness {
    var observed: InputIdentity? = physical
    var observationFails = false
    var captures: [FakeCapture] = []
    var resets = 0
    var factoryAction: ((FakeCapture) -> Void)?
    lazy var controller = CaptureController(observe: { [unowned self] in
        if observationFails { throw CaptureController.CaptureError.changed }
        return observed
    }, makeCapture: { [unowned self] target, _ in
        let capture = FakeCapture(target)
        captures.append(capture)
        factoryAction?(capture)
        return capture
    }, clearLevels: { [unowned self] in resets += 1 })
    func reconcile() { controller.reconcile(controller.invalidate()) }
}

@Test func physicalToVirtualToPhysicalReleasesThenResumes() {
    let harness = Harness()
    harness.reconcile()
    #expect(harness.captures.count == 1)
    #expect(harness.captures[0].starts == 1)
    harness.observed = virtual
    #expect(harness.controller.needsReconcile(observed: virtual))
    harness.reconcile()
    #expect(harness.captures[0].stops == 1)
    #expect(harness.captures.count == 1)
    #expect(harness.controller.state == .inactive(virtual))
    harness.observed = physical
    harness.reconcile()
    #expect(harness.captures.count == 2)
    #expect(harness.captures[1].starts == 1)
    #expect(harness.controller.state == .running(physical))
    #expect(harness.resets == 3)
}

@Test func supersededAndDuplicateRestartTicketsCannotStartCapture() {
    let harness = Harness()
    let stale = harness.controller.invalidate()
    let current = harness.controller.invalidate()
    harness.controller.reconcile(stale)
    #expect(harness.captures.isEmpty)
    harness.controller.reconcile(current)
    harness.controller.reconcile(current)
    #expect(harness.captures.count == 1)
    #expect(harness.captures[0].starts == 1)
}

@Test func rejectedInputsNeverCreateAnAudioCapture() {
    let harness = Harness()
    let rejected: [InputIdentity?] = [nil, virtual,
        InputIdentity(id: 1, uid: "aggregate", name: "Aggregate", transport: .aggregate),
        InputIdentity(id: 1, uid: "unknown", name: "Unknown", transport: .unsupported),
        InputIdentity(id: 0, uid: "invalid", name: "Invalid", transport: .physical),
        InputIdentity(id: 1, uid: "", name: "No UID", transport: .physical),
        InputIdentity(id: 1, uid: "dead", name: "Dead", transport: .physical, alive: false),
        InputIdentity(id: 1, uid: "output", name: "Output", transport: .physical, channels: 0),
        InputIdentity(id: 1, uid: virtual.uid, name: "Wrong transport", transport: .physical),
        InputIdentity(id: 1, uid: "nan", name: "Bad clock", transport: .physical, sampleRate: .nan)]
    for input in rejected { harness.observed = input; harness.reconcile() }
    #expect(harness.captures.isEmpty)
}

@Test func readFailureClosesCaptureAndManualRestartCanRecover() {
    let harness = Harness()
    harness.reconcile()
    harness.observationFails = true
    harness.reconcile()
    #expect(harness.captures[0].stops == 1)
    #expect(harness.captures.count == 1)
    harness.observationFails = false
    harness.reconcile()
    #expect(harness.controller.state == .running(physical))
    #expect(harness.captures.count == 2)
}

@Test func defaultChangesDuringConstructionPreventStart() {
    let harness = Harness()
    harness.factoryAction = { _ in harness.observed = virtual }
    harness.reconcile()
    #expect(harness.captures[0].starts == 0)
    #expect(harness.captures[0].stops == 1)
}

@Test func capturedUIDMismatchAndReadFailurePreventStart() {
    for failRead in [false, true] {
        let harness = Harness()
        harness.factoryAction = { capture in
            capture.identity = InputIdentity(id: physical.id, uid: "reused-device-id",
                                              name: physical.name, transport: .physical)
            capture.readFails = failRead
        }
        harness.reconcile()
        #expect(harness.captures[0].starts == 0)
        #expect(harness.captures[0].stops == 1)
    }
}

@Test func postStartDefaultOrCapturedUIDChangeStopsTheCandidate() {
    for changeDefault in [false, true] {
        let harness = Harness()
        harness.factoryAction = { capture in
            capture.startAction = {
                if changeDefault { harness.observed = virtual } else { capture.identity = virtual }
            }
        }
        harness.reconcile()
        #expect(harness.captures[0].starts == 1)
        #expect(harness.captures[0].stops == 1)
        #expect(harness.controller.state != .running(physical))
    }
}

@Test func synchronousInvalidationInsideStartCannotInstallStaleCapture() {
    let harness = Harness()
    harness.factoryAction = { capture in capture.startAction = { harness.controller.invalidate() } }
    harness.reconcile()
    #expect(harness.captures[0].stops == 1)
    #expect(harness.controller.state == .waiting)
}

@Test func activeCaptureIdentityIsRecheckedEvenWhenDefaultIsUnchanged() {
    let harness = Harness()
    harness.reconcile()
    #expect(!harness.controller.needsReconcile(observed: physical))
    harness.captures[0].identity = virtual
    #expect(harness.controller.needsReconcile(observed: physical))
}

@Test func virtualObservationIsReadOnceSoChangedDefaultIsNotHidden() {
    var reads = 0
    let controller = CaptureController(observe: {
        reads += 1
        return reads == 1 ? virtual : physical
    }, makeCapture: { _, _ in Issue.record("Unexpected capture"); return FakeCapture(physical) }, clearLevels: {})
    controller.reconcile(controller.invalidate())
    #expect(reads == 1)
    #expect(controller.needsReconcile(observed: physical))
}

@Test func accumulatorRejectsOldRouteCallbacksAndStaleLevels() {
    let accumulator = LevelAccumulator()
    let old = UUID(), current = UUID()
    let samples: [Float] = [0.5, -0.5]
    accumulator.reset(to: old)
    samples.withUnsafeBufferPointer { accumulator.add($0, frames: 2, generation: old, now: 10) }
    let initial = accumulator.snapshotAndReset(now: 10.1)
    #expect(abs((initial?.rmsDBFS ?? 0) - (-6.0206)) < 0.001)
    accumulator.reset(to: current)
    samples.withUnsafeBufferPointer { accumulator.add($0, frames: 2, generation: old, now: 11) }
    #expect(accumulator.snapshotAndReset(now: 11.1) == nil)
    samples.withUnsafeBufferPointer { accumulator.add($0, frames: 2, generation: current, now: 12) }
    #expect(accumulator.snapshotAndReset(now: 15) == nil)
    accumulator.reset()
    samples.withUnsafeBufferPointer { accumulator.add($0, frames: 2, generation: current, now: 16) }
    #expect(accumulator.snapshotAndReset(now: 16.1) == nil)
}

@Test func retryBudgetIsBoundedUntilRouteOrManualReset() {
    var retry = CaptureRetryPolicy()
    let steps: [(TimeInterval, Bool)] = [(0, false), (0.9, false), (1, true),
        (2, false), (4.9, false), (5, true), (6, false), (16, true), (100, false), (1_000, false)]
    for (time, expected) in steps {
        let actual = retry.shouldRetry(now: time)
        #expect(actual == expected)
    }
    retry.reset()
    let before = retry.shouldRetry(now: 2_000)
    let after = retry.shouldRetry(now: 2_001)
    #expect(!before)
    #expect(after)
}

@Test func failedCaptureTeardownPreventsFurtherStartsAndFalseVirtualRelease() {
    let harness = Harness()
    harness.reconcile()
    harness.captures[0].stopSucceeds = false
    harness.observed = virtual
    harness.reconcile()
    #expect(harness.controller.state != .inactive(virtual))
    harness.observed = physical
    harness.reconcile()
    #expect(harness.captures.count == 1)
    if case .failed = harness.controller.state {} else { Issue.record("Teardown failure was cleared") }
}

@Test func staleCandidateTeardownFailureAlsoPoisonsNewerTicket() {
    let harness = Harness()
    var replacement: UUID?
    harness.factoryAction = { capture in
        capture.stopSucceeds = false
        capture.startAction = { replacement = harness.controller.invalidate() }
    }
    harness.reconcile()
    if let replacement { harness.controller.reconcile(replacement) }
    #expect(harness.captures.count == 1)
    if case .failed = harness.controller.state {} else { Issue.record("Newer ticket ignored failed teardown") }
}
