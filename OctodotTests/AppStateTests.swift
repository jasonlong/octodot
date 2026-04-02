import Foundation
import Testing
@testable import Octodot

@MainActor
struct AppStateTests {
    static func makeNotification(id: Int, repo: String = "acme/alpha", isUnread: Bool = true) -> GitHubNotification {
        GitHubNotification(
            id: "\(id)",
            threadId: "\(id)",
            title: "Notification \(id)",
            repository: repo,
            reason: .subscribed,
            type: .pullRequest,
            updatedAt: Date().addingTimeInterval(Double(-id * 600)),
            isUnread: isUnread,
            url: URL(string: "https://github.com/acme/test/pull/\(id)")!,
            subjectURL: nil,
            subjectState: .open
        )
    }

    static func makeNotifications(_ count: Int = 5) -> [GitHubNotification] {
        (0..<count).map { i in
            makeNotification(
                id: i,
                repo: i % 2 == 0 ? "acme/alpha" : "acme/beta",
                isUnread: i < 3
            )
        }
    }

    static func makeIsolatedUserDefaults() -> UserDefaults {
        let suiteName = "OctodotTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    static func makeState(
        _ count: Int = 5,
        apiClient: GitHubAPIClient? = nil,
        actionDispatchDelayNanoseconds: UInt64 = 0,
        backgroundRefreshEnabled: Bool = false,
        sleepHandler: @escaping AppState.SleepHandler = { _ in },
        userDefaults: UserDefaults? = nil,
        urlOpener: @escaping AppState.URLOpener = { _ in true }
    ) -> AppState {
        let resolvedUserDefaults = userDefaults ?? makeIsolatedUserDefaults()
        return AppState(
            notifications: makeNotifications(count),
            authStatus: apiClient == nil ? .signedOut : .signedIn(username: "octodot"),
            apiClient: apiClient,
            actionDispatchDelayNanoseconds: actionDispatchDelayNanoseconds,
            backgroundRefreshEnabled: backgroundRefreshEnabled,
            sleepHandler: sleepHandler,
            userDefaults: resolvedUserDefaults,
            urlOpener: urlOpener
        )
    }

    fileprivate static func makeAuthedState(
        results: [Result<(Data, HTTPURLResponse), Error>] = [],
        count: Int = 5,
        actionDispatchDelayNanoseconds: UInt64 = 0,
        backgroundRefreshEnabled: Bool = false,
        sleepHandler: @escaping AppState.SleepHandler = { _ in },
        userDefaults: UserDefaults? = nil,
        urlOpener: @escaping AppState.URLOpener = { _ in true }
    ) -> (AppState, StubNetworkSession) {
        let session = StubNetworkSession(results: results)
        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let state = makeState(
            count,
            apiClient: client,
            actionDispatchDelayNanoseconds: actionDispatchDelayNanoseconds,
            backgroundRefreshEnabled: backgroundRefreshEnabled,
            sleepHandler: sleepHandler,
            userDefaults: userDefaults,
            urlOpener: urlOpener
        )
        return (state, session)
    }

