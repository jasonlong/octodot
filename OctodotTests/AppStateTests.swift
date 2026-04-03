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

    static func singleNotificationPayload(
        id: String,
        isUnread: Bool = true,
        updatedAt: String = "2026-04-01T12:00:00Z",
        subjectURL: String? = nil
    ) -> Data {
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
            "unread": \(isUnread ? "true" : "false"),
            "reason": "review_requested",
            "updated_at": "\(updatedAt)",
            "subject": {
              "title": "Notification \(id)",
              \(subjectURLField),
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

    static func dependabotAlertsPayload(updatedAt: String = "2026-04-01T12:00:00Z") -> Data {
        """
        [
          {
            "number": 7,
            "html_url": "https://github.com/acme/alpha/security/dependabot/7",
            "updated_at": "\(updatedAt)",
            "repository": {
              "full_name": "acme/alpha",
              "html_url": "https://github.com/acme/alpha"
            },
            "dependency": {
              "package": {
                "name": "electron"
              }
            },
            "security_advisory": {
              "ghsa_id": "GHSA-1234",
              "summary": "Upgrade electron"
            }
          }
        ]
        """.data(using: .utf8)!
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

    @Test func pageDownAdvancesByFixedJumpCount() {
        let state = Self.makeState(20)
        state.selectedIndex = 1
        state.pageDown()
        #expect(state.selectedIndex == 1 + AppState.pageJumpCount)
    }

    @Test func pageUpClampsAtTop() {
        let state = Self.makeState(20)
        state.selectedIndex = 3
        state.pageUp()
        #expect(state.selectedIndex == 0)
    }

    @Test func halfPageDownAdvancesByFixedJumpCount() {
        let state = Self.makeState(20)
        state.selectedIndex = 1
        state.halfPageDown()
        #expect(state.selectedIndex == 1 + AppState.halfPageJumpCount)
    }

    @Test func halfPageUpClampsAtTop() {
        let state = Self.makeState(20)
        state.selectedIndex = 3
        state.halfPageUp()
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

    @Test func selectNotificationByIDUpdatesSelection() {
        let state = Self.makeState()
        let expectedIndex = state.filteredNotifications.firstIndex(where: { $0.id == "3" })

        state.selectNotification(id: "3")

        #expect(state.selectedIndex == expectedIndex)
        #expect(state.selectedNotification?.id == "3")
        #expect(state.selectedNotificationID == "3")
    }

    @Test func selectNotificationByIDIgnoresUnknownIDs() {
        let state = Self.makeState()
        state.selectedIndex = 1
        let initialIndex = state.selectedIndex
        let initialNotificationID = state.selectedNotification?.id
        let initialSelectedNotificationID = state.selectedNotificationID

        state.selectNotification(id: "999")

        #expect(state.selectedIndex == initialIndex)
        #expect(state.selectedNotification?.id == initialNotificationID)
        #expect(state.selectedNotificationID == initialSelectedNotificationID)
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

    @Test func inboxModeShowsReadAndUnreadItemsByDefault() {
        let notifications = [
            Self.makeNotification(id: 1, isUnread: true),
            Self.makeNotification(id: 2, isUnread: false),
        ]
        let state = AppState(
            notifications: notifications,
            userDefaults: Self.makeIsolatedUserDefaults()
        )

        state.groupByRepo = false

        #expect(state.inboxMode == .inbox)
        #expect(state.filteredNotifications.count == 2)
        #expect(state.notifications.count == 2)
        #expect(state.filteredNotifications.map(\.isUnread).contains(true))
        #expect(state.filteredNotifications.map(\.isUnread).contains(false))
    }

    @Test func unreadModeShowsOnlyUnreadItems() {
        let oldNotification = GitHubNotification(
            id: "old",
            threadId: "old",
            title: "Old unread notification",
            repository: "acme/alpha",
            reason: .subscribed,
            type: .pullRequest,
            updatedAt: Date().addingTimeInterval(-45 * 24 * 60 * 60),
            isUnread: true,
            url: URL(string: "https://github.com/acme/test/pull/old")!,
            subjectURL: nil,
            subjectState: .open
        )
        let state = AppState(
            notifications: [oldNotification],
            userDefaults: Self.makeIsolatedUserDefaults()
        )

        state.groupByRepo = false
        state.inboxMode = .unread
        state.clampSelection()

        #expect(state.filteredNotifications.map(\.id) == ["old"])
    }

    @Test func inboxModeIncludesDependabotAlertsButUnreadModeDoesNot() async {
        let session = StubNetworkSession(results: [
            .success((
                Self.notificationsPayload(ids: ["1"]),
                Self.httpResponse(
                    url: "https://api.github.com/notifications",
                    statusCode: 200,
                    headers: ["Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT"]
                )
            )),
            .success((
                Data("[]".utf8),
                Self.httpResponse(
                    url: "https://api.github.com/notifications?all=true",
                    statusCode: 200
                )
            )),
            .success((
                Self.dependabotAlertsPayload(),
                Self.httpResponse(
                    url: "https://api.github.com/repos/acme/alpha/dependabot/alerts",
                    statusCode: 200
                )
            )),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let state = AppState(
            notifications: [],
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            userDefaults: Self.makeIsolatedUserDefaults()
        )
        state.groupByRepo = false
        state.isPanelVisible = true

        await state.loadNotifications(force: true)
        await Self.waitUntil {
            await MainActor.run {
                state.filteredNotifications.contains { $0.source == .dependabotAlert }
            }
        }

        #expect(state.filteredNotifications.count == 2)
        #expect(state.filteredNotifications.contains { $0.source == GitHubNotification.Source.dependabotAlert })
        #expect(state.filteredNotifications.first(where: { $0.source == .dependabotAlert })?.isUnread == true)
        #expect(state.unreadNotificationCount == 1)

        state.inboxMode = AppState.InboxMode.unread

        #expect(state.filteredNotifications.count == 1)
        #expect(state.filteredNotifications.allSatisfy { $0.source == GitHubNotification.Source.thread })
    }

    @Test func doneDismissesSecurityAlertLocallyUntilItUpdates() async {
        let session = StubNetworkSession(results: [
            .success((
                Self.notificationsPayload(ids: ["1"]),
                Self.httpResponse(
                    url: "https://api.github.com/notifications",
                    statusCode: 200,
                    headers: ["Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT"]
                )
            )),
            .success((
                Data("[]".utf8),
                Self.httpResponse(
                    url: "https://api.github.com/notifications?all=true",
                    statusCode: 200
                )
            )),
            .success((
                Self.dependabotAlertsPayload(updatedAt: "2026-04-01T12:00:00Z"),
                Self.httpResponse(
                    url: "https://api.github.com/repos/acme/alpha/dependabot/alerts",
                    statusCode: 200
                )
            )),
            .success((
                Self.notificationsPayload(ids: ["1"]),
                Self.httpResponse(
                    url: "https://api.github.com/notifications",
                    statusCode: 200,
                    headers: ["Last-Modified": "Wed, 01 Apr 2026 12:01:00 GMT"]
                )
            )),
            .success((
                Data("[]".utf8),
                Self.httpResponse(
                    url: "https://api.github.com/notifications?all=true",
                    statusCode: 200
                )
            )),
            .success((
                Self.dependabotAlertsPayload(updatedAt: "2026-04-01T12:00:00Z"),
                Self.httpResponse(
                    url: "https://api.github.com/repos/acme/alpha/dependabot/alerts",
                    statusCode: 200
                )
            )),
            .success((
                Self.notificationsPayload(ids: ["1"]),
                Self.httpResponse(
                    url: "https://api.github.com/notifications",
                    statusCode: 200,
                    headers: ["Last-Modified": "Wed, 02 Apr 2026 12:00:00 GMT"]
                )
            )),
            .success((
                Data("[]".utf8),
                Self.httpResponse(
                    url: "https://api.github.com/notifications?all=true",
                    statusCode: 200
                )
            )),
            .success((
                Self.dependabotAlertsPayload(updatedAt: "2026-04-02T12:00:00Z"),
                Self.httpResponse(
                    url: "https://api.github.com/repos/acme/alpha/dependabot/alerts",
                    statusCode: 200
                )
            )),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let state = AppState(
            notifications: [],
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            userDefaults: Self.makeIsolatedUserDefaults()
        )
        state.groupByRepo = false
        state.isPanelVisible = true

        await state.loadNotifications(force: true)
        let alertID = "dependabot:acme/alpha:7"
        await Self.waitUntil {
            await MainActor.run {
                state.filteredNotifications.contains { $0.id == alertID }
            }
        }
        #expect(state.filteredNotifications.contains { $0.id == alertID })

        state.selectNotification(id: alertID)
        state.done()
        #expect(state.filteredNotifications.contains { $0.id == alertID } == false)

        await state.loadNotifications(force: true)
        await Self.waitUntil {
            await session.recordedRequests().count == 6
        }
        #expect(state.filteredNotifications.contains { $0.id == alertID } == false)

        await state.loadNotifications(force: true)
        await Self.waitUntil {
            await session.recordedRequests().count == 9
        }
        await Self.waitUntil {
            await MainActor.run {
                state.filteredNotifications.contains { $0.id == alertID }
            }
        }
        #expect(state.filteredNotifications.contains { $0.id == alertID })
    }

    @Test func undoRestoresDismissedSecurityAlert() async {
        let session = StubNetworkSession(results: [
            .success((
                Self.notificationsPayload(ids: ["1"]),
                Self.httpResponse(
                    url: "https://api.github.com/notifications",
                    statusCode: 200,
                    headers: ["Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT"]
                )
            )),
            .success((
                Data("[]".utf8),
                Self.httpResponse(
                    url: "https://api.github.com/notifications?all=true",
                    statusCode: 200
                )
            )),
            .success((
                Self.dependabotAlertsPayload(updatedAt: "2026-04-01T12:00:00Z"),
                Self.httpResponse(
                    url: "https://api.github.com/repos/acme/alpha/dependabot/alerts",
                    statusCode: 200
                )
            )),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let state = AppState(
            notifications: [],
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            userDefaults: Self.makeIsolatedUserDefaults()
        )
        state.groupByRepo = false
        state.isPanelVisible = true

        await state.loadNotifications(force: true)
        let alertID = "dependabot:acme/alpha:7"
        await Self.waitUntil {
            await MainActor.run {
                state.filteredNotifications.contains { $0.id == alertID }
            }
        }
        state.selectNotification(id: alertID)
        state.done()
        #expect(state.filteredNotifications.contains { $0.id == alertID } == false)

        state.undo()
        #expect(state.filteredNotifications.contains { $0.id == alertID })
        #expect(state.selectedNotification?.id == alertID)
    }

    @Test func openInBrowserMarksSecurityAlertReadLocally() async {
        let session = StubNetworkSession(results: [
            .success((
                Self.notificationsPayload(ids: ["1"]),
                Self.httpResponse(
                    url: "https://api.github.com/notifications",
                    statusCode: 200,
                    headers: ["Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT"]
                )
            )),
            .success((
                Data("[]".utf8),
                Self.httpResponse(
                    url: "https://api.github.com/notifications?all=true",
                    statusCode: 200
                )
            )),
            .success((
                Self.dependabotAlertsPayload(updatedAt: "2026-04-01T12:00:00Z"),
                Self.httpResponse(
                    url: "https://api.github.com/repos/acme/alpha/dependabot/alerts",
                    statusCode: 200
                )
            )),
            .success((
                Self.notificationsPayload(ids: ["1"]),
                Self.httpResponse(
                    url: "https://api.github.com/notifications",
                    statusCode: 200,
                    headers: ["Last-Modified": "Wed, 01 Apr 2026 12:01:00 GMT"]
                )
            )),
            .success((
                Data("[]".utf8),
                Self.httpResponse(
                    url: "https://api.github.com/notifications?all=true",
                    statusCode: 200
                )
            )),
            .success((
                Self.dependabotAlertsPayload(updatedAt: "2026-04-01T12:00:00Z"),
                Self.httpResponse(
                    url: "https://api.github.com/repos/acme/alpha/dependabot/alerts",
                    statusCode: 200
                )
            )),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let state = AppState(
            notifications: [],
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            userDefaults: Self.makeIsolatedUserDefaults(),
            urlOpener: { _ in true }
        )
        state.groupByRepo = false
        state.isPanelVisible = true

        await state.loadNotifications(force: true)
        let alertID = "dependabot:acme/alpha:7"
        await Self.waitUntil {
            await MainActor.run {
                state.filteredNotifications.contains { $0.id == alertID }
            }
        }
        state.selectNotification(id: alertID)

        #expect(state.selectedNotification?.isUnread == true)
        #expect(state.openInBrowser() == true)
        #expect(state.selectedNotification?.isUnread == false)

        await state.loadNotifications(force: true)
        #expect(state.filteredNotifications.first(where: { $0.id == alertID })?.isUnread == false)
        #expect((await session.recordedRequests()).allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func loadNotificationsAppliesInboxBeforeDelayedSecurityAlertsFinish() async {
        let session = DelayedStubNetworkSession(results: [
            .success(
                payload: Self.notificationsPayload(ids: ["1"]),
                response: Self.httpResponse(
                    url: "https://api.github.com/notifications",
                    statusCode: 200,
                    headers: ["Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT"]
                ),
                delayNanoseconds: 0
            ),
            .success(
                payload: Data("[]".utf8),
                response: Self.httpResponse(
                    url: "https://api.github.com/notifications?all=true",
                    statusCode: 200
                ),
                delayNanoseconds: 0
            ),
            .success(
                payload: Self.dependabotAlertsPayload(),
                response: Self.httpResponse(
                    url: "https://api.github.com/repos/acme/alpha/dependabot/alerts",
                    statusCode: 200
                ),
                delayNanoseconds: 75_000_000
            ),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let state = AppState(
            notifications: [],
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            userDefaults: Self.makeIsolatedUserDefaults()
        )
        state.groupByRepo = false
        state.isPanelVisible = true

        await state.loadNotifications(force: true)

        #expect(state.filteredNotifications.map(\.id) == ["1"])

        await Self.waitUntil {
            await MainActor.run {
                state.filteredNotifications.contains { $0.source == .dependabotAlert }
            }
        }

        #expect(state.filteredNotifications.count == 2)
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
        let state = AppState(
            notifications: notifications,
            userDefaults: Self.makeIsolatedUserDefaults()
        )
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
        let state = AppState(
            notifications: notifications,
            userDefaults: Self.makeIsolatedUserDefaults()
        )
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

    @Test func viewPreferencesPersistAcrossStateInstances() {
        let defaults = Self.makeIsolatedUserDefaults()

        let firstState = Self.makeState(userDefaults: defaults)
        firstState.groupByRepo = false
        firstState.inboxMode = .inbox

        let secondState = Self.makeState(userDefaults: defaults)
        #expect(secondState.groupByRepo == false)
        #expect(secondState.inboxMode == .inbox)
    }

    @Test func legacyAllInboxModeMigratesToInbox() {
        let defaults = Self.makeIsolatedUserDefaults()
        defaults.set("all", forKey: "AppState.inboxMode.v1")

        let state = Self.makeState(userDefaults: defaults)

        #expect(state.inboxMode == .inbox)
    }

    @Test func toggleInboxModeRefreshesUsingUnreadFeedAndSwitchesProjection() async {
        let (state, session) = Self.makeAuthedState(
            results: [
                .success((
                    Self.singleNotificationPayload(id: "0", isUnread: true),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1",
                        statusCode: 200
                    )
                )),
                .success((
                    Self.singleNotificationPayload(id: "1", isUnread: false),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1&all=true",
                        statusCode: 200
                    )
                ))
            ],
            count: 0
        )

        state.inboxMode = .unread

        state.toggleInboxMode()

        await Self.waitUntil {
            await session.recordedRequests().count == 2
        }

        let requests = await session.recordedRequests()
        #expect(state.inboxMode == .inbox)
        #expect(requests.count == 2)
        #expect(requests.first?.url?.query?.contains("all=false") == true)
        #expect(requests.last?.url?.query?.contains("all=true") == true)
        #expect(requests.last?.url?.query?.contains("since=") == true)
    }

    @Test func inboxModeLoadsRecentReadItemsFromRecentInboxFeed() async {
        let (state, _) = Self.makeAuthedState(
            results: [
                .success((
                    Self.singleNotificationPayload(id: "0", isUnread: true),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1",
                        statusCode: 200
                    )
                )),
                .success((
                    Self.singleNotificationPayload(id: "1", isUnread: false),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1&all=true",
                        statusCode: 200
                    )
                ))
            ],
            count: 0
        )

        state.groupByRepo = false

        await state.loadNotifications(force: true)

        #expect(state.filteredNotifications.count == 2)
        #expect(Set(state.filteredNotifications.map(\.id)) == Set(["0", "1"]))
        #expect(state.filteredNotifications.contains(where: { $0.id == "0" && $0.isUnread }))
        #expect(state.filteredNotifications.contains(where: { $0.id == "1" && !$0.isUnread }))
    }

    @Test func inboxModeRecentReadSeedRunsWhenInboxSeedIsEmptyOnColdStart() async {
        let defaults = Self.makeIsolatedUserDefaults()

        let (firstState, firstSession) = Self.makeAuthedState(
            results: [
                .success((
                    Self.singleNotificationPayload(id: "0", isUnread: true),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1",
                        statusCode: 200
                    )
                )),
                .success((
                    Self.singleNotificationPayload(id: "1", isUnread: false),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1&all=true",
                        statusCode: 200
                    )
                ))
            ],
            count: 0,
            userDefaults: defaults
        )

        firstState.groupByRepo = false
        await firstState.loadNotifications(force: true)
        #expect((await firstSession.recordedRequests()).count == 2)

        let (secondState, secondSession) = Self.makeAuthedState(
            results: [
                .success((
                    Self.singleNotificationPayload(id: "0", isUnread: true),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1",
                        statusCode: 200
                    )
                )),
                .success((
                    Self.singleNotificationPayload(id: "1", isUnread: false),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1&all=true",
                        statusCode: 200
                    )
                ))
            ],
            count: 0,
            userDefaults: defaults
        )

        secondState.groupByRepo = false
        await secondState.loadNotifications(force: true)

        let secondRequests = await secondSession.recordedRequests()
        #expect(secondRequests.count == 2)
        #expect(secondRequests.first?.url?.query?.contains("all=false") == true)
        #expect(secondRequests.last?.url?.query?.contains("all=true") == true)
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
        state.inboxMode = .inbox
        #expect(state.notifications[0].isUnread == true)
        state.selectedIndex = 0
        state.markRead()
        #expect(state.notifications[0].isUnread == false)
        await Self.waitUntil {
            await session.recordedRequests().count == 1
        }

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
                .success((
                    Self.notificationsPayload(ids: []),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1&all=true",
                        statusCode: 200
                    )
                )),
            ],
            count: 1
        )

        state.inboxMode = .inbox
        state.groupByRepo = false
        state.selectedIndex = 0
        state.markRead()
        await Self.waitUntil {
            await session.recordedRequests().count == 1
        }

        #expect(state.notifications[0].isUnread == false)

        await state.loadNotifications(force: true)

        #expect(state.notifications.count == 1)
        #expect(state.notifications[0].isUnread == false)
        let requests = await session.recordedRequests()
        #expect(requests.count == 3)
        #expect(requests.last?.url?.query?.contains("all=true") == true)
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

    @Test func openInBrowserDoesNotMarkReadWhenOpenFails() async {
        let (state, session) = Self.makeAuthedState(
            count: 1,
            urlOpener: { _ in false }
        )

        state.groupByRepo = false
        state.selectedIndex = 0

        #expect(state.openInBrowser() == false)
        #expect(state.notifications[0].isUnread == true)

        await Self.settleTasks()

        #expect((await session.recordedRequests()).isEmpty)
    }

    @Test func loadNotificationsDefersVisibleSubjectStateResolution() async {
        let session = DelayedStubNetworkSession(results: [
            .success(
                payload: Self.singleNotificationPayload(
                    id: "7",
                    subjectURL: "https://api.github.com/repos/acme/alpha/pulls/7"
                ),
                response: Self.httpResponse(
                    url: "https://api.github.com/notifications?page=1",
                    statusCode: 200,
                    headers: ["Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT"]
                ),
                delayNanoseconds: 0
            ),
            .success(
                payload: #"{"state":"open"}"#.data(using: .utf8)!,
                response: Self.httpResponse(
                    url: "https://api.github.com/repos/acme/alpha/pulls/7",
                    statusCode: 200
                ),
                delayNanoseconds: 50_000_000
            ),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let state = Self.makeState(0, apiClient: client)

        state.inboxMode = .unread
        await state.loadNotifications(force: true)

        #expect(state.notifications.count == 1)
        #expect(state.notifications[0].subjectState == .unknown)

        state.notificationBecameVisible(id: "7")

        await Self.waitUntil {
            await MainActor.run {
                state.notifications.first?.subjectState == .open
            }
        }

        #expect(state.notifications[0].subjectState == .open)
    }

    @Test func visibleReadNotificationAlsoResolvesSubjectState() async {
        let session = DelayedStubNetworkSession(results: [
            .success(
                payload: Self.notificationsPayload(ids: []),
                response: Self.httpResponse(
                    url: "https://api.github.com/notifications?page=1",
                    statusCode: 200
                ),
                delayNanoseconds: 0
            ),
            .success(
                payload: Self.singleNotificationPayload(
                    id: "8",
                    isUnread: false,
                    subjectURL: "https://api.github.com/repos/acme/alpha/pulls/8"
                ),
                response: Self.httpResponse(
                    url: "https://api.github.com/notifications?page=1&all=true",
                    statusCode: 200
                ),
                delayNanoseconds: 0
            ),
            .success(
                payload: #"{"state":"closed","merged":true}"#.data(using: .utf8)!,
                response: Self.httpResponse(
                    url: "https://api.github.com/repos/acme/alpha/pulls/8",
                    statusCode: 200
                ),
                delayNanoseconds: 50_000_000
            ),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let state = AppState(
            notifications: [],
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            userDefaults: Self.makeIsolatedUserDefaults()
        )

        state.groupByRepo = false
        state.inboxMode = .inbox
        await state.loadNotifications(force: true)

        #expect(state.filteredNotifications.contains(where: { $0.id == "8" && $0.subjectState == .unknown }))

        state.notificationBecameVisible(id: "8")
        await Self.waitUntil {
            await MainActor.run {
                state.filteredNotifications.contains(where: { $0.id == "8" && $0.subjectState == .merged })
            }
        }

        #expect(state.filteredNotifications.contains(where: { $0.id == "8" && $0.subjectState == .merged }))
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

        state.inboxMode = .unread
        #expect(state.isPanelVisible == false)

        await Self.waitUntil {
            let didRequest = await session.recordedRequests().count == 1
            let didApply = await MainActor.run {
                state.notifications.count == 1 && state.notifications.first?.id == "99"
            }
            return didRequest && didApply
        }

        #expect(state.notifications.count == 1)
        #expect(state.notifications.first?.id == "99")

        state.signOut()
    }

    @Test func backgroundRefreshUsesUnreadFeedWhenInboxModeIsHidden() async {
        let sleeper = BackgroundRefreshSleeper()
        let session = StubNetworkSession(results: [
            .success((
                Self.singleNotificationPayload(id: "99"),
                Self.httpResponse(
                    url: "https://api.github.com/notifications?page=1",
                    statusCode: 200,
                    headers: ["X-Poll-Interval": "30"]
                )
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let state = AppState(
            notifications: [Self.makeNotification(id: 0, isUnread: false)],
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            backgroundRefreshEnabled: true,
            sleepHandler: { nanoseconds in
                await sleeper.sleep(nanoseconds: nanoseconds)
            },
            userDefaults: Self.makeIsolatedUserDefaults()
        )

        state.groupByRepo = false
        state.inboxMode = .inbox

        await Self.waitUntil {
            await session.recordedRequests().count == 1
        }

        let requests = await session.recordedRequests()
        #expect(requests.first?.url?.query?.contains("all=false") == true)
        #expect(state.notifications.count == 1)
        #expect(state.notifications.first?.id == "0")
        #expect(state.unreadNotificationCount == 1)

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
        state.inboxMode = .unread
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

        await Self.waitUntil {
            let requests = await session.recordedRequests()
            return requests.contains {
                $0.httpMethod == "DELETE" && $0.url?.path == "/notifications/threads/0"
            }
        }
        let requests = await session.recordedRequests()
        #expect(requests.contains {
            $0.httpMethod == "DELETE" && $0.url?.path == "/notifications/threads/0"
        })
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

    @Test func doneOnlyRemovesSelectedNotificationWhenTwoRowsShareARepository() async {
        let notifications = [
            GitHubNotification(
                id: "top",
                threadId: "top",
                title: "Process backup verification jobs",
                repository: "planetscale/api-bb",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: Date(),
                isUnread: true,
                url: URL(string: "https://github.com/planetscale/api-bb/pull/1")!,
                subjectURL: nil,
                subjectState: .open
            ),
            GitHubNotification(
                id: "second",
                threadId: "second",
                title: "Adds a sales serve toggle to the...",
                repository: "planetscale/api-bb",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: Date().addingTimeInterval(-3600),
                isUnread: true,
                url: URL(string: "https://github.com/planetscale/api-bb/pull/2")!,
                subjectURL: nil,
                subjectState: .open
            ),
        ]
        let session = StubNetworkSession(results: [
            .success((
                Data(),
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/top",
                    statusCode: 204
                )
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let state = AppState(
            notifications: notifications,
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            actionDispatchDelayNanoseconds: 0,
            userDefaults: Self.makeIsolatedUserDefaults()
        )

        state.groupByRepo = true
        state.selectNotification(id: "top")
        state.done()

        #expect(state.filteredNotifications.map(\.id) == ["second"])
        #expect(state.selectedNotification?.id == "second")

        await Self.waitUntil {
            let requests = await session.recordedRequests()
            return requests.contains {
                $0.httpMethod == "DELETE" && $0.url?.path == "/notifications/threads/top"
            }
        }
        let requests = await session.recordedRequests()
        #expect(requests.contains {
            $0.httpMethod == "DELETE" && $0.url?.path == "/notifications/threads/top"
        })
    }

    @Test func doneOnlyRemovesSelectedNotificationWhenRowsShareRepositoryAndTitle() async {
        let now = Date()
        let notifications = [
            GitHubNotification(
                id: "first",
                threadId: "first",
                title: "Process backup verification jobs",
                repository: "planetscale/api-bb",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now,
                isUnread: true,
                url: URL(string: "https://github.com/planetscale/api-bb/pull/1")!,
                subjectURL: nil,
                subjectState: .open
            ),
            GitHubNotification(
                id: "second",
                threadId: "second",
                title: "Process backup verification jobs",
                repository: "planetscale/api-bb",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now.addingTimeInterval(-60),
                isUnread: true,
                url: URL(string: "https://github.com/planetscale/api-bb/pull/2")!,
                subjectURL: nil,
                subjectState: .open
            ),
            GitHubNotification(
                id: "third",
                threadId: "third",
                title: "Process backup verification jobs",
                repository: "planetscale/api-bb",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now.addingTimeInterval(-120),
                isUnread: true,
                url: URL(string: "https://github.com/planetscale/api-bb/pull/3")!,
                subjectURL: nil,
                subjectState: .open
            ),
        ]
        let session = StubNetworkSession(results: [
            .success((
                Data(),
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/first",
                    statusCode: 204
                )
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let state = AppState(
            notifications: notifications,
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            actionDispatchDelayNanoseconds: 0,
            userDefaults: Self.makeIsolatedUserDefaults()
        )

        state.groupByRepo = true
        state.selectNotification(id: "first")
        state.done()

        #expect(state.filteredNotifications.map(\.id) == ["second", "third"])
        #expect(state.selectedNotification?.id == "second")

        await Self.settleTasks()
        #expect((await session.recordedRequests()).contains {
            $0.url?.path == "/notifications/threads/first"
        })
    }

    @Test func doneOnlyRemovesSelectedActivitySnapshotWhenRowsShareAThread() async {
        let now = Date()
        let notifications = [
            GitHubNotification(
                id: "first",
                threadId: "shared-thread",
                title: "Process backup verification jobs",
                repository: "planetscale/api-bb",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now,
                isUnread: true,
                url: URL(string: "https://github.com/planetscale/api-bb/pull/1")!,
                subjectURL: nil,
                subjectState: .open
            ),
            GitHubNotification(
                id: "second",
                threadId: "shared-thread",
                title: "Adds a sales serve toggle to the...",
                repository: "planetscale/api-bb",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now.addingTimeInterval(-3600),
                isUnread: true,
                url: URL(string: "https://github.com/planetscale/api-bb/pull/2")!,
                subjectURL: nil,
                subjectState: .open
            ),
            GitHubNotification(
                id: "third",
                threadId: "shared-thread",
                title: "Add `started_at` to `backup_ver`...",
                repository: "planetscale/api-bb",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now.addingTimeInterval(-7200),
                isUnread: true,
                url: URL(string: "https://github.com/planetscale/api-bb/pull/3")!,
                subjectURL: nil,
                subjectState: .open
            ),
        ]
        let session = StubNetworkSession(results: [
            .success((
                Data(),
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/shared-thread",
                    statusCode: 204
                )
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let state = AppState(
            notifications: notifications,
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            actionDispatchDelayNanoseconds: 0,
            userDefaults: Self.makeIsolatedUserDefaults()
        )

        state.groupByRepo = true
        state.selectNotification(id: "first")
        state.done()

        #expect(state.filteredNotifications.map(\.id) == ["second", "third"])
        #expect(state.selectedNotification?.id == "second")

        await Self.waitUntil {
            await session.recordedRequests().contains {
                $0.url?.path == "/notifications/threads/shared-thread"
            }
        }
        #expect((await session.recordedRequests()).contains {
            $0.url?.path == "/notifications/threads/shared-thread"
        })
    }

    @Test func unsubscribeOnlyRemovesSelectedNotificationWhenTwoRowsShareARepository() async {
        let notifications = [
            GitHubNotification(
                id: "top",
                threadId: "top",
                title: "Add TM to Database Traffic Control",
                repository: "planetscale/www",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: Date(),
                isUnread: true,
                url: URL(string: "https://github.com/planetscale/www/pull/1")!,
                subjectURL: nil,
                subjectState: .open
            ),
            GitHubNotification(
                id: "second",
                threadId: "second",
                title: "Add pricing link to docs llms.txt",
                repository: "planetscale/www",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: Date().addingTimeInterval(-60),
                isUnread: true,
                url: URL(string: "https://github.com/planetscale/www/pull/2")!,
                subjectURL: nil,
                subjectState: .open
            ),
        ]
        let session = StubNetworkSession(results: [
            .success((
                #"{"ignored":true}"#.data(using: .utf8)!,
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/top/subscription",
                    statusCode: 200
                )
            )),
            .success((
                Data(),
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/top",
                    statusCode: 204
                )
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let state = AppState(
            notifications: notifications,
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            actionDispatchDelayNanoseconds: 0,
            userDefaults: Self.makeIsolatedUserDefaults()
        )

        state.groupByRepo = true
        state.selectNotification(id: "top")
        state.unsubscribeFromThread()

        #expect(state.filteredNotifications.map(\.id) == ["second"])
        #expect(state.selectedNotification?.id == "second")

        await Self.waitUntil {
            await session.recordedRequests().count == 2
        }
        #expect((await session.recordedRequests()).count == 2)
    }

    @Test func groupedUnsubscribeDoesNotReorderOtherRepositoryBlocksDuringLocalHide() {
        let now = Date()
        let notifications = [
            GitHubNotification(
                id: "a-top",
                threadId: "a-top",
                title: "Top in repo A",
                repository: "acme/a",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now,
                isUnread: true,
                url: URL(string: "https://github.com/acme/a/pull/1")!,
                subjectURL: nil,
                subjectState: .open
            ),
            GitHubNotification(
                id: "b-top",
                threadId: "b-top",
                title: "Top in repo B",
                repository: "acme/b",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now.addingTimeInterval(-60),
                isUnread: true,
                url: URL(string: "https://github.com/acme/b/pull/2")!,
                subjectURL: nil,
                subjectState: .open
            ),
            GitHubNotification(
                id: "a-second",
                threadId: "a-second",
                title: "Second in repo A",
                repository: "acme/a",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now.addingTimeInterval(-120),
                isUnread: true,
                url: URL(string: "https://github.com/acme/a/pull/3")!,
                subjectURL: nil,
                subjectState: .open
            ),
            GitHubNotification(
                id: "c-top",
                threadId: "c-top",
                title: "Top in repo C",
                repository: "acme/c",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now.addingTimeInterval(-180),
                isUnread: true,
                url: URL(string: "https://github.com/acme/c/pull/4")!,
                subjectURL: nil,
                subjectState: .open
            ),
        ]
        let session = StubNetworkSession(results: [])
        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let state = AppState(
            notifications: notifications,
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            actionDispatchDelayNanoseconds: 2_500_000_000,
            userDefaults: Self.makeIsolatedUserDefaults()
        )

        state.groupByRepo = true
        state.selectNotification(id: "a-top")
        state.unsubscribeFromThread()

        #expect(state.filteredNotifications.map(\.id) == ["a-second", "b-top", "c-top"])
    }

    @Test func groupedUnsubscribeDoesNotReorderOtherRepositoryBlocksAfterSuccess() async {
        let now = Date()
        let notifications = [
            GitHubNotification(
                id: "a-top",
                threadId: "a-top",
                title: "Top in repo A",
                repository: "acme/a",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now,
                isUnread: true,
                url: URL(string: "https://github.com/acme/a/pull/1")!,
                subjectURL: nil,
                subjectState: .open
            ),
            GitHubNotification(
                id: "b-top",
                threadId: "b-top",
                title: "Top in repo B",
                repository: "acme/b",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now.addingTimeInterval(-60),
                isUnread: true,
                url: URL(string: "https://github.com/acme/b/pull/2")!,
                subjectURL: nil,
                subjectState: .open
            ),
            GitHubNotification(
                id: "a-second",
                threadId: "a-second",
                title: "Second in repo A",
                repository: "acme/a",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now.addingTimeInterval(-120),
                isUnread: true,
                url: URL(string: "https://github.com/acme/a/pull/3")!,
                subjectURL: nil,
                subjectState: .open
            ),
            GitHubNotification(
                id: "c-top",
                threadId: "c-top",
                title: "Top in repo C",
                repository: "acme/c",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now.addingTimeInterval(-180),
                isUnread: true,
                url: URL(string: "https://github.com/acme/c/pull/4")!,
                subjectURL: nil,
                subjectState: .open
            ),
        ]
        let session = StubNetworkSession(results: [
            .success((
                #"{"ignored":true}"#.data(using: .utf8)!,
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/a-top/subscription",
                    statusCode: 200
                )
            )),
            .success((
                Data(),
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/a-top",
                    statusCode: 204
                )
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let state = AppState(
            notifications: notifications,
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            actionDispatchDelayNanoseconds: 0,
            userDefaults: Self.makeIsolatedUserDefaults()
        )

        state.groupByRepo = true
        state.selectNotification(id: "a-top")
        state.unsubscribeFromThread()

        await Self.settleTasks()

        #expect(state.filteredNotifications.map(\.id) == ["a-second", "b-top", "c-top"])
    }

    @Test func unsubscribeOnlyRemovesSelectedActivitySnapshotWhenRowsShareAThread() async {
        let now = Date()
        let notifications = [
            GitHubNotification(
                id: "first",
                threadId: "shared-thread",
                title: "Add TM to Database Traffic Control",
                repository: "planetscale/www",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now,
                isUnread: true,
                url: URL(string: "https://github.com/planetscale/www/pull/1")!,
                subjectURL: nil,
                subjectState: .open
            ),
            GitHubNotification(
                id: "second",
                threadId: "shared-thread",
                title: "Add pricing link to docs llms.txt",
                repository: "planetscale/www",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now.addingTimeInterval(-60),
                isUnread: true,
                url: URL(string: "https://github.com/planetscale/www/pull/2")!,
                subjectURL: nil,
                subjectState: .open
            ),
        ]
        let session = StubNetworkSession(results: [
            .success((
                #"{"ignored":true}"#.data(using: .utf8)!,
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/shared-thread/subscription",
                    statusCode: 200
                )
            )),
            .success((
                Data(),
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/shared-thread",
                    statusCode: 204
                )
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let state = AppState(
            notifications: notifications,
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            actionDispatchDelayNanoseconds: 0,
            userDefaults: Self.makeIsolatedUserDefaults()
        )

        state.groupByRepo = true
        state.selectNotification(id: "first")
        state.unsubscribeFromThread()

        #expect(state.filteredNotifications.map(\.id) == ["second"])
        #expect(state.selectedNotification?.id == "second")

        await Self.waitUntil {
            await session.recordedRequests().count == 2
        }
        #expect((await session.recordedRequests()).count == 2)
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
        state.inboxMode = .unread
        state.selectedIndex = 0
        state.done()
        #expect(state.notifications.count == 2)
        state.undo()
        try? await Task.sleep(nanoseconds: 75_000_000)
        #expect(state.notifications.count == 3)
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

    @Test func actionDispatchWindowSlidesAcrossMultipleQueuedActions() async {
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
                    Data(),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications/threads/1",
                        statusCode: 204
                    )
                )),
            ],
            actionDispatchDelayNanoseconds: 80_000_000,
            sleepHandler: Self.realSleep
        )

        state.inboxMode = .unread
        state.groupByRepo = false
        state.selectedIndex = 0
        state.done()

        try? await Task.sleep(nanoseconds: 50_000_000)
        state.selectedIndex = 0
        state.done()

        try? await Task.sleep(nanoseconds: 40_000_000)
        #expect((await session.recordedRequests()).isEmpty)

        await Self.waitUntil(timeoutNanoseconds: 200_000_000) {
            await session.recordedRequests().count == 2
        }

        let requests = await session.recordedRequests()
        #expect(requests.count == 2)
    }

    @Test func refreshFlushesQueuedActionsImmediatelyBeforeReload() async {
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
                    Self.notificationsPayload(ids: []),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1",
                        statusCode: 200
                    )
                )),
            ],
            count: 1,
            actionDispatchDelayNanoseconds: 5_000_000_000,
            sleepHandler: Self.realSleep
        )

        state.inboxMode = .unread
        state.groupByRepo = false
        state.selectedIndex = 0
        state.done()

        state.refresh(force: true)

        await Self.waitUntil(timeoutNanoseconds: 250_000_000) {
            await session.recordedRequests().count == 2
        }

        let requests = await session.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests.first?.httpMethod == "DELETE")
        #expect(requests.last?.httpMethod == "GET")
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

        await Self.waitUntil {
            await session.recordedRequests().count == 1
        }

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

        state.inboxMode = .unread
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

        state.inboxMode = .unread
        state.groupByRepo = false
        state.selectedIndex = 0
        state.done()
        await Self.settleTasks()

        #expect(state.filteredNotifications.isEmpty)

        await state.loadNotifications(force: true)

        #expect(state.filteredNotifications.isEmpty)
        #expect((await session.recordedRequests()).count == 2)
    }

    @Test func inboxRetainsRecentlyReadThreadAfterItLeavesUnreadFeed() async {
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
                    Self.notificationsPayload(ids: []),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1",
                        statusCode: 200
                    )
                )),
                .success((
                    Self.notificationsPayload(ids: []),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1&all=true",
                        statusCode: 200
                    )
                )),
            ],
            count: 1
        )

        state.groupByRepo = false
        state.inboxMode = .inbox
        state.selectedIndex = 0
        state.markRead()

        await Self.waitUntil {
            await session.recordedRequests().count == 1
        }
        await state.loadNotifications(force: true)

        #expect(state.filteredNotifications.map(\.id) == ["0"])
        #expect(state.filteredNotifications.first?.isUnread == false)
        let requests = await session.recordedRequests()
        #expect(requests.count == 3)
        #expect(requests.last?.url?.query?.contains("all=true") == true)
    }

    @Test func inboxReadHistoryDoesNotReviveCommittedDoneThread() async {
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
                    Self.notificationsPayload(ids: []),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1",
                        statusCode: 200
                    )
                )),
                .success((
                    Self.singleNotificationPayload(id: "0", isUnread: false),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1&all=true",
                        statusCode: 200
                    )
                )),
            ],
            count: 1
        )

        state.groupByRepo = false
        state.inboxMode = .inbox
        state.selectedIndex = 0
        state.done()

        await Self.settleTasks()
        await state.loadNotifications(force: true)

        #expect(state.filteredNotifications.isEmpty)
        #expect((await session.recordedRequests()).count == 3)
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

        let staleSnapshot = GitHubNotification(
            id: "0",
            threadId: "0",
            title: "Notification 0",
            repository: "acme/alpha",
            reason: .subscribed,
            type: .pullRequest,
            updatedAt: Date(timeIntervalSince1970: 0),
            isUnread: true,
            url: URL(string: "https://github.com/acme/test/pull/0")!,
            subjectURL: nil,
            subjectState: .open
        )
        let relaunchedState = AppState(
            notifications: [staleSnapshot],
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

        state.inboxMode = .unread
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
        #expect((await session.recordedRequests()).count == 4)
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

        state.inboxMode = .unread
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

    @Test func refreshKeepsCommittedUnsubscribeHiddenAfterSuccess() async {
        let (state, session) = Self.makeAuthedState(
            results: [
                .success((
                    #"{"ignored":true}"#.data(using: .utf8)!,
                    Self.httpResponse(
                        url: "https://api.github.com/notifications/threads/0/subscription",
                        statusCode: 200
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

        state.inboxMode = .unread
        state.groupByRepo = false
        state.selectedIndex = 0
        state.unsubscribeFromThread()
        await Self.settleTasks()

        #expect(state.filteredNotifications.isEmpty)

        await state.loadNotifications(force: true)
        #expect(state.filteredNotifications.isEmpty)

        state.undo()
        #expect(state.notifications.contains(where: { $0.id == "0" }) == false)

        await Self.waitUntil {
            await session.recordedRequests().count == 3
        }

        let requests = await session.recordedRequests()
        #expect(requests.count == 3)
        #expect(requests[0].httpMethod == "PUT")
        if let body = requests[0].httpBody,
           let bodyObject = try? JSONSerialization.jsonObject(with: body) as? [String: Bool] {
            #expect(bodyObject["ignored"] == true)
            #expect(bodyObject["subscribed"] == nil)
        } else {
            Issue.record("Expected unsubscribe request body")
        }
        #expect(requests.dropFirst().contains { $0.httpMethod == "DELETE" })
        #expect(requests.dropFirst().contains { $0.httpMethod == "GET" })
    }

    @Test func unsubscribeSuccessIsNotUndoableAfterDispatch() async {
        let (state, session) = Self.makeAuthedState(results: [
            .success((
                #"{"ignored":true}"#.data(using: .utf8)!,
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/0/subscription",
                    statusCode: 200
                )
            )),
            .success((
                Data(),
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/0",
                    statusCode: 204
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
        #expect(state.notifications.contains(where: { $0.id == "0" }) == false)

        await Self.waitUntil {
            await session.recordedRequests().count == 2
        }

        let requests = await session.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests.first?.httpMethod == "PUT")
        if let body = requests.first?.httpBody,
           let bodyObject = try? JSONSerialization.jsonObject(with: body) as? [String: Bool] {
            #expect(bodyObject["ignored"] == true)
            #expect(bodyObject["subscribed"] == nil)
        } else {
            Issue.record("Expected unsubscribe request body")
        }
        #expect(requests.last?.httpMethod == "DELETE")
        #expect(state.notifications.contains(where: { $0.id == "0" }) == false)
    }
}
