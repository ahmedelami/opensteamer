import AudioToolbox
import CoreMedia
import Foundation
import ScreenCaptureKit
import Streaming
import XCTest
@testable import CaptureCore

/// Locks down ScreenCaptureKit configuration, callback ownership, and audio processing behavior.
final class SystemAudioCaptureSourceTests: XCTestCase {
    func testProductionConfigurationRequestsFortyEightKilohertzStereoAudioOnly() {
        let configuration = SystemAudioCaptureConfiguration.make()

        XCTAssertTrue(configuration.capturesAudio)
        XCTAssertTrue(configuration.excludesCurrentProcessAudio)
        XCTAssertEqual(configuration.sampleRate, 48_000)
        XCTAssertEqual(configuration.channelCount, 2)
        // ScreenCaptureKit still requires nonzero video dimensions even though this source
        // consumes only its audio output, so production uses the smallest practical surface.
        XCTAssertEqual(configuration.width, 2)
        XCTAssertEqual(configuration.height, 2)
    }

    func testPublishedFormatCannotDriftFromCaptureConfiguration() {
        let format = SystemAudioCaptureFormat(displayID: 73)
        let configuration = SystemAudioCaptureConfiguration.make()

        XCTAssertEqual(format.displayID, 73)
        XCTAssertEqual(format.sampleRate, configuration.sampleRate)
        XCTAssertEqual(format.channelCount, configuration.channelCount)
    }

    func testCaptureErrorsDistinguishConcurrentStartFromCancellation() {
        XCTAssertNotEqual(
            SystemAudioCaptureError.alreadyRunning.localizedDescription,
            SystemAudioCaptureError.startCancelled.localizedDescription
        )
        XCTAssertTrue(
            SystemAudioCaptureError.displayNotFound(9).localizedDescription.contains("9")
        )
    }

    func testFeedbackExclusionSelectsOnlyExactIPhoneMirroringBundle() {
        let bundleIdentifiers: [String?] = [
            "com.apple.ScreenContinuity",
            "com.spotify.client",
            "COM.APPLE.SCREENCONTINUITY",
            "com.apple.ScreenContinuity.helper",
            nil,
            "com.apple.ScreenContinuity"
        ]

        let excluded = SystemAudioApplicationExclusionPolicy.excludedApplications(
            from: bundleIdentifiers,
            bundleIdentifier: { $0 }
        )

        XCTAssertEqual(excluded, [
            "com.apple.ScreenContinuity",
            "com.apple.ScreenContinuity"
        ])
    }

    func testOnlyIPhoneMirroringLifecycleEventsRefreshTheAudioFilter() {
        XCTAssertTrue(
            SystemAudioApplicationExclusionPolicy.requiresFilterRefresh(
                bundleIdentifier: "com.apple.ScreenContinuity"
            )
        )
        XCTAssertFalse(
            SystemAudioApplicationExclusionPolicy.requiresFilterRefresh(
                bundleIdentifier: "com.apple.ScreenContinuity.helper"
            )
        )
        XCTAssertFalse(
            SystemAudioApplicationExclusionPolicy.requiresFilterRefresh(
                bundleIdentifier: nil
            )
        )
    }

    func testProcessTapExclusionsAlwaysContainFeedbackSourcesWithoutDuplicates() {
        XCTAssertEqual(
            SystemAudioApplicationExclusionPolicy.excludedBundleIdentifiers(
                currentBundleIdentifier: "com.elamin.AudioStreamer.CaptureServer"
            ),
            [
                "com.apple.ScreenContinuity",
                "com.elamin.AudioStreamer.CaptureServer",
            ]
        )

        XCTAssertEqual(
            SystemAudioApplicationExclusionPolicy.excludedBundleIdentifiers(
                currentBundleIdentifier: "org.example.opensteamer.Host"
            ),
            [
                "com.apple.ScreenContinuity",
                "com.elamin.AudioStreamer.CaptureServer",
                "org.example.opensteamer.Host",
            ]
        )
    }

    func testProcessTapStartupRefreshOccursAfterProcessListenerRegistration() {
        var listenerIsInstalled = false
        var refreshCount = 0

        CoreAudioProcessTapStartupExclusionFence
            .installListenerThenRefresh(
                installListener: {
                    listenerIsInstalled = true
                },
                refreshExclusions: {
                    XCTAssertTrue(listenerIsInstalled)
                    refreshCount += 1
                }
            )

        XCTAssertEqual(refreshCount, 1)
    }

    func testProcessTapListenerFailurePolicyFailsClosedBeforeMacOS26() {
        let registrationFailure = OSStatus(-50)

        XCTAssertFalse(
            CoreAudioProcessTapProcessListListenerPolicy.permitsCapture(
                listenerRegistrationStatus: registrationFailure,
                bundleIdentifierRestorationAvailable: false
            )
        )
        XCTAssertTrue(
            CoreAudioProcessTapProcessListListenerPolicy.permitsCapture(
                listenerRegistrationStatus: registrationFailure,
                bundleIdentifierRestorationAvailable: true
            )
        )
        XCTAssertTrue(
            CoreAudioProcessTapProcessListListenerPolicy.permitsCapture(
                listenerRegistrationStatus: noErr,
                bundleIdentifierRestorationAvailable: false
            )
        )
    }

    func testProcessTapFailedPostListenerRefreshRollsBackAndPermitsRetry() throws {
        var resourcesArePublished = false
        var listenerIsInstalled = false
        var shouldFailRefresh = true
        var events: [String] = []

        func attemptStartup() throws {
            try CoreAudioProcessTapStartupTransaction
                .installListenerPublishAndRefresh(
                    installListener: {
                        events.append("install-listener")
                        listenerIsInstalled = true
                    },
                    publishResources: {
                        events.append("publish-resources")
                        resourcesArePublished = true
                    },
                    refreshExclusions: {
                        events.append("refresh-exclusions")
                        if shouldFailRefresh {
                            throw ProcessTapStartupFixtureError.refreshFailed
                        }
                    },
                    rollbackPublishedResources: {
                        events.append("rollback")
                        resourcesArePublished = false
                        listenerIsInstalled = false
                    }
                )
        }

        XCTAssertThrowsError(try attemptStartup())
        XCTAssertEqual(
            events,
            [
                "install-listener",
                "publish-resources",
                "refresh-exclusions",
                "rollback",
            ]
        )
        XCTAssertFalse(resourcesArePublished)
        XCTAssertFalse(listenerIsInstalled)

        shouldFailRefresh = false
        events.removeAll()
        try attemptStartup()
        XCTAssertEqual(
            events,
            [
                "install-listener",
                "publish-resources",
                "refresh-exclusions",
            ]
        )
        XCTAssertTrue(resourcesArePublished)
        XCTAssertTrue(listenerIsInstalled)
    }

