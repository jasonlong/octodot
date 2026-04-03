import Foundation

@MainActor
final class InboxStore {
    private static let recentInboxReadsStorageKey = "AppState.recentInboxReads.v1"
    private static let recentInboxBootstrapUsersStorageKey = "AppState.recentInboxBootstrapUsers.v1"
    private static let recentInboxReadRetentionInterval: TimeInterval = 14 * 24 * 60 * 60
    private static let recentInboxReadLimit = 100
    private static let inboxRecentReadFallbackWindow: TimeInterval = 12 * 60 * 60
    private static let inboxRecentReadGraceBeforeOldestUnread: TimeInterval = 2 * 60 * 60
    static let inboxRecentReadMaxPages = 1
    static let inboxRecentReadMaxItems = 10

    private struct PersistedInboxNotification: Codable {
        let id: String
        let threadId: String
        let title: String
        let repository: String
        let reason: GitHubNotification.Reason
        let type: GitHubNotification.SubjectType
        let updatedAt: Date
        let isUnread: Bool
        let url: URL
        let subjectURL: String?
        let subjectState: GitHubNotification.SubjectState

        init(notification: GitHubNotification) {
            self.id = notification.id
            self.threadId = notification.threadId
            self.title = notification.title
            self.repository = notification.repository
            self.reason = notification.reason
            self.type = notification.type
            self.updatedAt = notification.updatedAt
            self.isUnread = notification.isUnread
            self.url = notification.url
            self.subjectURL = notification.subjectURL
            self.subjectState = notification.subjectState
        }

        var notification: GitHubNotification {
            GitHubNotification(
                id: id,
                threadId: threadId,
                title: title,
                repository: repository,
                reason: reason,
                type: type,
                updatedAt: updatedAt,
                isUnread: isUnread,
                url: url,
                subjectURL: subjectURL,
                subjectState: subjectState
            )
        }
    }

    struct LoadedState {
        let recentInboxNotifications: [GitHubNotification]
        let unreadCount: Int
    }

    private let userDefaults: UserDefaults
    private var recentInboxReadNotifications: [String: GitHubNotification]
    private var recentInboxBootstrapUsers: Set<String>
    private(set) var lastFetchedUnreadNotifications: [GitHubNotification]
    private(set) var unreadNotificationCount: Int

    init(userDefaults: UserDefaults, initialNotifications: [GitHubNotification]) {
        self.userDefaults = userDefaults
        self.recentInboxReadNotifications = Self.loadRecentInboxReadNotifications(from: userDefaults)
        self.recentInboxBootstrapUsers = Self.loadRecentInboxBootstrapUsers(from: userDefaults)
        self.lastFetchedUnreadNotifications = initialNotifications.filter(\.isUnread)
        self.unreadNotificationCount = initialNotifications.reduce(into: 0) { count, notification in
            if notification.isUnread {
                count += 1
            }
        }
    }

    func shouldFetchRecentInboxSeed(for username: String?) -> Bool {
        guard recentInboxReadNotifications.isEmpty else { return false }
        guard let username, !username.isEmpty else { return true }
        return !recentInboxBootstrapUsers.contains(username)
    }

    func recentInboxSinceDate(relativeTo unreadNotifications: [GitHubNotification], now: Date = Date()) -> Date {
        let fallback = now.addingTimeInterval(-Self.inboxRecentReadFallbackWindow)
        guard let oldestUnread = unreadNotifications.map(\.updatedAt).min() else {
            return fallback
        }

        let oldestUnreadGraceWindow = oldestUnread.addingTimeInterval(-Self.inboxRecentReadGraceBeforeOldestUnread)
        return max(fallback, oldestUnreadGraceWindow)
    }

    func applyLoaded(
        unreadNotifications: [GitHubNotification],
        recentInboxNotifications: [GitHubNotification],
        didFetchRecentInboxSeed: Bool,
        username: String?,
        projectedNotifications: ([GitHubNotification]) -> [GitHubNotification]
    ) -> LoadedState {
        recordRecentInboxReadTransitions(
            from: lastFetchedUnreadNotifications,
            to: unreadNotifications,
            projectedNotifications: projectedNotifications
        )
        let prunedRecentInboxNotifications = pruneServerRecentInboxNotifications(
            recentInboxNotifications,
            using: unreadNotifications
        )
        if didFetchRecentInboxSeed {
            markRecentInboxBootstrapCompleted(for: username)
        }
        lastFetchedUnreadNotifications = unreadNotifications
        unreadNotificationCount = unreadCount(in: unreadNotifications)
        pruneRecentInboxReadNotifications(
            using: unreadNotifications,
            projectedNotifications: projectedNotifications
        )
        return LoadedState(
            recentInboxNotifications: prunedRecentInboxNotifications,
            unreadCount: unreadNotificationCount
        )
    }

