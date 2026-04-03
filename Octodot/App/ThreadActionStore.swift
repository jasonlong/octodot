import Foundation

struct ThreadActionStore {
    static let committedThreadActionsStorageKey = "AppState.committedThreadActions.v1"

    enum ActionKind: String, Codable {
        case markRead
        case done
        case unsubscribe
        case restoreSubscription

        var hidesNotification: Bool {
            switch self {
            case .done, .unsubscribe:
                return true
            case .markRead, .restoreSubscription:
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
            case .restoreSubscription:
                return "Failed to restore thread subscription"
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
        let originalServerIndex: Int
        var phase: PendingActionPhase
        var restoreAfterSuccess = false
    }

    struct CommittedAction {
        let kind: ActionKind
        let threadId: String
        let updatedAt: Date
        let activityIdentity: String?
    }

    private struct PersistedCommittedAction: Codable {
        let kind: ActionKind
        let threadId: String
        let updatedAt: Date
        let activityIdentity: String?
    }

    enum UndoEntry {
        case cancelPending(threadId: String, requestID: UUID)
        case restoreSubscription(notification: GitHubNotification, originalServerIndex: Int)
        case restoreSecurityAlert(notification: GitHubNotification, originalVisibleIndex: Int)
    }

    enum UndoEffect {
        case none
        case cancelQueued(PendingAction)
        case restoreSubscription(notification: GitHubNotification, originalServerIndex: Int)
        case restoreSecurityAlert(notification: GitHubNotification, originalVisibleIndex: Int)
    }

    private let userDefaults: UserDefaults

    private(set) var pendingActions: [String: PendingAction]
    private(set) var committedActions: [String: CommittedAction]
    private(set) var undoStack: [UndoEntry]

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        self.pendingActions = [:]
        self.committedActions = Self.loadCommittedActions(from: userDefaults)
        self.undoStack = []
    }

    func hasPendingAction(for threadId: String) -> Bool {
        pendingActions[threadId] != nil
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
        originalServerIndex: Int,
        pushesUndo: Bool
    ) -> PendingAction {
        let requestID = UUID()
        let pending = PendingAction(
            requestID: requestID,
            kind: kind,
            notification: notification,
            originalServerIndex: originalServerIndex,
            phase: .queued
        )

        pendingActions[notification.threadId] = pending
        if pushesUndo {
            pushUndo(.cancelPending(threadId: notification.threadId, requestID: requestID))
        }
        return pending
    }

    mutating func updatePendingAction(_ pending: PendingAction) {
        pendingActions[pending.notification.threadId] = pending
    }

    mutating func applyUndo() -> UndoEffect {
        while let entry = undoStack.popLast() {
            switch entry {
            case .cancelPending(let threadId, let requestID):
                guard let pending = pendingActions[threadId],
                      pending.requestID == requestID else {
                    continue
                }

                switch pending.phase {
                case .queued:
                    pendingActions.removeValue(forKey: threadId)
                    return .cancelQueued(pending)

                case .executing:
                    return .none
                }

            case .restoreSubscription(let notification, let originalServerIndex):
                guard pendingActions[notification.threadId] == nil else {
                    continue
                }

                committedActions.removeValue(forKey: notification.threadId)
                persistCommittedActions()
                return .restoreSubscription(
                    notification: notification,
                    originalServerIndex: originalServerIndex
                )

            case .restoreSecurityAlert(let notification, let originalVisibleIndex):
                return .restoreSecurityAlert(
                    notification: notification,
                    originalVisibleIndex: originalVisibleIndex
                )
            }
        }

        return .none
    }

    mutating func pushSecurityAlertDismissUndo(
        notification: GitHubNotification,
        originalVisibleIndex: Int
    ) {
        pushUndo(.restoreSecurityAlert(
            notification: notification,
            originalVisibleIndex: originalVisibleIndex
        ))
    }

    mutating func handleSuccess(
        _ pending: PendingAction,
        serverNotifications: inout [GitHubNotification]
    ) -> UndoEffect {
        pendingActions[pending.notification.threadId] = nil

        switch pending.kind {
        case .markRead:
            if let index = serverNotifications.firstIndex(where: { $0.threadId == pending.notification.threadId }) {
                serverNotifications[index].isUnread = false
            }
            committedActions[pending.notification.threadId] = CommittedAction(
                kind: .markRead,
                threadId: pending.notification.threadId,
                updatedAt: pending.notification.updatedAt,
                activityIdentity: pending.notification.activityIdentity
            )
            persistCommittedActions()
            removeUndoEntry(for: pending.requestID)
            return .none

        case .done:
            serverNotifications.removeAll { $0.matchesActivity(as: pending.notification) }
            committedActions[pending.notification.threadId] = CommittedAction(
                kind: .done,
                threadId: pending.notification.threadId,
                updatedAt: pending.notification.updatedAt,
                activityIdentity: pending.notification.activityIdentity
            )
            persistCommittedActions()
            removeUndoEntry(for: pending.requestID)
            return .none

        case .unsubscribe:
            serverNotifications.removeAll { $0.matchesActivity(as: pending.notification) }
            committedActions[pending.notification.threadId] = CommittedAction(
                kind: .unsubscribe,
                threadId: pending.notification.threadId,
                updatedAt: pending.notification.updatedAt,
                activityIdentity: pending.notification.activityIdentity
            )
            persistCommittedActions()
            removeUndoEntry(for: pending.requestID)
            return .none

        case .restoreSubscription:
            committedActions.removeValue(forKey: pending.notification.threadId)
            persistCommittedActions()
            if let index = serverNotifications.firstIndex(where: { $0.threadId == pending.notification.threadId }) {
                serverNotifications[index] = pending.notification
            } else {
                let insertAt = min(max(0, pending.originalServerIndex), serverNotifications.count)
                serverNotifications.insert(pending.notification, at: insertAt)
            }
            return .none
        }
    }