    func testProcessTapControlQueueKeepsInventoryAndApplyIndivisible() {
        let queues = CoreAudioProcessTapQueueTopology(
            labelPrefix: "opensteamer.tests.ProcessTapSerialization"
        )
        let events = LockedStringEventRecorder()
        let firstInventoryEntered = DispatchSemaphore(value: 0)
        let releaseFirstInventory = DispatchSemaphore(value: 0)
        let secondRefreshAttempted = DispatchSemaphore(value: 0)
        let secondInventoryEntered = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            queues.syncControl {
                events.append("first-inventory")
                firstInventoryEntered.signal()
                releaseFirstInventory.wait()
                events.append("first-apply")
            }
        }
        XCTAssertEqual(
            firstInventoryEntered.wait(timeout: .now() + .seconds(1)),
            .success
        )

        DispatchQueue.global(qos: .userInitiated).async {
            secondRefreshAttempted.signal()
            queues.syncControl {
                events.append("second-inventory")
                events.append("second-apply")
                secondInventoryEntered.signal()
            }
        }
        XCTAssertEqual(
            secondRefreshAttempted.wait(timeout: .now() + .seconds(1)),
            .success
        )
        XCTAssertEqual(
            secondInventoryEntered.wait(
                timeout: .now() + .milliseconds(50)
            ),
            .timedOut,
            "A newer refresh must not inventory while the prior inventory awaits its apply."
        )

