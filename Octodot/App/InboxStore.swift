import Foundation

@MainActor
final class InboxStore {
    private static let recentInboxReadsStorageKey = "AppState.recentInboxReads.v1"
    private static let dismissedSecurityAlertsStorageKey = "AppState.dismissedSecurityAlerts.v1"
    private static let readSecurityAlertsStorageKey = "AppState.readSecurityAlerts.v1"
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
                source: source
            )
        }
    }

    struct LoadedState {
        let recentInboxNotifications: [GitHubNotification]
        let unreadCount: Int
    }

    private struct PersistedDismissedSecurityAlert: Codable {
        let id: String
        let updatedAt: Date
    }

    private let userDefaults: UserDefaults
    private var recentInboxReadNotifications: [String: GitHubNotification]
    private var dismissedSecurityAlerts: [String: Date]
    private var readSecurityAlerts: [String: Date]
    private(set) var lastFetchedUnreadNotifications: [GitHubNotification]
    private(set) var unreadNotificationCount: Int

    init(userDefaults: UserDefaults, initialNotifications: [GitHubNotification]) {
        self.userDefaults = userDefaults
        self.recentInboxReadNotifications = Self.loadRecentInboxReadNotifications(from: userDefaults)
        self.dismissedSecurityAlerts = Self.loadDismissedSecurityAlerts(from: userDefaults)
        self.readSecurityAlerts = Self.loadReadSecurityAlerts(from: userDefaults)
        self.lastFetchedUnreadNotifications = initialNotifications.filter(\.isUnread)
        self.unreadNotificationCount = initialNotifications.reduce(into: 0) { count, notification in
            if notification.isUnread {
                count += 1
            }
        }
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
        projectedSecurityAlerts: [GitHubNotification],
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
        lastFetchedUnreadNotifications = unreadNotifications
        unreadNotificationCount = unreadCount(in: unreadNotifications)
        reconcileDismissedSecurityAlerts(with: projectedSecurityAlerts)
        reconcileReadSecurityAlerts(with: projectedSecurityAlerts)
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

    func dismissSecurityAlert(_ notification: GitHubNotification) {
        dismissedSecurityAlerts[notification.id] = notification.updatedAt
        persistDismissedSecurityAlerts()
    }

    func restoreDismissedSecurityAlert(_ notification: GitHubNotification) {
        guard dismissedSecurityAlerts.removeValue(forKey: notification.id) != nil else {
            return
        }
        persistDismissedSecurityAlerts()
    }

    func markSecurityAlertRead(_ notification: GitHubNotification) {
        guard notification.source == .dependabotAlert else { return }
        if let existing = readSecurityAlerts[notification.id], existing >= notification.updatedAt {
            return
        }
        readSecurityAlerts[notification.id] = notification.updatedAt
        persistReadSecurityAlerts()
    }

    func projectedSecurityAlerts(from alerts: [GitHubNotification]) -> [GitHubNotification] {
        alerts.compactMap { alert in
            if let dismissedAt = dismissedSecurityAlerts[alert.id],
               alert.updatedAt <= dismissedAt {
                return nil
            }

            var projected = alert
            if let readAt = readSecurityAlerts[alert.id],
               alert.updatedAt <= readAt {
                projected.isUnread = false
            } else {
                projected.isUnread = true
            }

            return projected
        }
    }

    func clearSessionState() {
        lastFetchedUnreadNotifications = []
        unreadNotificationCount = 0
        recentInboxReadNotifications.removeAll()
        persistRecentInboxReadNotifications()
        dismissedSecurityAlerts.removeAll()
        persistDismissedSecurityAlerts()
        readSecurityAlerts.removeAll()
        persistReadSecurityAlerts()
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
            guard let metadata = resolvedMetadata[notification.id],
                  notification.subjectState != metadata.state || notification.ciStatus != metadata.ciStatus else {
                continue
            }

            var updated = notification
            updated.subjectState = metadata.state
            updated.ciStatus = metadata.ciStatus
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
            guard let metadata = resolvedMetadata[lastFetchedUnreadNotifications[index].id],
                  lastFetchedUnreadNotifications[index].subjectState != metadata.state ||
                    lastFetchedUnreadNotifications[index].ciStatus != metadata.ciStatus else {
                continue
            }

            lastFetchedUnreadNotifications[index].subjectState = metadata.state
            lastFetchedUnreadNotifications[index].ciStatus = metadata.ciStatus
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

    private func reconcileDismissedSecurityAlerts(with alerts: [GitHubNotification]) {
        dismissedSecurityAlerts = dismissedSecurityAlerts.filter { id, dismissedAt in
            guard let currentUpdatedAt = alerts.first(where: { $0.id == id })?.updatedAt else {
                return true
            }
            return currentUpdatedAt <= dismissedAt
        }
        persistDismissedSecurityAlerts()
    }

    private func reconcileReadSecurityAlerts(with alerts: [GitHubNotification]) {
        readSecurityAlerts = readSecurityAlerts.filter { id, readAt in
            guard let currentUpdatedAt = alerts.first(where: { $0.id == id })?.updatedAt else {
                return true
            }
            return currentUpdatedAt <= readAt
        }
        persistReadSecurityAlerts()
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

    private static func loadDismissedSecurityAlerts(from userDefaults: UserDefaults) -> [String: Date] {
        guard let data = userDefaults.data(forKey: dismissedSecurityAlertsStorageKey) else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let persisted = try? decoder.decode([PersistedDismissedSecurityAlert].self, from: data) else {
            return [:]
        }

        return Dictionary(uniqueKeysWithValues: persisted.map { ($0.id, $0.updatedAt) })
    }

    private static func loadReadSecurityAlerts(from userDefaults: UserDefaults) -> [String: Date] {
        guard let data = userDefaults.data(forKey: readSecurityAlertsStorageKey) else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let persisted = try? decoder.decode([PersistedDismissedSecurityAlert].self, from: data) else {
            return [:]
        }

        return Dictionary(uniqueKeysWithValues: persisted.map { ($0.id, $0.updatedAt) })
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

    private func persistDismissedSecurityAlerts() {
        guard !dismissedSecurityAlerts.isEmpty else {
            userDefaults.removeObject(forKey: Self.dismissedSecurityAlertsStorageKey)
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let persisted = dismissedSecurityAlerts.map { id, updatedAt in
            PersistedDismissedSecurityAlert(id: id, updatedAt: updatedAt)
        }
        guard let data = try? encoder.encode(persisted) else { return }
        userDefaults.set(data, forKey: Self.dismissedSecurityAlertsStorageKey)
    }

    private func persistReadSecurityAlerts() {
        guard !readSecurityAlerts.isEmpty else {
            userDefaults.removeObject(forKey: Self.readSecurityAlertsStorageKey)
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let persisted = readSecurityAlerts.map { id, updatedAt in
            PersistedDismissedSecurityAlert(id: id, updatedAt: updatedAt)
        }
        guard let data = try? encoder.encode(persisted) else { return }
        userDefaults.set(data, forKey: Self.readSecurityAlertsStorageKey)
    }
}