    func mergedInboxNotifications(
        unreadNotifications: [GitHubNotification],
        recentInboxNotifications: [GitHubNotification],
        projectedNotifications: ([GitHubNotification]) -> [GitHubNotification]
    ) -> [GitHubNotification] {
        let recentReads = prunedRecentInboxReadNotifications(
            using: unreadNotifications,
            projectedNotifications: projectedNotifications
        )
        let unreadThreadIDs = Set(unreadNotifications.map(\.threadId))
        let serverRecentReads = recentInboxNotifications.filter { notification in
            !notification.isUnread && !unreadThreadIDs.contains(notification.threadId)
        }
        let serverRecentReadThreadIDs = Set(serverRecentReads.map(\.threadId))
        let additionalRecentReads = recentReads.filter {
            !unreadThreadIDs.contains($0.threadId) && !serverRecentReadThreadIDs.contains($0.threadId)
        }
        return unreadNotifications + serverRecentReads + additionalRecentReads
    }

    func recordRecentReadNotification(
        _ notification: GitHubNotification,
        unreadNotifications: [GitHubNotification],
        projectedNotifications: ([GitHubNotification]) -> [GitHubNotification]
    ) {
        var snapshot = notification
        snapshot.isUnread = false
        if let existing = recentInboxReadNotifications[snapshot.threadId],
           existing.updatedAt >= snapshot.updatedAt {
            return
        }
        recentInboxReadNotifications[snapshot.threadId] = snapshot
        pruneRecentInboxReadNotifications(
            using: unreadNotifications,
            projectedNotifications: projectedNotifications
        )
    }

    func removeRecentReadNotification(threadId: String) {
        guard recentInboxReadNotifications.removeValue(forKey: threadId) != nil else { return }
        persistRecentInboxReadNotifications()
    }

    func clearSessionState() {
        lastFetchedUnreadNotifications = []
        unreadNotificationCount = 0
        recentInboxReadNotifications.removeAll()
        persistRecentInboxReadNotifications()
    }

    func updateUnreadCountOnly(from unreadNotifications: [GitHubNotification]) {
        unreadNotificationCount = unreadCount(in: unreadNotifications)
    }

    @discardableResult
    func applyResolvedSubjectStates(
        _ resolvedStates: [String: GitHubNotification.SubjectState]
    ) -> Bool {
        var didChange = false

        for (threadID, notification) in recentInboxReadNotifications {
            guard let resolvedState = resolvedStates[notification.id],
                  notification.subjectState != resolvedState else {
                continue
            }

            var updated = notification
            updated.subjectState = resolvedState
            recentInboxReadNotifications[threadID] = updated
            didChange = true
        }

        if didChange {
            persistRecentInboxReadNotifications()
        }

        return didChange
    }

    @discardableResult
    func applyResolvedSubjectStatesToLastFetchedUnread(
        _ resolvedStates: [String: GitHubNotification.SubjectState]
    ) -> Bool {
        var didChange = false

        for index in lastFetchedUnreadNotifications.indices {
            guard let resolvedState = resolvedStates[lastFetchedUnreadNotifications[index].id],
                  lastFetchedUnreadNotifications[index].subjectState != resolvedState else {
                continue
            }

            lastFetchedUnreadNotifications[index].subjectState = resolvedState
            didChange = true
        }

        return didChange
    }

    private func unreadCount(in notifications: [GitHubNotification]) -> Int {
        notifications.reduce(into: 0) { count, notification in
            if notification.isUnread {
                count += 1
            }
        }
    }

    private func markRecentInboxBootstrapCompleted(for username: String?) {
        guard let username, !username.isEmpty else { return }
        guard !recentInboxBootstrapUsers.contains(username) else { return }
        recentInboxBootstrapUsers.insert(username)
        persistRecentInboxBootstrapUsers()
    }

    private func recordRecentInboxReadTransitions(
        from previousUnread: [GitHubNotification],
        to currentUnread: [GitHubNotification],
        projectedNotifications: ([GitHubNotification]) -> [GitHubNotification]
    ) {
        guard !previousUnread.isEmpty else { return }

        let currentUnreadActivityIDs = Set(currentUnread.compactMap(\.activityIdentity))
        let currentUnreadThreadIDs = Set(currentUnread.map(\.threadId))
        let candidates = previousUnread.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id > rhs.id
        }

