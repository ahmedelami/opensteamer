import SwiftUI
import UIKit
import XCTest
@testable import opensteamer

/// Exercises the UIKit responder bridge without involving SwiftUI presentation timing.
/// The security-critical oracles are generation-bound callbacks, no mirrored remote text, secure
/// focus remaining closed, and exactly one Return action for software or hardware keyboards.
final class RemoteKeyboardInputProxyTests: XCTestCase {
    @MainActor
    func testSecureHostFocusIsNotEligibleForRemoteKeyboard() {
        XCTAssertNil(
            WorldwideSessionViewModel.remoteKeyboardGeneration(
                for: .editable(generation: 8, secure: true)
            )
        )
        XCTAssertEqual(
            WorldwideSessionViewModel.remoteKeyboardGeneration(
                for: .editable(generation: 9, secure: false)
            ),
            9
        )
        XCTAssertNil(WorldwideSessionViewModel.remoteKeyboardGeneration(for: .none))
    }

    func testPendingFeedbackMetadataDoesNotRetainCommittedText() {
        let sensitiveText = "never-retain-this-credential"
        let metadata = PendingRemoteInputKind(
            .insertText(sensitiveText, focusGeneration: 23)
        )

        XCTAssertEqual(metadata, .keyboard(focusGeneration: 23))
        XCTAssertFalse(String(reflecting: metadata).contains(sensitiveText))
    }

    func testTapAndPrimaryDragUsePointerFeedbackMetadata() {
        XCTAssertEqual(
            PendingRemoteInputKind(.tap(.init(x: 0.5, y: 0.5))),
            .pointer
        )
        XCTAssertEqual(
            PendingRemoteInputKind(
                .primaryDrag(
                    start: .init(x: 0.1, y: 0.2),
                    end: .init(x: 0.8, y: 0.9)
                )
            ),
            .pointer
        )
    }

    @MainActor
    func testInsertTextForwardsExactChunkWithCurrentFocusGeneration() {
        let proxy = RemoteKeyboardInputProxy(frame: .zero)
        var insertions: [(text: String, generation: UInt64)] = []
        proxy.inputAvailable = true
        proxy.focusGeneration = 41
        proxy.onInsertText = { text, generation in
            insertions.append((text, generation))
        }

        proxy.insertText("hello")
        proxy.focusGeneration = 42
        proxy.insertText(" world")
        proxy.insertText("")

        XCTAssertEqual(insertions.map(\.text), ["hello", " world"])
        XCTAssertEqual(insertions.map(\.generation), [41, 42])
    }

    @MainActor
    func testFunctionKeyScalarsRejectTheWholeCommittedTextChunk() {
        let proxy = RemoteKeyboardInputProxy(frame: .zero)
        var insertedTexts: [String] = []
        proxy.inputAvailable = true
        proxy.focusGeneration = 43
        proxy.onInsertText = { text, _ in insertedTexts.append(text) }

        proxy.insertText("safe\u{F700}text")
        proxy.insertText("safe\u{F8FF}text")
        proxy.insertText("ordinary \u{E000} private-use text")

        XCTAssertEqual(insertedTexts, ["ordinary \u{E000} private-use text"])
    }

    @MainActor
    func testInputCallbacksFailClosedWithoutAvailabilityAndGeneration() {
        let proxy = RemoteKeyboardInputProxy(frame: .zero)
        var insertionCount = 0
        var deletionCount = 0
        var returnCount = 0
        proxy.onInsertText = { _, _ in insertionCount += 1 }
        proxy.onDeleteBackward = { _ in deletionCount += 1 }
        proxy.onReturn = { _ in returnCount += 1 }

        proxy.focusGeneration = 1
        proxy.insertText("ignored")
        proxy.deleteBackward()
        proxy.insertText("\n")

        proxy.inputAvailable = true
        proxy.focusGeneration = nil
        proxy.insertText("ignored")
        proxy.deleteBackward()
        proxy.insertText("\n")

        XCTAssertEqual(insertionCount, 0)
        XCTAssertEqual(deletionCount, 0)
        XCTAssertEqual(returnCount, 0)
    }

