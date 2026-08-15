import AppKit
import Observation

private let defaultActionDispatchDelayNanoseconds: UInt64 = 2_500_000_000
private let defaultBackgroundRefreshFallbackNanoseconds: UInt64 = 60_000_000_000

private let defaultSleepHandler: AppState.SleepHandler = { nanoseconds in
    guard nanoseconds > 0 else { return }
    try? await Task.sleep(for: .nanoseconds(nanoseconds))
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
    static let pageJumpCount = 8
    static let halfPageJumpCount = 4

    enum AuthStatus: Equatable {
        case signedOut
        case signedIn(username: String)
    }

    private struct RefreshPolicy {
        let forceUnread: Bool
        let forceRecentInbox: Bool
        let forceSecurityAlerts: Bool

        static func uniform(force: Bool) -> RefreshPolicy {
            RefreshPolicy(
                forceUnread: force,
                forceRecentInbox: force,
                forceSecurityAlerts: force
            )
        }

        static let panelPresentation = RefreshPolicy(
            forceUnread: false,
            forceRecentInbox: true,
            forceSecurityAlerts: false
        )
    }

    enum InboxMode: String, Equatable {
        case inbox
        case unread

        var includesReadNotifications: Bool {
            self == .inbox
        }

        var title: String {
            switch self {
            case .inbox: "Inbox"
            case .unread: "Unread"
            }
        }
    }

    var authStatus: AuthStatus = .signedOut
    var isPanelVisible: Bool = false {
        didSet {
            guard isPanelVisible != oldValue, !isPanelVisible else { return }
            actionToasts.removeAll()
            cancelSecurityAlertsRefresh()
            cancelSubjectStateResolution()
        }
    }
    var isSearchActive: Bool = false
    var searchQuery: String = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            rebuildDerivedState()
        }
    }
    var isLoading: Bool = false
    var errorMessage: String?
    var warningMessage: String?
    var inboxMode: InboxMode = .inbox {
        didSet {
            guard inboxMode != oldValue else { return }
            persistInboxMode()
            rebuildDerivedState()
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
    private var serverRecentInboxNotifications: [GitHubNotification] = []
    private var serverSecurityAlerts: [GitHubNotification] = []
    private var repositoryOrderAnchor: [String] = []
    private var selectedThreadID: String?
    private var selectedIndexStorage = 0
    private(set) var checkedThreadIDs: Set<String> = []
    private var shouldSelectTopItemOnNextLoad = false
    private var threadActions: ThreadActionStore
    private var actionTasks: [String: Task<Void, Never>] = [:]
    private var batchDispatchTask: Task<Void, Never>?
    private var backgroundRefreshTask: Task<Void, Never>?
    private var securityAlertsRefreshTask: Task<Void, Never>?
    private var subjectStateResolutionTask: Task<Void, Never>?
    private var pendingVisibleSubjectStateIDs: [String] = []
    private var visibleSubjectStateInFlightIDs: Set<String> = []
    private var shouldRefreshVisibleCIMetadataAfterNextRebuild = false
    private var lastActionDebugThreadID: String?
    private var lastActionDebugKind: String?
    private var activeAuthRequestID = UUID()
    private var activeLoadRequestID = UUID()
    private let inboxStore: InboxStore
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
    private(set) var filteredNotifications: [GitHubNotification] = []
    private(set) var unreadNotificationCount = 0
    private(set) var panelUnreadCount = 0
    private(set) var actionToasts: [ActionToast] = []

    struct ActionToast: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }

    private static func applySearchFilter(_ notifications: [GitHubNotification], query rawQuery: String) -> [GitHubNotification] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return notifications }
        return notifications.filter {
            $0.title.localizedStandardContains(query) || $0.repository.localizedStandardContains(query)
        }
    }

    var selectedNotification: GitHubNotification? {
        let visible = filteredNotifications
        guard !visible.isEmpty else { return nil }

        if let selectedThreadID,
           let selected = visible.first(where: { $0.id == selectedThreadID }) {
            return selected
        }

        let clampedIndex = max(0, min(selectedIndexStorage, visible.count - 1))
        return visible[clampedIndex]
    }

    var selectedNotificationID: String? {
        selectedNotification?.id
    }

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
        self.inboxStore = InboxStore(userDefaults: userDefaults, initialNotifications: notifications)
        self.inboxMode = Self.loadInboxMode(from: userDefaults)
        self.groupByRepo = Self.loadGroupByRepo(from: userDefaults)
        self.repositoryOrderAnchor = Self.repositoryOrder(from: notifications)
        self.selectedThreadID = notifications.first?.id
        rebuildDerivedState()

        if let bootstrapToken {
            let client = apiClientFactory(bootstrapToken)
            let requestID = UUID()
            self.activeAuthRequestID = requestID
            self.apiClient = client
            self.authStatus = .signedIn(username: "")
            self.shouldSelectTopItemOnNextLoad = true
            Task { [weak self] in
                await self?.validateAndLoad(client: client, requestID: requestID)
            }
        }

        if bootstrapToken == nil {
            startBackgroundRefreshIfNeeded()
        }
    }

    convenience init(
        userDefaults: UserDefaults = .standard,
        bootstrapToken: String? = KeychainHelper.loadToken(),
        useMockData: Bool = false
    ) {
        self.init(
            notifications: useMockData ? MockData.generateNotifications() : [],
            authStatus: useMockData ? .signedIn(username: "demo") : .signedOut,
            actionDispatchDelayNanoseconds: defaultActionDispatchDelayNanoseconds,
            backgroundRefreshEnabled: !useMockData,
            sleepHandler: defaultSleepHandler,
            userDefaults: userDefaults,
            urlOpener: { NSWorkspace.shared.open($0) },
            tokenSaver: { try KeychainHelper.saveToken($0) },
            tokenDeleter: { KeychainHelper.deleteToken() },
            apiClientFactory: { GitHubAPIClient(token: $0) },
            bootstrapToken: useMockData ? nil : bootstrapToken
        )
    }

    func submitToken(_ token: String) async throws {
        let requestID = UUID()
        activeAuthRequestID = requestID
        activeLoadRequestID = UUID()
        isLoading = false
        let client = apiClientFactory(token)
        let username: String
        do {
            username = try await client.validateToken()
        } catch {
            guard requestID == activeAuthRequestID else { return }
            throw error
        }
        guard requestID == activeAuthRequestID else { return }
        try tokenSaver(token)
        errorMessage = nil
        warningMessage = nil
        signIn(token: token, username: username)
    }

    func toggleGroupByRepo() {
        groupByRepo.toggle()
        clampSelection()
    }

    func toggleInboxMode() {
        setInboxMode(inboxMode == .unread ? .inbox : .unread)
    }

    func setInboxMode(_ mode: InboxMode) {
        guard inboxMode != mode else { return }
        inboxMode = mode
        refresh(force: true)
    }

    func notificationBecameVisible(id: String) {
        guard let notification = filteredNotifications.first(where: { $0.id == id }),
              notification.needsSubjectMetadataResolution,
              !pendingVisibleSubjectStateIDs.contains(id),
              !visibleSubjectStateInFlightIDs.contains(id) else {
            return
        }

        pendingVisibleSubjectStateIDs.append(id)
        scheduleVisibleSubjectStateResolutionIfNeeded()
    }

    private func validateAndLoad(client: GitHubAPIClient, requestID: UUID) async {
        do {
            let username = try await client.validateToken()
            guard requestID == activeAuthRequestID else { return }
            self.authStatus = .signedIn(username: username)
            self.apiClient = client
            await loadNotifications(force: true)
            guard requestID == activeAuthRequestID else { return }
            startBackgroundRefreshIfNeeded()
        } catch {
            guard requestID == activeAuthRequestID else { return }
            cancelBackgroundRefresh()
            cancelSecurityAlertsRefresh()

            if Self.isUnauthorized(error) {
                signOut()
            } else {
                self.authStatus = .signedIn(username: "")
                self.apiClient = client
                self.errorMessage = error.localizedDescription
                startBackgroundRefreshIfNeeded()
            }
        }
    }

    func signIn(token: String, username: String) {
        let isSwitchingAccounts = signedInUsername.map {
            $0.caseInsensitiveCompare(username) != .orderedSame
        } ?? false
        let authRequestID = UUID()
        activeAuthRequestID = authRequestID
        cancelBackgroundRefresh()
        cancelSecurityAlertsRefresh()
        cancelSubjectStateResolution()
        cancelAllPendingActions()
        activeLoadRequestID = UUID()
        shouldSelectTopItemOnNextLoad = true
        warningMessage = nil
        if isSwitchingAccounts {
            serverNotifications = []
            serverRecentInboxNotifications = []
            serverSecurityAlerts = []
            repositoryOrderAnchor = []
            inboxStore.clearSessionState()
            threadActions.clearCommittedActions()
            actionToasts.removeAll()
            searchQuery = ""
            isSearchActive = false
            clearSelection()
            rebuildDerivedState()
        }
        apiClient = apiClientFactory(token)
        authStatus = .signedIn(username: username)
        Task { [weak self] in
            await self?.loadNotifications(force: true)
            guard let self, authRequestID == self.activeAuthRequestID else { return }
            self.startBackgroundRefreshIfNeeded()
        }
    }

    func signOut() {
        activeAuthRequestID = UUID()
        cancelBackgroundRefresh()
        cancelSecurityAlertsRefresh()
        cancelSubjectStateResolution()
        cancelAllPendingActions()
        activeLoadRequestID = UUID()
        tokenDeleter()
        apiClient = nil
        authStatus = .signedOut
        isLoading = false
        serverNotifications = []
        serverRecentInboxNotifications = []
        serverSecurityAlerts = []
        repositoryOrderAnchor = []
        inboxStore.clearSessionState()
        threadActions.clearCommittedActions()
        errorMessage = nil
        warningMessage = nil
        actionToasts.removeAll()
        searchQuery = ""
        isSearchActive = false
        clearSelection()
        rebuildDerivedState()
    }

    func loadNotifications(force: Bool = false) async {
        await loadNotifications(policy: .uniform(force: force))
    }

    private func loadNotifications(policy: RefreshPolicy) async {
        guard let client = apiClient else { return }
        let authRequestID = activeAuthRequestID
        let requestID = UUID()
        activeLoadRequestID = requestID
        cancelSecurityAlertsRefresh()
        cancelSubjectStateResolution()
        isLoading = true
        warningMessage = nil
        do {
            let fetched = try await client.fetchNotifications(all: false, force: policy.forceUnread)
            let fetchedRecentInbox: [GitHubNotification]
            var recentInboxWarningMessage: String?
            let shouldFetchRecentInbox = inboxMode == .inbox
            if shouldFetchRecentInbox {
                do {
                    fetchedRecentInbox = try await client.fetchRecentInboxNotifications(
                        since: inboxStore.recentInboxSinceDate(relativeTo: fetched),
                        force: policy.forceRecentInbox,
                        maxPages: InboxStore.inboxRecentReadMaxPages
                    )
                } catch {
                    guard requestID == activeLoadRequestID,
                          authRequestID == activeAuthRequestID else { return }
                    if Self.isUnauthorized(error) {
                        signOut()
                        return
                    }
                    fetchedRecentInbox = serverRecentInboxNotifications
                    recentInboxWarningMessage = "Unable to refresh recent inbox: \(error.localizedDescription)"
                }
            } else {
                fetchedRecentInbox = []
            }
            guard requestID == activeLoadRequestID,
                  authRequestID == activeAuthRequestID else { return }
            applyLoadedNotifications(
                unreadNotifications: fetched,
                recentInboxNotifications: fetchedRecentInbox,
                securityAlerts: serverSecurityAlerts
            )
            resetSelectionToTopOnNextLoadIfNeeded()
            isLoading = false
            errorMessage = nil
            warningMessage = recentInboxWarningMessage
            shouldRefreshVisibleCIMetadataAfterNextRebuild = true
            rebuildDerivedState()
            scheduleSecurityAlertsRefreshIfNeeded(
                requestID: requestID,
                client: client,
                unreadNotifications: fetched,
                recentInboxNotifications: fetchedRecentInbox.isEmpty ? serverRecentInboxNotifications : fetchedRecentInbox,
                force: policy.forceSecurityAlerts
            )
            DebugTrace.log(
                "load applied mode=\(inboxMode.rawValue) unread.count=\(serverNotifications.count) " +
                "recent.count=\(serverRecentInboxNotifications.count) " +
                "security.count=\(serverSecurityAlerts.count) " +
                "visible.count=\(filteredNotifications.count) visible.top=\(Self.topIDs(in: filteredNotifications))"
            )
            logLastActionSnapshot(context: "after-load")
        } catch {
            guard requestID == activeLoadRequestID,
                  authRequestID == activeAuthRequestID else { return }
            if Self.isUnauthorized(error) {
                signOut()
                return
            }
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

    func pageDown() {
        let count = filteredNotifications.count
        guard count > 0 else { return }
        selectedIndex = min(selectedIndex + Self.pageJumpCount, count - 1)
    }

    func pageUp() {
        guard !filteredNotifications.isEmpty else { return }
        selectedIndex = max(selectedIndex - Self.pageJumpCount, 0)
    }

    func halfPageDown() {
        let count = filteredNotifications.count
        guard count > 0 else { return }
        selectedIndex = min(selectedIndex + Self.halfPageJumpCount, count - 1)
    }

    func halfPageUp() {
        guard !filteredNotifications.isEmpty else { return }
        selectedIndex = max(selectedIndex - Self.halfPageJumpCount, 0)
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
        if let batch = checkedNotificationsBatch() {
            let originalVisibleOrder = filteredNotifications
            let originalSelectionID = selectedNotificationID
            var acceptedItems: [GitHubNotification] = []
            clearChecked()

            for notification in batch where notification.source == .dependabotAlert {
                dismissSecurityAlert(notification, updatesSelection: false)
                acceptedItems.append(notification)
            }
            for group in groupedThreadNotifications(from: batch) {
                guard let representative = group.first else { continue }
                if startThreadAction(
                    .done,
                    target: representative,
                    activityIdentities: group.map(\.activityIdentity),
                    updatesSelection: false
                ) {
                    acceptedItems.append(contentsOf: group)
                }
            }

            restoreSelectionAfterBulkMutation(
                originalSelectionID: originalSelectionID,
                originalVisibleOrder: originalVisibleOrder
            )
            presentActionToast(verb: .done, items: acceptedItems)
            return
        }
        guard let target = selectedNotification else { return }
        if target.source == .dependabotAlert {
            dismissSecurityAlert(target)
            presentActionToast(verb: .done, items: [target])
        } else if startThreadAction(.done) {
            presentActionToast(verb: .done, items: [target])
        }
    }

    func markRead() {
        startThreadAction(.markRead)
    }

    func unsubscribeFromThread() {
        if let batch = checkedNotificationsBatch() {
            let originalVisibleOrder = filteredNotifications
            let originalSelectionID = selectedNotificationID
            let securityAlerts = batch.filter { $0.source == .dependabotAlert }
            var unsubscribedItems: [GitHubNotification] = []
            clearChecked()

            for notification in securityAlerts {
                dismissSecurityAlert(notification, updatesSelection: false)
            }
            for group in groupedThreadNotifications(from: batch) {
                guard let representative = group.first else { continue }
                if startThreadAction(
                    .unsubscribe,
                    target: representative,
                    activityIdentities: group.map(\.activityIdentity),
                    updatesSelection: false
                ) {
                    inboxStore.muteThread(representative.threadId)
                    clampSelection()
                    unsubscribedItems.append(contentsOf: group)
                }
            }

            restoreSelectionAfterBulkMutation(
                originalSelectionID: originalSelectionID,
                originalVisibleOrder: originalVisibleOrder
            )
            presentActionToast(verb: .unsub, items: unsubscribedItems)
            presentActionToast(verb: .done, items: securityAlerts)
            return
        }
        guard let notification = selectedNotification else { return }
        if notification.source == .dependabotAlert {
            dismissSecurityAlert(notification)
            presentActionToast(verb: .done, items: [notification])
        } else if startThreadAction(.unsubscribe) {
            inboxStore.muteThread(notification.threadId)
            clampSelection()
            presentActionToast(verb: .unsub, items: [notification])
        }
    }

    func copyURL() {
        guard let notification = selectedNotification else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(notification.url.absoluteString, forType: .string)
    }

    func openInBrowser() -> Bool {
        if let batch = checkedNotificationsBatch() {
            clearChecked()
            var opened: [GitHubNotification] = []
            for notification in batch {
                if urlOpener(notification.url) {
                    opened.append(notification)
                    if notification.source == .thread, notification.isUnread {
                        startThreadAction(
                            .markRead,
                            target: notification,
                            delayNanosecondsOverride: 0
                        )
                    } else if notification.source == .dependabotAlert, notification.isUnread {
                        inboxStore.markSecurityAlertRead(notification)
                    }
                }
            }
            clampSelection()
            if !opened.isEmpty {
                presentActionToast(verb: .open, items: opened)
            }
            return !opened.isEmpty
        }
        guard let notification = selectedNotification else { return false }
        let didOpen = urlOpener(notification.url)
        if didOpen {
            if notification.source == .thread, notification.isUnread {
                startThreadAction(.markRead, delayNanosecondsOverride: 0)
            } else if notification.source == .dependabotAlert, notification.isUnread {
                inboxStore.markSecurityAlertRead(notification)
                clampSelection()
            }
            presentActionToast(verb: .open, items: [notification])
        }
        return didOpen
    }

    private enum ActionToastVerb {
        case done, unsub, open
    }

    private func presentActionToast(verb: ActionToastVerb, items: [GitHubNotification]) {
        guard !items.isEmpty else { return }
        let message: String
        switch verb {
        case .done:
            message = items.count == 1
                ? "Marked \(Self.toastIdentifier(for: items[0])) done"
                : "Marked \(items.count) items done"
        case .unsub:
            message = items.count == 1
                ? "Unsubscribed from \(Self.toastIdentifier(for: items[0]))"
                : "Unsubscribed from \(items.count) items"
        case .open:
            message = items.count == 1
                ? "Opened \(Self.toastIdentifier(for: items[0]))"
                : "Opened \(items.count) items"
        }

        let toast = ActionToast(message: message)
        actionToasts.append(toast)
        scheduleToastRemoval(id: toast.id)
    }

    #if DEBUG
    private static let debugToastSamples: [String] = [
        "Marked acme/backend#1042 done",
        "Unsubscribed from acme/web#891",
        "Marked acme/api-gateway#234 done",
        "Unsubscribed from acme/storage#203",
        "Marked 4 items done",
        "Opened acme/auth#156"
    ]
    private var debugToastCounter = 0

    func presentDebugToast() {
        let message = Self.debugToastSamples[debugToastCounter % Self.debugToastSamples.count]
        debugToastCounter += 1
        let toast = ActionToast(message: message)
        actionToasts.append(toast)
        scheduleToastRemoval(id: toast.id)
    }
    #endif

    private func scheduleToastRemoval(id: UUID) {
        Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            self?.actionToasts.removeAll { $0.id == id }
        }
    }

    private static func toastIdentifier(for notification: GitHubNotification) -> String {
        if let reference = notification.displayReferenceNumber {
            return "\(notification.repository)\(reference)"
        }
        return notification.repository
    }

    private func checkedNotificationsBatch() -> [GitHubNotification]? {
        guard !checkedThreadIDs.isEmpty else { return nil }
        let ordered = filteredNotifications.filter { checkedThreadIDs.contains($0.id) }
        return ordered.isEmpty ? nil : ordered
    }

    private func groupedThreadNotifications(
        from notifications: [GitHubNotification]
    ) -> [[GitHubNotification]] {
        var groups: [[GitHubNotification]] = []
        var groupIndexByThreadID: [String: Int] = [:]

        for notification in notifications where notification.source == .thread {
            if let groupIndex = groupIndexByThreadID[notification.threadId] {
                groups[groupIndex].append(notification)
            } else {
                groupIndexByThreadID[notification.threadId] = groups.count
                groups.append([notification])
            }
        }

        return groups
    }

    func refresh(force: Bool = false) {
        refresh(using: .uniform(force: force))
    }

    func refreshForPanelPresentation() {
        refresh(using: .panelPresentation)
    }

    private func refresh(using policy: RefreshPolicy) {
        searchQuery = ""
        isSearchActive = false
        checkedThreadIDs.removeAll()
        flushPendingActions()
        if apiClient != nil {
            Task { await loadNotifications(policy: policy) }
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

    func toggleChecked() {
        guard let id = selectedNotification?.id else { return }
        toggleChecked(id: id)
    }

    func toggleChecked(id: String) {
        guard filteredNotifications.contains(where: { $0.id == id }) else { return }
        if checkedThreadIDs.contains(id) {
            checkedThreadIDs.remove(id)
        } else {
            checkedThreadIDs.insert(id)
        }
    }

    func clearChecked() {
        checkedThreadIDs.removeAll()
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

    var hasPendingThreadActions: Bool {
        threadActions.hasPendingActions
    }

    /// Dispatches any debounced thread actions and gives in-flight requests a bounded
    /// opportunity to finish before the process exits.
    ///
    /// The injected sleeper keeps the timeout path deterministic in tests. Production
    /// callers should use the default monotonic task sleep.
    func drainPendingActions(
        timeoutNanoseconds: UInt64,
        pollIntervalNanoseconds: UInt64 = 25_000_000,
        terminationSleepHandler: @escaping SleepHandler = defaultSleepHandler
    ) async -> Bool {
        flushPendingActions()

        guard threadActions.hasPendingActions else { return true }
        guard timeoutNanoseconds > 0 else { return false }

        let pollInterval = max(1, min(pollIntervalNanoseconds, timeoutNanoseconds))
        var remainingNanoseconds = timeoutNanoseconds

        while threadActions.hasPendingActions {
            guard !Task.isCancelled else { return false }

            let sleepNanoseconds = min(pollInterval, remainingNanoseconds)
            await terminationSleepHandler(sleepNanoseconds)

            guard threadActions.hasPendingActions else { return true }
            guard remainingNanoseconds > sleepNanoseconds else { return false }
            remainingNanoseconds -= sleepNanoseconds
        }

        return true
    }

    private func rebuildDerivedState() {
        let projectedUnread = threadActions.projectedNotifications(from: serverNotifications)
        let projectedRecentInbox = threadActions.projectedNotifications(from: serverRecentInboxNotifications)
        let projectedSecurityAlerts = inboxStore.projectedSecurityAlerts(from: serverSecurityAlerts)
        let modeFiltered = filteredNotificationsForCurrentMode(
            unreadNotifications: projectedUnread,
            recentInboxNotifications: projectedRecentInbox,
            securityAlerts: projectedSecurityAlerts
        )
        let repoOrderSource = groupByRepo ? sortedByRecency(serverNotificationsForCurrentMode()) : []
        notifications = orderedNotifications(
            modeFiltered,
            preferredRepositoryOrder: repositoryOrderAnchor,
            repoOrderSource: repoOrderSource
        )
        #if DEBUG
        let repoOrder = notifications.reduce(into: [String]()) { order, n in
            if !order.contains(n.repository) { order.append(n.repository) }
        }
        DebugTrace.log("rebuildDerivedState repoOrder=\(repoOrder) anchor=\(repositoryOrderAnchor)")
        #endif
        panelUnreadCount = notifications.reduce(into: 0) { count, notification in
            if notification.isUnread {
                count += 1
            }
        }
        // Menubar icon count: thread-only, excludes security alerts and muted threads.
        unreadNotificationCount = inboxStore.filterMutedThreads(projectedUnread).filter(\.isUnread).count

        filteredNotifications = Self.applySearchFilter(notifications, query: searchQuery)
        if !checkedThreadIDs.isEmpty {
            let visibleIDs = Set(filteredNotifications.map(\.id))
            checkedThreadIDs.formIntersection(visibleIDs)
        }
        guard !filteredNotifications.isEmpty else {
            clearSelection()
            return
        }

        if let selectedThreadID,
           let index = filteredNotifications.firstIndex(where: { $0.id == selectedThreadID }) {
            selectedIndexStorage = index
        } else {
            selectedIndexStorage = min(selectedIndexStorage, filteredNotifications.count - 1)
        }

        selectedThreadID = filteredNotifications[selectedIndexStorage].id

        enqueueVisibleSubjectMetadataRefreshIfNeeded(
            forceOpenPRRefresh: shouldRefreshVisibleCIMetadataAfterNextRebuild
        )
        shouldRefreshVisibleCIMetadataAfterNextRebuild = false
    }

    private func filteredNotificationsForCurrentMode(
        unreadNotifications: [GitHubNotification],
        recentInboxNotifications: [GitHubNotification],
        securityAlerts: [GitHubNotification]
    ) -> [GitHubNotification] {
        switch inboxMode {
        case .unread:
            return unreadNotifications.filter(\.isUnread)
        case .inbox:
            let merged = inboxStore.mergedInboxNotifications(
                unreadNotifications: unreadNotifications,
                recentInboxNotifications: recentInboxNotifications,
                projectedNotifications: { self.threadActions.projectedNotifications(from: $0) }
            )
            return merged + dedupedSecurityAlerts(securityAlerts, against: merged)
        }
    }

    private func serverNotificationsForCurrentMode() -> [GitHubNotification] {
        switch inboxMode {
        case .unread:
            return serverNotifications.filter(\.isUnread)
        case .inbox:
            let merged = inboxStore.mergedInboxNotifications(
                unreadNotifications: serverNotifications,
                recentInboxNotifications: serverRecentInboxNotifications,
                projectedNotifications: { $0 }
            )
            let securityAlerts = inboxStore.projectedSecurityAlerts(from: serverSecurityAlerts)
            return merged + dedupedSecurityAlerts(securityAlerts, against: merged)
        }
    }

    private func dedupedSecurityAlerts(
        _ securityAlerts: [GitHubNotification],
        against existingNotifications: [GitHubNotification]
    ) -> [GitHubNotification] {
        let existingKeys = Set(existingNotifications.compactMap(Self.securityAlertDedupKey(for:)))
        return securityAlerts.filter { notification in
            guard notification.source == .dependabotAlert,
                  let key = Self.securityAlertDedupKey(for: notification) else {
                return true
            }
            return !existingKeys.contains(key)
        }
    }

    private static func securityAlertDedupKey(for notification: GitHubNotification) -> String? {
        guard notification.type == .securityAlert else { return nil }
        return "\(notification.repository)|\(notification.title)"
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
    }

    private func clearSelection() {
        selectedIndexStorage = 0
        selectedThreadID = nil
    }

    private func resetSelectionToTopOnNextLoadIfNeeded() {
        guard shouldSelectTopItemOnNextLoad else { return }
        shouldSelectTopItemOnNextLoad = false
        selectedIndexStorage = 0
        selectedThreadID = nil
    }

    @discardableResult
    private func startThreadAction(
        _ kind: ThreadActionStore.ActionKind,
        target explicitTarget: GitHubNotification? = nil,
        activityIdentities: [String]? = nil,
        delayNanosecondsOverride: UInt64? = nil,
        updatesSelection: Bool = true
    ) -> Bool {
        guard let client = apiClient else { return false }
        guard let target = explicitTarget ?? selectedNotification else { return false }
        guard target.source == .thread else {
            errorMessage = "Security alerts can only be opened or marked done"
            return false
        }
        guard !threadActions.hasPendingAction(for: target.threadId) else { return false }
        if kind == .markRead && !target.isUnread { return false }

        DebugTrace.log(
            "start action kind=\(kind.rawValue) target.id=\(target.id) target.thread=\(target.threadId) " +
            "selected=\(selectedNotificationID ?? "nil") visible=\(filteredNotifications.map(\.id).joined(separator: ","))"
        )
        lastActionDebugThreadID = target.threadId
        lastActionDebugKind = kind.rawValue

        let originalServerIndex = serverNotifications.firstIndex(where: { $0.id == target.id }) ?? serverNotifications.count
        let projectionCutoff = serverNotifications
            .filter { $0.threadId == target.threadId }
            .map(\.updatedAt)
            .max() ?? target.updatedAt
        let pending = threadActions.start(
            kind,
            notification: target,
            activityIdentities: activityIdentities,
            projectionCutoff: projectionCutoff,
            originalServerIndex: originalServerIndex
        )

        let visibleBeforeMutation = filteredNotifications

        if updatesSelection, kind.hidesNotification {
            let removeIndex = visibleBeforeMutation.firstIndex(where: { $0.id == target.id }) ?? selectedIndexStorage
            selectedThreadID = selectionAfterRemoving(threadId: target.id, from: visibleBeforeMutation)
            selectedIndexStorage = min(removeIndex, max(0, visibleBeforeMutation.count - 2))
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
        return true
    }

    private func dismissSecurityAlert(
        _ target: GitHubNotification,
        updatesSelection: Bool = true
    ) {
        guard target.source == .dependabotAlert else { return }

        let visibleBeforeMutation = filteredNotifications
        inboxStore.dismissSecurityAlert(target)
        errorMessage = nil

        if updatesSelection {
            let removeIndex = visibleBeforeMutation.firstIndex(where: { $0.id == target.id }) ?? selectedIndexStorage
            selectedThreadID = selectionAfterRemoving(threadId: target.id, from: visibleBeforeMutation)
            selectedIndexStorage = min(removeIndex, max(0, visibleBeforeMutation.count - 2))
        }
        clampSelection()
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
                do {
                    try await client.markAsDone(notification: pending.notification)
                } catch {
                    if Task.isCancelled || error is CancellationError { return }
                    if Self.isUnauthorized(error) {
                        signOut()
                        return
                    }
                    guard let latest = threadActions.pendingAction(for: pending.notification.threadId),
                          latest.requestID == pending.requestID else {
                        return
                    }

                    handlePendingUnsubscribePartialSuccess(latest)
                    return
                }
            }

            guard let latest = threadActions.pendingAction(for: pending.notification.threadId),
                  latest.requestID == pending.requestID else {
                return
            }

            handlePendingActionSuccess(latest)
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            guard let latest = threadActions.pendingAction(for: pending.notification.threadId),
                  latest.requestID == pending.requestID else {
                return
            }

            if Self.isUnauthorized(error) {
                signOut()
                return
            }

            handlePendingActionFailure(latest, error: error)
        }
    }

    private func handlePendingActionSuccess(_ pending: ThreadActionStore.PendingAction) {
        actionTasks[pending.notification.threadId] = nil
        threadActions.handleSuccess(pending, serverNotifications: &serverNotifications)
        switch pending.kind {
        case .markRead:
            var readNotification = pending.notification
            readNotification.isUnread = false
            inboxStore.recordRecentReadNotification(
                readNotification,
                unreadNotifications: serverNotifications.filter(\.isUnread),
                projectedNotifications: { self.threadActions.projectedNotifications(from: $0) }
            )
        case .done, .unsubscribe:
            inboxStore.removeRecentReadNotification(threadId: pending.notification.threadId)
        }
        DebugTrace.log(
            "success kind=\(pending.kind.rawValue) target.id=\(pending.notification.id) " +
            "target.thread=\(pending.notification.threadId) server=\(serverNotifications.map(\.id).joined(separator: ","))"
        )

        errorMessage = nil
        rebuildDerivedState()
        DebugTrace.log(
            "after rebuild success kind=\(pending.kind.rawValue) selected=\(selectedNotificationID ?? "nil") " +
            "visible=\(filteredNotifications.map(\.id).joined(separator: ","))"
        )
        logLastActionSnapshot(context: "after-action-success")
    }

    private func handlePendingUnsubscribePartialSuccess(_ pending: ThreadActionStore.PendingAction) {
        handlePendingActionSuccess(pending)
        errorMessage = "Unsubscribed, but failed to mark thread as done"
    }

    private func handlePendingActionFailure(_ pending: ThreadActionStore.PendingAction, error _: Error) {
        actionTasks[pending.notification.threadId] = nil

        if pending.kind == .unsubscribe {
            inboxStore.unmuteThread(pending.notification.threadId)
        }

        errorMessage = threadActions.handleFailure(pending)

        if pending.kind.hidesNotification,
           selectedThreadID == pending.notification.id {
            selectedThreadID = pending.notification.id
        }

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

    private func cancelSecurityAlertsRefresh() {
        securityAlertsRefreshTask?.cancel()
        securityAlertsRefreshTask = nil
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
            let resolvedMetadata = await client.resolveSubjectMetadata(for: candidates)
            let warningMessage = await client.takeNonFatalWarningMessage()
            guard !Task.isCancelled else { return }
            self?.applyResolvedSubjectMetadata(
                resolvedMetadata,
                expectedIDs: candidateIDs,
                warningMessage: warningMessage
            )
        }
    }

    private func applyResolvedSubjectMetadata(
        _ resolvedMetadata: [String: GitHubNotification.SubjectMetadata],
        expectedIDs: [String],
        warningMessage: String?
    ) {
        subjectStateResolutionTask = nil
        visibleSubjectStateInFlightIDs.subtract(expectedIDs)
        self.warningMessage = warningMessage

        let unreadChanged = applyResolvedSubjectMetadata(resolvedMetadata, to: &serverNotifications)
        let recentInboxChanged = applyResolvedSubjectMetadata(resolvedMetadata, to: &serverRecentInboxNotifications)
        let recentReadChanged = inboxStore.applyResolvedSubjectMetadata(resolvedMetadata)
        let lastFetchedUnreadChanged = inboxStore.applyResolvedSubjectMetadataToLastFetchedUnread(resolvedMetadata)
        let didChange = unreadChanged || recentInboxChanged || recentReadChanged || lastFetchedUnreadChanged

        if didChange {
            rebuildDerivedState()
        }

        scheduleVisibleSubjectStateResolutionIfNeeded()
    }

    @discardableResult
    private func applyResolvedSubjectMetadata(
        _ resolvedMetadata: [String: GitHubNotification.SubjectMetadata],
        to notifications: inout [GitHubNotification]
    ) -> Bool {
        var didChange = false

        for index in notifications.indices {
            guard let metadata = resolvedMetadata[notifications[index].id] else { continue }
            if notifications[index].apply(metadata) {
                didChange = true
            }
        }

        return didChange
    }

    @discardableResult
    private func applyResolvedSubjectMetadata(
        _ resolvedMetadata: [String: GitHubNotification.SubjectMetadata],
        to notificationsByThreadID: inout [String: GitHubNotification]
    ) -> Bool {
        var didChange = false

        for (threadID, notification) in notificationsByThreadID {
            guard let metadata = resolvedMetadata[notification.id] else { continue }
            var updated = notification
            guard updated.apply(metadata) else { continue }
            notificationsByThreadID[threadID] = updated
            didChange = true
        }

        return didChange
    }

    private func enqueueVisibleSubjectMetadataRefreshIfNeeded(forceOpenPRRefresh: Bool = false) {
        guard isPanelVisible else { return }

        for notification in filteredNotifications.prefix(Self.visibleSubjectStateBatchSize) {
            let shouldQueue = notification.needsSubjectMetadataResolution || (
                forceOpenPRRefresh &&
                notification.type == .pullRequest &&
                notification.subjectState == .open
            )

            guard shouldQueue else { continue }
            let id = notification.id
            guard !pendingVisibleSubjectStateIDs.contains(id),
                  !visibleSubjectStateInFlightIDs.contains(id) else {
                continue
            }
            pendingVisibleSubjectStateIDs.append(id)
        }

        scheduleVisibleSubjectStateResolutionIfNeeded()
    }

    private func selectionAfterRemoving(threadId: String, from list: [GitHubNotification]) -> String? {
        guard let removeIndex = list.firstIndex(where: { $0.id == threadId }) else {
            return selectedThreadID
        }
        guard list.count > 1 else { return nil }

        if removeIndex < list.count - 1 {
            return list[removeIndex + 1].id
        }
        return list[removeIndex - 1].id
    }

    private func restoreSelectionAfterBulkMutation(
        originalSelectionID: String?,
        originalVisibleOrder: [GitHubNotification]
    ) {
        guard let originalSelectionID,
              let originalIndex = originalVisibleOrder.firstIndex(where: { $0.id == originalSelectionID }) else {
            clampSelection()
            return
        }

        let currentNotifications = filteredNotifications
        let currentIndexByID = Dictionary(
            uniqueKeysWithValues: currentNotifications.enumerated().map { ($1.id, $0) }
        )

        if let currentIndex = currentIndexByID[originalSelectionID] {
            applySelection(index: currentIndex, in: currentNotifications)
            return
        }

        for notification in originalVisibleOrder.dropFirst(originalIndex + 1) {
            if let currentIndex = currentIndexByID[notification.id] {
                applySelection(index: currentIndex, in: currentNotifications)
                return
            }
        }

        for notification in originalVisibleOrder[..<originalIndex].reversed() {
            if let currentIndex = currentIndexByID[notification.id] {
                applySelection(index: currentIndex, in: currentNotifications)
                return
            }
        }

        clearSelection()
    }

    private func actionDelay(for kind: ThreadActionStore.ActionKind) -> UInt64 {
        switch kind {
        case .markRead, .done, .unsubscribe:
            return actionDispatchDelayNanoseconds
        }
    }

    private func startBackgroundRefreshIfNeeded() {
        guard backgroundRefreshEnabled else { return }
        guard apiClient != nil else { return }
        guard backgroundRefreshTask == nil else { return }

        backgroundRefreshTask = Task { [weak self, sleepHandler] in
            while !Task.isCancelled {
                guard let delayNanoseconds = await self?.backgroundRefreshDelayNanoseconds() else { return }
                await sleepHandler(delayNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.performBackgroundRefresh()
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
        let authRequestID = activeAuthRequestID
        let loadRequestID = activeLoadRequestID

        do {
            let fetched = try await client.fetchNotifications(all: false, force: false)
            guard authRequestID == activeAuthRequestID,
                  loadRequestID == activeLoadRequestID else { return }
            inboxStore.updateUnreadCountOnly(from: fetched)
            // Apply thread action projections so committed done/unsubscribe
            // actions are excluded from the count, matching what the panel shows.
            let projected = inboxStore.filterMutedThreads(
                threadActions.projectedNotifications(from: fetched)
            )
            unreadNotificationCount = projected.filter(\.isUnread).count
        } catch {
            guard authRequestID == activeAuthRequestID,
                  loadRequestID == activeLoadRequestID else { return }
            if Self.isUnauthorized(error) {
                signOut()
            }
            // Other background-only failures stay silent while the heavier inbox feed is hidden.
        }
    }

    private func scheduleSecurityAlertsRefreshIfNeeded(
        requestID: UUID,
        client: GitHubAPIClient,
        unreadNotifications: [GitHubNotification],
        recentInboxNotifications: [GitHubNotification],
        force: Bool
    ) {
        guard inboxMode == .inbox, isPanelVisible else { return }

        let repositoryNames = securityAlertRepositoryCandidates(
            unreadNotifications: unreadNotifications,
            recentInboxNotifications: recentInboxNotifications
        )
        let currentUsername = signedInUsername

        guard !repositoryNames.isEmpty else {
            if !serverSecurityAlerts.isEmpty {
                serverSecurityAlerts = []
                rebuildDerivedState()
            }
            return
        }

        securityAlertsRefreshTask = Task { [weak self, client, repositoryNames, requestID, force] in
            let alerts: [GitHubNotification]
            do {
                alerts = try await client.fetchDependabotAlerts(
                    repositoryNames: repositoryNames,
                    currentUsername: currentUsername,
                    force: force
                )
            } catch {
                DebugTrace.log("security fetch failed error=\(error.localizedDescription)")
                await MainActor.run {
                    guard let self, requestID == self.activeLoadRequestID else { return }
                    self.securityAlertsRefreshTask = nil
                    if Self.isUnauthorized(error) {
                        self.signOut()
                    }
                }
                return
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, requestID == self.activeLoadRequestID else { return }
                self.securityAlertsRefreshTask = nil
                guard self.serverSecurityAlerts != alerts else { return }
                self.serverSecurityAlerts = alerts
                self.rebuildDerivedState()
                DebugTrace.log(
                    "security applied count=\(alerts.count) visible.count=\(self.filteredNotifications.count) " +
                    "visible.top=\(Self.topIDs(in: self.filteredNotifications))"
                )
            }
        }
    }

    private func applyLoadedNotifications(
        unreadNotifications: [GitHubNotification],
        recentInboxNotifications: [GitHubNotification],
        securityAlerts: [GitHubNotification]
    ) {
        serverNotifications = unreadNotifications
        // Filter out threads with committed done/unsubscribe actions so they
        // don't linger in the recent inbox read list after the server confirms removal.
        let projectedRecentInbox = threadActions.projectedNotifications(from: recentInboxNotifications)
        let loadedState = inboxStore.applyLoaded(
            unreadNotifications: unreadNotifications,
            recentInboxNotifications: projectedRecentInbox,
            projectedSecurityAlerts: securityAlerts,
            projectedNotifications: { self.threadActions.projectedNotifications(from: $0) }
        )
        serverRecentInboxNotifications = loadedState.recentInboxNotifications
        serverSecurityAlerts = securityAlerts
        unreadNotificationCount = loadedState.unreadCount
        threadActions.reconcileCommittedActions(with: unreadNotifications)
        inboxStore.reconcileMutedThreadsWithUnread(
            unreadNotifications,
            committedThreadIDs: Set(threadActions.committedActions.keys)
        )
        if repositoryOrderAnchor.isEmpty {
            repositoryOrderAnchor = Self.repositoryOrder(from: serverNotificationsForCurrentMode())
        }
    }

    private func securityAlertRepositoryCandidates(
        unreadNotifications: [GitHubNotification],
        recentInboxNotifications: [GitHubNotification]
    ) -> [String] {
        let inboxNotifications = inboxStore.mergedInboxNotifications(
            unreadNotifications: unreadNotifications,
            recentInboxNotifications: recentInboxNotifications,
            projectedNotifications: { self.threadActions.projectedNotifications(from: $0) }
        )
        return Array(Set(inboxNotifications.map(\.repository))).sorted()
    }

    private static func loadInboxMode(from userDefaults: UserDefaults) -> InboxMode {
        guard let rawValue = userDefaults.string(forKey: inboxModeStorageKey) else {
            return .inbox
        }
        if rawValue == "all" {
            return .inbox
        }
        guard let mode = InboxMode(rawValue: rawValue) else {
            return .inbox
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

    private static func isUnauthorized(_ error: Error) -> Bool {
        if case GitHubAPIClient.APIError.unauthorized = error {
            return true
        }
        return false
    }

    private var signedInUsername: String? {
        if case .signedIn(let username) = authStatus {
            return username
        }
        return nil
    }
}