    static func httpResponse(
        url: String,
        statusCode: Int,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    static func singleNotificationPayload(id: String, isUnread: Bool = true, updatedAt: String = "2026-04-01T12:00:00Z") -> Data {
        """
        [
          {
            "id": "\(id)",
            "unread": \(isUnread ? "true" : "false"),
            "reason": "review_requested",
            "updated_at": "\(updatedAt)",
            "subject": {
              "title": "Notification \(id)",
              "url": null,
              "type": "PullRequest"
            },
            "repository": {
              "full_name": "acme/alpha",
              "html_url": "https://github.com/acme/alpha"
            }
          }
        ]
        """.data(using: .utf8)!
    }

    static func notificationsPayload(ids: [String], updatedAt: String = "2026-04-01T12:00:00Z") -> Data {
        let items = ids.map { id in
            """
              {
                "id": "\(id)",
                "unread": true,
                "reason": "review_requested",
                "updated_at": "\(updatedAt)",
                "subject": {
                  "title": "Notification \(id)",
                  "url": null,
                  "type": "PullRequest"
                },
                "repository": {
                  "full_name": "acme/alpha",
                  "html_url": "https://github.com/acme/alpha"
                }
              }
            """
        }.joined(separator: ",\n")

        return "[\n\(items)\n]".data(using: .utf8)!
    }

    static func settleTasks() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    static func waitUntil(
        timeoutNanoseconds: UInt64 = 250_000_000,
        intervalNanoseconds: UInt64 = 10_000_000,
        condition: @escaping @Sendable () async -> Bool
    ) async {
        let iterations = max(1, Int(timeoutNanoseconds / intervalNanoseconds))
        for _ in 0..<iterations {
            if await condition() {
                return
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
    }

    static let realSleep: AppState.SleepHandler = { nanoseconds in
        guard nanoseconds > 0 else { return }
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    actor BackgroundRefreshSleeper {
        private var callCount = 0

        func sleep(nanoseconds _: UInt64) async {
            callCount += 1
            guard callCount > 1 else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    // MARK: - Navigation

    @Test func moveDownIncrementsSelection() {
        let state = Self.makeState()
        #expect(state.selectedIndex == 0)
        state.moveDown()
        #expect(state.selectedIndex == 1)
        state.moveDown()
        #expect(state.selectedIndex == 2)
    }

    @Test func moveDownClampsAtEnd() {
        let state = Self.makeState(3)
        state.selectedIndex = 2
        state.moveDown()
        #expect(state.selectedIndex == 2)
    }

    @Test func moveUpDecrementsSelection() {
        let state = Self.makeState()
        state.selectedIndex = 3
        state.moveUp()
        #expect(state.selectedIndex == 2)
    }

    @Test func moveUpClampsAtZero() {
        let state = Self.makeState()
        state.selectedIndex = 0
        state.moveUp()
        #expect(state.selectedIndex == 0)
    }

    @Test func jumpToTop() {
        let state = Self.makeState()
        state.selectedIndex = 4
        state.jumpToTop()
        #expect(state.selectedIndex == 0)
    }

    @Test func jumpToBottom() {
        let state = Self.makeState()
        state.jumpToBottom()
        #expect(state.selectedIndex == 4)
    }

    @Test func navigationOnEmptyListIsNoOp() {
        let state = Self.makeState(0)
        state.moveDown()
        #expect(state.selectedIndex == 0)
        state.moveUp()
        #expect(state.selectedIndex == 0)
        state.jumpToTop()
        #expect(state.selectedIndex == 0)
        state.jumpToBottom()
        #expect(state.selectedIndex == 0)
    }

    // MARK: - Filtering

    @Test func searchFiltersbyTitle() {
        let state = Self.makeState()
        state.searchQuery = "Notification 2"
        #expect(state.filteredNotifications.count == 1)
        #expect(state.filteredNotifications.first?.id == "2")
    }

    @Test func searchFiltersByRepo() {
        let state = Self.makeState()
        state.groupByRepo = false
        state.searchQuery = "alpha"
        let filtered = state.filteredNotifications
        #expect(filtered.allSatisfy { $0.repository == "acme/alpha" })
    }

    @Test func emptySearchReturnsAll() {
        let state = Self.makeState()
        state.searchQuery = ""
        #expect(state.filteredNotifications.count == 5)
    }

    @Test func searchIsCaseInsensitive() {
        let state = Self.makeState()
        state.searchQuery = "NOTIFICATION 0"
        #expect(state.filteredNotifications.count == 1)
    }

    // MARK: - Group by repo

    @Test func groupByRepoSortsRepositoriesByMostRecentNotification() {
        let notifications = [
            Self.makeNotification(id: 4, repo: "acme/older"),
            Self.makeNotification(id: 1, repo: "acme/newer"),
            Self.makeNotification(id: 2, repo: "acme/newer"),
        ]
        let state = AppState(notifications: notifications)
        state.groupByRepo = true
        let repos = state.filteredNotifications.map(\.repository)
        #expect(repos == ["acme/newer", "acme/newer", "acme/older"])
    }

    @Test func groupByRepoKeepsNotificationsNewestFirstWithinRepository() {
        let notifications = [
            Self.makeNotification(id: 4, repo: "acme/alpha"),
            Self.makeNotification(id: 1, repo: "acme/alpha"),
            Self.makeNotification(id: 3, repo: "acme/beta"),
        ]
        let state = AppState(notifications: notifications)
        state.groupByRepo = true
        #expect(state.filteredNotifications.map(\.id) == ["1", "4", "3"])
    }

    @Test func toggleGroupByRepoFlips() {
        let state = Self.makeState()
        state.groupByRepo = false
        state.toggleGroupByRepo()
        #expect(state.groupByRepo == true)
        state.toggleGroupByRepo()
        #expect(state.groupByRepo == false)
    }

    // MARK: - Mark read

    @Test func markReadOptimisticallyMarksThreadReadAndDoesNotToggleBack() async {
        let (state, session) = Self.makeAuthedState(results: [
            .success((
                Data(),
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/0",
                    statusCode: 205
                )
            ))
        ])
        state.groupByRepo = false
        #expect(state.notifications[0].isUnread == true)
        state.selectedIndex = 0
        state.markRead()
        #expect(state.notifications[0].isUnread == false)
        await Self.settleTasks()

        let requests = await session.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.httpMethod == "PATCH")

        state.markRead()
        await Self.settleTasks()
        #expect((await session.recordedRequests()).count == 1)
        #expect(state.notifications[0].isUnread == false)
    }

    @Test func refreshKeepsCommittedMarkReadUntilServerCatchesUp() async {
        let (state, session) = Self.makeAuthedState(
            results: [
                .success((
                    Data(),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications/threads/0",
                        statusCode: 205
                    )
                )),
                .success((
                    Self.singleNotificationPayload(id: "0", isUnread: true),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1",
                        statusCode: 200,
                        headers: ["Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT"]
                    )
                )),
            ],
            count: 1
        )

        state.groupByRepo = false
        state.selectedIndex = 0
        state.markRead()
        await Self.settleTasks()

        #expect(state.notifications[0].isUnread == false)

        await state.loadNotifications(force: true)

        #expect(state.notifications.count == 1)
        #expect(state.notifications[0].isUnread == false)
        #expect((await session.recordedRequests()).count == 2)
    }

    @Test func openInBrowserMarksUnreadThreadReadImmediately() async {
        let (state, session) = Self.makeAuthedState(
            results: [
                .success((
                    Data(),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications/threads/0",
                        statusCode: 205
                    )
                ))
            ],
            count: 1,
            actionDispatchDelayNanoseconds: 50_000_000,
            sleepHandler: Self.realSleep,
            urlOpener: { _ in true }
        )

        state.groupByRepo = false
        state.selectedIndex = 0

        #expect(state.openInBrowser() == true)
        #expect(state.notifications[0].isUnread == false)

        await Self.waitUntil {
            await session.recordedRequests().count == 1
        }

        let requests = await session.recordedRequests()
        #expect(requests.first?.httpMethod == "PATCH")
    }

    @Test func backgroundRefreshLoadsNotificationsWhilePanelIsClosed() async {
        let sleeper = BackgroundRefreshSleeper()
        let (state, session) = Self.makeAuthedState(
            results: [
                .success((
                    Self.singleNotificationPayload(id: "99"),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1",
                        statusCode: 200,
                        headers: ["X-Poll-Interval": "30"]
                    )
                ))
            ],
            count: 0,
            backgroundRefreshEnabled: true,
            sleepHandler: { nanoseconds in
                await sleeper.sleep(nanoseconds: nanoseconds)
            }
        )

        #expect(state.isPanelVisible == false)

        await Self.waitUntil {
            await session.recordedRequests().count == 1
        }

        #expect(state.notifications.count == 1)
        #expect(state.notifications.first?.id == "99")

        state.signOut()
    }

