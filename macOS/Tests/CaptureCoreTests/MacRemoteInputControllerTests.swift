import CoreGraphics
import Foundation
import XCTest
@testable import CaptureCore

final class MacRemoteInputControllerTests: XCTestCase {
    private let displayID: UInt32 = 42
    private let showID: UInt64 = 73
    private let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    func testControllerIsFailClosedUntilExplicitlyEnabledAndArmed() {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        let controller = MacRemoteInputController(
            allowRemoteControl: false,
            system: system,
            clock: clock
        )

        XCTAssertEqual(
            controller.arm(displayID: displayID, screenRequestID: showID, inputSessionID: sessionID),
            .disabled
        )
        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: .init(x: 0.5, y: 0.5)
            ),
            .rejected(.disabled)
        )
        XCTAssertTrue(system.postedMousePoints.isEmpty)
    }

    func testArmRequiresBothTCCGrantsAndAnActiveDisplay() {
        let system = MockMacRemoteInputSystem()
        let controller = makeController(system: system)

        system.permissions = .init(accessibilityTrusted: true, postEventAllowed: false)
        XCTAssertEqual(
            controller.arm(displayID: displayID, screenRequestID: showID, inputSessionID: sessionID),
            .permissionRequired(system.permissions)
        )

        system.permissions = .init(accessibilityTrusted: true, postEventAllowed: true)
        system.bounds = nil
        XCTAssertEqual(
            controller.arm(displayID: displayID, screenRequestID: showID, inputSessionID: sessionID),
            .displayUnavailable
        )

        system.bounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        XCTAssertEqual(
            controller.arm(displayID: displayID, screenRequestID: showID, inputSessionID: sessionID),
            .armed
        )
    }

    func testTapMapsThroughNegativeGlobalDisplayOriginWithoutYFlip() {
        let system = MockMacRemoteInputSystem()
        system.bounds = CGRect(x: -1_920, y: -400, width: 1_920, height: 1_080)
        let controller = armedController(system: system)

        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: .init(x: 0.25, y: 0.75)
            ),
            .accepted(.none)
        )
        XCTAssertEqual(system.postedMousePoints.count, 1)
        XCTAssertEqual(system.postedMousePoints[0].x, -1_440, accuracy: 0.0001)
        XCTAssertEqual(system.postedMousePoints[0].y, 410, accuracy: 0.0001)
    }

    func testBottomRightNormalizedEdgeStaysInsideCapturedDisplay() {
        let system = MockMacRemoteInputSystem()
        system.bounds = CGRect(x: 1_920, y: -200, width: 1_280, height: 720)
        let controller = armedController(system: system)

        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: .init(x: 1, y: 1)
            ),
            .accepted(.none)
        )
        let posted = try! XCTUnwrap(system.postedMousePoints.first)
        XCTAssertGreaterThanOrEqual(posted.x, system.bounds!.minX)
        XCTAssertGreaterThanOrEqual(posted.y, system.bounds!.minY)
        XCTAssertLessThan(posted.x, system.bounds!.maxX)
        XCTAssertLessThan(posted.y, system.bounds!.maxY)
    }

    func testTapRejectsNonFiniteAndOutOfRangePointsWithoutInjection() {
        let system = MockMacRemoteInputSystem()
        let controller = armedController(system: system)

        for point in [
            MacRemoteNormalizedPoint(x: -.infinity, y: 0),
            MacRemoteNormalizedPoint(x: .nan, y: 0),
            MacRemoteNormalizedPoint(x: -0.001, y: 0.5),
            MacRemoteNormalizedPoint(x: 0.5, y: 1.001)
        ] {
            XCTAssertEqual(
                controller.handleTap(
                    screenRequestID: showID,
                    inputSessionID: sessionID,
                    normalizedPoint: point
                ),
                .rejected(.invalidPoint)
            )
        }
        XCTAssertTrue(system.postedMousePoints.isEmpty)
    }

    func testPrimaryDragMapsBothPointsAndPostsDownDragUpInOrder() {
        let system = MockMacRemoteInputSystem()
        system.bounds = CGRect(x: -1_920, y: -400, width: 1_920, height: 1_080)
        let controller = armedController(system: system)

        XCTAssertEqual(
            drag(
                controller,
                start: .init(x: 0.25, y: 0.75),
                end: .init(x: 0.75, y: 0.25)
            ),
            .accepted(.none)
        )

        XCTAssertEqual(system.postedDragEvents.count, 8)
        guard case .down(let down) = system.postedDragEvents[0],
              case .dragged(let firstDragged) = system.postedDragEvents[1],
              case .dragged(let finalDragged) = system.postedDragEvents[6],
              case .up(let up) = system.postedDragEvents[7] else {
            return XCTFail("Expected one complete down-dragged-path-up sequence")
        }
        XCTAssertEqual(down.x, -1_440, accuracy: 0.0001)
        XCTAssertEqual(down.y, 410, accuracy: 0.0001)
        XCTAssertEqual(firstDragged.x, -1_280, accuracy: 0.0001)
        XCTAssertEqual(firstDragged.y, 320, accuracy: 0.0001)
        XCTAssertEqual(finalDragged.x, -480, accuracy: 0.0001)
        XCTAssertEqual(finalDragged.y, -130, accuracy: 0.0001)
        XCTAssertEqual(up.x, finalDragged.x, accuracy: 0.0001)
        XCTAssertEqual(up.y, finalDragged.y, accuracy: 0.0001)
    }

    func testPrimaryDragRejectsStaleShowAndInputSession() {
        let system = MockMacRemoteInputSystem()
        let controller = armedController(system: system)

        XCTAssertEqual(
            controller.handlePrimaryDrag(
                screenRequestID: showID + 1,
                inputSessionID: sessionID,
                start: .init(x: 0.1, y: 0.2),
                end: .init(x: 0.8, y: 0.9)
            ),
            .rejected(.staleSession)
        )
        XCTAssertEqual(
            controller.handlePrimaryDrag(
                screenRequestID: showID,
                inputSessionID: UUID(),
                start: .init(x: 0.1, y: 0.2),
                end: .init(x: 0.8, y: 0.9)
            ),
            .rejected(.staleSession)
        )
        XCTAssertTrue(system.postedDragEvents.isEmpty)
    }

    func testPrimaryDragValidatesBothPointsBeforeInjection() {
        let system = MockMacRemoteInputSystem()
        let controller = armedController(system: system)
        let valid = MacRemoteNormalizedPoint(x: 0.5, y: 0.5)

        for (start, end) in [
            (MacRemoteNormalizedPoint(x: .nan, y: 0.2), valid),
            (MacRemoteNormalizedPoint(x: -0.001, y: 0.2), valid),
            (valid, MacRemoteNormalizedPoint(x: 0.2, y: .infinity)),
            (valid, MacRemoteNormalizedPoint(x: 0.2, y: 1.001))
        ] {
            XCTAssertEqual(
                drag(controller, start: start, end: end),
                .rejected(.invalidPoint)
            )
        }
        XCTAssertTrue(system.postedDragEvents.isEmpty)
    }

    func testPrimaryDragRechecksPermissionsAndDisplay() {
        let system = MockMacRemoteInputSystem()
        let controller = armedController(system: system)

        system.permissions = .init(accessibilityTrusted: false, postEventAllowed: true)
        XCTAssertEqual(drag(controller), .rejected(.permissionRequired))
        XCTAssertTrue(system.postedDragEvents.isEmpty)

        // Permission loss revokes the bound session.
        system.permissions = .init(accessibilityTrusted: true, postEventAllowed: true)
        XCTAssertEqual(drag(controller), .rejected(.staleSession))

        XCTAssertEqual(
            controller.arm(displayID: displayID, screenRequestID: showID, inputSessionID: sessionID),
            .armed
        )
        system.bounds = nil
        XCTAssertEqual(drag(controller), .rejected(.displayUnavailable))
        XCTAssertTrue(system.postedDragEvents.isEmpty)
    }

    func testPrimaryDragSharesTapRateLimitBudget() {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        let controller = armedController(system: system, clock: clock)

        for _ in 0..<11 {
            XCTAssertEqual(tap(controller), .accepted(.none))
        }
        XCTAssertEqual(drag(controller), .accepted(.none))
        XCTAssertEqual(drag(controller), .rejected(.rateLimited))
        XCTAssertEqual(system.postedMousePoints.count, 11)
        XCTAssertEqual(system.postedDragEvents.count, 8)

        clock.advance(by: 0.125)
        XCTAssertEqual(drag(controller), .accepted(.none))
    }

    func testPrimaryDragGrantsOnlySameNonsecureEditableFocus() {
        let system = MockMacRemoteInputSystem()
        let field = system.makeElement(role: "AXTextArea", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        let controller = armedController(system: system)

        XCTAssertEqual(
            drag(controller),
            .accepted(.editable(generation: 1, secure: false))
        )
        XCTAssertEqual(
            text(controller, generation: 1, value: "selected replacement"),
            .accepted(.editable(generation: 1, secure: false))
        )

        let secure = system.makeElement(
            role: "AXTextField",
            subrole: "AXSecureTextField",
            settable: true
        )
        system.hitElement = secure
        system.currentFocusedElement = secure
        XCTAssertEqual(drag(controller), .accepted(.none))
        XCTAssertEqual(
            text(controller, generation: 1, value: "must stay local"),
            .rejected(.focusChanged)
        )
        XCTAssertEqual(system.postedTexts, ["selected replacement"])
    }

    func testPrimaryDragRejectsWhilePhysicalPrimaryButtonIsHeld() {
        let system = MockMacRemoteInputSystem()
        system.physicalPrimaryButtonPressed = true
        let controller = armedController(system: system)

        XCTAssertEqual(drag(controller), .rejected(.primaryButtonInUse))
        XCTAssertTrue(system.postedDragEvents.isEmpty)

        system.physicalPrimaryButtonPressed = false
        XCTAssertEqual(drag(controller), .accepted(.none))
        XCTAssertEqual(system.postedDragEvents.count, 8)
    }

    func testEveryPrimaryDragClearsPriorKeyboardFocusEvenWhenInvalid() {
        let system = MockMacRemoteInputSystem()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        let controller = armedController(system: system)
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        XCTAssertEqual(
            drag(controller, end: .init(x: 2, y: 0.5)),
            .rejected(.invalidPoint)
        )
        XCTAssertEqual(
            text(controller, generation: 1, value: "blocked"),
            .rejected(.focusChanged)
        )
        XCTAssertTrue(system.postedDragEvents.isEmpty)
    }

    func testPrimaryDragBackendFailureIsAllOrNoneAndGrantsNoFocus() {
        let system = MockMacRemoteInputSystem()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        system.dragPostSucceeds = false
        let controller = armedController(system: system)

        XCTAssertEqual(drag(controller), .rejected(.injectionFailed))
        XCTAssertTrue(system.postedDragEvents.isEmpty)
        XCTAssertEqual(
            text(controller, generation: 1, value: "blocked"),
            .rejected(.focusChanged)
        )

        system.dragPostSucceeds = true
        XCTAssertEqual(
            drag(controller),
            .accepted(.editable(generation: 1, secure: false))
        )
        XCTAssertEqual(system.postedDragEvents.count, 8)
    }

    func testSecureEditableAncestorNeverGrantsRemoteKeyboardFocus() {
        let system = MockMacRemoteInputSystem()
        let hitChild = system.makeElement(role: "AXStaticText", settable: false)
        let focusedFieldEditor = system.makeElement(role: "AXGroup", settable: false)
        let secureField = system.makeElement(
            role: "AXTextField",
            subrole: "AXSecureTextField",
            settable: true
        )
        let editableContainer = system.makeElement(role: "AXTextArea", settable: true)
        system.setParent(secureField, of: hitChild)
        system.setParent(secureField, of: focusedFieldEditor)
        system.setParent(editableContainer, of: secureField)
        system.hitElement = hitChild
        system.currentFocusedElement = focusedFieldEditor
        let controller = armedController(system: system)

        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: .init(x: 0.4, y: 0.3)
            ),
            .accepted(.none)
        )
        XCTAssertEqual(
            text(controller, generation: 1, value: "canonical focus"),
            .rejected(.focusChanged)
        )
        XCTAssertEqual(system.postedMousePoints.count, 1)
        XCTAssertTrue(system.postedTexts.isEmpty)
    }

    func testAuthorizedFieldBecomingSecureRevokesTextAndKeyInjection() {
        let system = MockMacRemoteInputSystem()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        let controller = armedController(system: system)

        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        system.setSubrole("AXSecureTextField", of: field)
        XCTAssertEqual(
            text(controller, generation: 1, value: "must stay local"),
            .rejected(.focusChanged)
        )
        XCTAssertEqual(
            controller.pressKey(
                screenRequestID: showID,
                inputSessionID: sessionID,
                focusGeneration: 1,
                key: .returnKey
            ),
            .rejected(.focusChanged)
        )
        XCTAssertTrue(system.postedTexts.isEmpty)
        XCTAssertTrue(system.postedKeys.isEmpty)
    }

    func testClickingAnotherElementClearsOldKeyboardGrant() {
        let system = MockMacRemoteInputSystem()
        let first = system.makeElement(role: "AXTextField", settable: true)
        let second = system.makeElement(role: "AXTextArea", settable: true)
        system.hitElement = first
        system.currentFocusedElement = first
        let controller = armedController(system: system)

        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        system.hitElement = second
        system.currentFocusedElement = first
        XCTAssertEqual(tap(controller), .accepted(.none))
        XCTAssertEqual(
            controller.insertText(
                screenRequestID: showID,
                inputSessionID: sessionID,
                focusGeneration: 1,
                text: "must not be injected"
            ),
            .rejected(.focusChanged)
        )
        XCTAssertTrue(system.postedTexts.isEmpty)
    }

    func testTextAndExplicitKeysAreInjectedOnlyWhileExactElementRemainsFocused() {
        let system = MockMacRemoteInputSystem()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        let controller = armedController(system: system)
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        XCTAssertEqual(
            controller.insertText(
                screenRequestID: showID,
                inputSessionID: sessionID,
                focusGeneration: 1,
                text: "Hello 👋"
            ),
            .accepted(.editable(generation: 1, secure: false))
        )
        XCTAssertEqual(
            controller.pressKey(
                screenRequestID: showID,
                inputSessionID: sessionID,
                focusGeneration: 1,
                key: .backspace
            ),
            .accepted(.editable(generation: 1, secure: false))
        )
        XCTAssertEqual(
            controller.pressKey(
                screenRequestID: showID,
                inputSessionID: sessionID,
                focusGeneration: 1,
                key: .returnKey
            ),
            .accepted(.editable(generation: 1, secure: false))
        )
        XCTAssertEqual(system.postedTexts, ["Hello 👋"])
        XCTAssertEqual(system.postedKeys, [.backspace, .returnKey])

        let other = system.makeElement(role: "AXTextField", settable: true)
        system.currentFocusedElement = other
        XCTAssertEqual(
            controller.insertText(
                screenRequestID: showID,
                inputSessionID: sessionID,
                focusGeneration: 1,
                text: "blocked"
            ),
            .rejected(.focusChanged)
        )
        XCTAssertEqual(system.postedTexts, ["Hello 👋"])
    }

    func testStaleShowSessionGenerationAndRevocationCannotInject() {
        let system = MockMacRemoteInputSystem()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        let controller = armedController(system: system)
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        XCTAssertEqual(
            controller.insertText(
                screenRequestID: showID + 1,
                inputSessionID: sessionID,
                focusGeneration: 1,
                text: "wrong show"
            ),
            .rejected(.staleSession)
        )
        XCTAssertTrue(system.postedTexts.isEmpty)

        // Retap because any rejected keyboard request fail-closes its focus grant.
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 2, secure: false)))
        XCTAssertEqual(
            controller.pressKey(
                screenRequestID: showID,
                inputSessionID: UUID(),
                focusGeneration: 2,
                key: .returnKey
            ),
            .rejected(.staleSession)
        )
        XCTAssertTrue(system.postedKeys.isEmpty)

        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 3, secure: false)))
        XCTAssertEqual(
            controller.pressKey(
                screenRequestID: showID,
                inputSessionID: sessionID,
                focusGeneration: 2,
                key: .returnKey
            ),
            .rejected(.focusChanged)
        )

        controller.revoke()
        XCTAssertEqual(tap(controller), .rejected(.staleSession))
        XCTAssertEqual(system.postedMousePoints.count, 3)
    }

    func testPermissionsAreRecheckedForEveryAction() {
        let system = MockMacRemoteInputSystem()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        let controller = armedController(system: system)
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        system.permissions = .init(accessibilityTrusted: false, postEventAllowed: true)
        XCTAssertEqual(
            controller.insertText(
                screenRequestID: showID,
                inputSessionID: sessionID,
                focusGeneration: 1,
                text: "blocked"
            ),
            .rejected(.permissionRequired)
        )
        XCTAssertTrue(system.postedTexts.isEmpty)

        // Losing either grant revokes the entire session, so restoring permission cannot
        // silently revive the old capability without a fresh acknowledged Show.
        system.permissions = .init(accessibilityTrusted: true, postEventAllowed: true)
        XCTAssertEqual(tap(controller), .rejected(.staleSession))
        XCTAssertEqual(system.postedMousePoints.count, 1)
    }

    func testExplicitlyEditableNonstandardAXRoleCanReceiveText() {
        let system = MockMacRemoteInputSystem()
        let contentEditable = system.makeElement(
            role: "AXWebArea",
            settable: false,
            editable: true
        )
        system.hitElement = contentEditable
        system.currentFocusedElement = contentEditable
        let controller = armedController(system: system)

        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))
        XCTAssertEqual(
            text(controller, generation: 1, value: "content editable"),
            .accepted(.editable(generation: 1, secure: false))
        )
    }

    func testSettableTextAreaMayOmitAXEnabledButExplicitlyDisabledFieldIsRejected() {
        let system = MockMacRemoteInputSystem()
        let textArea = system.makeElement(
            role: "AXTextArea",
            enabled: nil,
            settable: true
        )
        system.hitElement = textArea
        system.currentFocusedElement = textArea
        let controller = armedController(system: system)

        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))
        XCTAssertEqual(
            text(controller, generation: 1, value: "TextEdit compatible"),
            .accepted(.editable(generation: 1, secure: false))
        )

        let disabledField = system.makeElement(
            role: "AXTextField",
            enabled: false,
            settable: true
        )
        system.hitElement = disabledField
        system.currentFocusedElement = disabledField
        XCTAssertEqual(tap(controller), .accepted(.none))
    }

    func testTextValidationEnforcesEncodingCapsAndRejectsControlAndFunctionKeyRanges() {
        XCTAssertNil(MacRemoteInputController.validatedTextByteCount(""))
        XCTAssertNil(MacRemoteInputController.validatedTextByteCount("line\nbreak"))
        XCTAssertNil(MacRemoteInputController.validatedTextByteCount("tab\there"))
        XCTAssertNil(MacRemoteInputController.validatedTextByteCount("C1\u{0085}"))
        XCTAssertNil(MacRemoteInputController.validatedTextByteCount("function\u{F700}"))
        XCTAssertNil(MacRemoteInputController.validatedTextByteCount("function\u{F8FF}"))
        XCTAssertNil(MacRemoteInputController.validatedTextByteCount(String(repeating: "a", count: 513)))
        XCTAssertNil(MacRemoteInputController.validatedTextByteCount(String(repeating: "😀", count: 129)))

        XCTAssertNil(
            MacRemoteInputController.validatedTextByteCount(String(repeating: "a", count: 512))
        )
        XCTAssertEqual(
            MacRemoteInputController.validatedTextByteCount(String(repeating: "é", count: 256)),
            512
        )
        XCTAssertEqual(MacRemoteInputController.validatedTextByteCount("ordinary text"), 13)
    }

    func testTapBucketHasDocumentedBurstAndMonotonicRefill() {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        let controller = armedController(system: system, clock: clock)

        for _ in 0..<12 {
            XCTAssertEqual(tap(controller), .accepted(.none))
        }
        XCTAssertEqual(tap(controller), .rejected(.rateLimited))
        XCTAssertEqual(system.postedMousePoints.count, 12)

        clock.advance(by: 0.125)
        XCTAssertEqual(tap(controller), .accepted(.none))
        XCTAssertEqual(tap(controller), .rejected(.rateLimited))

        // A regressing clock must never mint tokens.
        clock.advance(by: -10)
        XCTAssertEqual(tap(controller), .rejected(.rateLimited))
    }

    func testKeyBucketHasDocumentedBurstAndRefill() {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        let controller = armedController(system: system, clock: clock)
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        for _ in 0..<40 {
            XCTAssertEqual(key(controller, generation: 1), .accepted(.editable(generation: 1, secure: false)))
        }
        XCTAssertEqual(key(controller, generation: 1), .rejected(.rateLimited))
        XCTAssertEqual(system.postedKeys.count, 40)

        // Reauthorize focus, then one key token refills in 1/25 second.
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 2, secure: false)))
        clock.advance(by: 0.04)
        XCTAssertEqual(key(controller, generation: 2), .accepted(.editable(generation: 2, secure: false)))
    }

    func testTextBucketChargesUTF8BytesWithDocumentedBurstAndRefill() {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        let field = system.makeElement(role: "AXTextArea", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        let controller = armedController(system: system, clock: clock)
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        let chunk = String(repeating: "é", count: 256)
        for _ in 0..<8 {
            XCTAssertEqual(
                text(controller, generation: 1, value: chunk),
                .accepted(.editable(generation: 1, secure: false))
            )
        }
        XCTAssertEqual(text(controller, generation: 1, value: "x"), .rejected(.rateLimited))
        XCTAssertEqual(system.postedTexts.count, 8)

        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 2, secure: false)))
        clock.advance(by: 1.0 / 2_048.0)
        XCTAssertEqual(
            text(controller, generation: 2, value: "x"),
            .accepted(.editable(generation: 2, secure: false))
        )
    }

    func testPostClickFocusPollingIsBoundedToFiftyMilliseconds() {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = nil
        let controller = armedController(system: system, clock: clock)

        XCTAssertEqual(tap(controller), .accepted(.none))
        XCTAssertLessThanOrEqual(clock.totalSlept, 0.050_001)
        XCTAssertGreaterThan(clock.totalSlept, 0)
        XCTAssertLessThanOrEqual(clock.sleepCalls, 10)
    }

    func testPollingCanObserveDelayedFocusButNeverAuthorizesDifferentEditableElement() {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        let target = system.makeElement(role: "AXTextField", settable: true)
        let other = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = target
        system.focusSequence = [nil, other, target]
        let controller = armedController(system: system, clock: clock)

        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))
        XCTAssertEqual(clock.sleepCalls, 2)

        system.hitElement = target
        system.focusSequence = Array(repeating: other, count: 11)
        XCTAssertEqual(tap(controller), .accepted(.none))
    }

    func testRearmingCreatesAFreshAuthorizationDomainAndResetsGeneration() {
        let system = MockMacRemoteInputSystem()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        let controller = armedController(system: system)
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        let newSession = UUID()
        XCTAssertEqual(
            controller.arm(displayID: displayID, screenRequestID: showID + 1, inputSessionID: newSession),
            .armed
        )
        XCTAssertEqual(tap(controller), .rejected(.staleSession))
        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID + 1,
                inputSessionID: newSession,
                normalizedPoint: .init(x: 0.5, y: 0.5)
            ),
            .accepted(.editable(generation: 1, secure: false))
        )
    }

    func testBackendFailuresDoNotLeaveAKeyboardGrant() {
        let system = MockMacRemoteInputSystem()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        system.mousePostSucceeds = false
        let controller = armedController(system: system)

        XCTAssertEqual(tap(controller), .rejected(.injectionFailed))
        system.mousePostSucceeds = true
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        system.textPostSucceeds = false
        XCTAssertEqual(text(controller, generation: 1, value: "blocked"), .rejected(.injectionFailed))
        system.textPostSucceeds = true
        XCTAssertEqual(text(controller, generation: 1, value: "still blocked"), .rejected(.focusChanged))
        XCTAssertTrue(system.postedTexts.isEmpty)
    }

    private func makeController(
        system: MockMacRemoteInputSystem,
        clock: MockMacRemoteInputClock = .init()
    ) -> MacRemoteInputController {
        MacRemoteInputController(allowRemoteControl: true, system: system, clock: clock)
    }

    private func armedController(
        system: MockMacRemoteInputSystem,
        clock: MockMacRemoteInputClock = .init()
    ) -> MacRemoteInputController {
        let controller = makeController(system: system, clock: clock)
        XCTAssertEqual(
            controller.arm(displayID: displayID, screenRequestID: showID, inputSessionID: sessionID),
            .armed
        )
        return controller
    }

    private func tap(_ controller: MacRemoteInputController) -> MacRemoteInputResult {
        controller.handleTap(
            screenRequestID: showID,
            inputSessionID: sessionID,
            normalizedPoint: .init(x: 0.5, y: 0.5)
        )
    }

    private func drag(
        _ controller: MacRemoteInputController,
        start: MacRemoteNormalizedPoint = .init(x: 0.25, y: 0.25),
        end: MacRemoteNormalizedPoint = .init(x: 0.75, y: 0.75)
    ) -> MacRemoteInputResult {
        controller.handlePrimaryDrag(
            screenRequestID: showID,
            inputSessionID: sessionID,
            start: start,
            end: end
        )
    }

    private func key(
        _ controller: MacRemoteInputController,
        generation: UInt64
    ) -> MacRemoteInputResult {
        controller.pressKey(
            screenRequestID: showID,
            inputSessionID: sessionID,
            focusGeneration: generation,
            key: .backspace
        )
    }

    private func text(
        _ controller: MacRemoteInputController,
        generation: UInt64,
        value: String
    ) -> MacRemoteInputResult {
        controller.insertText(
            screenRequestID: showID,
            inputSessionID: sessionID,
            focusGeneration: generation,
            text: value
        )
    }
}

