import SwiftUI
import UIKit
import WebRTCTransport

/// The narrow UIKit boundary required for programmatic first-responder and `UIKeyInput` support.
struct RemoteKeyboardInputView: UIViewRepresentable {
    let inputAvailable: Bool
    let focusGeneration: UInt64?
    let isSecure: Bool
    let onInsertText: (String, UInt64) -> Void
    let onDeleteBackward: (UInt64) -> Void
    let onReturn: (UInt64) -> Void

    func makeUIView(context: Context) -> RemoteKeyboardInputProxy {
        let view = RemoteKeyboardInputProxy(frame: .zero)
        configure(view)
        return view
    }

    func updateUIView(_ view: RemoteKeyboardInputProxy, context: Context) {
        configure(view)

        let shouldBeFirstResponder = inputAvailable && !isSecure && focusGeneration != nil
        if shouldBeFirstResponder {
            // SwiftUI can update a representable before UIKit attaches it to a window. Use a
            // short bounded retry instead of silently losing the only keyboard presentation.
            view.requestFirstResponderIfEligible()
        } else {
            view.cancelPendingFirstResponderRequest()
            view.resignFirstResponder()
        }
    }

    static func dismantleUIView(_ view: RemoteKeyboardInputProxy, coordinator: Void) {
        view.cancelPendingFirstResponderRequest()
        view.inputAvailable = false
        view.focusGeneration = nil
        view.resignFirstResponder()
        view.clearCallbacks()
    }

    private func configure(_ view: RemoteKeyboardInputProxy) {
        // Secure AX controls are not remotely editable. Keep this UI boundary fail closed
        // even if an older or compromised host sends a legacy secure-focus response.
        view.inputAvailable = inputAvailable && !isSecure
        view.focusGeneration = isSecure ? nil : focusGeneration
        view.updateSecureEntry(false)
        view.onInsertText = onInsertText
        view.onDeleteBackward = onDeleteBackward
        view.onReturn = onReturn
    }
}

/// A content-less responder that turns iPhone keyboard editing operations into remote actions.
/// It never retains or mirrors the Mac field's text.
final class RemoteKeyboardInputProxy: UIView, UIKeyInput {
    private static let maximumResponderAttempts = 4
    private static let responderRetryDelay: TimeInterval = 0.025

    var inputAvailable = false
    var focusGeneration: UInt64?
    var onInsertText: ((String, UInt64) -> Void)?
    var onDeleteBackward: ((UInt64) -> Void)?
    var onReturn: ((UInt64) -> Void)?

    override var canBecomeFirstResponder: Bool {
        inputAvailable && focusGeneration != nil
    }

    private var responderAttemptGeneration: UInt64 = 0
    private var responderAttemptIsPending = false

    // `true` keeps Delete enabled without retaining sensitive remote field contents locally.
    var hasText: Bool { true }

    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .send
    var enablesReturnKeyAutomatically = false
    var isSecureTextEntry = false
    var textContentType: UITextContentType? = nil
    @available(iOS 17.0, *)
    var inlinePredictionType: UITextInlinePredictionType = .no
    @available(iOS 18.0, *)
    var mathExpressionCompletionType: UITextMathExpressionCompletionType {
        get { .no }
        set { }
    }
    @available(iOS 18.0, *)
    var writingToolsBehavior: UIWritingToolsBehavior {
        get { .none }
        set { }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    func insertText(_ text: String) {
        guard inputAvailable,
              let focusGeneration else {
            return
        }

        // UIKit normally delivers Return as a newline through UIKeyInput. Translate it into
        // a distinct key action so protocol text payloads never contain control characters.
        if text == "\n" || text == "\r" || text == "\r\n" {
            onReturn?(focusGeneration)
        } else if WebRTCInputAction.isValidCommittedText(text) {
            onInsertText?(text, focusGeneration)
        }
    }

    func deleteBackward() {
        guard inputAvailable,
              let focusGeneration else {
            return
        }
        onDeleteBackward?(focusGeneration)
    }

    func requestFirstResponderIfEligible() {
        // One bounded attempt series corresponds to the current focus generation. A later focus
        // update invalidates its generation so delayed UIKit callbacks cannot reopen the keyboard.
        guard canBecomeFirstResponder,
              !isFirstResponder,
              !responderAttemptIsPending else {
            return
        }

        responderAttemptGeneration &+= 1
        let generation = responderAttemptGeneration
        responderAttemptIsPending = true
        scheduleFirstResponderAttempt(
            generation: generation,
            remainingAttempts: Self.maximumResponderAttempts,
            delay: 0
        )
    }

    func cancelPendingFirstResponderRequest() {
        // Incrementing, rather than merely clearing the flag, fences already enqueued retries.
        responderAttemptGeneration &+= 1
        responderAttemptIsPending = false
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.count == 1,
           let press = presses.first,
           let characters = press.key?.charactersIgnoringModifiers,
           characters == "\r" || characters == "\n",
           inputAvailable,
           let focusGeneration {
            // Do not forward this press to UIKit: doing so could also invoke insertText("\n")
            // and duplicate a single hardware Return.
            onReturn?(focusGeneration)
            return
        }

        super.pressesBegan(presses, with: event)
    }

    func updateSecureEntry(_ secure: Bool) {
        guard isSecureTextEntry != secure else { return }
        isSecureTextEntry = secure
        if isFirstResponder {
            reloadInputViews()
        }
    }

    func clearCallbacks() {
        onInsertText = nil
        onDeleteBackward = nil
        onReturn = nil
    }

    private func scheduleFirstResponderAttempt(
        generation: UInt64,
        remainingAttempts: Int,
        delay: TimeInterval
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.responderAttemptIsPending,
                  self.responderAttemptGeneration == generation,
                  self.canBecomeFirstResponder else {
                return
            }

            if self.window != nil, self.becomeFirstResponder() {
                self.responderAttemptIsPending = false
                return
            }

            guard remainingAttempts > 1 else {
                self.responderAttemptIsPending = false
                return
            }
            self.scheduleFirstResponderAttempt(
                generation: generation,
                remainingAttempts: remainingAttempts - 1,
                delay: Self.responderRetryDelay
            )
        }
    }
}