    @Test func newerRefreshResultWinsWhenLoadsCompleteOutOfOrder() async {
        let session = DelayedStubNetworkSession(results: [
            .success(
                payload: Self.singleNotificationPayload(id: "old"),
                response: Self.httpResponse(
                    url: "https://api.github.com/notifications?page=1",
                    statusCode: 200,
                    headers: ["Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT"]
                ),
                delayNanoseconds: 80_000_000
            ),
            .success(
                payload: Self.singleNotificationPayload(id: "new"),
                response: Self.httpResponse(
                    url: "https://api.github.com/notifications?page=1",
                    statusCode: 200,
                    headers: ["Last-Modified": "Wed, 01 Apr 2026 12:01:00 GMT"]
                ),
                delayNanoseconds: 0
            ),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let state = Self.makeState(0, apiClient: client)
        state.groupByRepo = false

        async let firstLoad: Void = state.loadNotifications(force: true)
        try? await Task.sleep(nanoseconds: 5_000_000)
        async let secondLoad: Void = state.loadNotifications(force: true)

        _ = await (firstLoad, secondLoad)

        #expect(state.notifications.count == 1)
        #expect(state.notifications.first?.id == "new")
    }

    // MARK: - Done (remove + advance)

    @Test func doneRemovesSelectedNotificationOptimisticallyAndCommitsOnSuccess() async {
        let (state, session) = Self.makeAuthedState(results: [
            .success((
                Data(),
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/0",
                    statusCode: 204
                )
            ))
        ])
        state.groupByRepo = false
        let targetId = state.filteredNotifications[0].id
        state.selectedIndex = 0
        state.done()
        #expect(state.notifications.contains(where: { $0.id == targetId }) == false)
        #expect(state.notifications.count == 4)

        await Self.settleTasks()
        #expect((await session.recordedRequests()).count == 1)
    }

    @Test func doneAdvancesSelection() {
        let (state, _) = Self.makeAuthedState()
        state.groupByRepo = false
        state.selectedIndex = 1
        state.done()
        // Selection stays at 1 (now pointing to what was item 2)
        #expect(state.selectedIndex == 1)
    }

    @Test func doneAtLastItemClampsSelection() {
        let (state, _) = Self.makeAuthedState(count: 3)
        state.groupByRepo = false
        state.selectedIndex = 2
        state.done()
        #expect(state.selectedIndex == 1)
    }

    @Test func doneOnSingleItemResultsInEmptyList() {
        let (state, _) = Self.makeAuthedState(count: 1)
        state.done()
        #expect(state.filteredNotifications.isEmpty)
        #expect(state.selectedIndex == 0)
    }

    // MARK: - Undo

    @Test func undoRestoresPendingDoneBeforeItHitsTheAPI() async {
        let (state, session) = Self.makeAuthedState(
            results: [
                .success((
                    Data(),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications/threads/0",
                        statusCode: 204
                    )
                ))
            ],
            actionDispatchDelayNanoseconds: 50_000_000,
            sleepHandler: Self.realSleep
        )
        state.groupByRepo = false
        state.selectedIndex = 0
        state.done()
        #expect(state.notifications.count == 4)
        state.undo()
        try? await Task.sleep(nanoseconds: 75_000_000)
        #expect(state.notifications.count == 5)
        #expect(state.selectedNotification?.id == "0")
        #expect((await session.recordedRequests()).isEmpty)
    }