    mutating func handleFailure(_ pending: PendingAction) -> String {
        pendingActions[pending.notification.threadId] = nil
        removeUndoEntry(for: pending.requestID)
        return pending.kind.failureMessage
    }

    func projectedNotifications(from baseNotifications: [GitHubNotification]) -> [GitHubNotification] {
        var projected = baseNotifications

        for committed in committedActions.values {
            switch committed.kind {
            case .markRead:
                if let index = projected.firstIndex(where: { $0.threadId == committed.threadId }),
                   projected[index].updatedAt <= committed.updatedAt {
                    projected[index].isUnread = false
                }
            case .done, .unsubscribe:
                hideDismissedActivity(
                    activityIdentity: committed.activityIdentity,
                    threadId: committed.threadId,
                    updatedAt: committed.updatedAt,
                    useLegacyThreadFallback: committed.activityIdentity == nil,
                    in: &projected
                )
            case .restoreSubscription:
                break
            }
        }

        for pending in pendingActions.values {
            switch pending.kind {
            case .markRead:
                if let index = projected.firstIndex(where: { $0.threadId == pending.notification.threadId }) {
                    projected[index].isUnread = false
                }

            case .done, .unsubscribe:
                hideDismissedActivity(
                    activityIdentity: pending.notification.activityIdentity,
                    threadId: pending.notification.threadId,
                    updatedAt: pending.notification.updatedAt,
                    useLegacyThreadFallback: false,
                    in: &projected
                )

            case .restoreSubscription:
                if let index = projected.firstIndex(where: { $0.threadId == pending.notification.threadId }) {
                    projected[index] = pending.notification
                } else {
                    let insertAt = min(max(0, pending.originalServerIndex), projected.count)
                    projected.insert(pending.notification, at: insertAt)
                }
            }
        }

        return projected
    }

    mutating func reconcileCommittedActions(with fetchedNotifications: [GitHubNotification]) {
        committedActions = committedActions.filter { threadId, committed in
            switch committed.kind {
            case .markRead:
                guard let fetched = fetchedNotifications.first(where: { $0.threadId == threadId }) else {
                    return false
                }
                guard fetched.updatedAt <= committed.updatedAt else {
                    return false
                }
                return fetched.isUnread

            case .done, .unsubscribe:
                let fetchedSnapshots = fetchedNotifications.filter { $0.threadId == threadId }
                guard !fetchedSnapshots.isEmpty else {
                    return true
                }
                if let activityIdentity = committed.activityIdentity {
                    if fetchedSnapshots.contains(where: { $0.activityIdentity == activityIdentity }) {
                        return true
                    }
                    if fetchedSnapshots.count == 1,
                       fetchedSnapshots[0].updatedAt <= committed.updatedAt {
                        return true
                    }
                    return false
                }
                return fetchedSnapshots.contains { $0.updatedAt <= committed.updatedAt }

            case .restoreSubscription:
                return false
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
        undoStack.removeAll()
    }

    private func hideDismissedActivity(
        activityIdentity: String?,
        threadId: String,
        updatedAt: Date,
        useLegacyThreadFallback: Bool,
        in notifications: inout [GitHubNotification]
    ) {
        if let activityIdentity,
           let exactIndex = notifications.firstIndex(where: { $0.activityIdentity == activityIdentity }) {
            notifications.remove(at: exactIndex)
            return
        }

        let threadSnapshotIndices = notifications.indices.filter {
            notifications[$0].threadId == threadId
        }

        guard threadSnapshotIndices.count == 1 else {
            if useLegacyThreadFallback {
                notifications.removeAll {
                    $0.threadId == threadId && $0.updatedAt <= updatedAt
                }
            }
            return
        }

        let snapshotIndex = threadSnapshotIndices[0]
        guard notifications[snapshotIndex].updatedAt <= updatedAt else {
            return
        }

        notifications.remove(at: snapshotIndex)
    }

    private mutating func removeUndoEntry(for requestID: UUID) {
        undoStack.removeAll {
            if case .cancelPending(_, let entryRequestID) = $0 {
                return entryRequestID == requestID
            }
            return false
        }
    }

    private mutating func pushUndo(_ entry: UndoEntry) {
        undoStack.append(entry)
        if undoStack.count > 50 {
            undoStack.removeFirst()
        }
    }

    private static func loadCommittedActions(from userDefaults: UserDefaults) -> [String: CommittedAction] {
        guard let data = userDefaults.data(forKey: committedThreadActionsStorageKey) else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let persisted = try? decoder.decode([PersistedCommittedAction].self, from: data) else {
            return [:]
        }

        return Dictionary(
            uniqueKeysWithValues: persisted.map {
                (
                    $0.threadId,
                    CommittedAction(
                        kind: $0.kind,
                        threadId: $0.threadId,
                        updatedAt: $0.updatedAt,
                        activityIdentity: $0.activityIdentity
                    )
                )
            }
        )
    }

    private func persistCommittedActions() {
        guard !committedActions.isEmpty else {
            userDefaults.removeObject(forKey: Self.committedThreadActionsStorageKey)
            return
        }

        let persisted = committedActions.values.map {
            PersistedCommittedAction(
                kind: $0.kind,
                threadId: $0.threadId,
                updatedAt: $0.updatedAt,
                activityIdentity: $0.activityIdentity
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(persisted) else {
            return
        }

        userDefaults.set(data, forKey: Self.committedThreadActionsStorageKey)
    }
}
