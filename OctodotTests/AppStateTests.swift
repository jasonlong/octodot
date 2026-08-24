import Foundation
import Testing
@testable import Octodot

@MainActor
struct AppStateTests {
    static let recentDateString: String = {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date().addingTimeInterval(-2 * 24 * 60 * 60))
    }()

    static let recentUpdatedDateString: String = {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date().addingTimeInterval(-1 * 24 * 60 * 60))
    }()

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

    static func makeSharedThreadNotifications() -> [GitHubNotification] {
        let now = Date()
        return [
            GitHubNotification(
                id: "shared-new",
                threadId: "shared-thread",
                title: "New shared activity",
                repository: "acme/alpha",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now,
                isUnread: true,
                url: URL(string: "https://github.com/acme/alpha/pull/1")!,
                subjectURL: nil,
                subjectState: .open
            ),
            GitHubNotification(
                id: "shared-old",
                threadId: "shared-thread",
                title: "Older shared activity",
                repository: "acme/alpha",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now.addingTimeInterval(-60),
                isUnread: true,
                url: URL(string: "https://github.com/acme/alpha/pull/1")!,
                subjectURL: nil,
                subjectState: .open
            ),
        ]
    }

    static func makeSecurityAlert(id: String = "security-alert") -> GitHubNotification {
        GitHubNotification(
            id: id,
            threadId: id,
            title: "Upgrade a vulnerable dependency",
            repository: "acme/alpha",
            reason: .securityAlert,
            type: .securityAlert,
            updatedAt: Date(),
            isUnread: true,
            url: URL(string: "https://github.com/acme/alpha/security/dependabot/1")!,
            subjectURL: nil,
            subjectState: .open,
            source: .dependabotAlert
        )
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
        notifications: [GitHubNotification],
        results: [Result<(Data, HTTPURLResponse), Error>] = []
    ) -> (AppState, StubNetworkSession) {
        let defaults = makeIsolatedUserDefaults()
        let session = StubNetworkSession(results: results)
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let state = AppState(
            notifications: notifications,
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            actionDispatchDelayNanoseconds: 0,
            backgroundRefreshEnabled: false,
            sleepHandler: { _ in },
            userDefaults: defaults
        )
        return (state, session)
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
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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
        updatedAt: String = recentDateString,
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

    static func notificationsPayload(ids: [String], updatedAt: String = recentDateString) -> Data {
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

    static func dependabotAlertsPayload(updatedAt: String = recentDateString) -> Data {
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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
        #expect(state.panelUnreadCount == 2)

        state.inboxMode = AppState.InboxMode.unread

        #expect(state.filteredNotifications.count == 1)
        #expect(state.filteredNotifications.allSatisfy { $0.source == GitHubNotification.Source.thread })
        #expect(state.panelUnreadCount == 1)
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
                Self.dependabotAlertsPayload(),
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
                Self.dependabotAlertsPayload(),
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
                Self.dependabotAlertsPayload(updatedAt: Self.recentUpdatedDateString),
                Self.httpResponse(
                    url: "https://api.github.com/repos/acme/alpha/dependabot/alerts",
                    statusCode: 200
                )
            )),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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
        #expect(state.actionToasts.last?.message == "Marked acme/alpha done")

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

    @Test func unsubscribeCommandMarksSecurityAlertDone() async {
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
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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

        state.unsubscribeFromThread()

        #expect(state.filteredNotifications.contains { $0.id == alertID } == false)
        #expect(state.actionToasts.last?.message == "Marked acme/alpha done")
        #expect(state.errorMessage == nil)
        #expect((await session.recordedRequests()).count == 3)
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
                Self.dependabotAlertsPayload(),
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
                Self.dependabotAlertsPayload(),
                Self.httpResponse(
                    url: "https://api.github.com/repos/acme/alpha/dependabot/alerts",
                    statusCode: 200
                )
            )),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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

    @Test func panelPresentationInInboxUsesCachedUnreadAndRefreshesRecentInbox() async {
        let session = StubNetworkSession(results: [
            .success((
                Self.singleNotificationPayload(id: "0", isUnread: true),
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
                Self.singleNotificationPayload(id: "1", isUnread: false),
                Self.httpResponse(
                    url: "https://api.github.com/notifications?page=1&all=true",
                    statusCode: 200,
                    headers: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT",
                        "X-Poll-Interval": "60",
                    ]
                )
            )),
            .success((
                Data("[]".utf8),
                Self.httpResponse(
                    url: "https://api.github.com/repos/acme/alpha/dependabot/alerts",
                    statusCode: 200
                )
            )),
            .success((
                Self.singleNotificationPayload(id: "2", isUnread: false),
                Self.httpResponse(
                    url: "https://api.github.com/notifications?page=1&all=true",
                    statusCode: 200,
                    headers: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:01:00 GMT",
                        "X-Poll-Interval": "60",
                    ]
                )
            )),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let state = AppState(
            notifications: [],
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            userDefaults: Self.makeIsolatedUserDefaults()
        )
        state.groupByRepo = false
        state.inboxMode = .inbox
        state.isPanelVisible = true

        await state.loadNotifications(force: true)
        await Self.waitUntil {
            await session.recordedRequests().count == 3
        }

        state.refreshForPanelPresentation()
        await Self.waitUntil {
            let requests = await session.recordedRequests()
            let finishedLoading = await MainActor.run { !state.isLoading }
            return requests.count >= 4 && finishedLoading
        }

        let requests = await session.recordedRequests()
        let notificationRequests = requests.filter { $0.url?.path == "/notifications" }
        let unreadRequests = notificationRequests.filter { $0.url?.query?.contains("all=false") == true }
        let recentInboxRequests = notificationRequests.filter { $0.url?.query?.contains("all=true") == true }
        let securityRequests = requests.filter { $0.url?.path.contains("/dependabot/alerts") == true }

        #expect(unreadRequests.count == 1)
        #expect(recentInboxRequests.count == 2)
        #expect(securityRequests.count == 1)
    }

    @Test func panelPresentationInUnreadModeSkipsRecentInbox() async {
        let session = StubNetworkSession(results: [
            .success((
                Self.singleNotificationPayload(id: "0", isUnread: true),
                Self.httpResponse(
                    url: "https://api.github.com/notifications?page=1",
                    statusCode: 200,
                    headers: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT",
                        "X-Poll-Interval": "60",
                    ]
                )
            )),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let state = AppState(
            notifications: [],
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            userDefaults: Self.makeIsolatedUserDefaults()
        )
        state.inboxMode = .unread

        await state.loadNotifications(force: true)
        state.refreshForPanelPresentation()
        await Self.settleTasks()

        let requests = await session.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests.allSatisfy { $0.url?.query?.contains("all=false") == true })
    }

    @Test func explicitForceRefreshBypassesUnreadAndRecentInboxCaches() async {
        let session = StubNetworkSession(results: [
            .success((
                Self.singleNotificationPayload(id: "0", isUnread: true),
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
                Self.singleNotificationPayload(id: "1", isUnread: false),
                Self.httpResponse(
                    url: "https://api.github.com/notifications?page=1&all=true",
                    statusCode: 200,
                    headers: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT",
                        "X-Poll-Interval": "60",
                    ]
                )
            )),
            .success((
                Self.singleNotificationPayload(id: "0", isUnread: true),
                Self.httpResponse(
                    url: "https://api.github.com/notifications?page=1",
                    statusCode: 200,
                    headers: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:01:00 GMT",
                        "X-Poll-Interval": "60",
                    ]
                )
            )),
            .success((
                Self.singleNotificationPayload(id: "2", isUnread: false),
                Self.httpResponse(
                    url: "https://api.github.com/notifications?page=1&all=true",
                    statusCode: 200,
                    headers: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:01:00 GMT",
                        "X-Poll-Interval": "60",
                    ]
                )
            )),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let state = AppState(
            notifications: [],
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            userDefaults: Self.makeIsolatedUserDefaults()
        )
        state.inboxMode = .inbox

        await state.loadNotifications(force: true)
        state.refresh(force: true)
        await Self.waitUntil {
            await session.recordedRequests().count == 4
        }

        let requests = await session.recordedRequests()
        let notificationRequests = requests.filter { $0.url?.path == "/notifications" }
        #expect(notificationRequests.filter { $0.url?.query?.contains("all=false") == true }.count == 2)
        #expect(notificationRequests.filter { $0.url?.query?.contains("all=true") == true }.count == 2)
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

    @Test func markReadUpdatesEveryVisibleSnapshotOfSharedThread() async {
        let notifications = Self.makeSharedThreadNotifications()
        let (state, session) = Self.makeAuthedState(
            notifications: notifications,
            results: [
                .success((
                    Data(),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications/threads/shared-thread",
                        statusCode: 205
                    )
                )),
            ]
        )
        state.groupByRepo = false
        state.inboxMode = .inbox
        state.selectNotification(id: "shared-old")

        state.markRead()

        #expect(state.notifications.allSatisfy { !$0.isUnread })
        await Self.waitUntil {
            await session.recordedRequests().count == 1
        }
        #expect(state.notifications.allSatisfy { !$0.isUnread })
    }

    @Test func pendingMarkReadDoesNotMaskNewerActivityArrivingAfterActionStarted() {
        let defaults = Self.makeIsolatedUserDefaults()
        let notifications = Self.makeSharedThreadNotifications()
        let newer = notifications[0]
        let older = notifications[1]
        var store = ThreadActionStore(userDefaults: defaults)

        _ = store.start(.markRead, notification: older, originalServerIndex: 0)
        let projected = store.projectedNotifications(from: [newer, older])

        #expect(projected.first(where: { $0.id == newer.id })?.isUnread == true)
        #expect(projected.first(where: { $0.id == older.id })?.isUnread == false)
    }

    @Test func staleFailureCannotClearNewerPendingActionForSameThread() {
        let defaults = Self.makeIsolatedUserDefaults()
        let notifications = Self.makeSharedThreadNotifications()
        var store = ThreadActionStore(userDefaults: defaults)
        let first = store.start(.done, notification: notifications[0], originalServerIndex: 0)
        let second = store.start(.markRead, notification: notifications[1], originalServerIndex: 1)

        _ = store.handleFailure(first)

        #expect(store.pendingAction(for: first.notification.threadId)?.requestID == second.requestID)
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
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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

    @Test func failedVisibleSubjectMetadataResolutionSurfacesWarningMessage() async {
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
            .failure(
                error: GitHubAPIClient.APIError.forbidden,
                delayNanoseconds: 10_000_000
            ),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let state = Self.makeState(0, apiClient: client)

        state.inboxMode = .unread
        await state.loadNotifications(force: true)
        state.notificationBecameVisible(id: "7")

        await Self.waitUntil {
            await MainActor.run {
                state.warningMessage == GitHubAPIClient.subjectMetadataWarningMessage
            }
        }

        #expect(state.warningMessage == GitHubAPIClient.subjectMetadataWarningMessage)
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
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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

    @Test func unreadFeedStillAppliesWhenRecentInboxRefreshFails() async {
        let session = StubNetworkSession(results: [
            .success((
                Self.singleNotificationPayload(id: "fresh"),
                Self.httpResponse(
                    url: "https://api.github.com/notifications?page=1",
                    statusCode: 200
                )
            )),
            .failure(GitHubAPIClient.APIError.forbidden),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let state = Self.makeState(0, apiClient: client)
        state.groupByRepo = false
        state.inboxMode = .inbox

        await state.loadNotifications(force: true)

        #expect(state.notifications.map(\.id) == ["fresh"])
        #expect(state.errorMessage == nil)
        #expect(state.warningMessage?.contains("Unable to refresh recent inbox") == true)
    }

    @Test func unauthorizedNotificationRefreshSignsOutAndClearsLoadingState() async {
        let defaults = Self.makeIsolatedUserDefaults()
        let session = StubNetworkSession(results: [
            .success((
                Data(),
                Self.httpResponse(url: "https://api.github.com/notifications", statusCode: 401)
            )),
        ])
        let client = GitHubAPIClient(token: "ghp_expired", session: session, useGraphQLForSubjectMetadata: false)
        var tokenDeletionCount = 0
        let state = AppState(
            notifications: Self.makeNotifications(2),
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            userDefaults: defaults,
            tokenDeleter: { tokenDeletionCount += 1 }
        )

        await state.loadNotifications(force: true)

        #expect(state.authStatus == .signedOut)
        #expect(state.isLoading == false)
        #expect(state.notifications.isEmpty)
        #expect(tokenDeletionCount == 1)
    }

    @Test func signingOutWhileLoadIsInFlightCannotLeaveLoadingStateStuck() async {
        let session = DelayedStubNetworkSession(results: [
            .success(
                payload: Self.singleNotificationPayload(id: "stale"),
                response: Self.httpResponse(url: "https://api.github.com/notifications", statusCode: 200),
                delayNanoseconds: 100_000_000
            ),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let state = Self.makeState(0, apiClient: client)
        state.inboxMode = .unread

        let loadTask = Task { await state.loadNotifications(force: true) }
        await Self.waitUntil(timeoutNanoseconds: 1_000_000_000) {
            await MainActor.run { state.isLoading }
        }
        #expect(state.isLoading)

        state.signOut()
        await loadTask.value

        #expect(state.authStatus == .signedOut)
        #expect(state.isLoading == false)
        #expect(state.notifications.isEmpty)
    }

    @Test func cancelledBackgroundCountRefreshCannotMutateSignedOutState() async {
        let sleeper = BackgroundRefreshSleeper()
        let session = DelayedStubNetworkSession(results: [
            .success(
                payload: Self.singleNotificationPayload(id: "stale"),
                response: Self.httpResponse(url: "https://api.github.com/notifications", statusCode: 200),
                delayNanoseconds: 100_000_000
            ),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let state = Self.makeState(
            0,
            apiClient: client,
            backgroundRefreshEnabled: true,
            sleepHandler: { nanoseconds in
                await sleeper.sleep(nanoseconds: nanoseconds)
            }
        )

        await Self.settleTasks()
        state.signOut()
        try? await Task.sleep(for: .milliseconds(20))

        #expect(state.authStatus == .signedOut)
        #expect(state.unreadNotificationCount == 0)
        #expect(state.notifications.isEmpty)
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
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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
            )),
            .success((
                Data(),
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/a-top",
                    statusCode: 204
                )
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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

        // Muting a thread hides all activity snapshots sharing that thread ID
        #expect(state.filteredNotifications.isEmpty)

        await Self.waitUntil {
            await session.recordedRequests().count == 2
        }
        #expect((await session.recordedRequests()).count == 2)
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
        #expect(state.notifications.contains(where: { $0.id == "0" }))
        #expect(state.selectedNotification?.id == "1")
        #expect(state.errorMessage == "Failed to mark thread as done")
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

    @Test func inboxRetainsLocallyReadThreadWhenOtherUnreadsRemain() async {
        // Open an unread PR (markRead sent), merge it on github.com which
        // drops it from both the unread feed and the recent-inbox feed, then
        // refresh. The PR should still appear in the inbox as read, not
        // vanish entirely. Requires another unread to be present so the
        // prune step has a non-empty server thread set.
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
                    Self.notificationsPayload(ids: ["1"]),
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
            count: 2
        )

        state.groupByRepo = false
        state.inboxMode = .inbox
        state.selectedIndex = 0
        state.markRead()

        await Self.waitUntil {
            await session.recordedRequests().count == 1
        }

        await state.loadNotifications(force: true)

        let ids = state.filteredNotifications.map(\.id)
        #expect(ids.contains("0"))
        #expect(ids.contains("1"))
        #expect(state.filteredNotifications.first(where: { $0.id == "0" })?.isUnread == false)
        #expect(state.filteredNotifications.first(where: { $0.id == "1" })?.isUnread == true)
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

    static func notificationPayloadForRepo(
        id: String,
        repo: String,
        isUnread: Bool = true,
        updatedAt: String = "2026-04-01T12:00:00Z"
    ) -> String {
        """
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
              "full_name": "\(repo)",
              "html_url": "https://github.com/\(repo)"
            }
          }
        """
    }

    static func multiRepoPayload(_ items: [(id: String, repo: String, isUnread: Bool, updatedAt: String)]) -> Data {
        let entries = items.map { notificationPayloadForRepo(id: $0.id, repo: $0.repo, isUnread: $0.isUnread, updatedAt: $0.updatedAt) }
        return "[\n\(entries.joined(separator: ",\n"))\n]".data(using: .utf8)!
    }

    @Test func unsubscribeSuccessPersistsAfterDispatch() async {
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
        #expect(requests.dropFirst().allSatisfy { $0.httpMethod == "DELETE" })
        #expect(state.errorMessage == nil)
        #expect(state.notifications.contains(where: { $0.id == "0" }) == false)
    }

    @Test func unsubscribeSuccessPersistsWhenMarkDoneFails() async throws {
        let defaults = Self.makeIsolatedUserDefaults()
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
                        statusCode: 500
                    )
                )),
            ],
            count: 1,
            userDefaults: defaults
        )
        let originalNotification = try #require(state.notifications.first)

        state.groupByRepo = false
        state.selectedIndex = 0
        state.unsubscribeFromThread()

        await Self.waitUntil {
            await MainActor.run {
                state.errorMessage == "Unsubscribed, but failed to mark thread as done"
            }
        }

        let requests = await session.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "PUT")
        #expect(requests[1].httpMethod == "DELETE")
        #expect(state.filteredNotifications.isEmpty)
        #expect(state.unreadNotificationCount == 0)
        #expect(state.errorMessage == "Unsubscribed, but failed to mark thread as done")
        #expect(state.errorMessage != "Failed to unsubscribe from thread")

        let relaunchedState = AppState(
            notifications: [originalNotification],
            authStatus: .signedIn(username: "octodot"),
            userDefaults: defaults
        )
        relaunchedState.groupByRepo = false

        #expect(relaunchedState.filteredNotifications.isEmpty)
        #expect(relaunchedState.unreadNotificationCount == 0)
    }

    @Test func unsubscribeFailureKeepsSelectionInSameRepoWhenGrouped() async {
        let now = Date()
        let notifications = [
            GitHubNotification(
                id: "go-1",
                threadId: "go-1",
                title: "Go notification 1",
                repository: "planetscale/planetscale-go",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now.addingTimeInterval(-120),
                isUnread: true,
                url: URL(string: "https://github.com/planetscale/planetscale-go/pull/1")!,
                subjectURL: nil,
                subjectState: .open
            ),
            GitHubNotification(
                id: "go-2",
                threadId: "go-2",
                title: "Go notification 2",
                repository: "planetscale/planetscale-go",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now.addingTimeInterval(-180),
                isUnread: true,
                url: URL(string: "https://github.com/planetscale/planetscale-go/pull/2")!,
                subjectURL: nil,
                subjectState: .open
            ),
            GitHubNotification(
                id: "bb-1",
                threadId: "bb-1",
                title: "Top api-bb notification",
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
                id: "bb-2",
                threadId: "bb-2",
                title: "Second api-bb notification",
                repository: "planetscale/api-bb",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now.addingTimeInterval(-60),
                isUnread: true,
                url: URL(string: "https://github.com/planetscale/api-bb/pull/2")!,
                subjectURL: nil,
                subjectState: .open
            ),
        ]
        let session = StubNetworkSession(results: [
            .failure(GitHubAPIClient.APIError.forbidden),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let state = AppState(
            notifications: notifications,
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            actionDispatchDelayNanoseconds: 0,
            userDefaults: Self.makeIsolatedUserDefaults()
        )

        state.inboxMode = .inbox
        state.groupByRepo = true
        state.selectNotification(id: "bb-1")
        state.unsubscribeFromThread()

        #expect(state.selectedNotification?.id == "bb-2")
        #expect(state.selectedNotification?.repository == "planetscale/api-bb")

        await Self.settleTasks()

        #expect(state.selectedNotification?.id == "bb-2")
        #expect(state.selectedNotification?.repository == "planetscale/api-bb")
        #expect(state.filteredNotifications.contains(where: { $0.id == "bb-1" }))
        #expect(state.errorMessage == "Failed to unsubscribe from thread")
    }

    @Test func unsubscribeFailureDoesNotOverwriteSelectionAfterMovingOn() async {
        let now = Date()
        let notifications = [
            GitHubNotification(
                id: "go-1",
                threadId: "go-1",
                title: "Go notification",
                repository: "planetscale/planetscale-go",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now.addingTimeInterval(-120),
                isUnread: true,
                url: URL(string: "https://github.com/planetscale/planetscale-go/pull/1")!,
                subjectURL: nil,
                subjectState: .open
            ),
            GitHubNotification(
                id: "bb-1",
                threadId: "bb-1",
                title: "First api-bb notification",
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
                id: "bb-2",
                threadId: "bb-2",
                title: "Second api-bb notification",
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
                id: "bb-3",
                threadId: "bb-3",
                title: "Third api-bb notification",
                repository: "planetscale/api-bb",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now.addingTimeInterval(-90),
                isUnread: true,
                url: URL(string: "https://github.com/planetscale/api-bb/pull/3")!,
                subjectURL: nil,
                subjectState: .open
            ),
        ]
        let session = DelayedStubNetworkSession(results: [
            .failure(
                error: GitHubAPIClient.APIError.forbidden,
                delayNanoseconds: 50_000_000
            ),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let state = AppState(
            notifications: notifications,
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            actionDispatchDelayNanoseconds: 0,
            sleepHandler: { _ in },
            userDefaults: Self.makeIsolatedUserDefaults()
        )

        state.inboxMode = .inbox
        state.groupByRepo = true
        state.selectNotification(id: "bb-1")
        state.unsubscribeFromThread()
        state.selectNotification(id: "bb-3")

        await Self.waitUntil(timeoutNanoseconds: 250_000_000) {
            await MainActor.run {
                state.errorMessage == "Failed to unsubscribe from thread"
            }
        }

        #expect(state.selectedNotification?.id == "bb-3")
        #expect(state.selectedNotification?.repository == "planetscale/api-bb")
        #expect(state.filteredNotifications.contains(where: { $0.id == "bb-1" }))
    }

    // MARK: - Regression: repo order stability

    @Test func repositoryOrderStaysStableAcrossRefreshes() async {
        // Start with acme/beta having the newest notification (id "1", newer updatedAt)
        // and acme/alpha having an older notification (id "2", older updatedAt).
        let initialPayload = Self.multiRepoPayload([
            (id: "1", repo: "acme/beta", isUnread: true, updatedAt: "2026-04-01T14:00:00Z"),
            (id: "2", repo: "acme/alpha", isUnread: true, updatedAt: "2026-04-01T12:00:00Z"),
        ])
        // On refresh, acme/alpha now has a NEWER updatedAt than acme/beta.
        let refreshedPayload = Self.multiRepoPayload([
            (id: "1", repo: "acme/beta", isUnread: true, updatedAt: "2026-04-01T14:00:00Z"),
            (id: "2", repo: "acme/alpha", isUnread: true, updatedAt: "2026-04-01T16:00:00Z"),
        ])

        let session = StubNetworkSession(results: [
            .success((
                initialPayload,
                Self.httpResponse(
                    url: "https://api.github.com/notifications?page=1",
                    statusCode: 200,
                    headers: ["Last-Modified": "Wed, 01 Apr 2026 14:00:00 GMT"]
                )
            )),
            .success((
                refreshedPayload,
                Self.httpResponse(
                    url: "https://api.github.com/notifications?page=1",
                    statusCode: 200,
                    headers: ["Last-Modified": "Wed, 01 Apr 2026 16:00:00 GMT"]
                )
            )),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let state = AppState(
            notifications: [],
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            userDefaults: Self.makeIsolatedUserDefaults()
        )
        state.groupByRepo = true
        state.inboxMode = .unread

        await state.loadNotifications(force: true)
        let initialRepoOrder = state.filteredNotifications.map(\.repository)
        #expect(initialRepoOrder == ["acme/beta", "acme/alpha"])

        await state.loadNotifications(force: true)
        let refreshedRepoOrder = state.filteredNotifications.map(\.repository)
        #expect(refreshedRepoOrder == initialRepoOrder)
    }

    // MARK: - Regression: unread count excludes pending done

    @Test func backgroundUnreadCountExcludesPendingDoneActions() async {
        // Use multiRepoPayload to create 2 distinct unread notifications
        let twoNotifications = Self.multiRepoPayload([
            (id: "10", repo: "acme/alpha", isUnread: true, updatedAt: "2026-04-01T14:00:00Z"),
            (id: "20", repo: "acme/beta", isUnread: true, updatedAt: "2026-04-01T12:00:00Z"),
        ])

        let session = StubNetworkSession(results: [
            // Initial load: 2 unread notifications
            .success((
                twoNotifications,
                Self.httpResponse(
                    url: "https://api.github.com/notifications?page=1",
                    statusCode: 200,
                    headers: ["Last-Modified": "Wed, 01 Apr 2026 14:00:00 GMT"]
                )
            )),
            // Response for the done() DELETE call
            .success((
                Data(),
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/10",
                    statusCode: 204
                )
            )),
            // Refresh: server STILL returns the done notification (API lag)
            .success((
                twoNotifications,
                Self.httpResponse(
                    url: "https://api.github.com/notifications?page=1",
                    statusCode: 200,
                    headers: ["Last-Modified": "Wed, 01 Apr 2026 14:01:00 GMT"]
                )
            )),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let state = AppState(
            notifications: [],
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            userDefaults: Self.makeIsolatedUserDefaults()
        )

        state.groupByRepo = false
        state.inboxMode = .unread

        // Load initial notifications from server
        await state.loadNotifications(force: true)
        #expect(state.unreadNotificationCount == 2)

        // Mark notification 10 as done
        state.selectNotification(id: "10")
        state.done()

        await Self.waitUntil {
            await session.recordedRequests().count == 2
        }

        // After done + server ack, count should be down by 1
        #expect(state.unreadNotificationCount == 1)

        // Refresh where the server STILL returns the done notification
        await state.loadNotifications(force: true)

        // The done thread should still be excluded from the unread count
        #expect(state.unreadNotificationCount == 1)
        #expect(state.filteredNotifications.contains(where: { $0.id == "10" }) == false)
        #expect(state.filteredNotifications.contains(where: { $0.id == "20" }) == true)
    }

    // MARK: - Regression: done thread excluded from inbox recent reads

    @Test func inboxMergedNotificationsExcludesDoneThreadsFromRecentReads() async {
        let (state, session) = Self.makeAuthedState(
            results: [
                // Response for the done() DELETE call
                .success((
                    Data(),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications/threads/0",
                        statusCode: 204
                    )
                )),
                // Refresh: unread feed returns empty (thread is gone from unread)
                .success((
                    Self.notificationsPayload(ids: []),
                    Self.httpResponse(
                        url: "https://api.github.com/notifications?page=1",
                        statusCode: 200,
                        headers: ["Last-Modified": "Wed, 01 Apr 2026 12:01:00 GMT"]
                    )
                )),
                // Refresh: all=true feed still returns the thread as read
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

        // Mark the only notification as done
        state.selectedIndex = 0
        state.done()

        await Self.waitUntil {
            await session.recordedRequests().count == 1
        }

        #expect(state.filteredNotifications.isEmpty)

        // Refresh: unread feed empty, all=true feed returns thread 0 as read
        await state.loadNotifications(force: true)

        // The done thread should NOT reappear as a recent read
        #expect(state.filteredNotifications.isEmpty)
        #expect((await session.recordedRequests()).count == 3)
    }

    // MARK: - Muted threads

    @Test func recentInboxSinceDateNeverMovesIntoTheFuture() {
        let now = Date.now
        var futureUnread = Self.makeNotification(id: 42)
        futureUnread = GitHubNotification(
            id: futureUnread.id,
            threadId: futureUnread.threadId,
            title: futureUnread.title,
            repository: futureUnread.repository,
            reason: futureUnread.reason,
            type: futureUnread.type,
            updatedAt: now.addingTimeInterval(24 * 60 * 60),
            isUnread: true,
            url: futureUnread.url,
            subjectURL: futureUnread.subjectURL,
            subjectState: futureUnread.subjectState
        )
        let store = InboxStore(userDefaults: Self.makeIsolatedUserDefaults(), initialNotifications: [])

        #expect(store.recentInboxSinceDate(relativeTo: [futureUnread], now: now) == now)
    }

    @Test func newestUnreadSnapshotControlsRecentReadPruningForSharedThread() {
        let now = Date.now
        let makeShared: (String, TimeInterval, Bool) -> GitHubNotification = { id, offset, isUnread in
            GitHubNotification(
                id: id,
                threadId: "shared-pruning-thread",
                title: id,
                repository: "acme/alpha",
                reason: .reviewRequested,
                type: .pullRequest,
                updatedAt: now.addingTimeInterval(offset),
                isUnread: isUnread,
                url: URL(string: "https://github.com/acme/alpha/pull/1")!,
                subjectURL: nil,
                subjectState: .open
            )
        }
        let newerUnread = makeShared("newer", 0, true)
        let olderUnread = makeShared("older", -120, true)
        let recentRead = makeShared("recent-read", -60, false)
        let store = InboxStore(userDefaults: Self.makeIsolatedUserDefaults(), initialNotifications: [])

        store.recordRecentReadNotification(
            recentRead,
            unreadNotifications: [newerUnread, olderUnread],
            isNotificationVisible: { _ in true }
        )
        let historyAfterUnreadDisappears = store.mergedInboxNotifications(
            unreadNotifications: [],
            recentInboxNotifications: [],
            projectNotifications: { $0 },
            isNotificationVisible: { _ in true }
        )

        #expect(historyAfterUnreadDisappears.isEmpty)
    }

    @Test func mutedThreadsPersistAcrossSessions() async {
        let defaults = Self.makeIsolatedUserDefaults()
        let notifications = [
            Self.makeNotification(id: 1, isUnread: true),
            Self.makeNotification(id: 2, isUnread: true),
        ]

        let session = StubNetworkSession(results: [
            .success((
                #"{"ignored":true}"#.data(using: .utf8)!,
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/1/subscription",
                    statusCode: 200
                )
            )),
            .success((
                Data(),
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/1",
                    statusCode: 204
                )
            )),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)

        let state = AppState(
            notifications: notifications,
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            actionDispatchDelayNanoseconds: 0,
            userDefaults: defaults
        )

        state.inboxMode = .inbox
        state.groupByRepo = false
        state.selectNotification(id: "1")
        state.unsubscribeFromThread()

        #expect(state.filteredNotifications.contains(where: { $0.id == "1" }) == false)
        #expect(state.filteredNotifications.contains(where: { $0.id == "2" }) == true)

        // Create a new AppState with the same UserDefaults to simulate a new session
        let state2 = AppState(
            notifications: notifications,
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            actionDispatchDelayNanoseconds: 0,
            userDefaults: defaults
        )

        state2.inboxMode = .inbox
        state2.groupByRepo = false

        #expect(state2.filteredNotifications.contains(where: { $0.id == "1" }) == false)
        #expect(state2.filteredNotifications.contains(where: { $0.id == "2" }) == true)
    }

    @Test func mutedThreadsListCapsAtLimit() {
        let defaults = Self.makeIsolatedUserDefaults()
        let inboxStore = InboxStore(userDefaults: defaults, initialNotifications: [])

        for i in 0...200 {
            inboxStore.muteThread("thread-\(i)")
        }

        #expect(inboxStore.isThreadMuted("thread-0") == false)
        #expect(inboxStore.isThreadMuted("thread-200") == true)
    }

    @Test func clearingSessionStateRemovesPersistedMutedThreads() {
        let defaults = Self.makeIsolatedUserDefaults()
        let inboxStore = InboxStore(userDefaults: defaults, initialNotifications: [])
        inboxStore.muteThread("account-specific-thread")

        inboxStore.clearSessionState()

        let relaunchedStore = InboxStore(userDefaults: defaults, initialNotifications: [])
        #expect(relaunchedStore.isThreadMuted("account-specific-thread") == false)
    }

    @Test func mutedThreadDoesNotCountAsUnread() async {
        let defaults = Self.makeIsolatedUserDefaults()
        let session = StubNetworkSession(results: [
            .success((
                Data(),
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
                Data(),
                Self.httpResponse(
                    url: "https://api.github.com/notifications/threads/0",
                    statusCode: 204
                )
            )),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let state = Self.makeState(
            2,
            apiClient: client,
            actionDispatchDelayNanoseconds: 0,
            userDefaults: defaults
        )
        state.inboxMode = .unread
        state.groupByRepo = false
        state.selectNotification(id: "0")

        #expect(state.unreadNotificationCount == 2)

        state.unsubscribeFromThread()

        #expect(state.unreadNotificationCount == 1)
    }

    @Test func reconcileMutedThreadsRemovesStaleMuteOnNewUnread() {
        let defaults = Self.makeIsolatedUserDefaults()
        let inboxStore = InboxStore(userDefaults: defaults, initialNotifications: [])

        inboxStore.muteThread("100")
        #expect(inboxStore.isThreadMuted("100") == true)

        // Server sends new unread notification for that thread, no committed action protects it
        let unreadNotification = Self.makeNotification(id: 100, isUnread: true)
        inboxStore.reconcileMutedThreadsWithUnread(
            [unreadNotification],
            committedThreadIDs: []
        )

        // Mute should be permanently removed
        #expect(inboxStore.isThreadMuted("100") == false)
    }

    @Test func reconcileMutedThreadsKeepsMuteWhenCommittedActionExists() {
        let defaults = Self.makeIsolatedUserDefaults()
        let inboxStore = InboxStore(userDefaults: defaults, initialNotifications: [])

        inboxStore.muteThread("100")

        // Server still has the thread, but committed unsubscribe action protects the mute
        let unreadNotification = Self.makeNotification(id: 100, isUnread: true)
        inboxStore.reconcileMutedThreadsWithUnread(
            [unreadNotification],
            committedThreadIDs: ["100"]
        )

        #expect(inboxStore.isThreadMuted("100") == true)
    }

    @Test func reconcileMutedThreadsPreservesUnrelatedMutes() {
        let defaults = Self.makeIsolatedUserDefaults()
        let inboxStore = InboxStore(userDefaults: defaults, initialNotifications: [])

        inboxStore.muteThread("100")
        inboxStore.muteThread("200")

        // Only thread 100 has a new unread notification with no committed action
        let unreadNotification = Self.makeNotification(id: 100, isUnread: true)
        inboxStore.reconcileMutedThreadsWithUnread(
            [unreadNotification],
            committedThreadIDs: []
        )

        #expect(inboxStore.isThreadMuted("100") == false)
        #expect(inboxStore.isThreadMuted("200") == true)
    }

    @Test func toggleCheckedAddsAndRemovesSelectedId() {
        let (state, _) = Self.makeAuthedState(count: 3)
        state.groupByRepo = false
        state.selectedIndex = 1
        let id = state.filteredNotifications[1].id

        state.toggleChecked()
        #expect(state.checkedThreadIDs == [id])

        state.toggleChecked()
        #expect(state.checkedThreadIDs.isEmpty)
    }

    @Test func toggleCheckedByIdTogglesAnyRow() {
        let (state, _) = Self.makeAuthedState(count: 3)
        state.groupByRepo = false
        let firstId = state.filteredNotifications[0].id
        let lastId = state.filteredNotifications[2].id

        state.toggleChecked(id: firstId)
        state.toggleChecked(id: lastId)
        #expect(state.checkedThreadIDs == [firstId, lastId])

        state.toggleChecked(id: firstId)
        #expect(state.checkedThreadIDs == [lastId])
    }

    @Test func toggleCheckedIgnoresIDsOutsideVisibleProjection() {
        let (state, _) = Self.makeAuthedState(count: 3)

        state.toggleChecked(id: "not-visible")

        #expect(state.checkedThreadIDs.isEmpty)
    }

    @Test func bulkDoneRemovesAllCheckedRowsAndClearsChecks() async {
        let (state, session) = Self.makeAuthedState(
            results: [
                .success((Data(), Self.httpResponse(url: "https://api.github.com/notifications/threads/0", statusCode: 204))),
                .success((Data(), Self.httpResponse(url: "https://api.github.com/notifications/threads/2", statusCode: 204))),
            ],
            count: 3
        )
        state.groupByRepo = false
        let firstId = state.filteredNotifications[0].id
        let lastId = state.filteredNotifications[2].id

        state.toggleChecked(id: firstId)
        state.toggleChecked(id: lastId)
        #expect(state.checkedThreadIDs.count == 2)

        state.done()

        #expect(state.checkedThreadIDs.isEmpty)
        #expect(state.notifications.count == 1)
        #expect(state.notifications.contains { $0.id == firstId } == false)
        #expect(state.notifications.contains { $0.id == lastId } == false)

        await Self.waitUntil {
            let requests = await session.recordedRequests()
            let paths = requests.compactMap { $0.url?.path }
            return paths.contains("/notifications/threads/0") && paths.contains("/notifications/threads/2")
        }
    }

    @Test func bulkDonePreservesASelectedRowThatSurvives() {
        let notifications = (0..<4).map { Self.makeNotification(id: $0) }
        let responses = (0..<2).map { id in
            Result<(Data, HTTPURLResponse), Error>.success((
                Data(),
                Self.httpResponse(url: "https://api.github.com/notifications/threads/\(id)", statusCode: 204)
            ))
        }
        let (state, _) = Self.makeAuthedState(notifications: notifications, results: responses)
        state.groupByRepo = false
        state.selectNotification(id: "3")
        state.toggleChecked(id: "0")
        state.toggleChecked(id: "1")

        state.done()

        #expect(state.selectedNotificationID == "3")
        #expect(state.selectedIndex == 1)
    }

    @Test func bulkDoneAdvancesPastAllRemovedRows() {
        let notifications = (0..<5).map { Self.makeNotification(id: $0) }
        let responses = [1, 2].map { id in
            Result<(Data, HTTPURLResponse), Error>.success((
                Data(),
                Self.httpResponse(url: "https://api.github.com/notifications/threads/\(id)", statusCode: 204)
            ))
        }
        let (state, _) = Self.makeAuthedState(notifications: notifications, results: responses)
        state.groupByRepo = false
        state.selectNotification(id: "1")
        state.toggleChecked(id: "1")
        state.toggleChecked(id: "2")

        state.done()

        #expect(state.selectedNotificationID == "3")
    }

    @Test func bulkDoneFallsBackToNearestPrecedingSurvivorAtEnd() {
        let notifications = (0..<4).map { Self.makeNotification(id: $0) }
        let responses = [1, 3].map { id in
            Result<(Data, HTTPURLResponse), Error>.success((
                Data(),
                Self.httpResponse(url: "https://api.github.com/notifications/threads/\(id)", statusCode: 204)
            ))
        }
        let (state, _) = Self.makeAuthedState(notifications: notifications, results: responses)
        state.groupByRepo = false
        state.selectNotification(id: "3")
        state.toggleChecked(id: "1")
        state.toggleChecked(id: "3")

        state.done()

        #expect(state.selectedNotificationID == "2")
    }

    @Test func bulkDoneClearsSelectionWhenAllRowsAreRemoved() {
        let notifications = (0..<3).map { Self.makeNotification(id: $0) }
        let responses = (0..<3).map { id in
            Result<(Data, HTTPURLResponse), Error>.success((
                Data(),
                Self.httpResponse(url: "https://api.github.com/notifications/threads/\(id)", statusCode: 204)
            ))
        }
        let (state, _) = Self.makeAuthedState(notifications: notifications, results: responses)
        state.groupByRepo = false
        state.selectNotification(id: "1")
        for notification in notifications {
            state.toggleChecked(id: notification.id)
        }

        state.done()

        #expect(state.selectedNotificationID == nil)
        #expect(state.selectedIndex == 0)
    }

    @Test func groupedBulkUnsubscribeAdvancesAcrossRepositoryBoundary() {
        let notifications = [
            Self.makeNotification(id: 0, repo: "acme/alpha"),
            Self.makeNotification(id: 1, repo: "acme/beta"),
            Self.makeNotification(id: 2, repo: "acme/alpha"),
            Self.makeNotification(id: 3, repo: "acme/beta"),
        ]
        let responses = [2, 3].flatMap { id in
            [
                Result<(Data, HTTPURLResponse), Error>.success((
                    Data(),
                    Self.httpResponse(url: "https://api.github.com/notifications/threads/\(id)/subscription", statusCode: 204)
                )),
                Result<(Data, HTTPURLResponse), Error>.success((
                    Data(),
                    Self.httpResponse(url: "https://api.github.com/notifications/threads/\(id)", statusCode: 204)
                )),
            ]
        }
        let (state, _) = Self.makeAuthedState(notifications: notifications, results: responses)
        state.groupByRepo = true
        state.selectNotification(id: "2")
        state.toggleChecked(id: "2")
        state.toggleChecked(id: "3")

        state.unsubscribeFromThread()

        #expect(state.selectedNotificationID == "1")
        #expect(state.selectedNotification?.repository == "acme/beta")
    }

    @Test func legacySingleActivityCommittedActionStillDecodes() throws {
        let defaults = Self.makeIsolatedUserDefaults()
        let notification = Self.makeNotification(id: 0)
        let formatter = ISO8601DateFormatter()
        let payload: [[String: Any]] = [[
            "kind": "done",
            "threadId": notification.threadId,
            "updatedAt": formatter.string(from: notification.updatedAt),
            "activityIdentity": notification.activityIdentity,
        ]]
        defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: ThreadActionStore.committedThreadActionsStorageKey)

        let state = AppState(
            notifications: [notification],
            authStatus: .signedOut,
            userDefaults: defaults
        )
        state.groupByRepo = false

        #expect(state.filteredNotifications.isEmpty)
    }

    @Test func duplicatePersistedCommittedActionsDoNotCrashRelaunch() throws {
        let defaults = Self.makeIsolatedUserDefaults()
        let notification = Self.makeNotification(id: 0)
        let formatter = ISO8601DateFormatter()
        let action: [String: Any] = [
            "kind": "done",
            "threadId": notification.threadId,
            "updatedAt": formatter.string(from: notification.updatedAt),
            "activityIdentities": [notification.activityIdentity],
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: [action, action]),
            forKey: ThreadActionStore.committedThreadActionsStorageKey
        )

        let state = AppState(
            notifications: [notification],
            authStatus: .signedOut,
            userDefaults: defaults
        )

        #expect(state.filteredNotifications.isEmpty)
    }

    @Test func persistedMarkReadRetainsSubsecondReconciliationCutoff() {
        let defaults = Self.makeIsolatedUserDefaults()
        let base = Self.makeNotification(id: 0)
        let notification = GitHubNotification(
            id: base.id,
            threadId: base.threadId,
            title: base.title,
            repository: base.repository,
            reason: base.reason,
            type: base.type,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000.789),
            isUnread: true,
            url: base.url,
            subjectURL: base.subjectURL,
            subjectState: base.subjectState
        )
        var firstStore = ThreadActionStore(userDefaults: defaults)
        var serverNotifications = [notification]
        let pending = firstStore.start(.markRead, notification: notification, originalServerIndex: 0)
        firstStore.handleSuccess(pending, serverNotifications: &serverNotifications)

        let relaunchedStore = ThreadActionStore(userDefaults: defaults)
        let projected = relaunchedStore.projectedNotifications(from: [notification])

        #expect(projected.first?.isUnread == false)
    }

    @Test func duplicatePersistedRecentReadsKeepOneNewestSnapshot() throws {
        let defaults = Self.makeIsolatedUserDefaults()
        let older = Self.makeNotification(id: 1, isUnread: false)
        let newer = Self.makeNotification(id: 0, isUnread: false)
        let formatter = ISO8601DateFormatter()
        func payload(for notification: GitHubNotification) -> [String: Any] {
            [
                "id": notification.id,
                "threadId": "shared-persisted-thread",
                "title": notification.title,
                "repository": notification.repository,
                "reason": notification.reason.rawValue,
                "type": notification.type.rawValue,
                "updatedAt": formatter.string(from: notification.updatedAt),
                "isUnread": false,
                "url": notification.url.absoluteString,
                "subjectState": notification.subjectState.rawValue,
                "graphQLNodeID": "node-\(notification.id)",
                "openerLogin": "octocat-\(notification.id)",
                "openerAvatarURL": "https://avatars.githubusercontent.com/u/\(notification.id)",
                "hasResolvedOpener": true,
                "source": notification.source.rawValue,
            ]
        }
        defaults.set(
            try JSONSerialization.data(withJSONObject: [payload(for: older), payload(for: newer)]),
            forKey: "AppState.recentInboxReads.v1"
        )

        let state = AppState(notifications: [], userDefaults: defaults)
        state.groupByRepo = false

        #expect(state.filteredNotifications.map(\.id) == [newer.id])
        #expect(state.filteredNotifications.first?.graphQLNodeID == "node-\(newer.id)")
        #expect(state.filteredNotifications.first?.openerLogin == "octocat-\(newer.id)")
        #expect(state.filteredNotifications.first?.openerAvatarURL?.absoluteString == "https://avatars.githubusercontent.com/u/\(newer.id)")
        #expect(state.filteredNotifications.first?.hasResolvedOpener == true)
    }

    @Test func malformedPersistedStoreDataIsQuarantined() {
        let defaults = Self.makeIsolatedUserDefaults()
        let malformed = Data("not-json".utf8)
        let keys = [
            ThreadActionStore.committedThreadActionsStorageKey,
            "AppState.recentInboxReads.v1",
            "AppState.dismissedSecurityAlerts.v1",
            "AppState.readSecurityAlerts.v1",
            "AppState.mutedThreads.v1",
        ]
        for key in keys {
            defaults.set(malformed, forKey: key)
        }

        _ = AppState(notifications: [], userDefaults: defaults)

        #expect(keys.allSatisfy { defaults.object(forKey: $0) == nil })
    }

    @Test func bulkDoneGroupsSharedThreadActivitiesAndPersistsEveryIdentity() async {
        let defaults = Self.makeIsolatedUserDefaults()
        let notifications = Self.makeSharedThreadNotifications()
        let session = StubNetworkSession(results: [
            .success((
                Data(),
                Self.httpResponse(url: "https://api.github.com/notifications/threads/shared-thread", statusCode: 204)
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let state = AppState(
            notifications: notifications,
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            actionDispatchDelayNanoseconds: 0,
            userDefaults: defaults
        )
        state.groupByRepo = false
        for notification in notifications {
            state.toggleChecked(id: notification.id)
        }

        state.done()

        #expect(state.filteredNotifications.isEmpty)
        #expect(state.actionToasts.last?.message == "Marked 2 items done")
        await Self.waitUntil { await session.recordedRequests().count == 1 }
        #expect((await session.recordedRequests()).count == 1)

        let relaunched = AppState(
            notifications: notifications,
            authStatus: .signedOut,
            userDefaults: defaults
        )
        relaunched.groupByRepo = false
        #expect(relaunched.filteredNotifications.isEmpty)
    }

    @Test func failedGroupedBulkDoneRestoresEveryActivityWithoutMovingSelection() async {
        let shared = Self.makeSharedThreadNotifications()
        let survivor = Self.makeNotification(id: 99)
        let (state, _) = Self.makeAuthedState(
            notifications: shared + [survivor],
            results: [.failure(URLError(.badServerResponse))]
        )
        state.groupByRepo = false
        state.selectNotification(id: shared[0].id)
        for notification in shared {
            state.toggleChecked(id: notification.id)
        }

        state.done()
        #expect(state.selectedNotificationID == survivor.id)

        await Self.waitUntil {
            await MainActor.run { state.filteredNotifications.count == 3 }
        }
        #expect(Set(state.filteredNotifications.map(\.id)) == Set((shared + [survivor]).map(\.id)))
        #expect(state.selectedNotificationID == survivor.id)
    }

    @Test func bulkUnsubscribeGroupsSharedThreadActivitiesAndPersistsThem() async {
        let defaults = Self.makeIsolatedUserDefaults()
        let notifications = Self.makeSharedThreadNotifications()
        let session = StubNetworkSession(results: [
            .success((
                Data(),
                Self.httpResponse(url: "https://api.github.com/notifications/threads/shared-thread/subscription", statusCode: 204)
            )),
            .success((
                Data(),
                Self.httpResponse(url: "https://api.github.com/notifications/threads/shared-thread", statusCode: 204)
            )),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let state = AppState(
            notifications: notifications,
            authStatus: .signedIn(username: "octodot"),
            apiClient: client,
            actionDispatchDelayNanoseconds: 0,
            userDefaults: defaults
        )
        state.groupByRepo = false
        for notification in notifications {
            state.toggleChecked(id: notification.id)
        }

        state.unsubscribeFromThread()

        #expect(state.filteredNotifications.isEmpty)
        #expect(state.actionToasts.last?.message == "Unsubscribed from 2 items")
        await Self.waitUntil { await session.recordedRequests().count == 2 }
        #expect((await session.recordedRequests()).count == 2)

        let relaunched = AppState(
            notifications: notifications,
            authStatus: .signedOut,
            userDefaults: defaults
        )
        relaunched.groupByRepo = false
        #expect(relaunched.filteredNotifications.isEmpty)
    }

    @Test func bulkUnsubscribeMarksSecurityAlertsDoneAndReportsBothOutcomes() async {
        let thread = Self.makeNotification(id: 0)
        let alert = Self.makeSecurityAlert()
        let (state, session) = Self.makeAuthedState(
            notifications: [thread, alert],
            results: [
                .success((Data(), Self.httpResponse(url: "https://api.github.com/notifications/threads/0/subscription", statusCode: 204))),
                .success((Data(), Self.httpResponse(url: "https://api.github.com/notifications/threads/0", statusCode: 204))),
            ]
        )
        state.inboxMode = .inbox
        state.groupByRepo = false
        state.toggleChecked(id: thread.id)
        state.toggleChecked(id: alert.id)

        state.unsubscribeFromThread()

        #expect(state.actionToasts.map(\.message) == [
            "Unsubscribed from acme/alpha#0",
            "Marked acme/alpha done",
        ])
        #expect(state.errorMessage == nil)
        await Self.waitUntil { await session.recordedRequests().count == 2 }
        #expect(state.errorMessage == nil)
    }

    @Test func singleSecurityAlertUnsubscribeUsesDoneFallback() {
        let alert = Self.makeSecurityAlert()
        let (state, _) = Self.makeAuthedState(notifications: [alert])
        state.inboxMode = .inbox
        state.groupByRepo = false
        state.selectNotification(id: alert.id)

        state.unsubscribeFromThread()

        #expect(state.actionToasts.last?.message == "Marked acme/alpha done")
        #expect(state.errorMessage == nil)
    }

    @Test func securityAlertDoneProducesAccurateSingleAndMixedFeedback() {
        let firstAlert = Self.makeSecurityAlert(id: "security-one")
        let secondAlert = Self.makeSecurityAlert(id: "security-two")
        let thread = Self.makeNotification(id: 0)
        let (singleState, _) = Self.makeAuthedState(notifications: [firstAlert])
        singleState.inboxMode = .inbox
        singleState.groupByRepo = false
        singleState.done()
        #expect(singleState.actionToasts.last?.message == "Marked acme/alpha done")

        let (mixedState, _) = Self.makeAuthedState(
            notifications: [thread, secondAlert],
            results: [
                .success((Data(), Self.httpResponse(url: "https://api.github.com/notifications/threads/0", statusCode: 204)))
            ]
        )
        mixedState.inboxMode = .inbox
        mixedState.groupByRepo = false
        mixedState.toggleChecked(id: thread.id)
        mixedState.toggleChecked(id: secondAlert.id)
        mixedState.done()

        #expect(mixedState.actionToasts.last?.message == "Marked 2 items done")
    }

    @Test func bulkUnsubscribeRunsOnAllCheckedRows() async {
        let (state, session) = Self.makeAuthedState(
            results: [
                .success((Data(), Self.httpResponse(url: "https://api.github.com/notifications/threads/0/subscription", statusCode: 204))),
                .success((Data(), Self.httpResponse(url: "https://api.github.com/notifications/threads/0", statusCode: 204))),
                .success((Data(), Self.httpResponse(url: "https://api.github.com/notifications/threads/1/subscription", statusCode: 204))),
                .success((Data(), Self.httpResponse(url: "https://api.github.com/notifications/threads/1", statusCode: 204))),
            ],
            count: 3
        )
        state.groupByRepo = false
        let firstId = state.filteredNotifications[0].id
        let secondId = state.filteredNotifications[1].id

        state.toggleChecked(id: firstId)
        state.toggleChecked(id: secondId)

        state.unsubscribeFromThread()

        #expect(state.checkedThreadIDs.isEmpty)
        #expect(state.notifications.contains { $0.id == firstId } == false)
        #expect(state.notifications.contains { $0.id == secondId } == false)

        await Self.waitUntil {
            let requests = await session.recordedRequests()
            let subscriptions = requests.filter { ($0.url?.path ?? "").hasSuffix("/subscription") }
            return subscriptions.count >= 2
        }
    }

    @Test func bulkOpenOpensEveryCheckedUrlAndClearsChecks() {
        var openedURLs: [URL] = []
        let defaults = Self.makeIsolatedUserDefaults()
        let session = StubNetworkSession(results: [])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let state = Self.makeState(
            3,
            apiClient: client,
            userDefaults: defaults,
            urlOpener: { url in
                openedURLs.append(url)
                return true
            }
        )
        state.groupByRepo = false
        let firstId = state.filteredNotifications[0].id
        let secondId = state.filteredNotifications[1].id

        state.toggleChecked(id: firstId)
        state.toggleChecked(id: secondId)

        let didOpen = state.openInBrowser()

        #expect(didOpen == true)
        #expect(openedURLs.count == 2)
        #expect(state.checkedThreadIDs.isEmpty)
    }

    @Test func refreshClearsChecks() {
        let (state, _) = Self.makeAuthedState(count: 3)
        state.groupByRepo = false
        let firstId = state.filteredNotifications[0].id
        state.toggleChecked(id: firstId)
        #expect(state.checkedThreadIDs.contains(firstId))

        state.refresh(force: false)

        #expect(state.checkedThreadIDs.isEmpty)
    }

    @Test func searchFilteringPrunesChecksForHiddenRows() {
        let (state, _) = Self.makeAuthedState(count: 3)
        state.groupByRepo = false
        let firstId = state.filteredNotifications[0].id
        let secondId = state.filteredNotifications[1].id
        state.toggleChecked(id: firstId)
        state.toggleChecked(id: secondId)

        // Search matches only "Notification 0" (titles are unique per id in test fixtures).
        state.searchQuery = "Notification 0"

        #expect(state.checkedThreadIDs.contains(firstId) == true)
        #expect(state.checkedThreadIDs.contains(secondId) == false)
    }
}