        releaseFirstInventory.signal()
        XCTAssertEqual(
            secondInventoryEntered.wait(timeout: .now() + .seconds(1)),
            .success
        )
        XCTAssertEqual(
            events.snapshot(),
            [
                "first-inventory",
                "first-apply",
                "second-inventory",
                "second-apply",
            ]
        )
    }

    func testProcessTapPCMQueueIsIndependentAndDrainFencesCallbacks() {
        let queues = CoreAudioProcessTapQueueTopology(
            labelPrefix: "opensteamer.tests.ProcessTapQueueIsolation"
        )
        let controlEntered = DispatchSemaphore(value: 0)
        let releaseControl = DispatchSemaphore(value: 0)
        let controlFinished = DispatchSemaphore(value: 0)

        queues.controlQueue.async {
            controlEntered.signal()
            releaseControl.wait()
            controlFinished.signal()
        }
        XCTAssertEqual(
            controlEntered.wait(timeout: .now() + .seconds(1)),
            .success
        )

        let pcmRanWhileControlWasBlocked = DispatchSemaphore(value: 0)
        queues.ioCallbackQueue.async {
            pcmRanWhileControlWasBlocked.signal()
        }
        XCTAssertEqual(
            pcmRanWhileControlWasBlocked.wait(
                timeout: .now() + .seconds(1)
            ),
            .success
        )
        releaseControl.signal()
        XCTAssertEqual(
            controlFinished.wait(timeout: .now() + .seconds(1)),
            .success
        )

        let callbackEntered = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        queues.ioCallbackQueue.async {
            callbackEntered.signal()
            releaseCallback.wait()
        }
        XCTAssertEqual(
            callbackEntered.wait(timeout: .now() + .seconds(1)),
            .success
        )

        let drainAttempted = DispatchSemaphore(value: 0)
        let drainReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            drainAttempted.signal()
            queues.drainIOCallbacks()
            drainReturned.signal()
        }
        XCTAssertEqual(
            drainAttempted.wait(timeout: .now() + .seconds(1)),
            .success
        )
        XCTAssertEqual(
            drainReturned.wait(timeout: .now() + .milliseconds(50)),
            .timedOut,
            "Teardown must wait for an admitted PCM callback to return."
        )
        releaseCallback.signal()
        XCTAssertEqual(
            drainReturned.wait(timeout: .now() + .seconds(1)),
            .success
        )
    }

    func testFaceTimeDuplexPolicyRequiresInputAndOutputOnTheSameAllowedProcess() {
        let splitEvidence = [
            makeFaceTimeActivitySnapshot(
                processObjectID: 101,
                isRunningInput: true,
                isRunningOutput: false
            ),
            makeFaceTimeActivitySnapshot(
                processObjectID: 202,
                isRunningInput: false,
                isRunningOutput: true
            ),
        ]

        XCTAssertEqual(
            CoreAudioFaceTimeDuplexActivityPolicy
                .scan(from: splitEvidence),
            .known(activeProcessObjectIDs: [])
        )

        let exactEvidence = splitEvidence + [
            makeFaceTimeActivitySnapshot(
                processObjectID: 303,
                isRunningInput: true,
                isRunningOutput: true
            ),
        ]
        XCTAssertEqual(
            CoreAudioFaceTimeDuplexActivityPolicy
                .scan(from: exactEvidence),
            .known(activeProcessObjectIDs: [303])
        )
    }

    func testFaceTimeDuplexPolicyMakesEveryReadOrListenerFailureUnknown() {
        let incompleteEvidence = [
            makeFaceTimeActivitySnapshot(
                processObjectID: 101,
                hasRunningInputListener: false
            ),
            makeFaceTimeActivitySnapshot(
                processObjectID: 202,
                hasRunningOutputListener: false
            ),
            makeFaceTimeActivitySnapshot(
                processObjectID: 303,
                isRunningInput: nil
            ),
            makeFaceTimeActivitySnapshot(
                processObjectID: 404,
                isRunningOutput: nil
            ),
        ]

        for snapshot in incompleteEvidence {
            XCTAssertEqual(
                CoreAudioFaceTimeDuplexActivityPolicy
                    .scan(from: [snapshot]),
                .unknown
            )
        }
        XCTAssertEqual(
            CoreAudioFaceTimeDuplexActivityPolicy.scan(from: nil),
            .unknown
        )
    }

    func testFaceTimeDuplexPolicyRequiresAnExactAllowedBundleIdentifier() {
        let snapshots = [
            makeFaceTimeActivitySnapshot(
                processObjectID: 101,
                bundleIdentifier: "com.apple.FaceTime.helper"
            ),
            makeFaceTimeActivitySnapshot(
                processObjectID: 202,
                bundleIdentifier: "com.apple.facetime"
            ),
            makeFaceTimeActivitySnapshot(
                processObjectID: 203,
                bundleIdentifier: "com.apple.avconferenced.helper"
            ),
            makeFaceTimeActivitySnapshot(
                processObjectID: 303,
                bundleIdentifier: "com.apple.FaceTime.FTConversationService"
            ),
            makeFaceTimeActivitySnapshot(
                processObjectID: 304,
                bundleIdentifier: "com.apple.avconferenced"
            ),
        ]

        XCTAssertEqual(
            CoreAudioFaceTimeDuplexActivityPolicy
                .scan(from: snapshots),
            .known(activeProcessObjectIDs: [304])
        )
        XCTAssertEqual(
            CoreAudioFaceTimeDuplexActivityPolicy.scan(from: [
                makeFaceTimeActivitySnapshot(
                    processObjectID: 101,
                    bundleIdentifier: nil
                ),
            ]),
            .unknown
        )
        XCTAssertEqual(
            CoreAudioFaceTimeDuplexActivityPolicy.scan(from: [
                makeFaceTimeActivitySnapshot(
                    processObjectID: kAudioObjectUnknown
                ),
            ]),
            .unknown
        )
    }

    func testFaceTimeDuplexPolicyPrefersPresentMediaServiceOverTemporaryApp() {
        let temporaryApp = makeFaceTimeActivitySnapshot(
            processObjectID: 303,
            bundleIdentifier: "com.apple.FaceTime"
        )
        let inactiveMediaService = makeFaceTimeActivitySnapshot(
            processObjectID: 304,
            bundleIdentifier: "com.apple.avconferenced",
            isRunningInput: false,
            isRunningOutput: false
        )

        XCTAssertEqual(
            CoreAudioFaceTimeDuplexActivityPolicy.scan(from: [
                temporaryApp,
                inactiveMediaService,
            ]),
            .known(activeProcessObjectIDs: [])
        )
        XCTAssertEqual(
            CoreAudioFaceTimeDuplexActivityPolicy.scan(from: [
                temporaryApp,
                makeFaceTimeActivitySnapshot(
                    processObjectID: 304,
                    bundleIdentifier: "com.apple.avconferenced"
                ),
            ]),
            .known(activeProcessObjectIDs: [304])
        )
    }

    func testFaceTimeDuplexPolicyRetainsOlderSystemFallback() {
        XCTAssertEqual(
            CoreAudioFaceTimeDuplexActivityPolicy.scan(from: [
                makeFaceTimeActivitySnapshot(
                    processObjectID: 303,
                    bundleIdentifier: "com.apple.FaceTime"
                ),
            ]),
            .known(activeProcessObjectIDs: [303])
        )
    }

    func testFaceTimeDuplexPolicyKeepsSameTierCardinalityAmbiguous()
        throws {
        let scans = [
            CoreAudioFaceTimeDuplexActivityPolicy.scan(from: [
                makeFaceTimeActivitySnapshot(
                    processObjectID: 301,
                    bundleIdentifier:
                        "com.apple.FaceTime.FTConversationService"
                ),
                makeFaceTimeActivitySnapshot(
                    processObjectID: 302,
                    bundleIdentifier: "com.apple.FaceTime"
                ),
            ]),
            CoreAudioFaceTimeDuplexActivityPolicy.scan(from: [
                makeFaceTimeActivitySnapshot(
                    processObjectID: 303,
                    bundleIdentifier: "com.apple.avconferenced"
                ),
                makeFaceTimeActivitySnapshot(
                    processObjectID: 304,
                    bundleIdentifier: "com.apple.avconferenced"
                ),
            ]),
        ]

        for scan in scans {
            guard case .known(let activeProcessObjectIDs) = scan else {
                return XCTFail("A complete scan must remain known")
            }
            XCTAssertEqual(activeProcessObjectIDs.count, 2)

            var binder = CoreAudioFaceTimeCausalEpochBinder()
            _ = binder.installChallenge(
                makeFaceTimeActivityChallenge(
                    sequence: 1,
                    callEpochNonce: UUID()
                ),
                authoritativeScan: {
                    .known(activeProcessObjectIDs: [])
                }
            )

            let update = try XCTUnwrap(binder.observe(scan))
            XCTAssertNil(update.causalBindingID)
            XCTAssertEqual(binder.phase, .poisoned)
        }
    }

    func testFaceTimeDuplexPolicyKeepsIrrelevantAllowedReadFailureUnknown() {
        let scan = CoreAudioFaceTimeDuplexActivityPolicy.scan(from: [
            makeFaceTimeActivitySnapshot(
                processObjectID: 303,
                bundleIdentifier: "com.apple.avconferenced"
            ),
            makeFaceTimeActivitySnapshot(
                processObjectID: 304,
                bundleIdentifier: "com.apple.FaceTime",
                isRunningOutput: nil
            ),
        ])
        XCTAssertEqual(scan, .unknown)
    }

    func testFaceTimeInventoryRetryDiscardsFailedAttemptOnlyAfterExactObjectDisappears()
        throws {
        var inventories: [[AudioObjectID]] = [
            [101, 202],
            [202],
            [202],
        ]
        var attemptedInventories: [[AudioObjectID]] = []

        let result: CoreAudioFaceTimeCompleteInventoryReader
            .ReadResult<[AudioObjectID]>? =
            CoreAudioFaceTimeCompleteInventoryReader.read(
                readInventory: {
                    try XCTUnwrap(
                        inventories.isEmpty
                            ? nil
                            : inventories.removeFirst()
                    )
                },
                readCompleteAttempt: { inventory in
                    attemptedInventories.append(inventory)
                    if inventory.contains(101) {
                        return .unreadableObject(101)
                    }
                    return .complete(inventory)
                }
            )

        XCTAssertEqual(result?.value, [202])
        XCTAssertTrue(try XCTUnwrap(result).requiredRetry)
        XCTAssertNil(result?.stableValue)
        XCTAssertEqual(attemptedInventories, [[101, 202], [202]])
        XCTAssertTrue(inventories.isEmpty)
    }

    func testFaceTimeInventoryRetryKeepsStillPresentUnreadableObjectUnknown()
        throws {
        var inventories: [[AudioObjectID]] = [
            [101, 202],
            [101, 202],
        ]
        var attemptCount = 0

        let result: CoreAudioFaceTimeCompleteInventoryReader
            .ReadResult<[AudioObjectID]>? =
            CoreAudioFaceTimeCompleteInventoryReader.read(
                readInventory: {
                    try XCTUnwrap(
                        inventories.isEmpty
                            ? nil
                            : inventories.removeFirst()
                    )
                },
                readCompleteAttempt: { _ in
                    attemptCount += 1
                    return .unreadableObject(101)
                }
            )

        XCTAssertNil(result)
        XCTAssertEqual(attemptCount, 1)
        XCTAssertTrue(inventories.isEmpty)
    }

    func testFaceTimeInventoryRetryRestartsWhenClosingInventoryChanged()
        throws {
        var inventories: [[AudioObjectID]] = [
            [101],
            [101, 202],
            [101, 202],
        ]
        var attemptedInventories: [[AudioObjectID]] = []

        let result: CoreAudioFaceTimeCompleteInventoryReader
            .ReadResult<[AudioObjectID]>? =
            CoreAudioFaceTimeCompleteInventoryReader.read(
                readInventory: {
                    try XCTUnwrap(
                        inventories.isEmpty
                            ? nil
                            : inventories.removeFirst()
                    )
                },
                readCompleteAttempt: { inventory in
                    attemptedInventories.append(inventory)
                    return .complete(inventory)
                }
            )

        XCTAssertEqual(result?.value, [101, 202])
        XCTAssertTrue(try XCTUnwrap(result).requiredRetry)
        XCTAssertNil(result?.stableValue)
        XCTAssertEqual(attemptedInventories, [[101], [101, 202]])
    }

    func testFaceTimeInventoryFirstPassStableResultCanAuthorize() throws {
        var inventories: [[AudioObjectID]] = [
            [101],
            [101],
        ]

        let result: CoreAudioFaceTimeCompleteInventoryReader
            .ReadResult<[AudioObjectID]>? =
            CoreAudioFaceTimeCompleteInventoryReader.read(
                readInventory: {
                    try XCTUnwrap(
                        inventories.isEmpty
                            ? nil
                            : inventories.removeFirst()
                    )
                },
                readCompleteAttempt: { inventory in
                    .complete(inventory)
                }
            )

        XCTAssertFalse(try XCTUnwrap(result).requiredRetry)
        XCTAssertEqual(result?.stableValue, [101])
    }

    func testFaceTimeListenerRemovalRetriesOnlyTheExactFailedSelector() {
        let input = kAudioProcessPropertyIsRunningInput
        let output = kAudioProcessPropertyIsRunningOutput
        var firstRemovalCalls: Set<AudioObjectPropertySelector> = []

        let remaining =
            CoreAudioFaceTimeProcessListenerRemovalPolicy
                .remainingSelectors(
                    installedSelectors: [input, output]
                ) { selector in
                    firstRemovalCalls.insert(selector)
                    return selector == input ? noErr : OSStatus(-1)
                }

        XCTAssertEqual(firstRemovalCalls, [input, output])
        XCTAssertEqual(remaining, [output])

        var retryCalls: Set<AudioObjectPropertySelector> = []
        let finalRemainder =
            CoreAudioFaceTimeProcessListenerRemovalPolicy
                .remainingSelectors(
                    installedSelectors: remaining
                ) { selector in
                    retryCalls.insert(selector)
                    return noErr
                }

        XCTAssertEqual(retryCalls, [output])
        XCTAssertTrue(finalRemainder.isEmpty)
    }

    func testFaceTimeEpochBinderRequiresZeroBaselineThenOneExactProcess()
        throws {
        let epoch = UUID()
        let bindingID = UUID()
        let challenge = makeFaceTimeActivityChallenge(
            sequence: 1,
            callEpochNonce: epoch
        )
        var binder = CoreAudioFaceTimeCausalEpochBinder()

        let initial = try XCTUnwrap(
            binder.installChallenge(
                challenge,
                authoritativeScan: {
                    .known(activeProcessObjectIDs: [])
                },
                makeCausalBindingID: { bindingID }
            )
        )
        XCTAssertNil(initial.causalBindingID)
        XCTAssertTrue(initial.isCausallyArmed)
        XCTAssertEqual(binder.phase, .armed)

        let bound = try XCTUnwrap(
            binder.observe(
                .known(activeProcessObjectIDs: [101]),
                makeCausalBindingID: { bindingID }
            )
        )
        XCTAssertEqual(bound.causalBindingID, bindingID)
        XCTAssertFalse(bound.isCausallyArmed)
        XCTAssertEqual(
            binder.phase,
            .bound(processObjectID: 101, causalBindingID: bindingID)
        )

        let heartbeat = try XCTUnwrap(
            binder.observe(.known(activeProcessObjectIDs: [101]))
        )
        XCTAssertEqual(heartbeat.causalBindingID, bindingID)
        XCTAssertFalse(heartbeat.didPhaseChange)

        let inactive = try XCTUnwrap(
            binder.observe(.known(activeProcessObjectIDs: []))
        )
        XCTAssertNil(inactive.causalBindingID)
        XCTAssertEqual(binder.phase, .poisoned)

        let cannotRebind = try XCTUnwrap(
            binder.observe(.known(activeProcessObjectIDs: [101]))
        )
        XCTAssertNil(cannotRebind.causalBindingID)
        XCTAssertEqual(binder.phase, .poisoned)
    }

    func testFaceTimeEpochBinderPoisonsUnsafeInitialAndArmedScans() throws {
        let unsafeInitialScans: [CoreAudioFaceTimeDuplexActivityScan] = [
            .unknown,
            .known(activeProcessObjectIDs: [101]),
            .known(activeProcessObjectIDs: [101, 202]),
        ]
        for (index, scan) in unsafeInitialScans.enumerated() {
            var binder = CoreAudioFaceTimeCausalEpochBinder()
            let update = try XCTUnwrap(
                binder.installChallenge(
                    makeFaceTimeActivityChallenge(
                        sequence: UInt64(index + 1),
                        callEpochNonce: UUID()
                    ),
                    authoritativeScan: { scan }
                )
            )
            XCTAssertNil(update.causalBindingID)
            XCTAssertEqual(binder.phase, .poisoned)
            XCTAssertFalse(
                CoreAudioFaceTimeChallengeInstallEmissionPolicy.admits(
                    phase: binder.phase
                ),
                "An active or unknown first scan must not masquerade as an inactive preflight acknowledgement."
            )
        }

        let unsafeArmedScans: [CoreAudioFaceTimeDuplexActivityScan] = [
            .unknown,
            .known(activeProcessObjectIDs: [101, 202]),
        ]
        for scan in unsafeArmedScans {
            var binder = CoreAudioFaceTimeCausalEpochBinder()
            _ = binder.installChallenge(
                makeFaceTimeActivityChallenge(
                    sequence: 1,
                    callEpochNonce: UUID()
                ),
                authoritativeScan: {
                    .known(activeProcessObjectIDs: [])
                }
            )
            let update = try XCTUnwrap(binder.observe(scan))
            XCTAssertNil(update.causalBindingID)
            XCTAssertFalse(
                update.isCausallyArmed,
                "An armed-to-poisoned transition must not emit a preflight acknowledgement."
            )
            XCTAssertEqual(binder.phase, .poisoned)
        }
    }

    func testFaceTimeChallengeInstallEmissionRequiresArmedOrBoundState() {
        let bindingID = UUID()
        XCTAssertFalse(
            CoreAudioFaceTimeChallengeInstallEmissionPolicy.admits(
                phase: .noEpoch
            )
        )
        XCTAssertTrue(
            CoreAudioFaceTimeChallengeInstallEmissionPolicy.admits(
                phase: .armed
            )
        )
        XCTAssertTrue(
            CoreAudioFaceTimeChallengeInstallEmissionPolicy.admits(
                phase: .bound(
                    processObjectID: 101,
                    causalBindingID: bindingID
                )
            )
        )
        XCTAssertFalse(
            CoreAudioFaceTimeChallengeInstallEmissionPolicy.admits(
                phase: .poisoned
            )
        )
    }

    func testFaceTimeEpochBinderPoisonsEveryBoundIdentityMismatch() throws {
        let invalidBoundScans: [CoreAudioFaceTimeDuplexActivityScan] = [
            .known(activeProcessObjectIDs: []),
            .unknown,
            .known(activeProcessObjectIDs: [202]),
            .known(activeProcessObjectIDs: [101, 202]),
        ]
        for scan in invalidBoundScans {
            let bindingID = UUID()
            var binder = CoreAudioFaceTimeCausalEpochBinder()
            _ = binder.installChallenge(
                makeFaceTimeActivityChallenge(
                    sequence: 1,
                    callEpochNonce: UUID()
                ),
                authoritativeScan: {
                    .known(activeProcessObjectIDs: [])
                }
            )
            _ = binder.observe(
                .known(activeProcessObjectIDs: [101]),
                makeCausalBindingID: { bindingID }
            )

            let update = try XCTUnwrap(binder.observe(scan))
            XCTAssertNil(update.causalBindingID)
            XCTAssertEqual(binder.phase, .poisoned)
            let laterExactProcess = try XCTUnwrap(
                binder.observe(.known(activeProcessObjectIDs: [101]))
            )
            XCTAssertNil(laterExactProcess.causalBindingID)
        }
    }

    func testFaceTimeEpochBinderPreservesSameEpochAndIgnoresStaleChallenge()
        throws {
        let epoch = UUID()
        let bindingID = UUID()
        let first = makeFaceTimeActivityChallenge(
            sequence: 10,
            callEpochNonce: epoch
        )
        let armedRotation = makeFaceTimeActivityChallenge(
            sequence: 11,
            callEpochNonce: epoch
        )
        let boundRotation = makeFaceTimeActivityChallenge(
            sequence: 12,
            callEpochNonce: epoch
        )
        var binder = CoreAudioFaceTimeCausalEpochBinder()

        _ = binder.installChallenge(
            first,
            authoritativeScan: {
                .known(activeProcessObjectIDs: [])
            }
        )
        let stillArmed = try XCTUnwrap(
            binder.installChallenge(
                armedRotation,
                authoritativeScan: {
                    .known(activeProcessObjectIDs: [])
                }
            )
        )
        XCTAssertEqual(binder.phase, .armed)
        XCTAssertNil(stillArmed.causalBindingID)

        _ = binder.observe(
            .known(activeProcessObjectIDs: [101]),
            makeCausalBindingID: { bindingID }
        )
        let stillBound = try XCTUnwrap(
            binder.installChallenge(
                boundRotation,
                authoritativeScan: {
                    .known(activeProcessObjectIDs: [101])
                },
                makeCausalBindingID: {
                    XCTFail("A same-process rotation must not mint a new binding")
                    return UUID()
                }
            )
        )
        XCTAssertEqual(stillBound.challenge, boundRotation)
        XCTAssertEqual(stillBound.causalBindingID, bindingID)

        var staleChallengeWasScanned = false
        let stale = binder.installChallenge(
            armedRotation,
            authoritativeScan: {
                staleChallengeWasScanned = true
                return .unknown
            }
        )
        XCTAssertNil(stale)
        XCTAssertFalse(staleChallengeWasScanned)
        XCTAssertEqual(binder.currentChallenge, boundRotation)
        XCTAssertEqual(
            binder.phase,
            .bound(processObjectID: 101, causalBindingID: bindingID)
        )
    }

    func testFaceTimeEpochBinderNewEpochRequiresItsOwnSafeBaseline() throws {
        let firstEpoch = UUID()
        let secondEpoch = UUID()
        let thirdEpoch = UUID()
        var binder = CoreAudioFaceTimeCausalEpochBinder()

        _ = binder.installChallenge(
            makeFaceTimeActivityChallenge(
                sequence: 1,
                callEpochNonce: firstEpoch
            ),
            authoritativeScan: {
                .known(activeProcessObjectIDs: [])
            }
        )
        _ = binder.observe(.known(activeProcessObjectIDs: [101]))

        let unsafeNewEpoch = try XCTUnwrap(
            binder.installChallenge(
                makeFaceTimeActivityChallenge(
                    sequence: 2,
                    callEpochNonce: secondEpoch
                ),
                authoritativeScan: {
                    .known(activeProcessObjectIDs: [101])
                }
            )
        )
        XCTAssertNil(unsafeNewEpoch.causalBindingID)
        XCTAssertEqual(binder.phase, .poisoned)
        _ = binder.observe(.known(activeProcessObjectIDs: []))
        _ = binder.observe(.known(activeProcessObjectIDs: [101]))
        XCTAssertEqual(binder.phase, .poisoned)

        let safeNewEpoch = try XCTUnwrap(
            binder.installChallenge(
                makeFaceTimeActivityChallenge(
                    sequence: 3,
                    callEpochNonce: thirdEpoch
                ),
                authoritativeScan: {
                    .known(activeProcessObjectIDs: [])
                }
            )
        )
        XCTAssertNil(safeNewEpoch.causalBindingID)
        XCTAssertEqual(binder.phase, .armed)
        let newBinding = try XCTUnwrap(
            binder.observe(.known(activeProcessObjectIDs: [202]))
        )
        XCTAssertNotNil(newBinding.causalBindingID)
    }

    func testFaceTimeEpochBinderRevokeClearsBindingAndChallenge() throws {
        let challenge = makeFaceTimeActivityChallenge(
            sequence: 1,
            callEpochNonce: UUID()
        )
        var binder = CoreAudioFaceTimeCausalEpochBinder()
        _ = binder.installChallenge(
            challenge,
            authoritativeScan: {
                .known(activeProcessObjectIDs: [])
            }
        )
        _ = binder.observe(.known(activeProcessObjectIDs: [101]))

        let revoked = binder.revoke()
        XCTAssertEqual(revoked.challenge, challenge)
        XCTAssertNil(revoked.causalBindingID)
        XCTAssertEqual(binder.phase, .noEpoch)
        XCTAssertNil(binder.currentChallenge)
        XCTAssertNil(
            binder.observe(.known(activeProcessObjectIDs: [101]))
        )
    }

    func testProcessTapClockPolicyRejectsDuplexDefaultBlackHole() throws {
        let selected = try XCTUnwrap(
            CoreAudioProcessTapClockDeviceSelectionPolicy.select(from: [
                makeClockDeviceSnapshot(
                    deviceID: 101,
                    uid: "BlackHole2ch_UID",
                    isDefaultOutput: true,
                    inputChannelCount: 2,
                    outputChannelCount: 2
                ),
                makeClockDeviceSnapshot(
                    deviceID: 202,
                    uid: "BuiltInSpeakerDevice",
                    inputChannelCount: 0,
                    outputChannelCount: 2
                ),
            ])
        )

        XCTAssertEqual(selected.deviceID, 202)
        XCTAssertEqual(selected.uid, "BuiltInSpeakerDevice")
        XCTAssertEqual(selected.inputChannelCount, 0)
    }

    func testProcessTapClockPolicyPrefersSafeDefaultThenStableUID() throws {
        let safeDefault = makeClockDeviceSnapshot(
            deviceID: 303,
            uid: "z-default-output",
            isDefaultOutput: true,
            inputChannelCount: 0,
            outputChannelCount: 2
        )
        XCTAssertEqual(
            CoreAudioProcessTapClockDeviceSelectionPolicy.select(from: [
                makeClockDeviceSnapshot(
                    deviceID: 101,
                    uid: "a-other-output",
                    inputChannelCount: 0,
                    outputChannelCount: 2
                ),
                safeDefault,
            ]),
            safeDefault
        )

        let stableFallback = try XCTUnwrap(
            CoreAudioProcessTapClockDeviceSelectionPolicy.select(from: [
                makeClockDeviceSnapshot(
                    deviceID: 202,
                    uid: "z-output",
                    inputChannelCount: 0,
                    outputChannelCount: 2
                ),
                makeClockDeviceSnapshot(
                    deviceID: 101,
                    uid: "a-output",
                    inputChannelCount: 0,
                    outputChannelCount: 2
                ),
            ])
        )
        XCTAssertEqual(stableFallback.uid, "a-output")
    }

    func testProcessTapClockPolicyFailsClosedWithoutLiveOutputOnlyDevice() {
        let unsafeDevices = [
            makeClockDeviceSnapshot(
                deviceID: 101,
                uid: "dead-output",
                isAlive: false,
                inputChannelCount: 0,
                outputChannelCount: 2
            ),
            makeClockDeviceSnapshot(
                deviceID: 202,
                uid: "input-only",
                inputChannelCount: 2,
                outputChannelCount: 0
            ),
            makeClockDeviceSnapshot(
                deviceID: 303,
                uid: "duplex",
                isDefaultOutput: true,
                inputChannelCount: 1,
                outputChannelCount: 2
            ),
        ]

        XCTAssertNil(
            CoreAudioProcessTapClockDeviceSelectionPolicy.select(
                from: unsafeDevices
            )
        )
    }

    func testProcessTapBufferPolicyAcceptsExactInterleavedStereoFrames() {
        let format = makeLinearPCMFormat(
            bytesPerFrame: 8,
            channels: 2,
            nonInterleaved: false
        )
        withAudioBufferList(byteCounts: [8 * 480]) { list in
            XCTAssertEqual(
                CoreAudioProcessTapBufferPolicy.frameCount(
                    audioBufferList: list,
                    format: format
                ),
                480
            )
        }
    }

    func testProcessTapBufferPolicyAcceptsMatchingPlanarFramesAndRejectsMismatch() {
        let format = makeLinearPCMFormat(
            bytesPerFrame: 4,
            channels: 2,
            nonInterleaved: true
        )
        withAudioBufferList(byteCounts: [4 * 240, 4 * 240]) { list in
            XCTAssertEqual(
                CoreAudioProcessTapBufferPolicy.frameCount(
                    audioBufferList: list,
                    format: format
                ),
                240
            )
        }
        withAudioBufferList(byteCounts: [4 * 240, 4 * 239]) { list in
            XCTAssertNil(
                CoreAudioProcessTapBufferPolicy.frameCount(
                    audioBufferList: list,
                    format: format
                )
            )
        }
    }

    func testProcessTapPresentationTimePrefersSourceSampleClock() {
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = 96_000
        timestamp.mFlags = .sampleTimeValid

        let result = withUnsafePointer(to: &timestamp) {
            CoreAudioProcessTapBufferPolicy.presentationTime(
                inputTime: $0,
                sampleRate: 48_000
            )
        }

        XCTAssertEqual(result.seconds, 2, accuracy: 0.000_000_001)
    }

    func testScreenCaptureRegistrationUsesExactConsumerQueueAndSynchronousCallback() throws {
        let consumer = QueueProbeConsumer()
        let registration = ScreenCaptureAudioSource.makeOutputRegistration(consumer: consumer)

        XCTAssertTrue(registration.sampleHandlerQueue === consumer.sampleHandlerQueue)
        try registration.sampleHandlerQueue.sync {
            let sampleBuffer = try makeStereoFloatSampleBuffer(
                frames: [[0.25, -0.25], [0.5, -0.5]],
                presentationTime: .zero
            )
            registration.output.handle(sampleBuffer, outputType: .audio)
            // This assertion runs before the ScreenCaptureKit callback would return. A second
            // async handoff in StreamOutput would leave the count at zero here.
            XCTAssertEqual(consumer.consumeCount, 1)

            registration.output.handle(sampleBuffer, outputType: .screen)
            XCTAssertEqual(consumer.consumeCount, 1)
        }
    }

    func testFileProcessorConsumesSynchronouslyAndFinishesWithExactMetrics() throws {
        let outputURL = temporaryURL(name: "processor.wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let processor = AudioProcessor(outputURL: outputURL, logger: SilentLogger())

        try processor.sampleHandlerQueue.sync {
            let first = try makeStereoFloatSampleBuffer(
                frames: [[0.25, -0.25], [0.5, -0.5]],
                presentationTime: .zero
            )
            processor.consume(first)
            let firstSize = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber
            ).intValue
            XCTAssertGreaterThan(firstSize, 44)

            let second = try makeStereoFloatSampleBuffer(
                frames: [[-1, 1], [0, 0]],
                presentationTime: CMTime(value: 2, timescale: 48_000)
            )
            processor.consume(second)
            let secondSize = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber
            ).intValue
            XCTAssertGreaterThan(secondSize, firstSize)
        }

        let snapshot = processor.latestSnapshot()
        XCTAssertEqual(snapshot.callbackStatistics.count, 2)
        XCTAssertEqual(snapshot.framesWritten, 4)
        XCTAssertEqual(try XCTUnwrap(snapshot.latestMetrics).peak, 1, accuracy: 0.000_001)

        let summary = try processor.finish()
        XCTAssertEqual(summary.callbackStatistics.count, 2)
        XCTAssertEqual(summary.framesWritten, 4)
        XCTAssertEqual(summary.bytesWritten, 16)
        XCTAssertEqual(summary.streamFormat?.sampleRate, 48_000)
        XCTAssertEqual(summary.streamFormat?.channelCount, 2)
        XCTAssertEqual(try XCTUnwrap(summary.metricSummary.maximumPeak), 1, accuracy: 0.000_001)
    }

    func testStreamingSampleBufferIsFramedBeforeCallbackReturns() throws {
        let sink = RecordingPCMSink()
        let processor = StreamingAudioProcessor(sink: sink, logger: SilentLogger())
        let queueKey = DispatchSpecificKey<UInt8>()
        processor.sampleHandlerQueue.setSpecific(key: queueKey, value: 1)
        sink.expect(queueKey: queueKey)

        try processor.sampleHandlerQueue.sync {
            let sampleBuffer = try makeStereoFloatSampleBuffer(
                frames: [[0.25, -0.25], [0.5, -0.5]],
                presentationTime: CMTime(value: 96, timescale: 48_000)
            )
            processor.consume(sampleBuffer)
            // The sink must already contain the packet while the callback is still active.
            XCTAssertEqual(sink.snapshot().packets.count, 1)
        }

        let summary = try processor.finish()
        XCTAssertEqual(summary.callbackStatistics.count, 1)
        XCTAssertEqual(summary.framesStreamed, 2)
        XCTAssertEqual(summary.bytesStreamed, 8)
        XCTAssertEqual(summary.packetsStreamed, 1)

        let snapshot = sink.snapshot()
        XCTAssertEqual(snapshot.headers.count, 1)
        XCTAssertEqual(snapshot.headers[0].sampleRate, 48_000)
        XCTAssertEqual(snapshot.headers[0].channels, 2)
        XCTAssertEqual(snapshot.packets.map(\.sequence), [0])
        XCTAssertEqual(snapshot.packets.map(\.timestamp), [2_000_000])
        XCTAssertEqual(snapshot.packets.map(\.frameCount), [2])
        XCTAssertEqual(snapshot.offExpectedQueueCalls, 0)
    }

    func testBlackHolePCMEnqueueCapturesArrivalBeforeProcessingBacklog() throws {
        let sink = RecordingPCMSink()
        let queueKey = DispatchSpecificKey<UInt8>()
        let callbackClock = ManualCallbackArrivalClock(queueKey: queueKey)
        let processor = StreamingAudioProcessor(
            sink: sink,
            logger: SilentLogger(),
            callbackTimeProvider: {
                callbackClock.now()
            }
        )
        processor.sampleHandlerQueue.setSpecific(key: queueKey, value: 1)
        sink.expect(queueKey: queueKey)
        let format = makeStereoFloatFormat()
        let backlogEntered = DispatchSemaphore(value: 0)
        let releaseBacklog = DispatchSemaphore(value: 0)

        processor.sampleHandlerQueue.async {
            backlogEntered.signal()
            releaseBacklog.wait()
        }
        XCTAssertEqual(
            backlogEntered.wait(timeout: .now() + .seconds(1)),
            .success
        )

        let arrivalTimes: [UInt64] = [
            1_000_000,
            11_000_000,
            31_000_000,
        ]
        for (index, arrivalTime) in arrivalTimes.enumerated() {
            callbackClock.set(arrivalTime)
            let pcm = PCMBuffer(
                samples: [Float(index) / 64, -Float(index) / 64, 0.25, -0.25],
                frameCount: 2,
                channels: 2,
                format: format
            )
            processor.enqueue(
                pcm,
                presentationTimestampNanoseconds: UInt64(index) * 1_000_000
            )
        }
        callbackClock.set(1_000_000_000)
        releaseBacklog.signal()

        let summary = try processor.finish()
        XCTAssertEqual(summary.callbackStatistics.count, 3)
        XCTAssertEqual(summary.framesStreamed, 6)
        XCTAssertEqual(summary.bytesStreamed, 24)
        XCTAssertEqual(summary.packetsStreamed, 3)
        XCTAssertEqual(
            try XCTUnwrap(summary.callbackStatistics.minimumInterval),
            0.01,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(summary.callbackStatistics.maximumInterval),
            0.02,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            summary.callbackStatistics.averageInterval,
            0.015,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            callbackClock.processorQueueReadCount,
            0,
            "Arrival sampling must happen at enqueue, not after the serial processing backlog drains."
        )

        let snapshot = sink.snapshot()
        XCTAssertEqual(snapshot.headers.count, 1)
        XCTAssertEqual(snapshot.packets.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(snapshot.offExpectedQueueCalls, 0)
    }

    func testConcurrentBlackHolePCMEnqueueLinearizesArrivalWithoutUnderflow()
        throws {
        let sink = RecordingPCMSink()
        let queueKey = DispatchSpecificKey<UInt8>()
        let callbackClock =
            RegressingConcurrentCallbackArrivalClock(
                queueKey: queueKey
            )
        let processor = StreamingAudioProcessor(
            sink: sink,
            logger: SilentLogger(),
            callbackTimeProvider: {
                callbackClock.now()
            }
        )
        processor.sampleHandlerQueue.setSpecific(key: queueKey, value: 1)
        sink.expect(queueKey: queueKey)
        let format = makeStereoFloatFormat()
        let packetCount = 32

        DispatchQueue.concurrentPerform(iterations: packetCount) { index in
            let pcm = PCMBuffer(
                samples: [Float(index) / 64, -Float(index) / 64, 0.25, -0.25],
                frameCount: 2,
                channels: 2,
                format: format
            )
            processor.enqueue(
                pcm,
                presentationTimestampNanoseconds: UInt64(index) * 1_000_000
            )
        }

        let summary = try processor.finish()
        XCTAssertEqual(summary.callbackStatistics.count, packetCount)
        XCTAssertEqual(summary.framesStreamed, Int64(packetCount * 2))
        XCTAssertEqual(summary.bytesStreamed, Int64(packetCount * 8))
        XCTAssertEqual(summary.packetsStreamed, Int64(packetCount))
        XCTAssertEqual(
            try XCTUnwrap(summary.callbackStatistics.minimumInterval),
            0,
            accuracy: 0.000_001,
            "A regressing injected sample is clamped instead of subtracting UInt64 values out of order."
        )
        XCTAssertEqual(
            try XCTUnwrap(summary.callbackStatistics.maximumInterval),
            0.01,
            accuracy: 0.000_001
        )
        XCTAssertEqual(callbackClock.readCount, packetCount)
        XCTAssertEqual(
            callbackClock.processorQueueReadCount,
            0,
            "Concurrent arrivals must be timestamped before queue submission."
        )

        let snapshot = sink.snapshot()
        XCTAssertEqual(snapshot.headers.count, 1)
        XCTAssertEqual(snapshot.packets.count, packetCount)
        XCTAssertEqual(snapshot.packets.map(\.sequence), Array(0..<UInt32(packetCount)))
        XCTAssertEqual(
            Set(snapshot.packets.map(\.timestamp)),
            Set((0..<packetCount).map { UInt64($0) * 1_000_000 })
        )
        XCTAssertTrue(snapshot.packets.allSatisfy {
            $0.frameCount == 2 && $0.byteCount == 8
        })
        XCTAssertEqual(snapshot.offExpectedQueueCalls, 0)
    }

    private func temporaryURL(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-\(UUID().uuidString)-\(name)")
    }
}

