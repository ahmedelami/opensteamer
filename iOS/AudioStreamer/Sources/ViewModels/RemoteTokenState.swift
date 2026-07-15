import Combine
import Foundation

@MainActor
final class RemoteTokenState: ObservableObject {
    @Published var token = "" {
        didSet {
            guard !isApplyingLoadedValue else { return }
            hasUnpersistedUserEdit = true
            persistUserEditIfSafe()
        }
    }

    @Published private(set) var storageError: String?
    @Published private(set) var isStored = false

    private let store: any RemoteTokenStoring
    private var loadState = LoadState.notLoaded
    private var isApplyingLoadedValue = false
    private var hasUnpersistedUserEdit = false

    init(store: any RemoteTokenStoring = KeychainStore()) {
        self.store = store
    }

    func loadIfNeeded() {
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
            storageError = "The saved activation code could not be loaded securely."
        }
    }

    func persistNow() {
        persistUserEditIfSafe()
    }

    private func persistUserEditIfSafe() {
        guard hasUnpersistedUserEdit else { return }

        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // After a failed read, an empty field is not proof that the user intentionally removed
        // the existing Keychain item. Require a successful load or a non-empty replacement.
        guard loadState == .loaded || !trimmed.isEmpty else { return }

        do {
            try store.saveRemoteToken(token)
            loadState = .loaded
            hasUnpersistedUserEdit = false
            isStored = !trimmed.isEmpty
            storageError = nil
        } catch {
            isStored = false
            storageError = "The activation code could not be saved securely."
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