        for notification in candidates {
            if currentUnreadActivityIDs.contains(notification.activityIdentity) {
                continue
            }
            if currentUnreadThreadIDs.contains(notification.threadId) {
                continue
            }
            guard !projectedNotifications([notification]).isEmpty else {
                continue
            }
            recordRecentReadNotification(
                notification,
                unreadNotifications: currentUnread,
                projectedNotifications: projectedNotifications
            )
        }
    }

    private func pruneRecentInboxReadNotifications(
        using unreadNotifications: [GitHubNotification],
        projectedNotifications: ([GitHubNotification]) -> [GitHubNotification]
    ) {
        recentInboxReadNotifications = prunedRecentInboxReadNotifications(
            recentInboxReadNotifications,
            using: unreadNotifications,
            projectedNotifications: projectedNotifications
        )
        persistRecentInboxReadNotifications()
    }

    private func pruneServerRecentInboxNotifications(
        _ notifications: [GitHubNotification],
        using unreadNotifications: [GitHubNotification]
    ) -> [GitHubNotification] {
        let unreadThreadIDs = Set(unreadNotifications.map(\.threadId))
        let filtered = notifications.filter { notification in
            !notification.isUnread && !unreadThreadIDs.contains(notification.threadId)
        }

        return Array(
            filtered
                .sorted { lhs, rhs in
                    if lhs.updatedAt != rhs.updatedAt {
                        return lhs.updatedAt > rhs.updatedAt
                    }
                    return lhs.id > rhs.id
                }
                .prefix(Self.inboxRecentReadMaxItems)
        )
    }

    private func prunedRecentInboxReadNotifications(
        using unreadNotifications: [GitHubNotification],
        projectedNotifications: ([GitHubNotification]) -> [GitHubNotification]
    ) -> [GitHubNotification] {
        Array(
            prunedRecentInboxReadNotifications(
                recentInboxReadNotifications,
                using: unreadNotifications,
                projectedNotifications: projectedNotifications
            ).values
        )
    }

    private func prunedRecentInboxReadNotifications(
        _ notificationsByThreadID: [String: GitHubNotification],
        using unreadNotifications: [GitHubNotification],
        projectedNotifications: ([GitHubNotification]) -> [GitHubNotification],
        now: Date = Date()
    ) -> [String: GitHubNotification] {
        let cutoff = now.addingTimeInterval(-Self.recentInboxReadRetentionInterval)
        let unreadByThreadID = unreadNotifications.reduce(into: [String: GitHubNotification]()) { result, notification in
            guard notification.isUnread else { return }
            if let existing = result[notification.threadId] {
                if notification.updatedAt >= existing.updatedAt || notification.isUnread {
                    result[notification.threadId] = notification
                }
            } else {
                result[notification.threadId] = notification
            }
        }
        var pruned = notificationsByThreadID.filter { threadId, notification in
            guard notification.updatedAt >= cutoff else { return false }
            guard !projectedNotifications([notification]).isEmpty else { return false }
            if let unreadNotification = unreadByThreadID[threadId],
               unreadNotification.updatedAt >= notification.updatedAt {
                return false
            }
            return true
        }

        if pruned.count > Self.recentInboxReadLimit {
            let kept = pruned.values
                .sorted { lhs, rhs in
                    if lhs.updatedAt != rhs.updatedAt {
                        return lhs.updatedAt > rhs.updatedAt
                    }
                    return lhs.id > rhs.id
                }
                .prefix(Self.recentInboxReadLimit)
            pruned = Dictionary(uniqueKeysWithValues: Array(kept).map { ($0.threadId, $0) })
        }

        return pruned
    }

    private static func loadRecentInboxReadNotifications(from userDefaults: UserDefaults) -> [String: GitHubNotification] {
        guard let data = userDefaults.data(forKey: recentInboxReadsStorageKey) else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let persisted = try? decoder.decode([PersistedInboxNotification].self, from: data) else {
            return [:]
        }

        return Dictionary(uniqueKeysWithValues: persisted.map { ($0.threadId, $0.notification) })
    }

    private static func loadRecentInboxBootstrapUsers(from userDefaults: UserDefaults) -> Set<String> {
        let usernames = userDefaults.stringArray(forKey: recentInboxBootstrapUsersStorageKey) ?? []
        return Set(usernames)
    }

    private func persistRecentInboxBootstrapUsers() {
        userDefaults.set(
            Array(recentInboxBootstrapUsers).sorted(),
            forKey: Self.recentInboxBootstrapUsersStorageKey
        )
    }

    private func persistRecentInboxReadNotifications() {
        guard !recentInboxReadNotifications.isEmpty else {
            userDefaults.removeObject(forKey: Self.recentInboxReadsStorageKey)
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let persisted = recentInboxReadNotifications.values.map(PersistedInboxNotification.init(notification:))
        guard let data = try? encoder.encode(persisted) else { return }
        userDefaults.set(data, forKey: Self.recentInboxReadsStorageKey)
    }
}