private func makeLinearPCMFormat(
    bytesPerFrame: UInt32,
    channels: UInt32,
    nonInterleaved: Bool
) -> AudioStreamBasicDescription {
    var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    if nonInterleaved {
        flags |= kAudioFormatFlagIsNonInterleaved
    }
    return AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: flags,
        mBytesPerPacket: bytesPerFrame,
        mFramesPerPacket: 1,
        mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: channels,
        mBitsPerChannel: 32,
        mReserved: 0
    )
}

private func makeFaceTimeActivityChallenge(
    sequence: UInt64,
    nonce: UUID = UUID(),
    callEpochNonce: UUID
) -> SystemAudioMacFaceTimeActivityChallenge {
    SystemAudioMacFaceTimeActivityChallenge(
        sequence: sequence,
        nonce: nonce,
        callEpochNonce: callEpochNonce
    )
}

private func makeFaceTimeActivitySnapshot(
    processObjectID: AudioObjectID,
    bundleIdentifier: String? = "com.apple.FaceTime",
    hasRunningInputListener: Bool = true,
    hasRunningOutputListener: Bool = true,
    isRunningInput: Bool? = true,
    isRunningOutput: Bool? = true
) -> CoreAudioFaceTimeProcessActivitySnapshot {
    CoreAudioFaceTimeProcessActivitySnapshot(
        processObjectID: processObjectID,
        bundleIdentifier: bundleIdentifier,
        hasRunningInputListener: hasRunningInputListener,
        hasRunningOutputListener: hasRunningOutputListener,
        isRunningInput: isRunningInput,
        isRunningOutput: isRunningOutput
    )
}

