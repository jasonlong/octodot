import Foundation
import Testing
@testable import Octodot

struct GitHubAPIClientTests {
    private struct NotificationFixture {
        let id: String
        let unread: Bool
        let reason: String
        let title: String
        let subjectType: String
        let subjectURL: String?
        let repositoryFullName: String
        let repositoryHTMLURL: String

        init(
            id: String,
            unread: Bool,
            reason: String = "review_requested",
            title: String? = nil,
            subjectType: String,
            subjectURL: String?,
            repositoryFullName: String = "acme/test",
            repositoryHTMLURL: String = "https://github.com/acme/test"
        ) {
            self.id = id
            self.unread = unread
            self.reason = reason
            self.title = title ?? "Test subject \(id)"
            self.subjectType = subjectType
            self.subjectURL = subjectURL
            self.repositoryFullName = repositoryFullName
            self.repositoryHTMLURL = repositoryHTMLURL
        }
    }

    private struct DependabotAlertFixture {
        let number: Int
        let repositoryFullName: String
        let repositoryHTMLURL: String
        let summary: String
        let ghsaID: String
        let updatedAt: String

        init(
            number: Int,
            repositoryFullName: String,
            repositoryHTMLURL: String,
            summary: String,
            ghsaID: String,
            updatedAt: String = "2026-04-01T12:00:00Z"
        ) {
            self.number = number
            self.repositoryFullName = repositoryFullName
            self.repositoryHTMLURL = repositoryHTMLURL
            self.summary = summary
            self.ghsaID = ghsaID
            self.updatedAt = updatedAt
        }
    }

    private final class SubjectConcurrencyTrackingSession: @unchecked Sendable, NetworkSession {
        private let notificationsPayload: Data
        private let subjectDelayNanoseconds: UInt64
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        private var inFlightSubjectRequests = 0
        private var maxInFlightSubjectRequests = 0

        init(notificationsPayload: Data, subjectDelayNanoseconds: UInt64 = 50_000_000) {
            self.notificationsPayload = notificationsPayload
            self.subjectDelayNanoseconds = subjectDelayNanoseconds
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            record(request)

            guard let url = request.url else {
                throw StubNetworkSession.StubError.missingResponse
            }

            if url.path == "/notifications" {
                return (
                    notificationsPayload,
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT"]
                    )!
                )
            }

            beginSubjectRequest()
            defer { endSubjectRequest() }

            try? await Task.sleep(nanoseconds: subjectDelayNanoseconds)
            return (
                #"{"state":"open"}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )
        }

        func recordedRequests() -> [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        func recordedMaxInFlightSubjectRequests() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return maxInFlightSubjectRequests
        }

        private func record(_ request: URLRequest) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }

        private func beginSubjectRequest() {
            lock.lock()
            inFlightSubjectRequests += 1
            maxInFlightSubjectRequests = max(maxInFlightSubjectRequests, inFlightSubjectRequests)
            lock.unlock()
        }

