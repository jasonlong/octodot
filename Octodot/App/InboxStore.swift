import Foundation

@MainActor
final class InboxStore {
    private static let recentInboxReadsStorageKey = "AppState.recentInboxReads.v1"
    private static let legacySecurityAlertStorageKeys = [
        "AppState.dismissedSecurityAlerts.v1",
        "AppState.readSecurityAlerts.v1",
    ]
    private static let mutedThreadsStorageKey = "AppState.mutedThreads.v1"
    private static let mutedThreadsLimit = 200
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
        let ciStatus: GitHubNotification.CIStatus?
        let graphQLNodeID: String?
        let openerLogin: String?
        let openerAvatarURL: URL?
        let hasResolvedOpener: Bool
        let source: GitHubNotification.Source

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
            self.ciStatus = notification.ciStatus
            self.graphQLNodeID = notification.graphQLNodeID
            self.openerLogin = notification.openerLogin
            self.openerAvatarURL = notification.openerAvatarURL
            self.hasResolvedOpener = notification.hasResolvedOpener
            self.source = notification.source
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            threadId = try container.decode(String.self, forKey: .threadId)
            title = try container.decode(String.self, forKey: .title)
            repository = try container.decode(String.self, forKey: .repository)
            reason = try container.decode(GitHubNotification.Reason.self, forKey: .reason)
            type = try container.decode(GitHubNotification.SubjectType.self, forKey: .type)
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
            isUnread = try container.decode(Bool.self, forKey: .isUnread)
            url = try container.decode(URL.self, forKey: .url)
            subjectURL = try container.decodeIfPresent(String.self, forKey: .subjectURL)
            subjectState = try container.decode(GitHubNotification.SubjectState.self, forKey: .subjectState)
            ciStatus = try container.decodeIfPresent(GitHubNotification.CIStatus.self, forKey: .ciStatus)
            graphQLNodeID = try container.decodeIfPresent(String.self, forKey: .graphQLNodeID)
            openerLogin = try container.decodeIfPresent(String.self, forKey: .openerLogin)
            openerAvatarURL = try container.decodeIfPresent(URL.self, forKey: .openerAvatarURL)
            hasResolvedOpener = try container.decodeIfPresent(Bool.self, forKey: .hasResolvedOpener) ?? false
            source = try container.decodeIfPresent(GitHubNotification.Source.self, forKey: .source) ?? .thread
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
                subjectState: subjectState,
                ciStatus: ciStatus,
                graphQLNodeID: graphQLNodeID,
                openerLogin: openerLogin,
                openerAvatarURL: openerAvatarURL,
                hasResolvedOpener: hasResolvedOpener,
                source: source
            )
        }
    }

    struct LoadedState {
        let recentInboxNotifications: [GitHubNotification]
        let unreadCount: Int
    }

    private let userDefaults: UserDefaults
    private var recentInboxReadNotifications: [String: GitHubNotification]
    private var mutedThreads: [String: Date] // threadID → mutedAt
    private(set) var lastFetchedUnreadNotifications: [GitHubNotification]
    private(set) var unreadNotificationCount: Int

    init(userDefaults: UserDefaults, initialNotifications: [GitHubNotification]) {
        self.userDefaults = userDefaults
        for key in Self.legacySecurityAlertStorageKeys {
            userDefaults.removeObject(forKey: key)
        }
        self.recentInboxReadNotifications = Self.loadRecentInboxReadNotifications(from: userDefaults)
        self.mutedThreads = Self.loadMutedThreads(from: userDefaults)
        self.lastFetchedUnreadNotifications = initialNotifications.filter(\.isUnread)
        self.unreadNotificationCount = initialNotifications.reduce(into: 0) { count, notification in
            if notification.isUnread {
                count += 1
            }
        }
    }

    func recentInboxSinceDate(relativeTo unreadNotifications: [GitHubNotification], now: Date = .now) -> Date {
        let fallback = now.addingTimeInterval(-Self.inboxRecentReadFallbackWindow)
        guard let oldestUnread = unreadNotifications.map(\.updatedAt).min() else {
            return fallback
        }

        let oldestUnreadGraceWindow = oldestUnread.addingTimeInterval(-Self.inboxRecentReadGraceBeforeOldestUnread)
        return min(now, max(fallback, oldestUnreadGraceWindow))
    }

    func applyLoaded(
        unreadNotifications: [GitHubNotification],
        recentInboxNotifications: [GitHubNotification],
        projectNotifications: @escaping ([GitHubNotification]) -> [GitHubNotification],
        isNotificationVisible: @escaping (GitHubNotification) -> Bool
    ) -> LoadedState {
        recordRecentInboxReadTransitions(
            from: lastFetchedUnreadNotifications,
            to: unreadNotifications,
            isNotificationVisible: isNotificationVisible
        )
        let prunedRecentInboxNotifications = pruneServerRecentInboxNotifications(
            recentInboxNotifications,
            using: unreadNotifications
        )
        lastFetchedUnreadNotifications = unreadNotifications
        unreadNotificationCount = unreadCount(in: unreadNotifications)
        pruneRecentInboxReadNotifications(
            using: unreadNotifications,
            isNotificationVisible: isNotificationVisible
        )
        return LoadedState(
            recentInboxNotifications: prunedRecentInboxNotifications,
            unreadCount: unreadNotificationCount
        )
    }

    func mergedInboxNotifications(
        unreadNotifications: [GitHubNotification],
        recentInboxNotifications: [GitHubNotification],
        projectNotifications: @escaping ([GitHubNotification]) -> [GitHubNotification],
        isNotificationVisible: @escaping (GitHubNotification) -> Bool
    ) -> [GitHubNotification] {
        let recentReads = prunedRecentInboxReadNotifications(
            using: unreadNotifications,
            isNotificationVisible: isNotificationVisible
        )
        let unreadThreadIDs = Set(unreadNotifications.map(\.threadId))
        let serverRecentReads = projectNotifications(
            recentInboxNotifications.filter { notification in
                !notification.isUnread && !unreadThreadIDs.contains(notification.threadId)
            }
        )
        let serverRecentReadThreadIDs = Set(serverRecentReads.map(\.threadId))
        let additionalRecentReads = recentReads.filter {
            !unreadThreadIDs.contains($0.threadId) && !serverRecentReadThreadIDs.contains($0.threadId)
        }
        let merged = unreadNotifications + serverRecentReads + additionalRecentReads
        return filterMutedThreads(merged)
    }

    func recordRecentReadNotification(
        _ notification: GitHubNotification,
        unreadNotifications: [GitHubNotification],
        isNotificationVisible: @escaping (GitHubNotification) -> Bool
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
            isNotificationVisible: isNotificationVisible
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
        mutedThreads.removeAll()
        persistMutedThreads()
    }

    func updateUnreadCountOnly(from unreadNotifications: [GitHubNotification]) {
        unreadNotificationCount = unreadCount(in: unreadNotifications)
    }

    @discardableResult
    func applyResolvedSubjectMetadata(
        _ resolvedMetadata: [String: GitHubNotification.SubjectMetadata]
    ) -> Bool {
        var didChange = false

        for (threadID, notification) in recentInboxReadNotifications {
            guard let metadata = resolvedMetadata[notification.id] else { continue }
            var updated = notification
            guard updated.apply(metadata) else { continue }
            recentInboxReadNotifications[threadID] = updated
            didChange = true
        }

        if didChange {
            persistRecentInboxReadNotifications()
        }

        return didChange
    }

    @discardableResult
    func applyResolvedSubjectMetadataToLastFetchedUnread(
        _ resolvedMetadata: [String: GitHubNotification.SubjectMetadata]
    ) -> Bool {
        var didChange = false

        for index in lastFetchedUnreadNotifications.indices {
            guard let metadata = resolvedMetadata[lastFetchedUnreadNotifications[index].id] else { continue }
            if lastFetchedUnreadNotifications[index].apply(metadata) {
                didChange = true
            }
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

    private func recordRecentInboxReadTransitions(
        from previousUnread: [GitHubNotification],
        to currentUnread: [GitHubNotification],
        isNotificationVisible: @escaping (GitHubNotification) -> Bool
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
            guard isNotificationVisible(notification) else {
                continue
            }
            recordRecentReadNotification(
                notification,
                unreadNotifications: currentUnread,
                isNotificationVisible: isNotificationVisible
            )
        }
    }

    private func pruneRecentInboxReadNotifications(
        using unreadNotifications: [GitHubNotification],
        isNotificationVisible: @escaping (GitHubNotification) -> Bool
    ) {
        recentInboxReadNotifications = prunedRecentInboxReadNotifications(
            recentInboxReadNotifications,
            using: unreadNotifications,
            isNotificationVisible: isNotificationVisible
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
        isNotificationVisible: @escaping (GitHubNotification) -> Bool
    ) -> [GitHubNotification] {
        Array(
            prunedRecentInboxReadNotifications(
                recentInboxReadNotifications,
                using: unreadNotifications,
                isNotificationVisible: isNotificationVisible
            ).values
        )
    }

    private func prunedRecentInboxReadNotifications(
        _ notificationsByThreadID: [String: GitHubNotification],
        using unreadNotifications: [GitHubNotification],
        isNotificationVisible: @escaping (GitHubNotification) -> Bool,
        now: Date = .now
    ) -> [String: GitHubNotification] {
        let cutoff = now.addingTimeInterval(-Self.recentInboxReadRetentionInterval)
        let unreadByThreadID = unreadNotifications.reduce(into: [String: GitHubNotification]()) { result, notification in
            guard notification.isUnread else { return }
            if let existing = result[notification.threadId] {
                if notification.updatedAt > existing.updatedAt ||
                    (notification.updatedAt == existing.updatedAt && notification.id > existing.id) {
                    result[notification.threadId] = notification
                }
            } else {
                result[notification.threadId] = notification
            }
        }
        var pruned = notificationsByThreadID.filter { threadId, notification in
            guard notification.updatedAt >= cutoff else { return false }
            guard isNotificationVisible(notification) else { return false }
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
            userDefaults.removeObject(forKey: recentInboxReadsStorageKey)
            return [:]
        }

        return persisted.reduce(into: [:]) { notifications, stored in
            guard !stored.threadId.isEmpty else { return }
            let notification = stored.notification
            if let existing = notifications[stored.threadId],
               existing.updatedAt > notification.updatedAt ||
                (existing.updatedAt == notification.updatedAt && existing.id >= notification.id) {
                return
            }
            notifications[stored.threadId] = notification
        }
    }

    private func persistRecentInboxReadNotifications() {
        guard !recentInboxReadNotifications.isEmpty else {
            userDefaults.removeObject(forKey: Self.recentInboxReadsStorageKey)
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = PersistenceCoding.preciseDateEncodingStrategy
        let persisted = recentInboxReadNotifications.values
            .sorted { $0.threadId < $1.threadId }
            .map(PersistedInboxNotification.init(notification:))
        guard let data = try? encoder.encode(persisted) else { return }
        userDefaults.set(data, forKey: Self.recentInboxReadsStorageKey)
    }

    // MARK: - Muted threads

    func muteThread(_ threadId: String) {
        guard !threadId.isEmpty else { return }
        mutedThreads[threadId] = .now
        // Cap size by removing oldest entries
        if mutedThreads.count > Self.mutedThreadsLimit {
            let sorted = mutedThreads.sorted { $0.value < $1.value }
            let excess = mutedThreads.count - Self.mutedThreadsLimit
            for (key, _) in sorted.prefix(excess) {
                mutedThreads.removeValue(forKey: key)
            }
        }
        persistMutedThreads()
    }

    func unmuteThread(_ threadId: String) {
        guard mutedThreads.removeValue(forKey: threadId) != nil else { return }
        persistMutedThreads()
    }

    func isThreadMuted(_ threadId: String) -> Bool {
        mutedThreads[threadId] != nil
    }

    func filterMutedThreads(_ notifications: [GitHubNotification]) -> [GitHubNotification] {
        notifications.filter { !isThreadMuted($0.threadId) }
    }

    /// Remove stale mutes for threads that have new unread notifications from the server
    /// and no committed action still protecting them. This handles the case where a user
    /// unsubscribed long ago, but the server later sends a new notification (e.g., re-mention).
    func reconcileMutedThreadsWithUnread(
        _ unreadNotifications: [GitHubNotification],
        committedThreadIDs: Set<String>
    ) {
        var didChange = false
        for notification in unreadNotifications where notification.isUnread {
            guard isThreadMuted(notification.threadId),
                  !committedThreadIDs.contains(notification.threadId) else { continue }
            mutedThreads.removeValue(forKey: notification.threadId)
            didChange = true
        }
        if didChange {
            persistMutedThreads()
        }
    }

    private static func loadMutedThreads(from userDefaults: UserDefaults) -> [String: Date] {
        guard let data = userDefaults.data(forKey: mutedThreadsStorageKey) else {
            return [:]
        }
        guard let persisted = try? JSONDecoder().decode([String: Date].self, from: data) else {
            userDefaults.removeObject(forKey: mutedThreadsStorageKey)
            return [:]
        }
        return Dictionary(
            uniqueKeysWithValues: persisted
                .filter { !$0.key.isEmpty }
                .sorted { $0.value > $1.value }
                .prefix(mutedThreadsLimit)
                .map { ($0.key, $0.value) }
        )
    }

    private func persistMutedThreads() {
        guard !mutedThreads.isEmpty else {
            userDefaults.removeObject(forKey: Self.mutedThreadsStorageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(mutedThreads) else { return }
        userDefaults.set(data, forKey: Self.mutedThreadsStorageKey)
    }
}
