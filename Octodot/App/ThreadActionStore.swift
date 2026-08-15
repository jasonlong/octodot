import Foundation

struct ThreadActionStore {
    static let committedThreadActionsStorageKey = "AppState.committedThreadActions.v1"

    enum ActionKind: String, Codable {
        case markRead
        case done
        case unsubscribe

        var hidesNotification: Bool {
            switch self {
            case .done, .unsubscribe:
                return true
            case .markRead:
                return false
            }
        }

        var failureMessage: String {
            switch self {
            case .markRead:
                return "Failed to mark thread as read"
            case .done:
                return "Failed to mark thread as done"
            case .unsubscribe:
                return "Failed to unsubscribe from thread"
            }
        }
    }

    enum PendingActionPhase {
        case queued
        case executing
    }

    struct PendingAction {
        let requestID: UUID
        let kind: ActionKind
        let notification: GitHubNotification
        let activityIdentities: [String]
        let projectionCutoff: Date
        let originalServerIndex: Int
        var phase: PendingActionPhase
    }

    struct CommittedAction {
        let kind: ActionKind
        let threadId: String
        let updatedAt: Date
        let activityIdentities: [String]
    }

    private struct PersistedCommittedAction: Codable {
        let kind: ActionKind
        let threadId: String
        let updatedAt: Date
        let activityIdentity: String?
        let activityIdentities: [String]?
    }

    private let userDefaults: UserDefaults