    @MainActor
    func testReturnVariantsMapOnlyToReturnCallback() {
        let proxy = RemoteKeyboardInputProxy(frame: .zero)
        var insertedTexts: [String] = []
        var returnedGenerations: [UInt64] = []
        proxy.inputAvailable = true
        proxy.focusGeneration = 7
        proxy.onInsertText = { text, _ in insertedTexts.append(text) }
        proxy.onReturn = { returnedGenerations.append($0) }

        proxy.insertText("\n")
        proxy.insertText("\r")
        proxy.insertText("\r\n")

        XCTAssertTrue(insertedTexts.isEmpty)
        XCTAssertEqual(returnedGenerations, [7, 7, 7])
        XCTAssertEqual(proxy.returnKeyType, .send)
    }

    @MainActor
    func testDeleteBackwardForwardsCurrentFocusGeneration() {
        let proxy = RemoteKeyboardInputProxy(frame: .zero)
        var deletedGenerations: [UInt64] = []
        proxy.inputAvailable = true
        proxy.focusGeneration = 10
        proxy.onDeleteBackward = { deletedGenerations.append($0) }

        proxy.deleteBackward()
        proxy.focusGeneration = 11
        proxy.deleteBackward()

        XCTAssertEqual(deletedGenerations, [10, 11])
    }

    @MainActor
    func testProxyDoesNotAccumulateRemoteText() {
        let proxy = RemoteKeyboardInputProxy(frame: .zero)
        var chunks: [String] = []
        proxy.inputAvailable = true
        proxy.focusGeneration = 3
        proxy.onInsertText = { text, _ in chunks.append(text) }

        proxy.insertText("private")
        proxy.insertText(" value")
        proxy.deleteBackward()

        XCTAssertEqual(chunks, ["private", " value"])
        XCTAssertTrue(proxy.hasText, "Delete remains available without mirroring remote contents")
        XCTAssertTrue(proxy.subviews.isEmpty)
        XCTAssertNil(proxy.accessibilityValue)
    }

