import AppKit
import Observation

private let defaultActionDispatchDelayNanoseconds: UInt64 = 1_500_000_000
private let defaultBackgroundRefreshFallbackNanoseconds: UInt64 = 60_000_000_000

private let defaultSleepHandler: AppState.SleepHandler = { nanoseconds in
    guard nanoseconds > 0 else { return }
    try? await Task.sleep(nanoseconds: nanoseconds)
}

@MainActor
@Observable
final class AppState {
    typealias SleepHandler = @Sendable (UInt64) async -> Void
    typealias URLOpener = @MainActor (URL) -> Bool
    typealias TokenDeleter = @MainActor () -> Void
    typealias APIClientFactory = @MainActor (String) -> GitHubAPIClient
    private static let committedThreadActionsStorageKey = "AppState.committedThreadActions.v1"

    enum AuthStatus: Equatable {
        case signedOut
        case signedIn(username: String)
    }

    private enum ThreadActionKind: String, Codable {
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

    private enum PendingActionPhase {
        case queued
        case executing
    }

    private struct PendingThreadAction {
        let requestID: UUID
        let kind: ThreadActionKind
        let notification: GitHubNotification
        let originalServerIndex: Int
        var phase: PendingActionPhase
        var restoreAfterSuccess: Bool = false
    }

    private struct CommittedThreadAction {
        let kind: ThreadActionKind
        let threadId: String
        let updatedAt: Date
    }

    private struct PersistedCommittedThreadAction: Codable {
        let kind: ThreadActionKind
        let threadId: String
        let updatedAt: Date
    }

    private enum UndoEntry {
        case cancelPending(threadId: String, requestID: UUID)
        case restoreSubscription(notification: GitHubNotification, originalServerIndex: Int)
    }

