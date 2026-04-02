import Foundation
import Testing
@testable import Octodot

struct GitHubAPIClientTests {
    private struct NotificationFixture {
        let id: String
        let unread: Bool
        let subjectType: String
        let subjectURL: String?
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
        let resolvedStates = await client.resolveSubjectStates(for: initial)
        let refreshed = try await client.fetchNotifications(force: true)
        let requests = await session.recordedRequests()

        #expect(initial.first?.subjectState == .unknown)
        #expect(resolvedStates["1"] == .open)
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

    @Test func resolveSubjectStatesCapsConcurrentRequests() async throws {
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
        let resolvedStates = await client.resolveSubjectStates(for: notifications)
        let requests = session.recordedRequests()
        let subjectRequests = requests.filter { $0.url?.path.contains("/repos/acme/test/pulls/") == true }

        #expect(notifications.count == 4)
        #expect(resolvedStates.count == 4)
        #expect(resolvedStates.values.allSatisfy { $0 == .open })
        #expect(subjectRequests.count == 4)
        #expect(session.recordedMaxInFlightSubjectRequests() == 2)
    }

    @Test func resolveSubjectStatesOnlyFetchesUnreadIssueAndPullRequestStates() async throws {
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
        ]).data(using: .utf8)!

        let session = SubjectConcurrencyTrackingSession(notificationsPayload: payload)
        let client = GitHubAPIClient(token: "ghp_secret", session: session)

        let notifications = try await client.fetchNotifications(force: true)
        let resolvedStates = await client.resolveSubjectStates(for: notifications)
        let subjectRequests = session.recordedRequests().filter {
            $0.url?.path.contains("/repos/acme/test/") == true && $0.url?.path != "/notifications"
        }

        #expect(notifications.count == 4)
        #expect(subjectRequests.count == 2)
        #expect(subjectRequests.map(\.url?.path).contains("/repos/acme/test/pulls/1"))
        #expect(subjectRequests.map(\.url?.path).contains("/repos/acme/test/issues/4"))
        #expect(subjectRequests.map(\.url?.path).contains("/repos/acme/test/pulls/2") == false)
        #expect(subjectRequests.map(\.url?.path).contains("/repos/acme/test/discussions/3") == false)
        #expect(resolvedStates["1"] == .open)
        #expect(resolvedStates["4"] == .open)
        #expect(resolvedStates["2"] == nil)
        #expect(resolvedStates["3"] == nil)
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
        try await client.restoreSubscription(threadId: "thread-1", notification: notification, originalIndex: 0)
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
                "reason": "review_requested",
                "updated_at": "\(updatedAt)",
                "subject": {
                  "title": "Test subject \(item.id)",
                  \(subjectURLField),
                  "type": "\(item.subjectType)"
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