    @Test func multipleUndosCancelMultipleQueuedActions() async {
        let (state, session) = Self.makeAuthedState(
            actionDispatchDelayNanoseconds: 50_000_000,
            sleepHandler: Self.realSleep
        )
        state.groupByRepo = false
        state.selectedIndex = 0
        state.done()
        state.selectedIndex = 0
        state.done()
        #expect(state.notifications.count == 3)
        state.undo()
        #expect(state.notifications.count == 4)
        state.undo()
        try? await Task.sleep(nanoseconds: 75_000_000)
        #expect(state.notifications.count == 5)
        #expect((await session.recordedRequests()).isEmpty)
    }

    @Test func undoOnEmptyStackIsNoOp() {
        let state = Self.makeState()
        let before = state.notifications.count
        state.undo()
        #expect(state.notifications.count == before)
    }

    // MARK: - Clamp selection

    @Test func clampSelectionWhenIndexExceedsList() {
        let state = Self.makeState(3)
        state.selectedIndex = 10
        state.clampSelection()
        #expect(state.selectedIndex == 2)
    }

    @Test func clampSelectionOnEmptyList() {
        let state = Self.makeState(0)
        state.selectedIndex = 5
        state.clampSelection()
        #expect(state.selectedIndex == 0)
    }

    // MARK: - Selected notification

    @Test func selectedNotificationReturnsCorrectItem() {
        let state = Self.makeState()
        state.groupByRepo = false
        state.selectedIndex = 2
        #expect(state.selectedNotification?.id == "2")
    }