private func makeClockDeviceSnapshot(
    deviceID: AudioObjectID,
    uid: String,
    isAlive: Bool = true,
    isDefaultOutput: Bool = false,
    inputChannelCount: UInt32,
    outputChannelCount: UInt32
) -> CoreAudioProcessTapClockDeviceSnapshot {
    CoreAudioProcessTapClockDeviceSnapshot(
        deviceID: deviceID,
        uid: uid,
        isAlive: isAlive,
        isDefaultOutput: isDefaultOutput,
        inputChannelCount: inputChannelCount,
        outputChannelCount: outputChannelCount
    )
}

private func withAudioBufferList(
    byteCounts: [Int],
    operation: (UnsafePointer<AudioBufferList>) -> Void
) {
    precondition(!byteCounts.isEmpty)
    let allocationSize = MemoryLayout<AudioBufferList>.size
        + (byteCounts.count - 1) * MemoryLayout<AudioBuffer>.stride
    let listStorage = UnsafeMutableRawPointer.allocate(
        byteCount: allocationSize,
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    let list = listStorage.bindMemory(to: AudioBufferList.self, capacity: 1)
    list.pointee.mNumberBuffers = UInt32(byteCounts.count)
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    var dataStorage: [UnsafeMutableRawPointer] = []
    for (index, byteCount) in byteCounts.enumerated() {
        let data = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<Float>.alignment
        )
        data.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        dataStorage.append(data)
        buffers[index] = AudioBuffer(
            mNumberChannels: byteCounts.count == 1 ? 2 : 1,
            mDataByteSize: UInt32(byteCount),
            mData: data
        )
    }
    defer {
        dataStorage.forEach { $0.deallocate() }
        listStorage.deallocate()
    }
    operation(UnsafePointer(list))
}

