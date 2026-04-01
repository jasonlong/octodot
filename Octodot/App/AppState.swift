import AppKit
import Observation

@Observable
final class AppState {
    // Auth
    enum AuthStatus: Equatable {
        case signedOut
        case signedIn(username: String)
    }

    var authStatus: AuthStatus = .signedOut
    var isSignedIn: Bool {
        if case .signedIn = authStatus { return true }
        return false
    }

    // Notifications
    var notifications: [GitHubNotification] = []
    var selectedIndex: Int = 0
    var isPanelVisible: Bool = false
    var isSearchActive: Bool = false
    var searchQuery: String = ""
    var isLoading: Bool = false
    var errorMessage: String?

    // API
    private var apiClient: GitHubAPIClient?

    var filteredNotifications: [GitHubNotification] {
        guard !searchQuery.isEmpty else { return notifications }
        let query = searchQuery.lowercased()
        return notifications.filter {
            $0.title.lowercased().contains(query) || $0.repository.lowercased().contains(query)
        }
    }

    var selectedNotification: GitHubNotification? {
        let list = filteredNotifications
        guard selectedIndex >= 0 && selectedIndex < list.count else { return nil }
        return list[selectedIndex]
    }

    // MARK: - Init

    init() {
        if let token = KeychainHelper.loadToken() {
            apiClient = GitHubAPIClient(token: token)
            // We'll validate + load on first panel open
            // For now set signed in optimistically
            authStatus = .signedIn(username: "")
            Task { await validateAndLoad(token: token) }
        }
    }

    private func validateAndLoad(token: String) async {
        let client = GitHubAPIClient(token: token)
        do {
            let username = try await client.validateToken()
            await MainActor.run {
                self.authStatus = .signedIn(username: username)
                self.apiClient = client
            }
            await loadNotifications()
        } catch {
            await MainActor.run {
                self.authStatus = .signedOut
                self.apiClient = nil
                KeychainHelper.deleteToken()
            }
        }
    }

    // MARK: - Auth

    func signIn(token: String, username: String) {
        apiClient = GitHubAPIClient(token: token)
        authStatus = .signedIn(username: username)
        Task { await loadNotifications() }
    }

    func signOut() {
        KeychainHelper.deleteToken()
        apiClient = nil
        authStatus = .signedOut
        notifications = []
        selectedIndex = 0
    }

    // MARK: - Data loading

    func loadNotifications() async {
        guard let client = apiClient else { return }
        await MainActor.run { isLoading = true }
        do {
            let fetched = try await client.fetchNotifications()
            await MainActor.run {
                self.notifications = fetched
                self.isLoading = false
                self.errorMessage = nil
                clampSelection()
            }
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Navigation

    func moveDown() {
        let count = filteredNotifications.count
        guard count > 0 else { return }
        selectedIndex = min(selectedIndex + 1, count - 1)
    }

    func moveUp() {
        guard filteredNotifications.count > 0 else { return }
        selectedIndex = max(selectedIndex - 1, 0)
    }

    func jumpToTop() {
        guard filteredNotifications.count > 0 else { return }
        selectedIndex = 0
    }

    func jumpToBottom() {
        let count = filteredNotifications.count
        guard count > 0 else { return }
        selectedIndex = count - 1
    }

    // MARK: - Actions

    func done() {
        removeAndAdvance { client, threadId in
            try await client.markAsDone(threadId: threadId)
        }
    }

    func markRead() {
        let list = filteredNotifications
        guard selectedIndex >= 0 && selectedIndex < list.count else { return }
        let target = list[selectedIndex]
        let wasUnread = target.isUnread

        if let realIndex = notifications.firstIndex(where: { $0.id == target.id }) {
            notifications[realIndex].isUnread.toggle()
        }

        if let client = apiClient {
            Task {
                do {
                    if wasUnread {
                        try await client.markAsRead(threadId: target.threadId)
                    }
                    // GitHub API doesn't have "mark as unread", so toggling back is local-only
                } catch {
                    await MainActor.run {
                        if let realIndex = self.notifications.firstIndex(where: { $0.id == target.id }) {
                            self.notifications[realIndex].isUnread = wasUnread
                        }
                        self.errorMessage = "Failed to update read state"
                    }
                }
            }
        }
    }

    func unsubscribeFromThread() {
        removeAndAdvance { client, threadId in
            try await client.unsubscribe(threadId: threadId)
        }
    }

    func copyURL() {
        guard let notification = selectedNotification else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(notification.url.absoluteString, forType: .string)
    }

    func openInBrowser() {
        guard let notification = selectedNotification else { return }
        NSWorkspace.shared.open(notification.url)
    }

    /// Remove the selected notification from the list, advance selection, and call an API action.
    private func removeAndAdvance(apiAction: @escaping (GitHubAPIClient, String) async throws -> Void) {
        let list = filteredNotifications
        guard selectedIndex >= 0 && selectedIndex < list.count else { return }
        let target = list[selectedIndex]

        // Optimistic: remove from list
        if let realIndex = notifications.firstIndex(where: { $0.id == target.id }) {
            notifications.remove(at: realIndex)
        }
        clampSelection()

        if let client = apiClient {
            Task {
                do {
                    try await apiAction(client, target.threadId)
                } catch {
                    // Revert on failure
                    await MainActor.run {
                        self.notifications.append(target)
                        self.notifications.sort { $0.updatedAt > $1.updatedAt }
                        self.errorMessage = "Action failed"
                    }
                }
            }
        }
    }

    func refresh() {
        searchQuery = ""
        isSearchActive = false
        if apiClient != nil {
            Task { await loadNotifications() }
        } else {
            notifications = MockData.generateNotifications()
            selectedIndex = 0
        }
    }

    // MARK: - Search

    func activateSearch() {
        isSearchActive = true
    }

    func deactivateSearch() {
        isSearchActive = false
        searchQuery = ""
    }

    func clampSelection() {
        let count = filteredNotifications.count
        if count == 0 {
            selectedIndex = 0
        } else if selectedIndex >= count {
            selectedIndex = count - 1
        }
    }
}