private final class MockMacRemoteInputClock: @unchecked Sendable, MacRemoteInputClock {
    private(set) var time: TimeInterval = 100
    private(set) var totalSlept: TimeInterval = 0
    private(set) var sleepCalls = 0

    func now() -> TimeInterval {
        time
    }

    func sleep(for interval: TimeInterval) {
        sleepCalls += 1
        totalSlept += interval
        time += interval
    }

    func advance(by interval: TimeInterval) {
        time += interval
    }
}

private final class MockMacRemoteInputSystem: @unchecked Sendable, MacRemoteInputSystem {
    enum PostedDragEvent: Equatable {
        case down(CGPoint)
        case dragged(CGPoint)
        case up(CGPoint)
    }

    struct Node {
        var parent: MacRemoteAccessibilityElement?
        var role: String?
        var subrole: String?
        var enabled: Bool?
        var settable: Bool
        var editable: Bool?
    }

    var permissions = MacRemoteInputPermissionStatus(
        accessibilityTrusted: true,
        postEventAllowed: true
    )
    var bounds: CGRect? = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
    var physicalPrimaryButtonPressed = false
    var hitElement: MacRemoteAccessibilityElement?
    var currentFocusedElement: MacRemoteAccessibilityElement?
    var focusSequence: [MacRemoteAccessibilityElement?] = []

