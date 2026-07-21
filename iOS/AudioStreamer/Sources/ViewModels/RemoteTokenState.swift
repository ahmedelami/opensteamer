import Combine
import Foundation

/// Main-actor bridge between an editable credential field and durable Keychain storage.
///
/// Non-empty edits persist eagerly. Empty values are ignored unless the user invokes the explicit
/// clear action, preventing SwiftUI reconstruction, protected-data transitions, and app updates
/// from accidentally deleting the last usable credential.
@MainActor
final class RemoteTokenState: ObservableObject {
    @Published var token = "" {
        didSet {
            guard !isApplyingLoadedValue else { return }
            // Empty text is not proof of intentional deletion. Updates, SwiftUI field
            // replacement, and protected-data transitions may briefly publish it.
            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            hasUnpersistedUserEdit = true
            persistUserEditIfSafe()
        }
    }

    @Published private(set) var storageError: String?
    @Published private(set) var isStored = false

    private let store: any RemoteTokenStoring
    private let codeDisplayName: String
    private var loadState = LoadState.notLoaded
    private var isApplyingLoadedValue = false
    private var hasUnpersistedUserEdit = false

    init(
        store: any RemoteTokenStoring = KeychainStore(),
        codeDisplayName: String = "activation code"
    ) {
        self.store = store
        self.codeDisplayName = codeDisplayName
        // Hydrate before SwiftUI constructs its text field. This removes the launch/update
        // window in which an initially empty binding could win over the stored value.
        loadIfNeeded()
    }

    func loadIfNeeded() {
        // A local edit always wins over a late retry of failed Keychain hydration.
        guard loadState != .loaded, !hasUnpersistedUserEdit else { return }
        loadState = .loading

        do {
            isApplyingLoadedValue = true
            token = try store.loadRemoteToken() ?? ""
            isApplyingLoadedValue = false
            loadState = .loaded
            isStored = !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            storageError = nil
        } catch {
            isApplyingLoadedValue = false
            loadState = .failed
            // A protected-data or Keychain failure is not evidence that the user cleared the
            // credential. Leave the stored item untouched and surface a recoverable error.
            storageError = "The saved \(codeDisplayName) could not be loaded securely."
        }
    }

    func persistNow() {
        persistUserEditIfSafe()
    }

    /// Deletes the durable credential and only clears the binding after deletion succeeds.
    @discardableResult
    func clearSavedCode() -> Bool {
        do {
            try store.deleteRemoteToken()
            isApplyingLoadedValue = true
            token = ""
            isApplyingLoadedValue = false
            loadState = .loaded
            hasUnpersistedUserEdit = false
            isStored = false
            storageError = nil
            return true
        } catch {
            isApplyingLoadedValue = false
            storageError = "The saved \(codeDisplayName) could not be cleared securely."
            return false
        }
    }

    private func persistUserEditIfSafe() {
        guard hasUnpersistedUserEdit else { return }

        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            try store.saveRemoteToken(token)
            loadState = .loaded
            hasUnpersistedUserEdit = false
            isStored = !trimmed.isEmpty
            storageError = nil
        } catch {
            isStored = false
            storageError = "The \(codeDisplayName) could not be saved securely."
        }
    }
}

private extension RemoteTokenState {
    enum LoadState {
        case notLoaded
        case loading
        case loaded
        case failed
    }
}