        private func endSubjectRequest() {
            lock.lock()
            inFlightSubjectRequests -= 1
            lock.unlock()
        }
    }

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
        #expect(requests.first?.url?.query?.contains("all=false") == true)
        #expect(requests.last?.value(forHTTPHeaderField: "If-Modified-Since") == "Wed, 01 Apr 2026 12:00:00 GMT")
    }

    @Test func conditional200TriggersFullSnapshotRefetch() async throws {
        let session = StubNetworkSession(results: [
            .success((
                Self.notificationsPayload(ids: ["1", "2"]).data(using: .utf8)!,
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
                Self.notificationsPayload(ids: ["3"]).data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:01:00 GMT",
                        "X-Poll-Interval": "0",
                    ]
                )!
            )),
            .success((
                Self.notificationsPayload(ids: ["1", "2", "3", "4"]).data(using: .utf8)!,
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
        let initial = try await client.fetchNotifications(force: true)
        let refreshed = try await client.fetchNotifications(force: false)
        let requests = await session.recordedRequests()

        #expect(initial.map(\.id) == ["2", "1"])
        #expect(refreshed.map(\.id) == ["4", "3", "2", "1"])
        #expect(requests.count == 3)
        #expect(requests[1].value(forHTTPHeaderField: "If-Modified-Since") == "Wed, 01 Apr 2026 12:00:00 GMT")
        #expect(requests[2].value(forHTTPHeaderField: "If-Modified-Since") == nil)
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
        #expect(requests.last?.url?.query?.contains("all=false") == true)
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
        #expect(requests.first?.url?.query?.contains("all=false") == true)
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
        #expect(requests.first?.url?.query?.contains("all=false") == true)
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
        let resolvedMetadata = await client.resolveSubjectMetadata(for: initial)
        let refreshed = try await client.fetchNotifications(force: true)
        let requests = await session.recordedRequests()

        #expect(initial.first?.subjectState == .unknown)
        #expect(resolvedMetadata["1"]?.state == .open)
        #expect(refreshed.first?.subjectState == .open)
        #expect(requests.count == 3)
    }

    @Test func fetchNotificationsMaintainsSeparateCachesForUnreadAndAllModes() async throws {
        let session = StubNetworkSession(results: [
            .success((
                Self.notificationsPayload(id: "unread-only").data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications?all=false")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT",
                        "X-Poll-Interval": "0",
                    ]
                )!
            )),
            .success((
                Self.notificationsPayload(id: "all-feed").data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications?all=true")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:05:00 GMT",
                        "X-Poll-Interval": "0",
                    ]
                )!
            )),
            .success((
                Data(),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications?all=false")!,
                    statusCode: 304,
                    httpVersion: nil,
                    headerFields: ["X-Poll-Interval": "60"]
                )!
            )),
            .success((
                Data(),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications?all=true")!,
                    statusCode: 304,
                    httpVersion: nil,
                    headerFields: ["X-Poll-Interval": "60"]
                )!
            )),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let unreadInitial = try await client.fetchNotifications(all: false, force: true)
        let allInitial = try await client.fetchNotifications(all: true, force: true)
        let unreadCached = try await client.fetchNotifications(all: false, force: false)
        let allCached = try await client.fetchNotifications(all: true, force: false)
        let requests = await session.recordedRequests()

        #expect(unreadInitial.first?.id == "unread-only")
        #expect(allInitial.first?.id == "all-feed")
        #expect(unreadCached.first?.id == "unread-only")
        #expect(allCached.first?.id == "all-feed")
        #expect(requests.count == 4)
        #expect(requests[2].url?.query?.contains("all=false") == true)
        #expect(requests[2].value(forHTTPHeaderField: "If-Modified-Since") == "Wed, 01 Apr 2026 12:00:00 GMT")
        #expect(requests[3].url?.query?.contains("all=true") == true)
        #expect(requests[3].value(forHTTPHeaderField: "If-Modified-Since") == "Wed, 01 Apr 2026 12:05:00 GMT")
    }

    @Test func fetchRecentInboxUsesBoundedAllQueryWithSinceParameter() async throws {
        let session = StubNetworkSession(results: [
            .success((
                Self.notificationsPayload(id: "inbox-1").data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications?all=true")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT"]
                )!
            ))
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let since = ISO8601DateFormatter().date(from: "2026-03-20T12:00:00Z")!
        let notifications = try await client.fetchRecentInboxNotifications(since: since, force: true)
        let requests = await session.recordedRequests()
        let queryItems = URLComponents(url: try #require(requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems

        #expect(notifications.count == 1)
        #expect(requests.count == 1)
        #expect(queryItems?.contains(URLQueryItem(name: "all", value: "true")) == true)
        #expect(queryItems?.contains(URLQueryItem(name: "since", value: "2026-03-20T12:00:00Z")) == true)
    }

    @Test func fetchRecentInboxStopsAtConfiguredPageCap() async throws {
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
                        "Link": #"<https://api.github.com/notifications?all=true&per_page=100&page=2>; rel="next""#
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
        let since = ISO8601DateFormatter().date(from: "2026-03-20T12:00:00Z")!
        let notifications = try await client.fetchRecentInboxNotifications(
            since: since,
            force: true,
            maxPages: 1
        )
        let requests = await session.recordedRequests()

        #expect(notifications.count == 100)
        #expect(requests.count == 1)
    }

    @Test func fetchDependabotAlertsUsesRepositoryEndpointsForAllRepositories() async throws {
        let firstPayload = Self.dependabotAlertsPayload(items: [
            DependabotAlertFixture(
                number: 7,
                repositoryFullName: "acme/api",
                repositoryHTMLURL: "https://github.com/acme/api",
                summary: "Upgrade electron",
                ghsaID: "GHSA-1234"
            )
        ]).data(using: .utf8)!
        let secondPayload = Self.dependabotAlertsPayload(items: [
            DependabotAlertFixture(
                number: 3,
                repositoryFullName: "octodot/personal",
                repositoryHTMLURL: "https://github.com/octodot/personal",
                summary: "Bump lodash",
                ghsaID: "GHSA-9999"
            )
        ]).data(using: .utf8)!

        let session = StubNetworkSession(results: [
            .success((
                firstPayload,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/repos/acme/api/dependabot/alerts")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
            .success((
                secondPayload,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/repos/octodot/personal/dependabot/alerts")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let alerts = try await client.fetchDependabotAlerts(
            repositoryNames: ["acme/api", "octodot/personal"],
            currentUsername: "octodot",
            force: true
        )
        let requests = await session.recordedRequests()

        #expect(alerts.count == 2)
        #expect(alerts.map(\.repository).contains("acme/api"))
        #expect(alerts.map(\.repository).contains("octodot/personal"))
        #expect(alerts.allSatisfy { $0.source == .dependabotAlert })
        #expect(alerts.allSatisfy { $0.isUnread })
        #expect(requests.count == 2)
        #expect(
            Set(requests.compactMap(\.url?.path)) ==
            Set(["/repos/acme/api/dependabot/alerts", "/repos/octodot/personal/dependabot/alerts"])
        )
    }

    @Test func fetchDependabotAlertsSkipsForbiddenRepositories() async throws {
        let payload = Self.dependabotAlertsPayload(items: [
            DependabotAlertFixture(
                number: 3,
                repositoryFullName: "octodot/personal",
                repositoryHTMLURL: "https://github.com/octodot/personal",
                summary: "Bump lodash",
                ghsaID: "GHSA-9999"
            )
        ]).data(using: .utf8)!

        let session = StubNetworkSession(results: [
            .success((
                Data(#"{"message":"Forbidden"}"#.utf8),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/repos/acme/api/dependabot/alerts")!,
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
            .success((
                payload,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/repos/octodot/personal/dependabot/alerts")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let alerts = try await client.fetchDependabotAlerts(
            repositoryNames: ["acme/api", "octodot/personal"],
            currentUsername: "octodot",
            force: true
        )

        #expect(alerts.count == 1)
        #expect(alerts.first?.repository == "octodot/personal")
    }

    @Test func fetchDependabotAlertsFiltersOutOldAlerts() async throws {
        let payload = Self.dependabotAlertsPayload(items: [
            DependabotAlertFixture(
                number: 7,
                repositoryFullName: "acme/api",
                repositoryHTMLURL: "https://github.com/acme/api",
                summary: "Recent electron issue",
                ghsaID: "GHSA-1234",
                updatedAt: "2026-04-01T12:00:00Z"
            ),
            DependabotAlertFixture(
                number: 8,
                repositoryFullName: "acme/api",
                repositoryHTMLURL: "https://github.com/acme/api",
                summary: "Ancient electron issue",
                ghsaID: "GHSA-5678",
                updatedAt: "2025-12-01T12:00:00Z"
            )
        ]).data(using: .utf8)!

        let session = StubNetworkSession(results: [
            .success((
                payload,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/repos/acme/api/dependabot/alerts")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            ))
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let alerts = try await client.fetchDependabotAlerts(
            repositoryNames: ["acme/api"],
            currentUsername: "octodot",
            force: true
        )

        #expect(alerts.count == 1)
        #expect(alerts.first?.id == "dependabot:acme/api:7")
    }

    @Test func resolveSubjectMetadataCapsConcurrentRequests() async throws {
        let session = SubjectConcurrencyTrackingSession(
            notificationsPayload: Self.notificationsPayload(
                ids: ["1", "2", "3", "4"],
                subjectURLPrefix: "https://api.github.com/repos/acme/test/pulls"
            ).data(using: .utf8)!
        )

        let client = GitHubAPIClient(
            token: "ghp_secret",
            session: session,
            maxConcurrentSubjectRequests: 2
        )

        let notifications = try await client.fetchNotifications(force: true)
        let resolvedMetadata = await client.resolveSubjectMetadata(for: notifications)
        let requests = session.recordedRequests()
        let subjectRequests = requests.filter { $0.url?.path.contains("/repos/acme/test/pulls/") == true }

        #expect(notifications.count == 4)
        #expect(resolvedMetadata.count == 4)
        #expect(resolvedMetadata.values.allSatisfy { $0.state == .open })
        #expect(subjectRequests.count == 4)
        #expect(session.recordedMaxInFlightSubjectRequests() == 2)
    }

    @Test func resolveSubjectMetadataOnlyFetchesIssueAndPullRequestStates() async throws {
        let payload = Self.notificationsPayload(items: [
            NotificationFixture(
                id: "1",
                unread: true,
                subjectType: "PullRequest",
                subjectURL: "https://api.github.com/repos/acme/test/pulls/1"
            ),
            NotificationFixture(
                id: "2",
                unread: false,
                subjectType: "PullRequest",
                subjectURL: "https://api.github.com/repos/acme/test/pulls/2"
            ),
            NotificationFixture(
                id: "3",
                unread: true,
                subjectType: "Discussion",
                subjectURL: "https://api.github.com/repos/acme/test/discussions/3"
            ),
            NotificationFixture(
                id: "4",
                unread: true,
                subjectType: "Issue",
                subjectURL: "https://api.github.com/repos/acme/test/issues/4"
            ),
            NotificationFixture(
                id: "5",
                unread: true,
                reason: "security_alert",
                title: "GHSA-532v-xpq5-8h95",
                subjectType: "RepositoryVulnerabilityAlert",
                subjectURL: "https://api.github.com/repos/acme/test/dependabot/alerts/5"
            ),
        ]).data(using: .utf8)!

        let session = SubjectConcurrencyTrackingSession(notificationsPayload: payload)
        let client = GitHubAPIClient(token: "ghp_secret", session: session)

        let notifications = try await client.fetchNotifications(force: true)
        let resolvedMetadata = await client.resolveSubjectMetadata(for: notifications)
        let subjectRequests = session.recordedRequests().filter {
            $0.url?.path.contains("/repos/acme/test/") == true && $0.url?.path != "/notifications"
        }

        #expect(notifications.count == 5)
        #expect(subjectRequests.count == 3)
        #expect(subjectRequests.map(\.url?.path).contains("/repos/acme/test/pulls/1"))
        #expect(subjectRequests.map(\.url?.path).contains("/repos/acme/test/pulls/2"))
        #expect(subjectRequests.map(\.url?.path).contains("/repos/acme/test/issues/4"))
        #expect(subjectRequests.map(\.url?.path).contains("/repos/acme/test/discussions/3") == false)
        #expect(subjectRequests.map(\.url?.path).contains("/repos/acme/test/dependabot/alerts/5") == false)
        #expect(resolvedMetadata["1"]?.state == .open)
        #expect(resolvedMetadata["2"]?.state == .open)
        #expect(resolvedMetadata["4"]?.state == .open)
        #expect(resolvedMetadata["3"] == nil)
        #expect(resolvedMetadata["5"] == nil)
    }

    @Test func resolveSubjectMetadataTreatsMergedAtAsMergedPullRequest() async throws {
        let payload = Self.notificationsPayload(items: [
            NotificationFixture(
                id: "1",
                unread: false,
                subjectType: "PullRequest",
                subjectURL: "https://api.github.com/repos/acme/test/pulls/1"
            )
        ]).data(using: .utf8)!

        let session = StubNetworkSession(results: [
            .success((
                payload,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT"]
                )!
            )),
            .success((
                #"{"state":"closed","merged_at":"2026-04-01T12:00:00Z"}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/repos/acme/test/pulls/1")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            ))
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let notifications = try await client.fetchNotifications(force: true)
        let resolvedMetadata = await client.resolveSubjectMetadata(for: notifications)

        #expect(resolvedMetadata["1"]?.state == .merged)
    }

    @Test func resolveSubjectMetadataTreatsDraftPullRequestAsDraft() async throws {
        let payload = Self.notificationsPayload(items: [
            NotificationFixture(
                id: "1",
                unread: false,
                subjectType: "PullRequest",
                subjectURL: "https://api.github.com/repos/acme/test/pulls/1"
            )
        ]).data(using: .utf8)!

        let session = StubNetworkSession(results: [
            .success((
                payload,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT"]
                )!
            )),
            .success((
                #"{"state":"open","draft":true}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/repos/acme/test/pulls/1")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            ))
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let notifications = try await client.fetchNotifications(force: true)
        let resolvedMetadata = await client.resolveSubjectMetadata(for: notifications)

        #expect(resolvedMetadata["1"]?.state == .draft)
    }

    @Test func resolveSubjectMetadataRecordsNonFatalWarningWhenSubjectFetchFails() async throws {
        let payload = Self.notificationsPayload(items: [
            NotificationFixture(
                id: "1",
                unread: true,
                subjectType: "PullRequest",
                subjectURL: "https://api.github.com/repos/acme/test/pulls/1"
            )
        ]).data(using: .utf8)!

        let session = StubNetworkSession(results: [
            .success((
                payload,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT"]
                )!
            )),
            .failure(GitHubAPIClient.APIError.forbidden)
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let notifications = try await client.fetchNotifications(force: true)
        let resolvedMetadata = await client.resolveSubjectMetadata(for: notifications)
        let warning = await client.takeNonFatalWarningMessage()

        #expect(resolvedMetadata["1"]?.state == .unknown)
        #expect(warning == GitHubAPIClient.subjectMetadataWarningMessage)
        #expect(await client.takeNonFatalWarningMessage() == nil)
    }

    @Test func resolveSubjectMetadataMapsOpenPullRequestCheckRunsToCIStatus() async throws {
        let payload = Self.notificationsPayload(items: [
            NotificationFixture(
                id: "1",
                unread: true,
                subjectType: "PullRequest",
                subjectURL: "https://api.github.com/repos/acme/test/pulls/1"
            )
        ]).data(using: .utf8)!

        let session = StubNetworkSession(results: [
            .success((
                payload,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT"]
                )!
            )),
            .success((
                #"{"state":"open","head":{"sha":"abc123"}}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/repos/acme/test/pulls/1")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
            .success((
                #"{"check_runs":[{"status":"completed","conclusion":"success"}]}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/repos/acme/test/commits/abc123/check-runs?per_page=100")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let notifications = try await client.fetchNotifications(force: true)
        let resolvedMetadata = await client.resolveSubjectMetadata(for: notifications)

        #expect(resolvedMetadata["1"]?.state == .open)
        #expect(resolvedMetadata["1"]?.ciStatus == .success)
    }

    @Test func resolveSubjectMetadataRecordsNonFatalWarningWhenCIStatusFails() async throws {
        let payload = Self.notificationsPayload(items: [
            NotificationFixture(
                id: "1",
                unread: true,
                subjectType: "PullRequest",
                subjectURL: "https://api.github.com/repos/acme/test/pulls/1"
            )
        ]).data(using: .utf8)!

        let session = StubNetworkSession(results: [
            .success((
                payload,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT"]
                )!
            )),
            .success((
                #"{"state":"open","head":{"sha":"abc123"}}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/repos/acme/test/pulls/1")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
            .failure(GitHubAPIClient.APIError.rateLimited),
            .failure(GitHubAPIClient.APIError.forbidden),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let notifications = try await client.fetchNotifications(force: true)
        let resolvedMetadata = await client.resolveSubjectMetadata(for: notifications)
        let warning = await client.takeNonFatalWarningMessage()

        #expect(resolvedMetadata["1"]?.state == .open)
        #expect(resolvedMetadata["1"]?.ciStatus == nil)
        #expect(warning == GitHubAPIClient.subjectMetadataWarningMessage)
    }

    @Test func resolveSubjectMetadataPersistsCIStatusAcrossRefreshes() async throws {
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
                #"{"state":"open","head":{"sha":"abc123"}}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/repos/acme/test/pulls/1")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
            .success((
                #"{"check_runs":[{"status":"queued","conclusion":null}]}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/repos/acme/test/commits/abc123/check-runs?per_page=100")!,
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
        let resolvedMetadata = await client.resolveSubjectMetadata(for: initial)
        let refreshed = try await client.fetchNotifications(force: true)

        #expect(resolvedMetadata["1"]?.ciStatus == .pending)
        #expect(refreshed.first?.ciStatus == .pending)
    }

    @Test func fetchNotificationsMapsSecurityAlertsExplicitly() async throws {
        let payload = Self.notificationsPayload(items: [
            NotificationFixture(
                id: "sec-1",
                unread: true,
                reason: "security_alert",
                title: "GHSA-532v-xpq5-8h95",
                subjectType: "RepositoryVulnerabilityAlert",
                subjectURL: "https://api.github.com/repos/electron/electron/dependabot/alerts/1",
                repositoryFullName: "electron/electron",
                repositoryHTMLURL: "https://github.com/electron/electron"
            )
        ]).data(using: .utf8)!

        let session = StubNetworkSession(results: [
            .success((
                payload,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT"]
                )!
            ))
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let notifications = try await client.fetchNotifications(force: true)
        let notification = try #require(notifications.first)

        #expect(notification.reason == .securityAlert)
        #expect(notification.type == .securityAlert)
        #expect(notification.url.absoluteString == "https://github.com/advisories/GHSA-532v-xpq5-8h95")
    }

    @Test func markAsReadInvalidatesUnreadCacheForNextRefresh() async throws {
        let session = StubNetworkSession(results: [
            .success((
                Self.notificationsPayload(ids: ["1", "2"]).data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications?all=false")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT",
                        "X-Poll-Interval": "60",
                    ]
                )!
            )),
            .success((
                Data(),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications/threads/1")!,
                    statusCode: 205,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
            .success((
                Self.notificationsPayload(ids: ["2", "3"]).data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications?all=false")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:05:00 GMT",
                        "X-Poll-Interval": "60",
                    ]
                )!
            )),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let initial = try await client.fetchNotifications(all: false, force: true)
        try await client.markAsRead(threadId: "1")
        let refreshed = try await client.fetchNotifications(all: false, force: false)
        let requests = await session.recordedRequests()

        #expect(initial.map(\.id) == ["2", "1"])
        #expect(refreshed.map(\.id) == ["3", "2"])
        #expect(requests.count == 3)
        #expect(requests[2].httpMethod == "GET")
        #expect(requests[2].url?.query?.contains("all=false") == true)
        #expect(requests[2].value(forHTTPHeaderField: "If-Modified-Since") == nil)
    }

    @Test func unsubscribeIgnoresFutureUpdatesAndRemovesThreadFromInbox() async throws {
        let notification = GitHubNotification(
            id: "1",
            threadId: "thread-1",
            title: "Notification 1",
            repository: "acme/alpha",
            reason: .reviewRequested,
            type: .pullRequest,
            updatedAt: Date(),
            isUnread: true,
            url: URL(string: "https://github.com/acme/alpha/pull/1")!,
            subjectURL: nil,
            subjectState: .open
        )
        let session = StubNetworkSession(results: [
            .success((
                #"{"subscribed":true,"ignored":true}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications/threads/thread-1/subscription")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
            .success((
                Data(),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications/threads/thread-1")!,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            ))
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        try await client.unsubscribe(notification: notification)
        let requests = await session.recordedRequests()
        let request = try #require(requests.first)
        let body = try #require(request.httpBody)
        let bodyObject = try #require(JSONSerialization.jsonObject(with: body) as? [String: Bool])

        #expect(requests.count == 2)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/notifications/threads/thread-1/subscription")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(bodyObject["ignored"] == true)
        #expect(bodyObject["subscribed"] == nil)
        #expect(requests[1].httpMethod == "DELETE")
        #expect(requests[1].url?.path == "/notifications/threads/thread-1")
    }

    @Test func doneInvalidatesCacheWithoutReusingLocallyPrunedUnreadFeed() async throws {
        let notification = GitHubNotification(
            id: "1",
            threadId: "thread-1",
            title: "Notification 1",
            repository: "acme/alpha",
            reason: .reviewRequested,
            type: .pullRequest,
            updatedAt: Date(),
            isUnread: true,
            url: URL(string: "https://github.com/acme/alpha/pull/1")!,
            subjectURL: nil,
            subjectState: .open
        )
        let session = StubNetworkSession(results: [
            .success((
                Self.notificationsPayload(ids: ["1", "2"]).data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications?all=false")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT",
                        "X-Poll-Interval": "60",
                    ]
                )!
            )),
            .success((
                Data(),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications/threads/thread-1")!,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
            .success((
                Self.notificationsPayload(ids: ["2", "3"]).data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications?all=false")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:05:00 GMT",
                        "X-Poll-Interval": "60",
                    ]
                )!
            )),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let initial = try await client.fetchNotifications(all: false, force: true)
        try await client.markAsDone(notification: notification)
        let refreshed = try await client.fetchNotifications(all: false, force: false)
        let requests = await session.recordedRequests()

        #expect(initial.map(\.id) == ["2", "1"])
        #expect(refreshed.map(\.id) == ["3", "2"])
        #expect(requests.count == 3)
        #expect(requests[2].httpMethod == "GET")
        #expect(requests[2].value(forHTTPHeaderField: "If-Modified-Since") == nil)
    }

    @Test func unsubscribeInvalidatesCacheWithoutReusingLocallyPrunedUnreadFeed() async throws {
        let notification = GitHubNotification(
            id: "1",
            threadId: "thread-1",
            title: "Notification 1",
            repository: "acme/alpha",
            reason: .reviewRequested,
            type: .pullRequest,
            updatedAt: Date(),
            isUnread: true,
            url: URL(string: "https://github.com/acme/alpha/pull/1")!,
            subjectURL: nil,
            subjectState: .open
        )
        let session = StubNetworkSession(results: [
            .success((
                Self.notificationsPayload(ids: ["1", "2"]).data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications?all=false")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT",
                        "X-Poll-Interval": "60",
                    ]
                )!
            )),
            .success((
                #"{"subscribed":true,"ignored":true}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications/threads/thread-1/subscription")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
            .success((
                Data(),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications/threads/thread-1")!,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
            .success((
                Self.notificationsPayload(ids: ["2", "3"]).data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications?all=false")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:05:00 GMT",
                        "X-Poll-Interval": "60",
                    ]
                )!
            )),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let initial = try await client.fetchNotifications(all: false, force: true)
        try await client.unsubscribe(notification: notification)
        let refreshed = try await client.fetchNotifications(all: false, force: false)
        let requests = await session.recordedRequests()

        #expect(initial.map(\.id) == ["2", "1"])
        #expect(refreshed.map(\.id) == ["3", "2"])
        #expect(requests.count == 4)
        #expect(requests[3].httpMethod == "GET")
        #expect(requests[3].value(forHTTPHeaderField: "If-Modified-Since") == nil)
    }

    @Test func restoreSubscriptionClearsIgnoredThreadSubscription() async throws {
        let notification = GitHubNotification(
            id: "1",
            threadId: "thread-1",
            title: "Notification 1",
            repository: "acme/alpha",
            reason: .reviewRequested,
            type: .pullRequest,
            updatedAt: Date(),
            isUnread: true,
            url: URL(string: "https://github.com/acme/alpha/pull/1")!,
            subjectURL: nil,
            subjectState: .open
        )
        let session = StubNetworkSession(results: [
            .success((
                #"{"subscribed":true,"ignored":false}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications/threads/thread-1/subscription")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            ))
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        try await client.restoreSubscription(threadId: "thread-1", notification: notification)
        let requests = await session.recordedRequests()
        let request = try #require(requests.first)
        let body = try #require(request.httpBody)
        let bodyObject = try #require(JSONSerialization.jsonObject(with: body) as? [String: Bool])

        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/notifications/threads/thread-1/subscription")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(bodyObject["ignored"] == false)
        #expect(bodyObject["subscribed"] == nil)
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

    private static func notificationsPayload(
        ids: [String],
        subjectURLPrefix: String? = nil
    ) -> String {
        notificationsPayload(items: ids.enumerated().map { offset, id in
            NotificationFixture(
                id: id,
                unread: true,
                subjectType: "PullRequest",
                subjectURL: subjectURLPrefix.map { "\($0)/\(id)" }
            )
        })
    }

    private static func notificationsPayload(items: [NotificationFixture]) -> String {
        let iso = ISO8601DateFormatter()
        let baseDate = iso.date(from: "2026-04-01T12:00:00Z") ?? Date()

        let items = items.enumerated().map { offset, item in
            let updatedAt = iso.string(from: baseDate.addingTimeInterval(TimeInterval(offset * 60)))
            let subjectURLField: String
            if let subjectURL = item.subjectURL {
                subjectURLField = #""url":"\#(subjectURL)""#
            } else {
                subjectURLField = #""url":null"#
            }
            return """
              {
                "id": "\(item.id)",
                "unread": \(item.unread ? "true" : "false"),
                "reason": "\(item.reason)",
                "updated_at": "\(updatedAt)",
                "subject": {
                  "title": "\(item.title)",
                  \(subjectURLField),
                  "type": "\(item.subjectType)"
                },
                "repository": {
                  "full_name": "\(item.repositoryFullName)",
                  "html_url": "\(item.repositoryHTMLURL)"
                }
              }
            """
        }.joined(separator: ",\n")

        return "[\n\(items)\n]"
    }

    private static func dependabotAlertsPayload(items: [DependabotAlertFixture]) -> String {
        let alerts = items.map { fixture in
            """
              {
                "number": \(fixture.number),
                "html_url": "https://github.com/\(fixture.repositoryFullName)/security/dependabot/\(fixture.number)",
                "updated_at": "\(fixture.updatedAt)",
                "repository": {
                  "full_name": "\(fixture.repositoryFullName)",
                  "html_url": "\(fixture.repositoryHTMLURL)"
                },
                "dependency": {
                  "package": {
                    "name": "electron"
                  }
                },
                "security_advisory": {
                  "ghsa_id": "\(fixture.ghsaID)",
                  "summary": "\(fixture.summary)"
                }
              }
            """
        }.joined(separator: ",\n")

        return "[\n\(alerts)\n]"
    }
}
