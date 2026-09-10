import Foundation
import Testing
@testable import Octodot

struct GitHubAPIClientTests {
    private static let recentDateString: String = {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date().addingTimeInterval(-2 * 24 * 60 * 60))
    }()

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

    private static func metadataIssue(id: String, number: Int) -> GitHubNotification {
        GitHubNotification(
            id: id,
            threadId: id,
            title: "Issue \(number)",
            repository: "acme/test",
            reason: .subscribed,
            type: .issue,
            updatedAt: Date(),
            isUnread: true,
            url: URL(string: "https://github.com/acme/test/issues/\(number)")!,
            subjectURL: "https://api.github.com/repos/acme/test/issues/\(number)",
            subjectState: .unknown
        )
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
                #"{"state":"open","user":{"login":"octocat","avatar_url":"https://avatars.githubusercontent.com/u/1?v=4"}}"#.data(using: .utf8)!,
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

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var currentDate: Date

        init(now: Date) {
            currentDate = now
        }

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return currentDate
        }

        func advance(by interval: TimeInterval) {
            lock.lock()
            currentDate = currentDate.addingTimeInterval(interval)
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let username = try await client.validateToken()
        let requests = await session.recordedRequests()

        #expect(username == "octodot")
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_secret")
    }

    @Test func validateTokenRejectsExternalFinalResponseURL() async throws {
        let session = StubNetworkSession(results: [
            .success((
                #"{"login":"attacker"}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://example.com/captured")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)

        do {
            _ = try await client.validateToken()
            Issue.record("Expected a redirected external response to be rejected")
        } catch GitHubAPIClient.APIError.untrustedGitHubAPIURL {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func validateTokenAcceptsRequiredClassicScopes() async throws {
        let session = StubNetworkSession(results: [
            .success((
                #"{"login":"octodot"}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/user")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["X-OAuth-Scopes": "notifications, repo"]
                )!
            ))
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let username = try await client.validateToken()

        #expect(username == "octodot")
    }

    @Test func validateTokenRejectsMissingRepoScope() async throws {
        let session = StubNetworkSession(results: [
            .success((
                #"{"login":"octodot"}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/user")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["X-OAuth-Scopes": "notifications"]
                )!
            ))
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)

        do {
            _ = try await client.validateToken()
            Issue.record("Expected validateToken to reject a token missing repo scope")
        } catch GitHubAPIClient.APIError.insufficientScopes(let missing) {
            #expect(missing == ["repo"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func validateTokenRejectsMissingNotificationsScope() async throws {
        let session = StubNetworkSession(results: [
            .success((
                #"{"login":"octodot"}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/user")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["X-OAuth-Scopes": "repo"]
                )!
            ))
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)

        do {
            _ = try await client.validateToken()
            Issue.record("Expected validateToken to reject a token missing notifications scope")
        } catch GitHubAPIClient.APIError.insufficientScopes(let missing) {
            #expect(missing == ["notifications"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func validateTokenRejectsExplicitlyEmptyClassicScopes() async throws {
        let session = StubNetworkSession(results: [
            .success((
                #"{"login":"octodot"}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/user")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["X-OAuth-Scopes": ""]
                )!
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)

        do {
            _ = try await client.validateToken()
            Issue.record("Expected validateToken to reject an empty classic scope list")
        } catch GitHubAPIClient.APIError.insufficientScopes(let missing) {
            #expect(missing == ["notifications", "repo"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func validateTokenMapsExhausted403ToRateLimitError() async throws {
        let session = StubNetworkSession(results: [
            .success((
                Data(),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/user")!,
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: ["X-RateLimit-Remaining": "0"]
                )!
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)

        do {
            _ = try await client.validateToken()
            Issue.record("Expected exhausted 403 response to map to rate limiting")
        } catch GitHubAPIClient.APIError.rateLimited {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func retryAfterCooldownBlocksManualRefreshUntilExpiry() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 2_000_000_000))
        let session = StubNetworkSession(results: [
            .success((
                Data(),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "120"]
                )!
            )),
            .success((
                Self.notificationsPayload(id: "after-cooldown").data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
        ])
        let client = GitHubAPIClient(
            token: "ghp_secret",
            session: session,
            useGraphQLForSubjectMetadata: false,
            dateProvider: { clock.now() }
        )

        do {
            _ = try await client.fetchNotifications(force: true)
            Issue.record("Expected the initial response to be rate limited")
        } catch GitHubAPIClient.APIError.rateLimited {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await client.suggestedRefreshDelayNanoseconds() == 120_000_000_000)

        do {
            _ = try await client.fetchNotifications(force: true)
            Issue.record("Expected manual refresh to honor the active cooldown")
        } catch GitHubAPIClient.APIError.rateLimitCooldown(let until) {
            #expect(until == clock.now().addingTimeInterval(120))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await session.recordedRequests().count == 1)

        clock.advance(by: 120)
        let notifications = try await client.fetchNotifications(force: true)

        #expect(notifications.map(\.id) == ["after-cooldown"])
        #expect(await session.recordedRequests().count == 2)
    }

    @Test func exhausted403UsesLaterRateLimitResetDeadline() async throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = TestClock(now: start)
        let session = StubNetworkSession(results: [
            .success((
                Data(),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/user")!,
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: [
                        "Retry-After": "30",
                        "X-RateLimit-Remaining": "0",
                        "X-RateLimit-Reset": "2000000120",
                    ]
                )!
            ))
        ])
        let client = GitHubAPIClient(
            token: "ghp_secret",
            session: session,
            useGraphQLForSubjectMetadata: false,
            dateProvider: { clock.now() }
        )

        do {
            _ = try await client.validateToken()
            Issue.record("Expected exhausted 403 response to be rate limited")
        } catch GitHubAPIClient.APIError.rateLimited {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.suggestedRefreshDelayNanoseconds() == 120_000_000_000)
    }

    @Test func malformedCooldownHeadersUseDefaultAndHostileDurationsAreClamped() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 2_000_000_000))
        let rateLimitedResponse: ([String: String]) -> HTTPURLResponse = { headers in
            HTTPURLResponse(
                url: URL(string: "https://api.github.com/user")!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: headers
            )!
        }
        let session = StubNetworkSession(results: [
            .success((Data(), rateLimitedResponse([
                "Retry-After": "not-a-duration",
                "X-RateLimit-Reset": "also-invalid",
            ]))),
            .success((Data(), rateLimitedResponse(["Retry-After": "999999"]))),
        ])
        let client = GitHubAPIClient(
            token: "ghp_secret",
            session: session,
            useGraphQLForSubjectMetadata: false,
            dateProvider: { clock.now() }
        )

        do {
            _ = try await client.validateToken()
        } catch GitHubAPIClient.APIError.rateLimited {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await client.suggestedRefreshDelayNanoseconds() == 60_000_000_000)

        clock.advance(by: 60)
        do {
            _ = try await client.validateToken()
        } catch GitHubAPIClient.APIError.rateLimited {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.suggestedRefreshDelayNanoseconds() == 3_600_000_000_000)
    }

    @Test func tokenReplacementClearsAccountSpecificCooldown() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 2_000_000_000))
        let session = StubNetworkSession(results: [
            .success((
                Data(),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/user")!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "300"]
                )!
            )),
            .success((
                Data(#"{"login":"new-account"}"#.utf8),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/user")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
        ])
        let client = GitHubAPIClient(
            token: "old_token",
            session: session,
            useGraphQLForSubjectMetadata: false,
            dateProvider: { clock.now() }
        )

        do {
            _ = try await client.validateToken()
        } catch GitHubAPIClient.APIError.rateLimited {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await client.suggestedRefreshDelayNanoseconds() == 300_000_000_000)

        await client.updateToken("new_token")
        let username = try await client.validateToken()
        let requests = await session.recordedRequests()

        #expect(username == "new-account")
        #expect(requests.count == 2)
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer new_token")
        #expect(await client.suggestedRefreshDelayNanoseconds() == 60_000_000_000)
    }

    @Test func suggestedRefreshDelayUsesLaterFeedOrCooldownDeadline() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 2_000_000_000))
        let session = StubNetworkSession(results: [
            .success((
                Self.notificationsPayload(id: "1").data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["X-Poll-Interval": "300"]
                )!
            )),
            .success((
                Data(),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications/threads/1")!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "60"]
                )!
            )),
        ])
        let client = GitHubAPIClient(
            token: "ghp_secret",
            session: session,
            useGraphQLForSubjectMetadata: false,
            dateProvider: { clock.now() }
        )

        _ = try await client.fetchNotifications(force: true)
        do {
            try await client.markAsRead(threadId: "1")
        } catch GitHubAPIClient.APIError.rateLimited {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await client.suggestedRefreshDelayNanoseconds() == 300_000_000_000)
        clock.advance(by: 250)
        #expect(await client.suggestedRefreshDelayNanoseconds() == 50_000_000_000)
    }

    @Test func metadataRateLimitSkipsRESTFallbackAndSubsequentWork() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 2_000_000_000))
        let session = StubNetworkSession(results: [
            .success((
                Data(),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/graphql")!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "90"]
                )!
            ))
        ])
        let client = GitHubAPIClient(
            token: "ghp_secret",
            session: session,
            dateProvider: { clock.now() }
        )
        let notification = Self.metadataIssue(id: "issue-1", number: 1)

        let initial = await client.resolveSubjectMetadata(for: [notification])
        let deferred = await client.resolveSubjectMetadata(for: [notification])

        #expect(initial.isEmpty)
        #expect(deferred.isEmpty)
        #expect(await session.recordedRequests().count == 1)
        #expect(await client.takeNonFatalWarningMessage() == GitHubAPIClient.subjectMetadataWarningMessage)
    }

    @Test func tokenReplacementRejectsInFlightNotificationResponse() async throws {
        let session = DelayedStubNetworkSession(results: [
            .success(
                payload: Self.notificationsPayload(id: "old-account").data(using: .utf8)!,
                response: HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!,
                delayNanoseconds: 80_000_000
            )
        ])
        let client = GitHubAPIClient(token: "old_token", session: session, useGraphQLForSubjectMetadata: false)
        let fetch = Task {
            try await client.fetchNotifications(force: true)
        }
        try await Task.sleep(nanoseconds: 5_000_000)

        await client.updateToken("new_token")

        do {
            _ = try await fetch.value
            Issue.record("Expected the old credential response to be rejected")
        } catch GitHubAPIClient.APIError.staleCredentialResponse {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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

    @Test func successfulEmptyFeedIsCachedUntilPollingDeadline() async throws {
        let session = StubNetworkSession(results: [
            .success((
                Data("[]".utf8),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["X-Poll-Interval": "60"]
                )!
            )),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)

        let initial = try await client.fetchNotifications(force: false)
        let cached = try await client.fetchNotifications(force: false)

        #expect(initial.isEmpty)
        #expect(cached.isEmpty)
        #expect(await session.recordedRequests().count == 1)
    }

    @Test func forceRefreshBypassesSuccessfulEmptyFeedCache() async throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com/notifications")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["X-Poll-Interval": "60"]
        )!
        let session = StubNetworkSession(results: [
            .success((Data("[]".utf8), response)),
            .success((Data("[]".utf8), response)),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)

        _ = try await client.fetchNotifications(force: false)
        _ = try await client.fetchNotifications(force: true)

        #expect(await session.recordedRequests().count == 2)
    }

    @Test func expiredEmptyFeedUsesConditionalRequest() async throws {
        let session = StubNetworkSession(results: [
            .success((
                Data("[]".utf8),
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
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)

        _ = try await client.fetchNotifications(force: false)
        let refreshed = try await client.fetchNotifications(force: false)
        let requests = await session.recordedRequests()

        #expect(refreshed.isEmpty)
        #expect(requests.count == 2)
        #expect(requests[1].value(forHTTPHeaderField: "If-Modified-Since") == "Wed, 01 Apr 2026 12:00:00 GMT")
    }

    @Test func successfulEmptyFeedCachesRemainIsolatedByScope() async throws {
        let emptyResponse: (String) -> HTTPURLResponse = { url in
            HTTPURLResponse(
                url: URL(string: url)!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["X-Poll-Interval": "60"]
            )!
        }
        let session = StubNetworkSession(results: [
            .success((Data("[]".utf8), emptyResponse("https://api.github.com/notifications?all=false"))),
            .success((Data("[]".utf8), emptyResponse("https://api.github.com/notifications?all=true"))),
            .success((Data("[]".utf8), emptyResponse("https://api.github.com/notifications?all=true&since=2026-04-01T12:00:00Z"))),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let since = Date(timeIntervalSince1970: 1_775_044_800)

        _ = try await client.fetchNotifications(all: false)
        _ = try await client.fetchNotifications(all: true)
        _ = try await client.fetchRecentInboxNotifications(since: since)
        _ = try await client.fetchNotifications(all: false)
        _ = try await client.fetchNotifications(all: true)
        _ = try await client.fetchRecentInboxNotifications(since: since)

        #expect(await session.recordedRequests().count == 3)
    }

    @Test func tokenReplacementInvalidatesSuccessfulEmptyFeedCache() async throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com/notifications")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["X-Poll-Interval": "60"]
        )!
        let session = StubNetworkSession(results: [
            .success((Data("[]".utf8), response)),
            .success((Data("[]".utf8), response)),
        ])
        let client = GitHubAPIClient(token: "old_token", session: session, useGraphQLForSubjectMetadata: false)

        _ = try await client.fetchNotifications()
        await client.updateToken("new_token")
        _ = try await client.fetchNotifications()
        let requests = await session.recordedRequests()

        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer old_token")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer new_token")
    }

    @Test func duplicateNotificationIDsAreDeduplicatedWithoutPoisoningCache() async throws {
        let duplicatePayload = Self.notificationsPayload(items: [
            NotificationFixture(
                id: "duplicate",
                unread: true,
                title: "First copy",
                subjectType: "PullRequest",
                subjectURL: nil
            ),
            NotificationFixture(
                id: "duplicate",
                unread: true,
                title: "Second copy",
                subjectType: "PullRequest",
                subjectURL: nil
            ),
        ])
        let session = StubNetworkSession(results: [
            .success((
                duplicatePayload.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["X-Poll-Interval": "0"]
                )!
            )),
            .success((
                Self.notificationsPayload(id: "duplicate").data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)

        let initial = try await client.fetchNotifications(force: true)
        let refreshed = try await client.fetchNotifications(force: true)

        #expect(initial.map(\.id) == ["duplicate"])
        #expect(refreshed.map(\.id) == ["duplicate"])
    }

    @Test func malformedPollIntervalFallsBackToSafeDefault() async throws {
        let session = StubNetworkSession(results: [
            .success((
                Self.notificationsPayload(id: "1").data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["X-Poll-Interval": "nan"]
                )!
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)

        _ = try await client.fetchNotifications(force: true)
        let delay = await client.suggestedRefreshDelayNanoseconds()

        #expect(delay > 55_000_000_000)
        #expect(delay <= 60_000_000_000)
    }

    @Test func notificationsWithInvalidTimestampsAreDropped() async throws {
        let session = StubNetworkSession(results: [
            .success((
                Self.notificationsPayload(id: "1", updatedAt: "not-a-date").data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)

        let notifications = try await client.fetchNotifications(force: true)

        #expect(notifications.isEmpty)
    }

    @Test func olderConcurrentFetchDoesNotOverwriteNewerUnreadCache() async throws {
        let session = DelayedStubNetworkSession(results: [
            .success(
                payload: Self.notificationsPayload(id: "older").data(using: .utf8)!,
                response: HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT",
                        "X-Poll-Interval": "60",
                    ]
                )!,
                delayNanoseconds: 80_000_000
            ),
            .success(
                payload: Self.notificationsPayload(id: "newer").data(using: .utf8)!,
                response: HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:01:00 GMT",
                        "X-Poll-Interval": "60",
                    ]
                )!,
                delayNanoseconds: 0
            ),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)

        let olderTask = Task {
            try await client.fetchNotifications(all: false, force: true)
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        let newerTask = Task {
            try await client.fetchNotifications(all: false, force: true)
        }

        let older = try await olderTask.value
        let newer = try await newerTask.value
        let cached = try await client.fetchNotifications(all: false, force: false)

        #expect(older.map(\.id) == ["older"])
        #expect(newer.map(\.id) == ["newer"])
        #expect(cached.map(\.id) == ["newer"])
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let notifications = try await client.fetchNotifications(force: true)
        let requests = await session.recordedRequests()

        #expect(notifications.count == 2)
        #expect(requests.count == 2)
        #expect(requests.first?.url?.query?.contains("all=false") == true)
        #expect(requests.last?.url?.absoluteString.contains("page=2") == true)
        #expect(requests.first?.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func fetchNotificationsRejectsExternalLinkHeaderPaginationURL() async throws {
        let firstPage = Self.notificationsPayload(ids: ["1"]).data(using: .utf8)!

        let session = StubNetworkSession(results: [
            .success((
                firstPage,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications?page=1")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Link": #"<https://example.com/notifications?all=false&per_page=100&page=2>; rel="next""#,
                        "Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT",
                    ]
                )!
            )),
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)

        do {
            _ = try await client.fetchNotifications(force: true)
            Issue.record("Expected fetchNotifications to reject an external pagination URL")
        } catch GitHubAPIClient.APIError.untrustedGitHubAPIURL {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let requests = await session.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.url?.host == "api.github.com")
    }

    @Test func fetchNotificationsRejectsGitHubPaginationURLOnUnexpectedPort() async throws {
        let session = StubNetworkSession(results: [
            .success((
                Self.notificationsPayload(id: "1").data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Link": #"<https://api.github.com:8443/notifications?page=2>; rel="next""#,
                    ]
                )!
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)

        do {
            _ = try await client.fetchNotifications(force: true)
            Issue.record("Expected pagination on a custom port to be rejected")
        } catch GitHubAPIClient.APIError.untrustedGitHubAPIURL {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await session.recordedRequests().count == 1)
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
                #"{"state":"open","user":{"login":"octocat","avatar_url":"https://avatars.githubusercontent.com/u/1?v=4"}}"#.data(using: .utf8)!,
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let initial = try await client.fetchNotifications(force: true)
        let resolvedMetadata = await client.resolveSubjectMetadata(for: initial)
        let refreshed = try await client.fetchNotifications(force: true)
        let requests = await session.recordedRequests()

        #expect(initial.first?.subjectState == .unknown)
        #expect(resolvedMetadata["1"]?.state == .open)
        #expect(resolvedMetadata["1"]?.openerLogin == "octocat")
        #expect(resolvedMetadata["1"]?.openerAvatarURL?.absoluteString == "https://avatars.githubusercontent.com/u/1?v=4")
        #expect(resolvedMetadata["1"]?.hasResolvedOpener == true)
        #expect(resolvedMetadata["1"]?.hasResolvedCIStatus == true)
        #expect(refreshed.first?.subjectState == .open)
        #expect(refreshed.first?.openerLogin == "octocat")
        #expect(refreshed.first?.openerAvatarURL?.absoluteString == "https://avatars.githubusercontent.com/u/1?v=4")
        #expect(refreshed.first?.hasResolvedOpener == true)
        #expect(refreshed.first?.hasResolvedCIStatus == true)
        #expect(requests.count == 3)
    }

    @Test func resolvedAbsentCIIsSkippedUntilForcedRefresh() async {
        let graphQLPayload = """
        {
          "data": {
            "n0": {
              "pullRequest": {
                "id": "PR_node_42",
                "state": "OPEN",
                "isDraft": false,
                "mergedAt": null,
                "author": null,
                "commits": {
                  "nodes": [
                    { "commit": { "statusCheckRollup": null } }
                  ]
                }
              }
            }
          }
        }
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com/graphql")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [:]
        )!
        let session = StubNetworkSession(results: [
            .success((graphQLPayload, response)),
            .success((graphQLPayload, response)),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        var notification = GitHubNotification(
            id: "42",
            threadId: "42",
            title: "Pull request",
            repository: "acme/test",
            reason: .reviewRequested,
            type: .pullRequest,
            updatedAt: Date(),
            isUnread: true,
            url: URL(string: "https://github.com/acme/test/pull/42")!,
            subjectURL: "https://api.github.com/repos/acme/test/pulls/42",
            subjectState: .unknown
        )

        let initialMetadata = await client.resolveSubjectMetadata(for: [notification])
        let didApplyInitialMetadata = notification.apply(initialMetadata["42"]!)
        #expect(didApplyInitialMetadata)
        #expect(notification.ciStatus == nil)
        #expect(notification.hasResolvedCIStatus)

        let repeatedMetadata = await client.resolveSubjectMetadata(for: [notification])
        #expect(repeatedMetadata.isEmpty)
        #expect(await session.recordedRequests().count == 1)

        let forcedMetadata = await client.resolveSubjectMetadata(
            for: [notification],
            forceActiveSubjectRefresh: true
        )
        #expect(forcedMetadata["42"]?.hasResolvedCIStatus == true)
        #expect(await session.recordedRequests().count == 2)
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)

        let notifications = try await client.fetchNotifications(force: true)
        let resolvedMetadata = await client.resolveSubjectMetadata(for: notifications)
        let subjectRequests = session.recordedRequests().filter {
            $0.url?.path.contains("/repos/acme/test/") == true && $0.url?.path != "/notifications"
        }

        #expect(notifications.count == 3)
        #expect(subjectRequests.count == 3)
        #expect(subjectRequests.map(\.url?.path).contains("/repos/acme/test/pulls/1"))
        #expect(subjectRequests.map(\.url?.path).contains("/repos/acme/test/pulls/2"))
        #expect(subjectRequests.map(\.url?.path).contains("/repos/acme/test/issues/4"))
        #expect(subjectRequests.map(\.url?.path).contains("/repos/acme/test/discussions/3") == false)
        #expect(subjectRequests.map(\.url?.path).contains("/repos/acme/test/dependabot/alerts/5") == false)
        #expect(resolvedMetadata["1"]?.state == .open)
        #expect(resolvedMetadata["2"]?.state == .open)
        #expect(resolvedMetadata["4"]?.state == .open)
        #expect(resolvedMetadata["1"]?.openerLogin == "octocat")
        #expect(resolvedMetadata["4"]?.openerAvatarURL?.absoluteString == "https://avatars.githubusercontent.com/u/1?v=4")
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let notifications = try await client.fetchNotifications(force: true)
        let resolvedMetadata = await client.resolveSubjectMetadata(for: notifications)

        #expect(resolvedMetadata["1"]?.state == .merged)
    }

    @Test func resolveSubjectMetadataRefreshesOpenPullRequestWithExistingCIStatus() async throws {
        let notification = GitHubNotification(
            id: "426",
            threadId: "426",
            title: "Bump undici from 7.25.0 to 7.28.0",
            repository: "jasonlong/isometric-contributions",
            reason: .subscribed,
            type: .pullRequest,
            updatedAt: Date(),
            isUnread: false,
            url: URL(string: "https://github.com/jasonlong/isometric-contributions/pull/426")!,
            subjectURL: "https://api.github.com/repos/jasonlong/isometric-contributions/pulls/426",
            subjectState: .open,
            ciStatus: .success
        )
        let session = StubNetworkSession(results: [
            .success((
                #"{"state":"closed","merged":true}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/repos/jasonlong/isometric-contributions/pulls/426")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            ))
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let resolvedMetadata = await client.resolveSubjectMetadata(for: [notification])
        let requests = await session.recordedRequests()

        #expect(resolvedMetadata["426"]?.state == .merged)
        #expect(resolvedMetadata["426"]?.ciStatus == nil)
        #expect(requests.count == 1)
        #expect(requests.first?.url?.absoluteString == "https://api.github.com/repos/jasonlong/isometric-contributions/pulls/426")
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let notifications = try await client.fetchNotifications(force: true)
        let resolvedMetadata = await client.resolveSubjectMetadata(for: notifications)

        #expect(resolvedMetadata["1"]?.state == .draft)
    }

    @Test func resolveSubjectMetadataTreatsClosedDraftPullRequestAsClosed() async {
        let notification = GitHubNotification(
            id: "8688",
            threadId: "8688",
            title: "Closed draft pull request",
            repository: "acme/test",
            reason: .author,
            type: .pullRequest,
            updatedAt: .now,
            isUnread: false,
            url: URL(string: "https://github.com/acme/test/pull/8688")!,
            subjectURL: "https://api.github.com/repos/acme/test/pulls/8688",
            subjectState: .unknown
        )
        let session = StubNetworkSession(results: [
            .success((
                #"{"state":"closed","draft":true,"merged":false,"merged_at":null}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/repos/acme/test/pulls/8688")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)

        let metadata = await client.resolveSubjectMetadata(for: [notification])

        #expect(metadata["8688"]?.state == .closed)
    }

    @Test func resolveSubjectMetadataTreatsGraphQLDraftPullRequestAsDraft() async throws {
        let payload = Self.notificationsPayload(items: [
            NotificationFixture(
                id: "1",
                unread: false,
                subjectType: "PullRequest",
                subjectURL: "https://api.github.com/repos/acme/test/pulls/1"
            )
        ]).data(using: .utf8)!

        let graphQLPayload = """
        {
          "data": {
            "n0": {
              "pullRequest": {
                "id": "PR_node_1",
                "state": "OPEN",
                "isDraft": true,
                "mergedAt": null,
                "author": {
                  "login": "hubot",
                  "avatarUrl": "https://avatars.githubusercontent.com/u/2?v=4"
                },
                "commits": { "nodes": [] }
              }
            }
          }
        }
        """.data(using: .utf8)!

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
                graphQLPayload,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/graphql")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            ))
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let notifications = try await client.fetchNotifications(force: true)
        let resolvedMetadata = await client.resolveSubjectMetadata(for: notifications)
        let requests = await session.recordedRequests()

        #expect(resolvedMetadata["1"]?.state == .draft)
        #expect(resolvedMetadata["1"]?.nodeID == "PR_node_1")
        #expect(resolvedMetadata["1"]?.openerLogin == "hubot")
        #expect(resolvedMetadata["1"]?.openerAvatarURL?.absoluteString == "https://avatars.githubusercontent.com/u/2?v=4")
        #expect(resolvedMetadata["1"]?.hasResolvedOpener == true)
        #expect(requests.count == 2)
        #expect(requests[1].url?.path == "/graphql")
        let queryBody = requests[1].httpBody.flatMap { String(data: $0, encoding: .utf8) }
        #expect(queryBody?.contains("author") == true)
        #expect(queryBody?.contains("avatarUrl") == true)
    }

    @Test func forcedMetadataRefreshTreatsGraphQLClosedDraftPullRequestAsClosed() async {
        let notification = GitHubNotification(
            id: "8688",
            threadId: "8688",
            title: "Closed draft pull request",
            repository: "acme/test",
            reason: .author,
            type: .pullRequest,
            updatedAt: .now,
            isUnread: false,
            url: URL(string: "https://github.com/acme/test/pull/8688")!,
            subjectURL: "https://api.github.com/repos/acme/test/pulls/8688",
            subjectState: .draft,
            hasResolvedCIStatus: true,
            openerLogin: "hubot",
            hasResolvedOpener: true
        )
        let graphQLPayload = """
        {
          "data": {
            "n0": {
              "pullRequest": {
                "id": "PR_node_8688",
                "state": "CLOSED",
                "isDraft": true,
                "mergedAt": null,
                "author": {
                  "login": "hubot",
                  "avatarUrl": "https://avatars.githubusercontent.com/u/2?v=4"
                },
                "commits": { "nodes": [] }
              }
            }
          }
        }
        """.data(using: .utf8)!
        let session = StubNetworkSession(results: [
            .success((
                graphQLPayload,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/graphql")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            ))
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session)

        let metadata = await client.resolveSubjectMetadata(
            for: [notification],
            forceActiveSubjectRefresh: true
        )

        #expect(metadata["8688"]?.state == .closed)
        #expect(await session.recordedRequests().count == 1)
    }

    @Test func resolveSubjectMetadataIncludesGraphQLIssueOpener() async throws {
        let payload = Self.notificationsPayload(items: [
            NotificationFixture(
                id: "42",
                unread: true,
                subjectType: "Issue",
                subjectURL: "https://api.github.com/repos/acme/test/issues/42"
            )
        ]).data(using: .utf8)!
        let graphQLPayload = """
        {
          "data": {
            "n0": {
              "issue": {
                "id": "I_node_42",
                "state": "OPEN",
                "stateReason": null,
                "author": {
                  "login": "monalisa",
                  "avatarUrl": "https://avatars.githubusercontent.com/u/3?v=4"
                }
              }
            }
          }
        }
        """.data(using: .utf8)!
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
                graphQLPayload,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/graphql")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            ))
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let notifications = try await client.fetchNotifications(force: true)
        let metadata = await client.resolveSubjectMetadata(for: notifications)["42"]

        #expect(metadata?.state == .open)
        #expect(metadata?.nodeID == "I_node_42")
        #expect(metadata?.openerLogin == "monalisa")
        #expect(metadata?.openerAvatarURL?.absoluteString == "https://avatars.githubusercontent.com/u/3?v=4")
        #expect(metadata?.hasResolvedOpener == true)
    }

    @Test func resolveSubjectMetadataPreservesPartialGraphQLDataAndFallsBackOnlyUnresolvedAlias() async {
        let graphQLPayload = """
        {
          "data": {
            "n0": {
              "issue": {
                "id": "I_node_1",
                "state": "OPEN",
                "stateReason": null,
                "author": null
              }
            },
            "n1": { "issue": null }
          },
          "errors": [
            { "message": "Issue not found", "path": ["n1", "issue"] }
          ]
        }
        """.data(using: .utf8)!
        let restPayload = #"{"state":"closed","state_reason":"not_planned","user":{"login":"octocat"}}"#.data(using: .utf8)!
        let session = StubNetworkSession(results: [
            .success((
                graphQLPayload,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/graphql")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
            .success((
                restPayload,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/repos/acme/test/issues/2")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session)

        let metadata = await client.resolveSubjectMetadata(for: [
            Self.metadataIssue(id: "1", number: 1),
            Self.metadataIssue(id: "2", number: 2),
        ])
        let requests = await session.recordedRequests()

        #expect(metadata["1"]?.state == .open)
        #expect(metadata["1"]?.nodeID == "I_node_1")
        #expect(metadata["2"]?.state == .closedNotPlanned)
        #expect(metadata["2"]?.openerLogin == "octocat")
        #expect(requests.count == 2)
        #expect(requests.first?.url?.path == "/graphql")
        #expect(requests.last?.url?.path == "/repos/acme/test/issues/2")
        #expect(await client.takeNonFatalWarningMessage() == nil)
    }

    @Test func resolveSubjectMetadataFallsBackForNullGraphQLRepositoryAlias() async {
        let graphQLPayload = #"{"data":{"n0":null}}"#.data(using: .utf8)!
        let restPayload = #"{"state":"open","user":null}"#.data(using: .utf8)!
        let session = StubNetworkSession(results: [
            .success((
                graphQLPayload,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/graphql")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
            .success((
                restPayload,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/repos/acme/test/issues/1")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session)

        let metadata = await client.resolveSubjectMetadata(
            for: [Self.metadataIssue(id: "1", number: 1)]
        )
        let requests = await session.recordedRequests()

        #expect(metadata["1"]?.state == .open)
        #expect(requests.count == 2)
        #expect(requests.last?.url?.path == "/repos/acme/test/issues/1")
        #expect(await client.takeNonFatalWarningMessage() == nil)
    }

    @Test func resolveSubjectMetadataFallsBackAfterTotalGraphQLTransportFailure() async {
        let restPayload = #"{"state":"closed","state_reason":"completed","user":null}"#.data(using: .utf8)!
        let session = StubNetworkSession(results: [
            .failure(GitHubAPIClient.APIError.forbidden),
            .success((
                restPayload,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/repos/acme/test/issues/1")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session)

        let metadata = await client.resolveSubjectMetadata(
            for: [Self.metadataIssue(id: "1", number: 1)]
        )
        let requests = await session.recordedRequests()

        #expect(metadata["1"]?.state == .closed)
        #expect(requests.count == 2)
        #expect(requests.first?.url?.path == "/graphql")
        #expect(requests.last?.url?.path == "/repos/acme/test/issues/1")
        #expect(await client.takeNonFatalWarningMessage() == nil)
    }

    @Test func resolveSubjectMetadataCancellationDoesNotStartRESTFallback() async {
        let graphQLPayload = """
        {
          "data": {
            "n0": {
              "issue": {
                "id": "I_node_1",
                "state": "OPEN",
                "stateReason": null,
                "author": null
              }
            }
          }
        }
        """.data(using: .utf8)!
        let session = GatedStubNetworkSession(results: [
            .success((
                graphQLPayload,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/graphql")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        let notification = Self.metadataIssue(id: "1", number: 1)

        let resolution = Task {
            await client.resolveSubjectMetadata(for: [notification])
        }
        await session.waitUntilRequestCount(1)
        resolution.cancel()
        await session.releaseRequest(at: 0)
        let metadata = await resolution.value

        #expect(metadata.isEmpty)
        #expect(await session.recordedRequests().count == 1)
        #expect(await client.takeNonFatalWarningMessage() == nil)
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let notifications = try await client.fetchNotifications(force: true)
        let resolvedMetadata = await client.resolveSubjectMetadata(for: notifications)
        let warning = await client.takeNonFatalWarningMessage()

        #expect(resolvedMetadata["1"]?.state == .unknown)
        #expect(warning == GitHubAPIClient.subjectMetadataWarningMessage)
        #expect(await client.takeNonFatalWarningMessage() == nil)
    }

    @Test func resolveSubjectMetadataDoesNotFetchExternalSubjectURL() async throws {
        let notification = GitHubNotification(
            id: "1",
            threadId: "1",
            title: "External subject",
            repository: "acme/test",
            reason: .reviewRequested,
            type: .pullRequest,
            updatedAt: Date(),
            isUnread: true,
            url: URL(string: "https://github.com/acme/test/pull/1")!,
            subjectURL: "https://example.com/repos/acme/test/pulls/1",
            subjectState: .unknown
        )
        let session = StubNetworkSession(results: [])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)

        let resolvedMetadata = await client.resolveSubjectMetadata(for: [notification])
        let requests = await session.recordedRequests()

        #expect(resolvedMetadata["1"]?.state == .unknown)
        #expect(requests.isEmpty)
    }

    @Test func resolveSubjectMetadataRejectsUnexpectedGitHubAPIPath() async throws {
        let notification = GitHubNotification(
            id: "1",
            threadId: "1",
            title: "Malformed subject",
            repository: "acme/test",
            reason: .reviewRequested,
            type: .pullRequest,
            updatedAt: Date(),
            isUnread: true,
            url: URL(string: "https://github.com/acme/test/pull/1")!,
            subjectURL: "https://api.github.com/repos/acme/test/pulls/1/comments",
            subjectState: .unknown
        )
        let session = StubNetworkSession(results: [])
        let client = GitHubAPIClient(token: "ghp_secret", session: session)

        let metadata = await client.resolveSubjectMetadata(for: [notification])

        #expect(metadata["1"]?.state == .unknown)
        #expect(await session.recordedRequests().isEmpty)
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let notifications = try await client.fetchNotifications(force: true)
        let resolvedMetadata = await client.resolveSubjectMetadata(for: notifications)
        let warning = await client.takeNonFatalWarningMessage()

        #expect(resolvedMetadata["1"]?.state == .open)
        #expect(resolvedMetadata["1"]?.ciStatus == nil)
        #expect(resolvedMetadata["1"]?.hasResolvedCIStatus == false)
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let initial = try await client.fetchNotifications(force: true)
        let resolvedMetadata = await client.resolveSubjectMetadata(for: initial)
        let refreshed = try await client.fetchNotifications(force: true)

        #expect(resolvedMetadata["1"]?.ciStatus == .pending)
        #expect(refreshed.first?.ciStatus == .pending)
    }

    @Test func fetchNotificationsIncludesOnlyIssuesAndPullRequests() async throws {
        let payload = Self.notificationsPayload(items: [
            NotificationFixture(
                id: "issue-1",
                unread: true,
                subjectType: "Issue",
                subjectURL: "https://api.github.com/repos/acme/test/issues/1"
            ),
            NotificationFixture(
                id: "pr-1",
                unread: true,
                subjectType: "PullRequest",
                subjectURL: "https://api.github.com/repos/acme/test/pulls/1"
            ),
            NotificationFixture(
                id: "sec-1",
                unread: true,
                reason: "security_alert",
                title: "GHSA-532v-xpq5-8h95",
                subjectType: "RepositoryVulnerabilityAlert",
                subjectURL: "https://api.github.com/repos/electron/electron/dependabot/alerts/1",
                repositoryFullName: "electron/electron",
                repositoryHTMLURL: "https://github.com/electron/electron"
            ),
            NotificationFixture(
                id: "release-1",
                unread: true,
                subjectType: "Release",
                subjectURL: "https://api.github.com/repos/acme/test/releases/1"
            ),
            NotificationFixture(
                id: "unknown-1",
                unread: true,
                subjectType: "CheckSuite",
                subjectURL: nil
            ),
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let notifications = try await client.fetchNotifications(force: true)

        #expect(Set(notifications.map(\.id)) == Set(["issue-1", "pr-1"]))
        #expect(notifications.allSatisfy { $0.isIssueOrPullRequest })
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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

    @Test func cacheInvalidationPreventsInFlightFetchFromRepopulatingUnreadCache() async throws {
        let session = DelayedStubNetworkSession(results: [
            .success(
                payload: Self.notificationsPayload(id: "stale").data(using: .utf8)!,
                response: HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications?all=false")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:00:00 GMT",
                        "X-Poll-Interval": "60",
                    ]
                )!,
                delayNanoseconds: 80_000_000
            ),
            .success(
                payload: Data(),
                response: HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications/threads/stale")!,
                    statusCode: 205,
                    httpVersion: nil,
                    headerFields: [:]
                )!,
                delayNanoseconds: 0
            ),
            .success(
                payload: Self.notificationsPayload(id: "fresh").data(using: .utf8)!,
                response: HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications?all=false")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Last-Modified": "Wed, 01 Apr 2026 12:05:00 GMT",
                        "X-Poll-Interval": "60",
                    ]
                )!,
                delayNanoseconds: 0
            ),
        ])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)

        let staleFetch = Task {
            try await client.fetchNotifications(all: false, force: true)
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        try await client.markAsRead(threadId: "stale")
        let stale = try await staleFetch.value
        let refreshed = try await client.fetchNotifications(all: false, force: false)

        #expect(stale.map(\.id) == ["stale"])
        #expect(refreshed.map(\.id) == ["fresh"])
    }

    @Test func threadActionsRejectPathTraversalIdentifiersWithoutNetworking() async throws {
        let session = StubNetworkSession(results: [])
        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)

        do {
            try await client.markAsRead(threadId: "../user")
            Issue.record("Expected an invalid thread identifier to be rejected")
        } catch GitHubAPIClient.APIError.invalidThreadID {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await session.recordedRequests().isEmpty)
    }

    @Test func markAsReadMapsRevokedCredentialsToUnauthorized() async {
        let session = StubNetworkSession(results: [
            .success((
                Data(),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications/threads/1")!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            ))
        ])
        let client = GitHubAPIClient(token: "revoked", session: session, useGraphQLForSubjectMetadata: false)

        do {
            try await client.markAsRead(threadId: "1")
            Issue.record("Expected revoked credentials to be reported as unauthorized")
        } catch GitHubAPIClient.APIError.unauthorized {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func unsubscribeIgnoresFutureUpdatesWithoutRemovingThreadFromInbox() async throws {
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
            ))
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        try await client.unsubscribe(notification: notification)
        let requests = await session.recordedRequests()
        let request = try #require(requests.first)
        let body = try #require(request.httpBody)
        let bodyObject = try #require(JSONSerialization.jsonObject(with: body) as? [String: Bool])

        #expect(requests.count == 1)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/notifications/threads/thread-1/subscription")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(bodyObject["ignored"] == true)
        #expect(bodyObject["subscribed"] == nil)
    }

    @Test func unsubscribeFallsBackToRESTWhenGraphQLReturnsErrors() async throws {
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
            subjectState: .open,
            graphQLNodeID: "PR_node_1"
        )
        let session = StubNetworkSession(results: [
            .success((
                #"{"data":{"updateSubscription":null},"errors":[{"message":"failed"}]}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/graphql")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
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
            ))
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)
        try await client.unsubscribe(notification: notification)
        let requests = await session.recordedRequests()

        #expect(requests.count == 2)
        #expect(requests[0].url?.path == "/graphql")
        #expect(requests[1].httpMethod == "PUT")
        #expect(requests[1].url?.path == "/notifications/threads/thread-1/subscription")
    }

    @Test func unsubscribeGraphQLMapsRevokedCredentialsToUnauthorizedWithoutRESTFallback() async {
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
            subjectState: .open,
            graphQLNodeID: "PR_node_1"
        )
        let session = StubNetworkSession(results: [
            .success((
                Data(),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/graphql")!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            ))
        ])
        let client = GitHubAPIClient(token: "revoked", session: session)

        do {
            try await client.unsubscribe(notification: notification)
            Issue.record("Expected revoked credentials to be reported as unauthorized")
        } catch GitHubAPIClient.APIError.unauthorized {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await session.recordedRequests().count == 1)
    }

    @Test func unsubscribeRESTMapsRevokedCredentialsToUnauthorized() async {
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
                Data(),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications/threads/thread-1/subscription")!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            ))
        ])
        let client = GitHubAPIClient(token: "revoked", session: session)

        do {
            try await client.unsubscribe(notification: notification)
            Issue.record("Expected revoked credentials to be reported as unauthorized")
        } catch GitHubAPIClient.APIError.unauthorized {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func unsubscribeThrowsWhenGraphQLErrorsAndRESTFallbackFails() async throws {
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
            subjectState: .open,
            graphQLNodeID: "PR_node_1"
        )
        let session = StubNetworkSession(results: [
            .success((
                #"{"data":{"updateSubscription":null},"errors":[{"message":"failed"}]}"#.data(using: .utf8)!,
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/graphql")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )),
            .success((
                Data(),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications/threads/thread-1/subscription")!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            ))
        ])

        let client = GitHubAPIClient(token: "ghp_secret", session: session)

        do {
            try await client.unsubscribe(notification: notification)
            Issue.record("Expected unsubscribe to throw when GraphQL and REST fallback both fail")
        } catch GitHubAPIClient.APIError.httpError(let status) {
            #expect(status == 500)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let requests = await session.recordedRequests()
        #expect(requests.count == 2)
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
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

    @Test func markAsDoneMapsRevokedCredentialsToUnauthorized() async {
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
                Data(),
                HTTPURLResponse(
                    url: URL(string: "https://api.github.com/notifications/threads/thread-1")!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            ))
        ])
        let client = GitHubAPIClient(token: "revoked", session: session, useGraphQLForSubjectMetadata: false)

        do {
            try await client.markAsDone(notification: notification)
            Issue.record("Expected revoked credentials to be reported as unauthorized")
        } catch GitHubAPIClient.APIError.unauthorized {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func unsubscribeThenDoneInvalidatesCacheWithoutReusingLocallyPrunedUnreadFeed() async throws {
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

        let client = GitHubAPIClient(token: "ghp_secret", session: session, useGraphQLForSubjectMetadata: false)
        let initial = try await client.fetchNotifications(all: false, force: true)
        try await client.unsubscribe(notification: notification)
        try await client.markAsDone(notification: notification)
        let refreshed = try await client.fetchNotifications(all: false, force: false)
        let requests = await session.recordedRequests()

        #expect(initial.map(\.id) == ["2", "1"])
        #expect(refreshed.map(\.id) == ["3", "2"])
        #expect(requests.count == 4)
        #expect(requests[3].httpMethod == "GET")
        #expect(requests[3].value(forHTTPHeaderField: "If-Modified-Since") == nil)
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

}