    @Test func selectedNotificationNilWhenEmpty() {
        let state = Self.makeState(0)
        #expect(state.selectedNotification == nil)
    }

    // MARK: - Search activation

    @Test func activateAndDeactivateSearch() {
        let state = Self.makeState()
        state.activateSearch()
        #expect(state.isSearchActive == true)
        state.searchQuery = "test"
        state.deactivateSearch()
        #expect(state.isSearchActive == false)
        #expect(state.searchQuery == "")
    }

    @Test func doneFailureRestoresThreadAndSelection() async {
        let (state, session) = Self.makeAuthedState(results: [
            .success((
                Data(),
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/0",
                    statusCode: 500
                )
            ))
        ])

        state.groupByRepo = false
        state.selectedIndex = 0
        state.done()
        #expect(state.notifications.count == 4)

        await Self.settleTasks()

        #expect(state.notifications.count == 5)
        #expect(state.selectedNotification?.id == "0")
        #expect(state.errorMessage == "Failed to mark thread as done")
        #expect((await session.recordedRequests()).count == 1)
    }

    @Test func refreshKeepsPendingHiddenThreadFilteredOut() async {
        let (state, session) = Self.makeAuthedState(
            results: [
                .success((
                    Self.singleNotificationPayload(id: "0"),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications",
                        statusCode: 200,
                        headers: ["Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT"]
                    )
                ))
            ],
            count: 1,
            actionDispatchDelayNanoseconds: 50_000_000,
            sleepHandler: Self.realSleep
        )

        state.groupByRepo = false
        state.selectedIndex = 0
        state.done()
        #expect(state.filteredNotifications.isEmpty)

        await state.loadNotifications(force: true)
        #expect(state.filteredNotifications.isEmpty)

        state.undo()
        try? await Task.sleep(nanoseconds: 75_000_000)

        #expect((await session.recordedRequests()).count == 1)
    }

    @Test func refreshKeepsCommittedDoneThreadHiddenUntilServerCatchesUp() async {
        let (state, session) = Self.makeAuthedState(
            results: [
                .success((
                    Data(),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications/threads/0",
                        statusCode: 204
                    )
                )),
                .success((
                    Self.singleNotificationPayload(id: "0"),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1",
                        statusCode: 200,
                        headers: ["Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT"]
                    )
                )),
            ],
            count: 1
        )

        state.groupByRepo = false
        state.selectedIndex = 0
        state.done()
        await Self.settleTasks()

        #expect(state.filteredNotifications.isEmpty)

        await state.loadNotifications(force: true)

        #expect(state.filteredNotifications.isEmpty)
        #expect((await session.recordedRequests()).count == 2)
    }

    @Test func relaunchKeepsCommittedDoneThreadHiddenUntilServerCatchesUp() async {
        let defaults = Self.makeIsolatedUserDefaults()
        let (state, session) = Self.makeAuthedState(
            results: [
                .success((
                    Data(),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications/threads/0",
                        statusCode: 204
                    )
                ))
            ],
            count: 1,
            userDefaults: defaults
        )

        state.groupByRepo = false
        state.selectedIndex = 0
        state.done()
        await Self.waitUntil {
            await session.recordedRequests().count == 1
        }

        let relaunchedState = AppState(
            notifications: Self.makeNotifications(1),
            authStatus: .signedIn(username: "octodot"),
            userDefaults: defaults
        )
        relaunchedState.groupByRepo = false

        #expect(state.filteredNotifications.isEmpty)
        #expect(relaunchedState.filteredNotifications.isEmpty)
    }

    @Test func cachedRefreshDoesNotDropCommittedDoneHideBeforeServerCatchesUp() async {
        let initialPayload = Self.notificationsPayload(ids: ["0", "1"])
        let stalePayload = Self.notificationsPayload(ids: ["0", "1"])

        let (state, session) = Self.makeAuthedState(
            results: [
                .success((
                    initialPayload,
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1",
                        statusCode: 200,
                        headers: [
                            "Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT",
                            "X-Poll-Interval": "60",
                        ]
                    )
                )),
                .success((
                    Data(),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications/threads/0",
                        statusCode: 204
                    )
                )),
                .success((
                    stalePayload,
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1",
                        statusCode: 200,
                        headers: ["Last-Modified": "Wed, 01 Apr 2026 12:01:00 GMT"]
                    )
                )),
            ],
            count: 2
        )

        state.groupByRepo = false
        await state.loadNotifications(force: true)
        state.selectedIndex = 0
        state.done()
        await Self.waitUntil {
            await session.recordedRequests().count == 2
        }

        #expect(state.filteredNotifications.map(\.id) == ["0"])

        await state.loadNotifications(force: false)
        #expect(state.filteredNotifications.map(\.id) == ["0"])

        await state.loadNotifications(force: true)
        #expect(state.filteredNotifications.map(\.id) == ["0"])
        #expect((await session.recordedRequests()).count == 3)
    }

    @Test func newerActivityRevivesCommittedDoneThread() async {
        let newerPayload = """
        [
          {
            "id": "0",
            "unread": true,
            "reason": "review_requested",
            "updated_at": "2099-04-01T13:00:00Z",
            "subject": {
              "title": "Notification 0",
              "url": null,
              "type": "PullRequest"
            },
            "repository": {
              "full_name": "acme/alpha",
              "html_url": "https://github.com/acme/alpha"
            }
          }
        ]
        """.data(using: .utf8)!

        let (state, session) = Self.makeAuthedState(
            results: [
                .success((
                    Data(),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications/threads/0",
                        statusCode: 204
                    )
                )),
                .success((
                    newerPayload,
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1",
                        statusCode: 200,
                        headers: ["Last-Modified": "Wed, 01 Apr 2026 13:00:00 GMT"]
                    )
                )),
            ],
            count: 1
        )

        state.groupByRepo = false
        state.selectedIndex = 0
        state.done()
        await Self.waitUntil {
            await session.recordedRequests().count == 1
        }

        #expect(state.filteredNotifications.isEmpty)

        await state.loadNotifications(force: true)

        #expect(state.filteredNotifications.count == 1)
        #expect(state.filteredNotifications.first?.id == "0")
        #expect((await session.recordedRequests()).count == 2)
    }

    @Test func refreshKeepsCommittedUnsubscribeHiddenAndUndoStillRestores() async {
        let (state, session) = Self.makeAuthedState(
            results: [
                .success((
                    Data(),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications/threads/0/subscription",
                        statusCode: 204
                    )
                )),
                .success((
                    Self.singleNotificationPayload(id: "0"),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1",
                        statusCode: 200,
                        headers: ["Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT"]
                    )
                )),
                .success((
                    Data(),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications/threads/0/subscription",
                        statusCode: 200
                    )
                )),
            ],
            count: 1
        )

        state.groupByRepo = false
        state.selectedIndex = 0
        state.unsubscribeFromThread()
        await Self.settleTasks()

        #expect(state.filteredNotifications.isEmpty)

        await state.loadNotifications(force: true)
        #expect(state.filteredNotifications.isEmpty)

        state.undo()
        #expect(state.notifications.contains(where: { $0.id == "0" }))

        await Self.waitUntil {
            await session.recordedRequests().count == 3
        }

        let requests = await session.recordedRequests()
        #expect(requests.count == 3)
        #expect(requests[0].httpMethod == "DELETE")
        #expect(requests[1].httpMethod == "GET")
        #expect(requests[2].httpMethod == "PUT")
    }

    @Test func unsubscribeSuccessCanBeUndoneWithRestoreSubscription() async {
        let (state, session) = Self.makeAuthedState(results: [
            .success((
                Data(),
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/0/subscription",
                    statusCode: 204
                )
            )),
            .success((
                Data(),
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/0/subscription",
                    statusCode: 200
                )
            )),
        ])

        state.groupByRepo = false
        state.selectedIndex = 0
        state.unsubscribeFromThread()
        #expect(state.notifications.contains(where: { $0.id == "0" }) == false)

        await Self.settleTasks()
        #expect(state.notifications.contains(where: { $0.id == "0" }) == false)

        state.undo()
        #expect(state.notifications.contains(where: { $0.id == "0" }))

        await Self.waitUntil {
            await session.recordedRequests().count == 2
        }

        let requests = await session.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests.first?.httpMethod == "DELETE")
        #expect(requests.last?.httpMethod == "PUT")
        #expect(state.notifications.contains(where: { $0.id == "0" }))
    }
}

