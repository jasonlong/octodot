import AppKit
import Observation

private let defaultActionDispatchDelayNanoseconds: UInt64 = 2_500_000_000
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
    typealias TokenSaver = @MainActor (String) throws -> Void
    typealias APIClientFactory = @MainActor (String) -> GitHubAPIClient
    private static let inboxModeStorageKey = "AppState.inboxMode.v1"
    private static let groupByRepoStorageKey = "AppState.groupByRepo.v1"
    private static let visibleSubjectStateBatchSize = 20
    private static let allModeRetentionInterval: TimeInterval = 30 * 24 * 60 * 60

    enum AuthStatus: Equatable {
        case signedOut
        case signedIn(username: String)
    }

    enum InboxMode: String, Equatable {
        case unread
        case all

        var includesReadNotifications: Bool {
            self == .all
        }

        var title: String {
            switch self {
            case .unread: "Unread"
            case .all: "All"
            }
        }
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
    var inboxMode: InboxMode = .unread {
        didSet {
            guard inboxMode != oldValue else { return }
            persistInboxMode()
        }
    }
    var groupByRepo: Bool = true {
        didSet {
            guard groupByRepo != oldValue else { return }
            persistGroupByRepo()
            rebuildDerivedState()
        }
    }

    private var serverNotifications: [GitHubNotification] = []
    private var repositoryOrderAnchor: [String] = []
    private var selectedThreadID: String?
    private var selectedIndexStorage = 0
    private var threadActions: ThreadActionStore
    private var actionTasks: [String: Task<Void, Never>] = [:]
    private var batchDispatchTask: Task<Void, Never>?
    private var backgroundRefreshTask: Task<Void, Never>?
    private var subjectStateResolutionTask: Task<Void, Never>?
    private var pendingVisibleSubjectStateIDs: [String] = []
    private var visibleSubjectStateInFlightIDs: Set<String> = []
    private var lastActionDebugThreadID: String?
    private var lastActionDebugKind: String?
    private var activeLoadRequestID = UUID()
    private var apiClient: GitHubAPIClient?
    private let actionDispatchDelayNanoseconds: UInt64
    private let backgroundRefreshEnabled: Bool
    private let sleepHandler: SleepHandler
    private let userDefaults: UserDefaults
    private let urlOpener: URLOpener
    private let tokenSaver: TokenSaver
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
        tokenSaver: @escaping TokenSaver = { _ in },
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
        self.tokenSaver = tokenSaver
        self.tokenDeleter = tokenDeleter
        self.apiClientFactory = apiClientFactory
        self.threadActions = ThreadActionStore(userDefaults: userDefaults)
        self.inboxMode = Self.loadInboxMode(from: userDefaults)
        self.groupByRepo = Self.loadGroupByRepo(from: userDefaults)
        self.repositoryOrderAnchor = Self.repositoryOrder(from: notifications)
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
            tokenSaver: { try KeychainHelper.saveToken($0) },
            tokenDeleter: { KeychainHelper.deleteToken() },
            apiClientFactory: { GitHubAPIClient(token: $0) },
            bootstrapToken: KeychainHelper.loadToken()
        )
    }

    func submitToken(_ token: String) async throws {
        let client = apiClientFactory(token)
        let username = try await client.validateToken()
        try tokenSaver(token)
        errorMessage = nil
        signIn(token: token, username: username)
    }

    func toggleGroupByRepo() {
        groupByRepo.toggle()
        clampSelection()
    }

    func toggleInboxMode() {
        setInboxMode(inboxMode == .unread ? .all : .unread)
    }

    func setInboxMode(_ mode: InboxMode) {
        guard inboxMode != mode else { return }
        inboxMode = mode
        refresh(force: true)
    }

    func notificationBecameVisible(id: String) {
        guard let notification = filteredNotifications.first(where: { $0.id == id }),
              notification.isUnread,
              notification.subjectURL != nil,
              notification.subjectState == .unknown,
              !pendingVisibleSubjectStateIDs.contains(id),
              !visibleSubjectStateInFlightIDs.contains(id) else {
            return
        }

        pendingVisibleSubjectStateIDs.append(id)
        scheduleVisibleSubjectStateResolutionIfNeeded()
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
                self.threadActions.clearCommittedActions()
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
        cancelSubjectStateResolution()
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
        cancelSubjectStateResolution()
        cancelAllPendingActions()
        activeLoadRequestID = UUID()
        tokenDeleter()
        apiClient = nil
        authStatus = .signedOut
        serverNotifications = []
        repositoryOrderAnchor = []
        threadActions.clearCommittedActions()
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
        cancelSubjectStateResolution()
        isLoading = true
        do {
            let fetched = try await client.fetchNotifications(
                all: inboxMode.includesReadNotifications,
                force: force
            )
            guard requestID == activeLoadRequestID else { return }
            serverNotifications = fetched
            threadActions.reconcileCommittedActions(with: fetched)
            repositoryOrderAnchor = Self.repositoryOrder(from: filteredNotificationsForCurrentMode(fetched))
            isLoading = false
            errorMessage = nil
            rebuildDerivedState()
            DebugTrace.log(
                "load applied mode=\(inboxMode.rawValue) server.count=\(serverNotifications.count) " +
                "visible.count=\(filteredNotifications.count) visible.top=\(Self.topIDs(in: filteredNotifications))"
            )
            logLastActionSnapshot(context: "after-load")
        } catch {
            guard requestID == activeLoadRequestID else { return }
            isLoading = false
            errorMessage = error.localizedDescription
            logLastActionSnapshot(context: "load-failed")
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
        switch threadActions.applyUndo() {
        case .none:
            clampSelection()
        case .cancelQueued(let pending):
            actionTasks.removeValue(forKey: pending.notification.threadId)?.cancel()
            errorMessage = nil
            if pending.kind.hidesNotification || pending.kind == .restoreSubscription {
                selectedThreadID = pending.notification.id
                selectedIndexStorage = pending.originalServerIndex
            }
            clampSelection()
        case .restoreSubscription(let notification, let originalServerIndex):
            startRestoreSubscriptionUndo(notification: notification, originalServerIndex: originalServerIndex)
        }
    }

    func refresh(force: Bool = false) {
        searchQuery = ""
        isSearchActive = false
        flushPendingActions()
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

    func flushPendingActions() {
        batchDispatchTask?.cancel()
        batchDispatchTask = nil

        guard let client = apiClient else { return }
        dispatchQueuedActions(using: client)
    }

    private func rebuildDerivedState() {
        let projected = threadActions.projectedNotifications(from: serverNotifications)
        let modeFiltered = filteredNotificationsForCurrentMode(projected)
        let serverModeFiltered = filteredNotificationsForCurrentMode(serverNotifications)
        notifications = modeFiltered
        unreadNotificationCount = modeFiltered.reduce(into: 0) { count, notification in
            if notification.isUnread {
                count += 1
            }
        }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = query.isEmpty ? modeFiltered : modeFiltered.filter {
            $0.title.lowercased().contains(query) || $0.repository.lowercased().contains(query)
        }

        let ordered = orderedNotifications(
            filtered,
            preferredRepositoryOrder: repositoryOrderAnchor,
            repoOrderSource: sortedByRecency(serverModeFiltered)
        )
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

    private func filteredNotificationsForCurrentMode(_ notifications: [GitHubNotification]) -> [GitHubNotification] {
        guard inboxMode == .all else {
            return notifications
        }

        let cutoffDate = Date().addingTimeInterval(-Self.allModeRetentionInterval)
        return notifications.filter { $0.updatedAt >= cutoffDate }
    }

    private func orderedNotifications(
        _ notifications: [GitHubNotification],
        preferredRepositoryOrder: [String],
        repoOrderSource: [GitHubNotification]
    ) -> [GitHubNotification] {
        if !groupByRepo {
            return sortedByRecency(notifications)
        }

        let grouped = Dictionary(grouping: notifications, by: \.repository)
        let anchoredRepositories = preferredRepositoryOrder.filter { grouped[$0] != nil }
        let serverOrderedRepositories = repoOrderSource.reduce(into: [String]()) { order, notification in
            guard grouped[notification.repository] != nil,
                  !order.contains(notification.repository) else {
                return
            }
            order.append(notification.repository)
        }
        let remainingRepositories = serverOrderedRepositories.filter { !anchoredRepositories.contains($0) }
        let fallbackRepositories = grouped.keys
            .filter { !anchoredRepositories.contains($0) && !remainingRepositories.contains($0) }
            .sorted()
        let orderedRepositories = anchoredRepositories + remainingRepositories + fallbackRepositories

        return orderedRepositories.flatMap { repository in
            sortedByRecency(grouped[repository] ?? [])
        }
    }

    private func sortedByRecency(_ notifications: [GitHubNotification]) -> [GitHubNotification] {
        notifications.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id > rhs.id
        }
    }

    private static func repositoryOrder(from notifications: [GitHubNotification]) -> [String] {
        notifications
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id > rhs.id
            }
            .reduce(into: [String]()) { order, notification in
            guard !order.contains(notification.repository) else { return }
            order.append(notification.repository)
        }
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
        _ kind: ThreadActionStore.ActionKind,
        delayNanosecondsOverride: UInt64? = nil,
        pushesUndo: Bool = true
    ) {
        guard let client = apiClient,
              let target = selectedNotification else {
            return
        }
        guard !threadActions.hasPendingAction(for: target.threadId) else { return }
        if kind == .markRead && !target.isUnread { return }

        DebugTrace.log(
            "start action kind=\(kind.rawValue) target.id=\(target.id) target.thread=\(target.threadId) " +
            "selected=\(selectedNotificationID ?? "nil") visible=\(filteredNotifications.map(\.id).joined(separator: ","))"
        )
        lastActionDebugThreadID = target.threadId
        lastActionDebugKind = kind.rawValue

        let originalServerIndex = serverNotifications.firstIndex(where: { $0.id == target.id }) ?? serverNotifications.count
        let pending = threadActions.start(
            kind,
            notification: target,
            originalServerIndex: originalServerIndex,
            pushesUndo: pushesUndo
        )

        let visibleBeforeMutation = filteredNotifications

        if kind.hidesNotification {
            selectedThreadID = selectionAfterRemoving(threadId: target.id, from: visibleBeforeMutation)
            selectedIndexStorage = min(selectedIndexStorage, max(0, visibleBeforeMutation.count - 2))
        }
        clampSelection()
        DebugTrace.log(
            "after local action kind=\(kind.rawValue) selected=\(selectedNotificationID ?? "nil") " +
            "visible=\(filteredNotifications.map(\.id).joined(separator: ","))"
        )

        let delayNanoseconds = delayNanosecondsOverride ?? actionDelay(for: kind)
        if delayNanoseconds == 0 {
            dispatchPendingActionImmediately(client: client, pending: pending)
        } else {
            scheduleBatchDispatch(client: client, delayNanoseconds: delayNanoseconds)
        }
    }

    private func startRestoreSubscriptionUndo(notification: GitHubNotification, originalServerIndex: Int) {
        guard let client = apiClient else { return }

        let pending = threadActions.start(
            .restoreSubscription,
            notification: notification,
            originalServerIndex: originalServerIndex,
            pushesUndo: false
        )

        selectedThreadID = notification.id
        selectedIndexStorage = originalServerIndex
        errorMessage = nil
        clampSelection()

        dispatchPendingActionImmediately(client: client, pending: pending)
    }

    private func scheduleBatchDispatch(client: GitHubAPIClient, delayNanoseconds: UInt64) {
        batchDispatchTask?.cancel()
        batchDispatchTask = Task { [sleepHandler] in
            await sleepHandler(delayNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.batchDispatchTask = nil
                self.dispatchQueuedActions(using: client)
            }
        }
    }

    private func dispatchQueuedActions(using client: GitHubAPIClient) {
        let queuedActions = threadActions.queuedActionsForDispatch()
        guard !queuedActions.isEmpty else { return }

        for pending in queuedActions {
            dispatchPendingActionImmediately(client: client, pending: pending)
        }
    }

    private func dispatchPendingActionImmediately(
        client: GitHubAPIClient,
        pending: ThreadActionStore.PendingAction
    ) {
        DebugTrace.log(
            "dispatch pending kind=\(pending.kind.rawValue) target.id=\(pending.notification.id) " +
            "target.thread=\(pending.notification.threadId) request=\(pending.requestID.uuidString)"
        )
        actionTasks[pending.notification.threadId]?.cancel()
        actionTasks[pending.notification.threadId] = Task {
            await self.executePendingAction(client: client, pending: pending)
        }
    }

    private func executePendingAction(client: GitHubAPIClient, pending: ThreadActionStore.PendingAction) async {
        guard var current = threadActions.pendingAction(for: pending.notification.threadId),
              current.requestID == pending.requestID else {
            actionTasks[pending.notification.threadId] = nil
            return
        }

        current.phase = .executing
        threadActions.updatePendingAction(current)

        do {
            switch pending.kind {
            case .markRead:
                try await client.markAsRead(threadId: pending.notification.threadId)
            case .done:
                try await client.markAsDone(notification: pending.notification)
            case .unsubscribe:
                try await client.unsubscribe(notification: pending.notification)
            case .restoreSubscription:
                try await client.restoreSubscription(
                    threadId: pending.notification.threadId,
                    notification: pending.notification
                )
            }

            guard let latest = threadActions.pendingAction(for: pending.notification.threadId),
                  latest.requestID == pending.requestID else {
                actionTasks[pending.notification.threadId] = nil
                return
            }

            handlePendingActionSuccess(latest)
        } catch {
            if Task.isCancelled { return }
            guard let latest = threadActions.pendingAction(for: pending.notification.threadId),
                  latest.requestID == pending.requestID else {
                actionTasks[pending.notification.threadId] = nil
                return
            }

            handlePendingActionFailure(latest, error: error)
        }
    }

    private func handlePendingActionSuccess(_ pending: ThreadActionStore.PendingAction) {
        actionTasks[pending.notification.threadId] = nil
        let successEffect = threadActions.handleSuccess(pending, serverNotifications: &serverNotifications)
        DebugTrace.log(
            "success kind=\(pending.kind.rawValue) target.id=\(pending.notification.id) " +
            "target.thread=\(pending.notification.threadId) server=\(serverNotifications.map(\.id).joined(separator: ","))"
        )
        if case .restoreSubscription(let notification, let originalServerIndex) = successEffect {
            startRestoreSubscriptionUndo(
                notification: notification,
                originalServerIndex: originalServerIndex
            )
        }

        errorMessage = nil
        rebuildDerivedState()
        DebugTrace.log(
            "after rebuild success kind=\(pending.kind.rawValue) selected=\(selectedNotificationID ?? "nil") " +
            "visible=\(filteredNotifications.map(\.id).joined(separator: ","))"
        )
        logLastActionSnapshot(context: "after-action-success")
    }

    private func handlePendingActionFailure(_ pending: ThreadActionStore.PendingAction, error _: Error) {
        actionTasks[pending.notification.threadId] = nil

        if pending.kind.hidesNotification {
            selectedThreadID = pending.notification.id
            selectedIndexStorage = pending.originalServerIndex
        }

        errorMessage = threadActions.handleFailure(pending)
        rebuildDerivedState()
        DebugTrace.log(
            "failure kind=\(pending.kind.rawValue) target.id=\(pending.notification.id) " +
            "selected=\(selectedNotificationID ?? "nil") visible=\(filteredNotifications.map(\.id).joined(separator: ",")) " +
            "error=\(errorMessage ?? "unknown")"
        )
        logLastActionSnapshot(context: "after-action-failure")
    }

    private func logLastActionSnapshot(context: String) {
        guard let threadId = lastActionDebugThreadID else { return }

        let serverMatch = serverNotifications.first(where: { $0.threadId == threadId })
        let visibleMatch = filteredNotifications.first(where: { $0.threadId == threadId })
        DebugTrace.log(
            "snapshot context=\(context) kind=\(lastActionDebugKind ?? "unknown") thread=\(threadId) " +
            "server.present=\(serverMatch != nil) server.unread=\(serverMatch?.isUnread.description ?? "nil") " +
            "server.updated=\(serverMatch.map { Self.debugDate($0.updatedAt) } ?? "nil") " +
            "visible.present=\(visibleMatch != nil) visible.unread=\(visibleMatch?.isUnread.description ?? "nil") " +
            "selected=\(selectedNotificationID ?? "nil")"
        )
    }

    private static func debugDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func topIDs(in notifications: [GitHubNotification], limit: Int = 10) -> String {
        let ids = notifications.prefix(limit).map(\.id)
        return ids.isEmpty ? "none" : ids.joined(separator: ",")
    }

    private func cancelAllPendingActions() {
        batchDispatchTask?.cancel()
        batchDispatchTask = nil
        for task in actionTasks.values {
            task.cancel()
        }
        actionTasks.removeAll()
        threadActions.cancelAllPendingActions()
    }

    private func cancelSubjectStateResolution() {
        subjectStateResolutionTask?.cancel()
        subjectStateResolutionTask = nil
        pendingVisibleSubjectStateIDs = []
        visibleSubjectStateInFlightIDs = []
    }

    private func scheduleVisibleSubjectStateResolutionIfNeeded() {
        guard let client = apiClient else {
            cancelSubjectStateResolution()
            return
        }

        guard subjectStateResolutionTask == nil else {
            return
        }

        let candidateIDs = Array(pendingVisibleSubjectStateIDs.prefix(Self.visibleSubjectStateBatchSize))
        guard !candidateIDs.isEmpty else {
            return
        }

        pendingVisibleSubjectStateIDs.removeAll { candidateIDs.contains($0) }
        visibleSubjectStateInFlightIDs.formUnion(candidateIDs)
        let candidates = candidateIDs.compactMap { candidateID in
            filteredNotifications.first(where: { $0.id == candidateID })
        }

        subjectStateResolutionTask = Task { [weak self, client, candidates, candidateIDs] in
            let resolvedStates = await client.resolveSubjectStates(for: candidates)
            guard !Task.isCancelled else { return }
            self?.applyResolvedSubjectStates(resolvedStates, expectedIDs: candidateIDs)
        }
    }

    private func applyResolvedSubjectStates(
        _ resolvedStates: [String: GitHubNotification.SubjectState],
        expectedIDs: [String]
    ) {
        subjectStateResolutionTask = nil
        visibleSubjectStateInFlightIDs.subtract(expectedIDs)

        var didChange = false
        for index in serverNotifications.indices {
            guard let resolvedState = resolvedStates[serverNotifications[index].id],
                  serverNotifications[index].subjectState != resolvedState else {
                continue
            }

            serverNotifications[index].subjectState = resolvedState
            didChange = true
        }

        if didChange {
            rebuildDerivedState()
        }

        scheduleVisibleSubjectStateResolutionIfNeeded()
    }

    private func selectionAfterRemoving(threadId: String, from list: [GitHubNotification]) -> String? {
        guard let removeIndex = list.firstIndex(where: { $0.id == threadId }) else {
            return selectedThreadID
        }
        guard list.count > 1 else { return nil }

        let nextIndex = min(removeIndex, list.count - 2)
        return list[nextIndex].id
    }

    private func actionDelay(for kind: ThreadActionStore.ActionKind) -> UInt64 {
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
                await self.performBackgroundRefresh()
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

    private func performBackgroundRefresh() async {
        if isPanelVisible || inboxMode == .unread {
            await loadNotifications()
            return
        }

        await refreshUnreadCountInBackground()
    }

    private func refreshUnreadCountInBackground() async {
        guard let client = apiClient else { return }

        do {
            let fetched = try await client.fetchNotifications(all: false, force: false)
            unreadNotificationCount = fetched.reduce(into: 0) { count, notification in
                if notification.isUnread {
                    count += 1
                }
            }
        } catch {
            // Ignore background-only refresh failures while the heavy "All" feed is hidden.
        }
    }

    private static func loadInboxMode(from userDefaults: UserDefaults) -> InboxMode {
        guard let rawValue = userDefaults.string(forKey: inboxModeStorageKey),
              let mode = InboxMode(rawValue: rawValue) else {
            return .unread
        }
        return mode
    }

    private static func loadGroupByRepo(from userDefaults: UserDefaults) -> Bool {
        guard userDefaults.object(forKey: groupByRepoStorageKey) != nil else {
            return true
        }
        return userDefaults.bool(forKey: groupByRepoStorageKey)
    }

    private func persistInboxMode() {
        userDefaults.set(inboxMode.rawValue, forKey: Self.inboxModeStorageKey)
    }

    private func persistGroupByRepo() {
        userDefaults.set(groupByRepo, forKey: Self.groupByRepoStorageKey)
    }
}