    var mousePostSucceeds = true
    var dragPostSucceeds = true
    var textPostSucceeds = true
    var keyPostSucceeds = true

    private(set) var postedMousePoints: [CGPoint] = []
    private(set) var postedDragEvents: [PostedDragEvent] = []
    private(set) var postedTexts: [String] = []
    private(set) var postedKeys: [MacRemoteInputKey] = []
    private var nodes: [ObjectIdentifier: Node] = [:]

    func makeElement(
        role: String?,
        subrole: String? = nil,
        enabled: Bool? = true,
        settable: Bool,
        editable: Bool? = nil
    ) -> MacRemoteAccessibilityElement {
        let element = MacRemoteAccessibilityElement(rawValue: NSObject())
        nodes[ObjectIdentifier(element)] = Node(
            role: role,
            subrole: subrole,
            enabled: enabled,
            settable: settable,
            editable: editable
        )
        return element
    }

    func setParent(
        _ parent: MacRemoteAccessibilityElement,
        of child: MacRemoteAccessibilityElement
    ) {
        nodes[ObjectIdentifier(child)]?.parent = parent
    }

    func setSubrole(
        _ subrole: String?,
        of element: MacRemoteAccessibilityElement
    ) {
        nodes[ObjectIdentifier(element)]?.subrole = subrole
    }