struct KeychainHelperTests {
    @Test func savesAndLoadsTokenFromKeychain() throws {
        let service = "com.octodot.tests.\(UUID().uuidString)"
        let account = UUID().uuidString
        defer { KeychainHelper.deleteToken(service: service, account: account) }

        try KeychainHelper.saveToken("ghp_test_token", service: service, account: account)

        #expect(KeychainHelper.loadToken(service: service, account: account) == "ghp_test_token")
    }

    @Test func saveTokenOverwritesExistingValue() throws {
        let service = "com.octodot.tests.\(UUID().uuidString)"
        let account = UUID().uuidString
        defer { KeychainHelper.deleteToken(service: service, account: account) }

        try KeychainHelper.saveToken("ghp_first", service: service, account: account)
        try KeychainHelper.saveToken("ghp_second", service: service, account: account)

        #expect(KeychainHelper.loadToken(service: service, account: account) == "ghp_second")
    }

}

struct GitHubAPIClientTests {
    @Test func validateTokenReturnsUsername() async throws {
        let session = StubNetworkSession(results: [
            .success((
                #"{"login":"octodot"}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/user")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            ))
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let username = try await client.validateToken()
        let requests = await session.recordedRequests()

        #expect(username == "octodot")
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_secret")
    }

    @Test func fetchNotificationsUsesConditionalPollingHeaders() async throws {
        let session = StubNetworkSession(results: [
            .success((
                Self.notificationsPayload(id: "1").data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT",
                        "X-Poll-Interval": "0",
                    ]
                )!
            )),
            .success((
                Data(),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 304,
                    httpVersion: nil,
                    headerFields: ["X-Poll-Interval": "60"]
                )!
            )),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let initial = try await client.fetchNotifications(force: true)
        let cached = try await client.fetchNotifications(force: false)
        let requests = await session.recordedRequests()

        #expect(initial.count == 1)
        #expect(cached.count == 1)
        #expect(cached.first?.id == initial.first?.id)
        #expect(requests.count == 2)
        #expect(requests.last?.value(forHTTPHeaderField: "If-Modified-Since") == "Wed, 01 Apr 2026 12:00:00 GMT")
    }

    @Test func forceRefreshBypassesConditionalHeaders() async throws {
        let session = StubNetworkSession(results: [
            .success((
                Self.notificationsPayload(id: "1").data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT",
                        "X-Poll-Interval": "60",
                    ]
                )!
            )),
            .success((
                Self.notificationsPayload(id: "2").data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:01:00 GMT",
                        "X-Poll-Interval": "60",
                    ]
                )!
            )),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        _ = try await client.fetchNotifications(force: true)
        let refreshed = try await client.fetchNotifications(force: true)
        let requests = await session.recordedRequests()

        #expect(refreshed.count == 1)
        #expect(refreshed.first?.id == "2")
        #expect(requests.count == 2)
        #expect(requests.last?.value(forHTTPHeaderField: "If-Modified-Since") == nil)
    }

    @Test func fetchNotificationsLoadsMultiplePages() async throws {
        let firstPage = Self.notificationsPayload(ids: (1...100).map(String.init)).data(using: .utf8)!
        let secondPage = Self.notificationsPayload(ids: ["101"]).data(using: .utf8)!

        let session = StubNetworkSession(results: [
            .success((
                firstPage,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications?page=1")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT",
                        "X-Poll-Interval": "60",
                    ]
                )!
            )),
            .success((
                secondPage,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications?page=2")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let notifications = try await client.fetchNotifications(force: true)
        let requests = await session.recordedRequests()

        #expect(notifications.count == 101)
        #expect(requests.count == 2)
        #expect(requests.first?.url?.query?.contains("per_page=100") == true)
        #expect(requests.first?.url?.query?.contains("page=1") == true)
        #expect(requests.last?.url?.query?.contains("page=2") == true)
        #expect(requests.first?.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func fetchNotificationsFollowsLinkHeaderPagination() async throws {
        let firstPage = Self.notificationsPayload(ids: ["1"]).data(using: .utf8)!
        let secondPage = Self.notificationsPayload(ids: ["2"]).data(using: .utf8)!

        let session = StubNetworkSession(results: [
            .success((
                firstPage,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications?page=1")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Link": #"<https://api.github.com/notifications?all=false&per_page=100&page=2>; rel="next""#,
                        "Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT",
                    ]
                )!
            )),
            .success((
                secondPage,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications?page=2")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let notifications = try await client.fetchNotifications(force: true)
        let requests = await session.recordedRequests()

        #expect(notifications.count == 2)
        #expect(requests.count == 2)
        #expect(requests.last?.url?.absoluteString.contains("page=2") == true)
        #expect(requests.first?.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func fetchNotificationsReusesSubjectStateForUnchangedItems() async throws {
        let session = StubNetworkSession(results: [
            .success((
                Self.notificationsPayload(
                    id: "1",
                    updatedAt: "2026-04-01T12:00:00Z",
                    subjectURL: "https://api.github.com/repos/acme/test/pulls/1"
                ).data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT"]
                )!
            )),
            .success((
                #"{"state":"open"}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/repos/acme/test/pulls/1")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
            .success((
                Self.notificationsPayload(
                    id: "1",
                    updatedAt: "2026-04-01T12:00:00Z",
                    subjectURL: "https://api.github.com/repos/acme/test/pulls/1"
                ).data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Last-Modified": "Wed, 01 Apr 2026 12:01:00 GMT"]
                )!
            )),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let initial = try await client.fetchNotifications(force: true)
        let refreshed = try await client.fetchNotifications(force: true)
        let requests = await session.recordedRequests()

        #expect(initial.first?.subjectState == .open)
        #expect(refreshed.first?.subjectState == .open)
        #expect(requests.count == 3)
    }

    private static func notificationsPayload(
        id: String,
        updatedAt: String = "2026-04-01T12:00:00Z",
        subjectURL: String? = nil
    ) -> String {
        let subjectURLField: String
        if let subjectURL {
            subjectURLField = #""url":"\#(subjectURL)""#
        } else {
            subjectURLField = #""url":null"#
        }

        return """
        [
          {
            "id": "\(id)",
            "unread": true,
            "reason": "review_requested",
            "updated_at": "\(updatedAt)",
            "subject": {
              "title": "Test pull request",
              \(subjectURLField),
              "type": "PullRequest"
            },
            "repository": {
              "full_name": "acme/test",
              "html_url": "https://github.com/acme/test"
            }
          }
        ]
        """
    }

    private static func notificationsPayload(ids: [String]) -> String {
        let iso = ISO8601DateFormatter()
        let baseDate = iso.date(from: "2026-04-01T12:00:00Z") ?? Date()

        let items = ids.enumerated().map { offset, id in
            let updatedAt = iso.string(from: baseDate.addingTimeInterval(TimeInterval(offset * 60)))
            return """
              {
                "id": "\(id)",
                "unread": true,
                "reason": "review_requested",
                "updated_at": "\(updatedAt)",
                "subject": {
                  "title": "Test pull request \(id)",
                  "url": null,
                  "type": "PullRequest"
                },
                "repository": {
                  "full_name": "acme/test",
                  "html_url": "https://github.com/acme/test"
                }
              }
            """
        }.joined(separator: ",\n")

        return "[\n\(items)\n]"
    }
}

private actor StubNetworkSession: NetworkSession {
    private var results: [Result<(Data, HTTPURLResponse), Error>]
    private var requests: [URLRequest] = []

    init(results: [Result<(Data, HTTPURLResponse), Error>]) {
        self.results = results
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !results.isEmpty else {
            throw StubError.missingResponse
        }

        let result = results.removeFirst()
        switch result {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    enum StubError: Error {
        case missingResponse
    }
}

private actor DelayedStubNetworkSession: NetworkSession {
    enum ResultEnvelope {
        case success(payload: Data, response: HTTPURLResponse, delayNanoseconds: UInt64)
        case failure(error: Error, delayNanoseconds: UInt64)
    }

    private var results: [ResultEnvelope]

    init(results: [ResultEnvelope]) {
        self.results = results
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard !results.isEmpty else {
            throw StubNetworkSession.StubError.missingResponse
        }

        let result = results.removeFirst()
        switch result {
        case .success(let payload, let response, let delayNanoseconds):
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            return (payload, response)
        case .failure(let error, let delayNanoseconds):
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            throw error
        }
    }
}