private enum ProcessTapStartupFixtureError: Error {
    case refreshFailed
}

private final class LockedStringEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.withLock {
            events.append(event)
        }
    }

    func snapshot() -> [String] {
        lock.withLock { events }
    }
}

private final class QueueProbeConsumer: SampleBufferConsumer {
    let sampleHandlerQueue = DispatchQueue(label: "opensteamer.tests.QueueProbeConsumer")
    private(set) var consumeCount = 0

    func consume(_ sampleBuffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(sampleHandlerQueue))
        XCTAssertTrue(sampleBuffer.isValid)
        consumeCount += 1
    }
}

private struct SilentLogger: Logger {
    func info(_: String) {}
    func debug(_: String) {}
    func error(_: String) {}
}

private final class ManualCallbackArrivalClock: @unchecked Sendable {
    private let queueKey: DispatchSpecificKey<UInt8>
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var processorQueueReadCountStorage = 0

    init(queueKey: DispatchSpecificKey<UInt8>) {
        self.queueKey = queueKey
    }

    func set(_ value: UInt64) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if DispatchQueue.getSpecific(key: queueKey) == 1 {
            processorQueueReadCountStorage += 1
        }
        return value
    }

    var processorQueueReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return processorQueueReadCountStorage
    }
}

private final class RegressingConcurrentCallbackArrivalClock:
    @unchecked Sendable
{
    private let queueKey: DispatchSpecificKey<UInt8>
    private let lock = NSLock()
    private var readCountStorage = 0
    private var processorQueueReadCountStorage = 0

    init(queueKey: DispatchSpecificKey<UInt8>) {
        self.queueKey = queueKey
    }

    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if DispatchQueue.getSpecific(key: queueKey) == 1 {
            processorQueueReadCountStorage += 1
        }
        let index = readCountStorage
        readCountStorage += 1
        switch index {
        case 0:
            return 2_000_000
        case 1:
            return 1_000_000
        default:
            return 2_000_000
                + UInt64(index - 1) * 10_000_000
        }
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCountStorage
    }

    var processorQueueReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return processorQueueReadCountStorage
    }
}

