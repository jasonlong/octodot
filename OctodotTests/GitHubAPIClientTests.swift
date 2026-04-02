import Foundation
import Testing
@testable import Octodot

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