    var authStatus: AuthStatus = .signedOut
    var isPanelVisible: Bool = false
    var isSearchActive: Bool = false
    var searchQuery: String = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            rebuildDerivedState()
        }
    }
    var isLoading: Bool = false
    var errorMessage: String?
    var groupByRepo: Bool = true {
        didSet {
            guard groupByRepo != oldValue else { return }
            rebuildDerivedState()
        }
    }

    private var serverNotifications: [GitHubNotification] = []
    private var selectedThreadID: String?
    private var selectedIndexStorage = 0
    private var pendingThreadActions: [String: PendingThreadAction] = [:]
    private var committedThreadActions: [String: CommittedThreadAction] = [:]
    private var undoStack: [UndoEntry] = []
    private var actionTasks: [String: Task<Void, Never>] = [:]
    private var backgroundRefreshTask: Task<Void, Never>?
    private var activeLoadRequestID = UUID()
    private var apiClient: GitHubAPIClient?
    private let actionDispatchDelayNanoseconds: UInt64
    private let backgroundRefreshEnabled: Bool
    private let sleepHandler: SleepHandler
    private let userDefaults: UserDefaults
    private let urlOpener: URLOpener
    private let tokenDeleter: TokenDeleter
    private let apiClientFactory: APIClientFactory

    private(set) var notifications: [GitHubNotification] = []
    private(set) var unreadNotificationCount = 0
    private(set) var filteredNotifications: [GitHubNotification] = []
    private(set) var selectedNotification: GitHubNotification?
    private(set) var selectedNotificationID: String?

    var isSignedIn: Bool {
        if case .signedIn = authStatus { return true }
        return false
    }

    var selectedIndex: Int {
        get {
            filteredNotifications.isEmpty ? 0 : selectedIndexStorage
        }
        set {
            let list = filteredNotifications
            guard !list.isEmpty else {
                clearSelection()
                return
            }

            let clamped = max(0, min(newValue, list.count - 1))
            applySelection(index: clamped, in: list)
        }
    }

    init(
        notifications: [GitHubNotification],
        authStatus: AuthStatus = .signedOut,
        apiClient: GitHubAPIClient? = nil,
        actionDispatchDelayNanoseconds: UInt64 = defaultActionDispatchDelayNanoseconds,
        backgroundRefreshEnabled: Bool = false,
        sleepHandler: @escaping SleepHandler = defaultSleepHandler,
        userDefaults: UserDefaults = .standard,
        urlOpener: @escaping URLOpener = { NSWorkspace.shared.open($0) },
        tokenDeleter: @escaping TokenDeleter = {},
        apiClientFactory: @escaping APIClientFactory = { GitHubAPIClient(token: $0) },
        bootstrapToken: String? = nil
    ) {
        self.authStatus = authStatus
        self.apiClient = apiClient
        self.serverNotifications = notifications
        self.actionDispatchDelayNanoseconds = actionDispatchDelayNanoseconds
        self.backgroundRefreshEnabled = backgroundRefreshEnabled
        self.sleepHandler = sleepHandler
        self.userDefaults = userDefaults
        self.urlOpener = urlOpener
        self.tokenDeleter = tokenDeleter
        self.apiClientFactory = apiClientFactory
        self.committedThreadActions = Self.loadCommittedThreadActions(from: userDefaults)
        self.selectedThreadID = notifications.first?.id
        rebuildDerivedState()

        if let bootstrapToken {
            let client = apiClientFactory(bootstrapToken)
            self.apiClient = client
            self.authStatus = .signedIn(username: "")
            Task { await validateAndLoad(client: client) }
        }

        startBackgroundRefreshIfNeeded()
    }

    convenience init() {
        self.init(
            notifications: [],
            actionDispatchDelayNanoseconds: defaultActionDispatchDelayNanoseconds,
            backgroundRefreshEnabled: true,
            sleepHandler: defaultSleepHandler,
            userDefaults: .standard,
            urlOpener: { NSWorkspace.shared.open($0) },
            tokenDeleter: { KeychainHelper.deleteToken() },
            apiClientFactory: { GitHubAPIClient(token: $0) },
            bootstrapToken: KeychainHelper.loadToken()
        )
    }

    func toggleGroupByRepo() {
        groupByRepo.toggle()
        clampSelection()
    }

    private func validateAndLoad(client: GitHubAPIClient) async {
        do {
            let username = try await client.validateToken()
            self.authStatus = .signedIn(username: username)
            self.apiClient = client
            await loadNotifications(force: true)
            startBackgroundRefreshIfNeeded()
        } catch {
            cancelBackgroundRefresh()

            if case GitHubAPIClient.APIError.unauthorized = error {
                self.authStatus = .signedOut
                self.apiClient = nil
                self.committedThreadActions.removeAll()
                self.persistCommittedThreadActions()
                tokenDeleter()
                rebuildDerivedState()
            } else {
                self.authStatus = .signedIn(username: "")
                self.apiClient = client
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func signIn(token: String, username: String) {
        cancelBackgroundRefresh()
        cancelAllPendingActions()
        activeLoadRequestID = UUID()
        apiClient = apiClientFactory(token)
        authStatus = .signedIn(username: username)
        Task {
            await loadNotifications(force: true)
            startBackgroundRefreshIfNeeded()
        }
    }

    func signOut() {
        cancelBackgroundRefresh()
        cancelAllPendingActions()
        activeLoadRequestID = UUID()
        tokenDeleter()
        apiClient = nil
        authStatus = .signedOut
        serverNotifications = []
        committedThreadActions.removeAll()
        persistCommittedThreadActions()
        errorMessage = nil
        searchQuery = ""
        isSearchActive = false
        clearSelection()
        rebuildDerivedState()
    }

    func loadNotifications(force: Bool = false) async {
        guard let client = apiClient else { return }
        let requestID = UUID()
        activeLoadRequestID = requestID
        isLoading = true
        do {
            let fetched = try await client.fetchNotifications(force: force)
            guard requestID == activeLoadRequestID else { return }
            serverNotifications = fetched
            reconcileCommittedThreadActions(with: fetched)
            isLoading = false
            errorMessage = nil
            rebuildDerivedState()
        } catch {
            guard requestID == activeLoadRequestID else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func moveDown() {
        let count = filteredNotifications.count
        guard count > 0 else { return }
        selectedIndex = min(selectedIndex + 1, count - 1)
    }

    func moveUp() {
        guard !filteredNotifications.isEmpty else { return }
        selectedIndex = max(selectedIndex - 1, 0)
    }

    func jumpToTop() {
        guard !filteredNotifications.isEmpty else { return }
        selectedIndex = 0
    }

    func jumpToBottom() {
        let count = filteredNotifications.count
        guard count > 0 else { return }
        selectedIndex = count - 1
    }

    func done() {
        startThreadAction(.done)
    }

    func markRead() {
        startThreadAction(.markRead)
    }

    func unsubscribeFromThread() {
        startThreadAction(.unsubscribe)
    }

    func copyURL() {
        guard let notification = selectedNotification else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(notification.url.absoluteString, forType: .string)
    }

    func openInBrowser() -> Bool {
        guard let notification = selectedNotification else { return false }
        let didOpen = urlOpener(notification.url)
        if didOpen, notification.isUnread {
            startThreadAction(.markRead, delayNanosecondsOverride: 0, pushesUndo: false)
        }
        return didOpen
    }

    func undo() {
        while let entry = undoStack.popLast() {
            switch entry {
            case .cancelPending(let threadId, let requestID):
                guard var pending = pendingThreadActions[threadId],
                      pending.requestID == requestID else {
                    continue
                }

                switch pending.phase {
                case .queued:
                    actionTasks.removeValue(forKey: threadId)?.cancel()
                    pendingThreadActions.removeValue(forKey: threadId)
                    errorMessage = nil

                    if pending.kind.hidesNotification || pending.kind == .restoreSubscription {
                        selectedThreadID = pending.notification.id
                        selectedIndexStorage = pending.originalServerIndex
                    }
                    clampSelection()
                    return

                case .executing:
                    guard pending.kind == .unsubscribe else {
                        clampSelection()
                        return
                    }

                    pending.restoreAfterSuccess = true
                    pendingThreadActions[threadId] = pending
                    errorMessage = nil
                    return
                }

            case .restoreSubscription(let notification, let originalServerIndex):
                guard pendingThreadActions[notification.threadId] == nil else {
                    continue
                }

                committedThreadActions.removeValue(forKey: notification.threadId)
                persistCommittedThreadActions()
                startRestoreSubscriptionUndo(notification: notification, originalServerIndex: originalServerIndex)
                return
            }
        }
    }

    func refresh(force: Bool = false) {
        searchQuery = ""
        isSearchActive = false
        if apiClient != nil {
            Task { await loadNotifications(force: force) }
        } else {
            serverNotifications = MockData.generateNotifications()
            selectedIndexStorage = 0
            selectedThreadID = serverNotifications.first?.id
            rebuildDerivedState()
        }
    }

    func activateSearch() {
        isSearchActive = true
    }

    func deactivateSearch() {
        isSearchActive = false
        searchQuery = ""
    }

    func selectNotification(id: String) {
        guard let index = filteredNotifications.firstIndex(where: { $0.id == id }) else {
            return
        }
        applySelection(index: index, in: filteredNotifications)
    }

    func clampSelection() {
        rebuildDerivedState()
    }

    private func rebuildDerivedState() {
        let projected = projectedNotifications(from: serverNotifications)
        notifications = projected
        unreadNotificationCount = projected.reduce(into: 0) { count, notification in
            if notification.isUnread {
                count += 1
            }
        }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = query.isEmpty ? projected : projected.filter {
            $0.title.lowercased().contains(query) || $0.repository.lowercased().contains(query)
        }

        let ordered = orderedNotifications(filtered)
        filteredNotifications = ordered

        guard !ordered.isEmpty else {
            clearSelection()
            return
        }

        if let selectedThreadID,
           let index = ordered.firstIndex(where: { $0.id == selectedThreadID }) {
            selectedIndexStorage = index
        } else {
            selectedIndexStorage = min(selectedIndexStorage, ordered.count - 1)
        }

        applySelection(index: selectedIndexStorage, in: ordered)
    }

    private func orderedNotifications(_ notifications: [GitHubNotification]) -> [GitHubNotification] {
        if !groupByRepo {
            return notifications.sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id > rhs.id
            }
        }

        let grouped = Dictionary(grouping: notifications, by: \.repository)
        let orderedRepositories = grouped.keys.sorted { lhs, rhs in
            let lhsMostRecent = grouped[lhs]?.map(\.updatedAt).max() ?? .distantPast
            let rhsMostRecent = grouped[rhs]?.map(\.updatedAt).max() ?? .distantPast

            if lhsMostRecent != rhsMostRecent {
                return lhsMostRecent > rhsMostRecent
            }

            return lhs < rhs
        }

        return orderedRepositories.flatMap { repository in
            (grouped[repository] ?? []).sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id > rhs.id
            }
        }
    }

    private func projectedNotifications(from baseNotifications: [GitHubNotification]) -> [GitHubNotification] {
        var projected = baseNotifications

        for committed in committedThreadActions.values {
            switch committed.kind {
            case .markRead:
                if let index = projected.firstIndex(where: { $0.threadId == committed.threadId }),
                   projected[index].updatedAt <= committed.updatedAt {
                    projected[index].isUnread = false
                }
            case .done, .unsubscribe:
                projected.removeAll { $0.threadId == committed.threadId }
            case .restoreSubscription:
                break
            }
        }

        for pending in pendingThreadActions.values {
            switch pending.kind {
            case .markRead:
                if let index = projected.firstIndex(where: { $0.threadId == pending.notification.threadId }) {
                    projected[index].isUnread = false
                }

            case .done, .unsubscribe:
                projected.removeAll { $0.threadId == pending.notification.threadId }

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

    private func applySelection(index: Int, in notifications: [GitHubNotification]) {
        guard !notifications.isEmpty else {
            clearSelection()
            return
        }

        let clampedIndex = max(0, min(index, notifications.count - 1))
        let selected = notifications[clampedIndex]
        selectedIndexStorage = clampedIndex
        selectedThreadID = selected.id
        selectedNotificationID = selected.id
        selectedNotification = selected
    }

    private func clearSelection() {
        selectedIndexStorage = 0
        selectedThreadID = nil
        selectedNotificationID = nil
        selectedNotification = nil
    }

    private func startThreadAction(
        _ kind: ThreadActionKind,
        delayNanosecondsOverride: UInt64? = nil,
        pushesUndo: Bool = true
    ) {
        guard let client = apiClient,
              let target = selectedNotification else {
            return
        }
        guard pendingThreadActions[target.threadId] == nil else { return }
        if kind == .markRead && !target.isUnread { return }

        let originalServerIndex = serverNotifications.firstIndex(where: { $0.id == target.id }) ?? serverNotifications.count
        let requestID = UUID()
        let pending = PendingThreadAction(
            requestID: requestID,
            kind: kind,
            notification: target,
            originalServerIndex: originalServerIndex,
            phase: .queued
        )

        let visibleBeforeMutation = filteredNotifications
        pendingThreadActions[target.threadId] = pending
        if pushesUndo {
            pushUndo(.cancelPending(threadId: target.threadId, requestID: requestID))
        }

        if kind.hidesNotification {
            selectedThreadID = selectionAfterRemoving(threadId: target.id, from: visibleBeforeMutation)
            selectedIndexStorage = min(selectedIndexStorage, max(0, visibleBeforeMutation.count - 2))
        }
        clampSelection()

        schedulePendingAction(
            client: client,
            pending: pending,
            delayNanoseconds: delayNanosecondsOverride ?? actionDelay(for: kind)
        )
    }

    private func startRestoreSubscriptionUndo(notification: GitHubNotification, originalServerIndex: Int) {
        guard let client = apiClient else { return }

        let requestID = UUID()
        let pending = PendingThreadAction(
            requestID: requestID,
            kind: .restoreSubscription,
            notification: notification,
            originalServerIndex: originalServerIndex,
            phase: .queued
        )

        pendingThreadActions[notification.threadId] = pending
        selectedThreadID = notification.id
        selectedIndexStorage = originalServerIndex
        errorMessage = nil
        clampSelection()

        schedulePendingAction(client: client, pending: pending, delayNanoseconds: actionDelay(for: .restoreSubscription))
    }

    private func schedulePendingAction(
        client: GitHubAPIClient,
        pending: PendingThreadAction,
        delayNanoseconds: UInt64
    ) {
        actionTasks[pending.notification.threadId]?.cancel()
        actionTasks[pending.notification.threadId] = Task { [sleepHandler] in
            await sleepHandler(delayNanoseconds)
            guard !Task.isCancelled else { return }
            await self.executePendingAction(client: client, pending: pending)
        }
    }

    private func executePendingAction(client: GitHubAPIClient, pending: PendingThreadAction) async {
        guard var current = pendingThreadActions[pending.notification.threadId],
              current.requestID == pending.requestID else {
            actionTasks[pending.notification.threadId] = nil
            return
        }

        current.phase = .executing
        pendingThreadActions[pending.notification.threadId] = current

        do {
            switch pending.kind {
            case .markRead:
                try await client.markAsRead(threadId: pending.notification.threadId)
            case .done:
                try await client.markAsDone(threadId: pending.notification.threadId)
            case .unsubscribe:
                try await client.unsubscribe(threadId: pending.notification.threadId)
            case .restoreSubscription:
                try await client.restoreSubscription(
                    threadId: pending.notification.threadId,
                    notification: pending.notification,
                    originalIndex: pending.originalServerIndex
                )
            }

            guard let latest = pendingThreadActions[pending.notification.threadId],
                  latest.requestID == pending.requestID else {
                actionTasks[pending.notification.threadId] = nil
                return
            }

            handlePendingActionSuccess(latest)
        } catch {
            if Task.isCancelled { return }
            guard let latest = pendingThreadActions[pending.notification.threadId],
                  latest.requestID == pending.requestID else {
                actionTasks[pending.notification.threadId] = nil
                return
            }

            handlePendingActionFailure(latest, error: error)
        }
    }

    private func handlePendingActionSuccess(_ pending: PendingThreadAction) {
        actionTasks[pending.notification.threadId] = nil
        pendingThreadActions[pending.notification.threadId] = nil

        switch pending.kind {
        case .markRead:
            if let index = serverNotifications.firstIndex(where: { $0.threadId == pending.notification.threadId }) {
                serverNotifications[index].isUnread = false
            }
            committedThreadActions[pending.notification.threadId] = CommittedThreadAction(
                kind: .markRead,
                threadId: pending.notification.threadId,
                updatedAt: pending.notification.updatedAt
            )
            persistCommittedThreadActions()
            removeUndoEntry(for: pending.requestID)

        case .done:
            serverNotifications.removeAll { $0.threadId == pending.notification.threadId }
            committedThreadActions[pending.notification.threadId] = CommittedThreadAction(
                kind: .done,
                threadId: pending.notification.threadId,
                updatedAt: pending.notification.updatedAt
            )
            persistCommittedThreadActions()
            removeUndoEntry(for: pending.requestID)

        case .unsubscribe:
            serverNotifications.removeAll { $0.threadId == pending.notification.threadId }
            if pending.restoreAfterSuccess {
                startRestoreSubscriptionUndo(
                    notification: pending.notification,
                    originalServerIndex: pending.originalServerIndex
                )
            } else {
                committedThreadActions[pending.notification.threadId] = CommittedThreadAction(
                    kind: .unsubscribe,
                    threadId: pending.notification.threadId,
                    updatedAt: pending.notification.updatedAt
                )
                persistCommittedThreadActions()
                replaceUndoEntry(
                    for: pending.requestID,
                    with: .restoreSubscription(
                        notification: pending.notification,
                        originalServerIndex: pending.originalServerIndex
                    )
                )
            }

        case .restoreSubscription:
            committedThreadActions.removeValue(forKey: pending.notification.threadId)
            persistCommittedThreadActions()
            if let index = serverNotifications.firstIndex(where: { $0.threadId == pending.notification.threadId }) {
                serverNotifications[index] = pending.notification
            } else {
                let insertAt = min(max(0, pending.originalServerIndex), serverNotifications.count)
                serverNotifications.insert(pending.notification, at: insertAt)
            }
        }

        errorMessage = nil
        rebuildDerivedState()
    }

    private func handlePendingActionFailure(_ pending: PendingThreadAction, error _: Error) {
        actionTasks[pending.notification.threadId] = nil
        pendingThreadActions[pending.notification.threadId] = nil
        removeUndoEntry(for: pending.requestID)

        if pending.kind.hidesNotification {
            selectedThreadID = pending.notification.id
            selectedIndexStorage = pending.originalServerIndex
        }

        errorMessage = pending.kind.failureMessage
        rebuildDerivedState()
    }

    private func removeUndoEntry(for requestID: UUID) {
        undoStack.removeAll {
            if case .cancelPending(_, let entryRequestID) = $0 {
                return entryRequestID == requestID
            }
            return false
        }
    }

    private func replaceUndoEntry(for requestID: UUID, with entry: UndoEntry) {
        if let index = undoStack.lastIndex(where: {
            if case .cancelPending(_, let entryRequestID) = $0 {
                return entryRequestID == requestID
            }
            return false
        }) {
            undoStack[index] = entry
        }
    }

    private func pushUndo(_ entry: UndoEntry) {
        undoStack.append(entry)
        if undoStack.count > 50 {
            undoStack.removeFirst()
        }
    }

    private func cancelAllPendingActions() {
        for task in actionTasks.values {
            task.cancel()
        }
        actionTasks.removeAll()
        pendingThreadActions.removeAll()
        undoStack.removeAll()
    }

    private func reconcileCommittedThreadActions(with fetchedNotifications: [GitHubNotification]) {
        let fetchedByThreadID = Dictionary(uniqueKeysWithValues: fetchedNotifications.map { ($0.threadId, $0) })
        committedThreadActions = committedThreadActions.filter { threadId, committed in
            switch committed.kind {
            case .markRead:
                guard let fetched = fetchedByThreadID[threadId] else {
                    return false
                }
                guard fetched.updatedAt <= committed.updatedAt else {
                    return false
                }
                return fetched.isUnread

            case .done, .unsubscribe:
                guard let fetched = fetchedByThreadID[threadId] else {
                    return true
                }
                return fetched.updatedAt <= committed.updatedAt

            case .restoreSubscription:
                return false
            }
        }
        persistCommittedThreadActions()
    }

    private func selectionAfterRemoving(threadId: String, from list: [GitHubNotification]) -> String? {
        guard let removeIndex = list.firstIndex(where: { $0.id == threadId }) else {
            return selectedThreadID
        }
        guard list.count > 1 else { return nil }

        let nextIndex = min(removeIndex, list.count - 2)
        return list[nextIndex].id
    }

    private func actionDelay(for kind: ThreadActionKind) -> UInt64 {
        switch kind {
        case .restoreSubscription:
            return 0
        case .markRead, .done, .unsubscribe:
            return actionDispatchDelayNanoseconds
        }
    }

    private func startBackgroundRefreshIfNeeded() {
        guard backgroundRefreshEnabled else { return }
        guard apiClient != nil else { return }
        guard backgroundRefreshTask == nil else { return }

        backgroundRefreshTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                let delayNanoseconds = await self.backgroundRefreshDelayNanoseconds()
                await self.sleepHandler(delayNanoseconds)
                guard !Task.isCancelled else { return }
                await self.loadNotifications()
            }
        }
    }

    private func cancelBackgroundRefresh() {
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = nil
    }

    private func backgroundRefreshDelayNanoseconds() async -> UInt64 {
        guard let client = apiClient else {
            return defaultBackgroundRefreshFallbackNanoseconds
        }

        let suggestedDelay = await client.suggestedRefreshDelayNanoseconds()
        return suggestedDelay > 0 ? suggestedDelay : defaultBackgroundRefreshFallbackNanoseconds
    }

    private static func loadCommittedThreadActions(from userDefaults: UserDefaults) -> [String: CommittedThreadAction] {
        guard let data = userDefaults.data(forKey: committedThreadActionsStorageKey) else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let persisted = try? decoder.decode([PersistedCommittedThreadAction].self, from: data) else {
            return [:]
        }

        return Dictionary(
            uniqueKeysWithValues: persisted.map {
                (
                    $0.threadId,
                    CommittedThreadAction(
                        kind: $0.kind,
                        threadId: $0.threadId,
                        updatedAt: $0.updatedAt
                    )
                )
            }
        )
    }

    private func persistCommittedThreadActions() {
        guard !committedThreadActions.isEmpty else {
            userDefaults.removeObject(forKey: Self.committedThreadActionsStorageKey)
            return
        }

        let persisted = committedThreadActions.values.map {
            PersistedCommittedThreadAction(
                kind: $0.kind,
                threadId: $0.threadId,
                updatedAt: $0.updatedAt
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