private final class RecordingPCMSink: PCMFrameSink, @unchecked Sendable {
    struct Packet: Equatable {
        let sequence: UInt32
        let timestamp: UInt64
        let frameCount: UInt32
        let byteCount: Int
    }

    struct Snapshot {
        let headers: [PCMStreamHeader]
        let packets: [Packet]
        let offExpectedQueueCalls: Int
    }

    private let lock = NSLock()
    private var expectedQueueKey: DispatchSpecificKey<UInt8>?
    private var headers: [PCMStreamHeader] = []
    private var packets: [Packet] = []
    private var offExpectedQueueCalls = 0

    func expect(queueKey: DispatchSpecificKey<UInt8>) {
        lock.lock()
        expectedQueueKey = queueKey
        lock.unlock()
    }

    func configureStream(_ header: PCMStreamHeader) {
        lock.lock()
        recordQueueExpectation()
        headers.append(header)
        lock.unlock()
    }

    func sendPCMFrame(metadata: PCMPacketMetadata, pcmBytes: Data) {
        lock.lock()
        recordQueueExpectation()
        packets.append(
            Packet(
                sequence: metadata.sequence,
                timestamp: metadata.presentationTimestampNanoseconds,
                frameCount: metadata.frameCount,
                byteCount: pcmBytes.count
            )
        )
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            headers: headers,
            packets: packets,
            offExpectedQueueCalls: offExpectedQueueCalls
        )
    }

    private func recordQueueExpectation() {
        guard let expectedQueueKey,
              DispatchQueue.getSpecific(key: expectedQueueKey) == 1 else {
            offExpectedQueueCalls += 1
            return
        }
    }
}