    @MainActor
    func testSecureEntryAndPrivacyPreservingKeyboardTraits() {
        let proxy = RemoteKeyboardInputProxy(frame: .zero)

        proxy.updateSecureEntry(true)

        XCTAssertTrue(proxy.isSecureTextEntry)
        XCTAssertEqual(proxy.autocapitalizationType, .none)
        XCTAssertEqual(proxy.autocorrectionType, .no)
        XCTAssertEqual(proxy.spellCheckingType, .no)
        XCTAssertEqual(proxy.smartQuotesType, .no)
        XCTAssertEqual(proxy.smartDashesType, .no)
        XCTAssertEqual(proxy.smartInsertDeleteType, .no)
        XCTAssertNil(proxy.textContentType)
        XCTAssertFalse(proxy.enablesReturnKeyAutomatically)
        if #available(iOS 17.0, *) {
            XCTAssertEqual(proxy.inlinePredictionType, .no)
        }
        if #available(iOS 18.0, *) {
            XCTAssertEqual(proxy.mathExpressionCompletionType, .no)
            XCTAssertEqual(proxy.writingToolsBehavior, .none)
        }

        proxy.updateSecureEntry(false)
        XCTAssertFalse(proxy.isSecureTextEntry)
    }

    @MainActor
    func testResponderEligibilityAndDismantleLifecycleInWindow() {
        let proxy = RemoteKeyboardInputProxy(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        let (window, previousKeyWindow) = makeWindow(containing: proxy)
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }

        XCTAssertFalse(proxy.canBecomeFirstResponder)
        XCTAssertFalse(proxy.becomeFirstResponder())

        proxy.inputAvailable = true
        XCTAssertFalse(proxy.canBecomeFirstResponder)
        XCTAssertFalse(proxy.becomeFirstResponder())

        proxy.focusGeneration = 99
        XCTAssertTrue(proxy.canBecomeFirstResponder)
        XCTAssertTrue(proxy.becomeFirstResponder())
        XCTAssertTrue(proxy.isFirstResponder)

        var callbackInvoked = false
        proxy.onInsertText = { _, _ in callbackInvoked = true }
        proxy.onDeleteBackward = { _ in callbackInvoked = true }
        proxy.onReturn = { _ in callbackInvoked = true }

        RemoteKeyboardInputView.dismantleUIView(proxy, coordinator: ())

        XCTAssertFalse(proxy.isFirstResponder)
        XCTAssertFalse(proxy.inputAvailable)
        XCTAssertNil(proxy.focusGeneration)
        XCTAssertNil(proxy.onInsertText)
        XCTAssertNil(proxy.onDeleteBackward)
        XCTAssertNil(proxy.onReturn)

        proxy.insertText("ignored")
        proxy.deleteBackward()
        XCTAssertFalse(callbackInvoked)
    }

    @MainActor
    func testActualSwiftUIWrapperPresentsKeyboardFromHitTestingDisabledOnePointView() async throws {
        let rootView = AnyView(
            RemoteKeyboardInputView(
                inputAvailable: true,
                focusGeneration: 314,
                isSecure: false,
                onInsertText: { _, _ in },
                onDeleteBackward: { _ in },
                onReturn: { _ in }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
        )
        let hostingController = UIHostingController(rootView: rootView)
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let previousKeyWindow = scene?.windows.first(where: \.isKeyWindow)
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
            window.frame = scene.screen.bounds
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }

        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.layoutIfNeeded()

        try await Task.sleep(for: .milliseconds(150))
        let proxy = try XCTUnwrap(
            firstSubview(of: RemoteKeyboardInputProxy.self, in: hostingController.view)
        )
        XCTAssertEqual(proxy.focusGeneration, 314)
        XCTAssertTrue(proxy.isFirstResponder)
    }

    @MainActor
    func testActualSwiftUIWrapperRejectsSecureHostFocus() async throws {
        let rootView = AnyView(
            RemoteKeyboardInputView(
                inputAvailable: true,
                focusGeneration: 315,
                isSecure: true,
                onInsertText: { _, _ in },
                onDeleteBackward: { _ in },
                onReturn: { _ in }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
        )
        let hostingController = UIHostingController(rootView: rootView)
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let previousKeyWindow = scene?.windows.first(where: \.isKeyWindow)
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
            window.frame = scene.screen.bounds
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }

        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.layoutIfNeeded()

        try await Task.sleep(for: .milliseconds(150))
        let proxy = try XCTUnwrap(
            firstSubview(of: RemoteKeyboardInputProxy.self, in: hostingController.view)
        )
        XCTAssertFalse(proxy.inputAvailable)
        XCTAssertNil(proxy.focusGeneration)
        XCTAssertFalse(proxy.isFirstResponder)
        XCTAssertFalse(proxy.isSecureTextEntry)
    }

    // MARK: - UIKit responder fixtures

    /// Attaches the proxy to a real key-window hierarchy so first-responder behavior is genuine.
    @MainActor
    private func makeWindow(containing view: UIView) -> (UIWindow, UIWindow?) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let previousKeyWindow = scene?.windows.first(where: \.isKeyWindow)
        let window: UIWindow

        if let scene {
            window = UIWindow(windowScene: scene)
            window.frame = scene.screen.bounds
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }

        let viewController = UIViewController()
        window.rootViewController = viewController
        viewController.view.addSubview(view)
        window.makeKeyAndVisible()
        viewController.view.layoutIfNeeded()
        return (window, previousKeyWindow)
    }

    @MainActor
    private func firstSubview<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) {
                return match
            }
        }
        return nil
    }
}