    private(set) var pendingActions: [String: PendingAction]
    private(set) var committedActions: [String: CommittedAction]

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        self.pendingActions = [:]
        self.committedActions = Self.loadCommittedActions(from: userDefaults)
    }

    func hasPendingAction(for threadId: String) -> Bool {
        pendingActions[threadId] != nil
    }

    var hasPendingActions: Bool {
        !pendingActions.isEmpty
    }

    func pendingAction(for threadId: String) -> PendingAction? {
        pendingActions[threadId]
    }

    func queuedActionsForDispatch() -> [PendingAction] {
        pendingActions.values
            .filter { $0.phase == .queued }
            .sorted { lhs, rhs in
                if lhs.originalServerIndex != rhs.originalServerIndex {
                    return lhs.originalServerIndex < rhs.originalServerIndex
                }
                return lhs.notification.id < rhs.notification.id
            }
    }

    mutating func start(
        _ kind: ActionKind,
        notification: GitHubNotification,
        activityIdentities: [String]? = nil,
        projectionCutoff: Date? = nil,
        originalServerIndex: Int
    ) -> PendingAction {
        let pending = PendingAction(
            requestID: UUID(),
            kind: kind,
            notification: notification,
            activityIdentities: activityIdentities ?? [notification.activityIdentity],
            projectionCutoff: projectionCutoff ?? notification.updatedAt,
            originalServerIndex: originalServerIndex,
            phase: .queued
        )

        pendingActions[notification.threadId] = pending
        return pending
    }

    mutating func updatePendingAction(_ pending: PendingAction) {
        guard pendingActions[pending.notification.threadId]?.requestID == pending.requestID else {
            return
        }
        pendingActions[pending.notification.threadId] = pending
    }

    mutating func handleSuccess(
        _ pending: PendingAction,
        serverNotifications: inout [GitHubNotification]
    ) {
        guard pendingActions[pending.notification.threadId]?.requestID == pending.requestID else {
            return
        }
        pendingActions[pending.notification.threadId] = nil

        switch pending.kind {
        case .markRead:
            for index in serverNotifications.indices
                where serverNotifications[index].threadId == pending.notification.threadId &&
                    serverNotifications[index].updatedAt <= pending.projectionCutoff {
                serverNotifications[index].isUnread = false
            }
            committedActions[pending.notification.threadId] = CommittedAction(
                kind: .markRead,
                threadId: pending.notification.threadId,
                updatedAt: pending.projectionCutoff,
                activityIdentities: pending.activityIdentities
            )
            persistCommittedActions()

        case .done:
            removeActivities(pending.activityIdentities, from: &serverNotifications)
            committedActions[pending.notification.threadId] = CommittedAction(
                kind: .done,
                threadId: pending.notification.threadId,
                updatedAt: pending.notification.updatedAt,
                activityIdentities: pending.activityIdentities
            )
            persistCommittedActions()

        case .unsubscribe:
            removeActivities(pending.activityIdentities, from: &serverNotifications)
            committedActions[pending.notification.threadId] = CommittedAction(
                kind: .unsubscribe,
                threadId: pending.notification.threadId,
                updatedAt: pending.notification.updatedAt,
                activityIdentities: pending.activityIdentities
            )
            persistCommittedActions()
        }
    }

    mutating func handleFailure(_ pending: PendingAction) -> String {
        guard pendingActions[pending.notification.threadId]?.requestID == pending.requestID else {
            return pending.kind.failureMessage
        }
        pendingActions[pending.notification.threadId] = nil
        return pending.kind.failureMessage
    }

    func projectedNotifications(from baseNotifications: [GitHubNotification]) -> [GitHubNotification] {
        var projected = baseNotifications

        for committed in committedActions.values {
            switch committed.kind {
            case .markRead:
                for index in projected.indices
                    where projected[index].threadId == committed.threadId &&
                        projected[index].updatedAt <= committed.updatedAt {
                    projected[index].isUnread = false
                }
            case .done, .unsubscribe:
                hideDismissedActivities(
                    activityIdentities: committed.activityIdentities,
                    threadId: committed.threadId,
                    updatedAt: committed.updatedAt,
                    useLegacyThreadFallback: committed.activityIdentities.isEmpty,
                    in: &projected
                )
            }
        }

        for pending in pendingActions.values {
            switch pending.kind {
            case .markRead:
                for index in projected.indices
                    where projected[index].threadId == pending.notification.threadId &&
                        projected[index].updatedAt <= pending.projectionCutoff {
                    projected[index].isUnread = false
                }

            case .done, .unsubscribe:
                hideDismissedActivities(
                    activityIdentities: pending.activityIdentities,
                    threadId: pending.notification.threadId,
                    updatedAt: pending.notification.updatedAt,
                    useLegacyThreadFallback: false,
                    in: &projected
                )
            }
        }

        return projected
    }

    mutating func reconcileCommittedActions(with fetchedNotifications: [GitHubNotification]) {
        committedActions = committedActions.filter { threadId, committed in
            switch committed.kind {
            case .markRead:
                let fetchedSnapshots = fetchedNotifications.filter { $0.threadId == threadId }
                guard !fetchedSnapshots.isEmpty else {
                    return false
                }
                guard fetchedSnapshots.allSatisfy({ $0.updatedAt <= committed.updatedAt }) else {
                    return false
                }
                return fetchedSnapshots.contains(where: \.isUnread)

            case .done, .unsubscribe:
                let fetchedSnapshots = fetchedNotifications.filter { $0.threadId == threadId }
                guard !fetchedSnapshots.isEmpty else {
                    return true
                }
                if !committed.activityIdentities.isEmpty {
                    let representedIdentities = Set(committed.activityIdentities)
                    if fetchedSnapshots.contains(where: { representedIdentities.contains($0.activityIdentity) }) {
                        return true
                    }
                    if fetchedSnapshots.count == 1,
                       fetchedSnapshots[0].updatedAt <= committed.updatedAt {
                        return true
                    }
                    return false
                }
                return fetchedSnapshots.contains { $0.updatedAt <= committed.updatedAt }
            }
        }
        persistCommittedActions()
    }

    mutating func clearCommittedActions() {
        committedActions.removeAll()
        persistCommittedActions()
    }

    mutating func cancelAllPendingActions() {
        pendingActions.removeAll()
    }

    private func hideDismissedActivities(
        activityIdentities: [String],
        threadId: String,
        updatedAt: Date,
        useLegacyThreadFallback: Bool,
        in notifications: inout [GitHubNotification]
    ) {
        if !activityIdentities.isEmpty {
            let representedIdentities = Set(activityIdentities)
            let originalCount = notifications.count
            notifications.removeAll { representedIdentities.contains($0.activityIdentity) }
            if notifications.count < originalCount {
                return
            }

            let threadSnapshots = notifications.filter { $0.threadId == threadId }
            if threadSnapshots.count == 1, threadSnapshots[0].updatedAt <= updatedAt {
                notifications.removeAll { $0.id == threadSnapshots[0].id }
            }
            return
        }

        guard useLegacyThreadFallback else { return }
        notifications.removeAll {
            $0.threadId == threadId && $0.updatedAt <= updatedAt
        }
    }

    private func removeActivities(
        _ activityIdentities: [String],
        from notifications: inout [GitHubNotification]
    ) {
        let representedIdentities = Set(activityIdentities)
        notifications.removeAll { representedIdentities.contains($0.activityIdentity) }
    }

    private static func loadCommittedActions(from userDefaults: UserDefaults) -> [String: CommittedAction] {
        guard let data = userDefaults.data(forKey: committedThreadActionsStorageKey) else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let persisted = try? decoder.decode([PersistedCommittedAction].self, from: data) else {
            userDefaults.removeObject(forKey: committedThreadActionsStorageKey)
            return [:]
        }

        return persisted.reduce(into: [:]) { actions, stored in
            guard !stored.threadId.isEmpty else { return }
            let rawActivityIdentities = stored.activityIdentities ?? stored.activityIdentity.map { [$0] } ?? []
            let activityIdentities = rawActivityIdentities.reduce(into: [String]()) { identities, identity in
                guard !identity.isEmpty, !identities.contains(identity) else { return }
                identities.append(identity)
            }
            let action = CommittedAction(
                kind: stored.kind,
                threadId: stored.threadId,
                updatedAt: stored.updatedAt,
                activityIdentities: activityIdentities
            )
            if let existing = actions[stored.threadId], existing.updatedAt > action.updatedAt {
                return
            }
            actions[stored.threadId] = action
        }
    }

    private func persistCommittedActions() {
        guard !committedActions.isEmpty else {
            userDefaults.removeObject(forKey: Self.committedThreadActionsStorageKey)
            return
        }

        let persisted = committedActions.values
            .sorted { $0.threadId < $1.threadId }
            .map {
                PersistedCommittedAction(
                    kind: $0.kind,
                    threadId: $0.threadId,
                    updatedAt: $0.updatedAt,
                    activityIdentity: $0.activityIdentities.first,
                    activityIdentities: $0.activityIdentities
                )
            }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = Self.preciseDateEncodingStrategy

        guard let data = try? encoder.encode(persisted) else {
            return
        }

        userDefaults.set(data, forKey: Self.committedThreadActionsStorageKey)
    }

    private static var preciseDateEncodingStrategy: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
    }
}