private func makeStereoFloatFormat() -> StreamAudioFormat {
    let description = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8,
        mFramesPerPacket: 1,
        mBytesPerFrame: 8,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    return StreamAudioFormat(description)
}

private func makeStereoFloatSampleBuffer(
    frames: [[Float]],
    presentationTime: CMTime
) throws -> CMSampleBuffer {
    guard !frames.isEmpty, frames.allSatisfy({ $0.count == 2 }) else {
        throw SampleBufferFixtureError.invalidFrames
    }
    let samples = frames.flatMap { $0 }
    let byteCount = samples.count * MemoryLayout<Float>.size

    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: byteCount,
        flags: 0,
        blockBufferOut: &blockBuffer
    )
    guard status == kCMBlockBufferNoErr, let blockBuffer else {
        throw SampleBufferFixtureError.blockBuffer(status)
    }
    status = samples.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else {
            return kCMBlockBufferBadLengthParameterErr
        }
        return CMBlockBufferReplaceDataBytes(
            with: baseAddress,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
    }
    guard status == kCMBlockBufferNoErr else {
        throw SampleBufferFixtureError.blockBuffer(status)
    }

    var description = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8,
        mFramesPerPacket: 1,
        mBytesPerFrame: 8,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    status = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &description,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    )
    guard status == noErr, let formatDescription else {
        throw SampleBufferFixtureError.formatDescription(status)
    }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: presentationTime,
        decodeTimeStamp: .invalid
    )
    var sampleSize = 8
    var sampleBuffer: CMSampleBuffer?
    status = CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: frames.count,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sampleBuffer else {
        throw SampleBufferFixtureError.sampleBuffer(status)
    }
    return sampleBuffer
}

private enum SampleBufferFixtureError: Error {
    case invalidFrames
    case blockBuffer(OSStatus)
    case formatDescription(OSStatus)
    case sampleBuffer(OSStatus)
}