    func permissionStatus(promptIfNeeded _: Bool) -> MacRemoteInputPermissionStatus {
        permissions
    }

    func displayBounds(for _: UInt32) -> CGRect? {
        bounds
    }

    func isPhysicalPrimaryButtonPressed() -> Bool {
        physicalPrimaryButtonPressed
    }

    func element(at _: CGPoint) -> MacRemoteAccessibilityElement? {
        hitElement
    }

    func parent(of element: MacRemoteAccessibilityElement) -> MacRemoteAccessibilityElement? {
        nodes[ObjectIdentifier(element)]?.parent
    }

    func role(of element: MacRemoteAccessibilityElement) -> String? {
        nodes[ObjectIdentifier(element)]?.role
    }

    func subrole(of element: MacRemoteAccessibilityElement) -> String? {
        nodes[ObjectIdentifier(element)]?.subrole
    }

    func isEnabled(_ element: MacRemoteAccessibilityElement) -> Bool? {
        nodes[ObjectIdentifier(element)]?.enabled
    }

    func isEditable(_ element: MacRemoteAccessibilityElement) -> Bool? {
        nodes[ObjectIdentifier(element)]?.editable
    }

    func isValueSettable(_ element: MacRemoteAccessibilityElement) -> Bool {
        nodes[ObjectIdentifier(element)]?.settable ?? false
    }

    func focusedElement() -> MacRemoteAccessibilityElement? {
        if !focusSequence.isEmpty {
            return focusSequence.removeFirst()
        }
        return currentFocusedElement
    }

    func elementsEqual(
        _ lhs: MacRemoteAccessibilityElement,
        _ rhs: MacRemoteAccessibilityElement
    ) -> Bool {
        lhs === rhs
    }

    func postMouseClick(at point: CGPoint) -> Bool {
        guard mousePostSucceeds else { return false }
        postedMousePoints.append(point)
        return true
    }

    func postPrimaryDrag(from start: CGPoint, to end: CGPoint) -> Bool {
        guard dragPostSucceeds else { return false }
        postedDragEvents.append(.down(start))
        postedDragEvents.append(
            contentsOf: MacRemoteInputDragPath.points(from: start, to: end).map {
                .dragged($0)
            }
        )
        postedDragEvents.append(.up(end))
        return true
    }

    func postUnicodeText(_ text: String) -> Bool {
        guard textPostSucceeds else { return false }
        postedTexts.append(text)
        return true
    }

    func postKey(_ key: MacRemoteInputKey) -> Bool {
        guard keyPostSucceeds else { return false }
        postedKeys.append(key)
        return true
    }
}
