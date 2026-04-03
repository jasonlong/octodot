import Foundation

protocol NetworkSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: NetworkSession {}

actor GitHubAPIClient {
    private let baseURL = URL(string: "https://api.github.com")!
    private let notificationsPerPage = 100
    private let defaultPollInterval: TimeInterval = 60
    private let defaultRecentInboxMaxPages = 2
    private let defaultSecurityRefreshInterval: TimeInterval = 5 * 60
    private let defaultSecurityLookbackInterval: TimeInterval = 14 * 24 * 60 * 60
    private let maxConcurrentSubjectRequests: Int
    private let maxConcurrentSecurityRequests: Int
    private let maxSubjectResolutionBatchSize = 40
    private let session: any NetworkSession
    private var token: String

    private enum FeedScope: CaseIterable {
        case unread
        case all
        case inbox

        init(all: Bool) {
            self = all ? .all : .unread
        }
    }

    private struct FeedCache {
        var notifications: [GitHubNotification] = []
        var lastModifiedValue: String?
        var nextNotificationsRefreshAt = Date.distantPast
    }

    private struct SecurityAlertsCache {
        var alerts: [GitHubNotification] = []
        var sourceSignature = ""
        var nextRefreshAt = Date.distantPast
    }

    private var cachedFeeds: [FeedScope: FeedCache] = [:]
    private var cachedDependabotAlerts = SecurityAlertsCache()

    private struct SubjectRequestContext: Sendable {
        let token: String
        let session: any NetworkSession
    }

    init(
        token: String,
        session: any NetworkSession = URLSession.shared,
        maxConcurrentSubjectRequests: Int = 6,
        maxConcurrentSecurityRequests: Int = 4
    ) {
        self.token = token
        self.session = session
        self.maxConcurrentSubjectRequests = max(1, maxConcurrentSubjectRequests)
        self.maxConcurrentSecurityRequests = max(1, maxConcurrentSecurityRequests)
    }

    func updateToken(_ token: String) {
        self.token = token
        cachedFeeds.removeAll()
        cachedDependabotAlerts = SecurityAlertsCache()
    }

    // MARK: - Fetch notifications

    func fetchNotifications(all: Bool = false, force: Bool = false) async throws -> [GitHubNotification] {
        try await fetchNotifications(
            scope: FeedScope(all: all),
            all: all,
            since: nil,
            force: force,
            maxPages: nil
        )
    }

    func fetchRecentInboxNotifications(
        since: Date,
        force: Bool = false,
        maxPages: Int? = nil
    ) async throws -> [GitHubNotification] {
        try await fetchNotifications(
            scope: .inbox,
            all: true,
            since: since,
            force: force,
            maxPages: maxPages ?? defaultRecentInboxMaxPages
        )
    }

    func fetchDependabotAlerts(
        repositoryNames: [String],
        currentUsername _: String?,
        force: Bool = false
    ) async throws -> [GitHubNotification] {
        let repositories = Array(Set(repositoryNames)).sorted()
        let signature = repositories.joined(separator: ",")

        if !force,
           cachedDependabotAlerts.sourceSignature == signature,
           Date() < cachedDependabotAlerts.nextRefreshAt {
            return cachedDependabotAlerts.alerts
        }

        guard !repositories.isEmpty else {
            cachedDependabotAlerts = SecurityAlertsCache()
            return []
        }

        DebugTrace.log(
            "security fetch start repos=\(repositories.joined(separator: ",")) force=\(force)"
        )

        let alerts = try await fetchDependabotAlertsForRepositories(repositories)

        let deduped = Self.sortedAndDedupedAlerts(alerts)
        let recentAlerts = Self.recentAlerts(
            from: deduped,
            lookbackInterval: defaultSecurityLookbackInterval
        )
        cachedDependabotAlerts = SecurityAlertsCache(
            alerts: recentAlerts,
            sourceSignature: signature,
            nextRefreshAt: Date().addingTimeInterval(defaultSecurityRefreshInterval)
        )
        DebugTrace.log(
            "security fetch complete raw=\(deduped.count) recent=\(recentAlerts.count) top=\(Self.topIDs(in: recentAlerts))"
        )
        return recentAlerts
    }

    private func fetchNotifications(
        scope: FeedScope,
        all: Bool,
        since: Date?,
        force: Bool,
        maxPages: Int?
    ) async throws -> [GitHubNotification] {
        let cachedFeed = feedCache(for: scope)
        var shouldUseConditionalRequest = !force && cachedFeed.lastModifiedValue != nil
        DebugTrace.log(
            "fetch start scope=\(Self.debugName(for: scope)) force=\(force) " +
            "cached.count=\(cachedFeed.notifications.count) ifModified=\(cachedFeed.lastModifiedValue ?? "nil")"
        )

        if !force,
           !cachedFeed.notifications.isEmpty,
           Date() < cachedFeed.nextNotificationsRefreshAt {
            DebugTrace.log(
                "fetch cache-hit scope=\(Self.debugName(for: scope)) count=\(cachedFeed.notifications.count) " +
                "top=\(Self.topIDs(in: cachedFeed.notifications))"
            )
            return cachedFeed.notifications
        }

        var apiItems: [APINotification] = []
        var lastModifiedFromResponse: String?
        var page = 1
        let maximumPages = maxPages.map { max(1, $0) }
        var currentURL: URL? = notificationsURL(all: all, page: page, since: since)

        while let requestURL = currentURL {
            var request = makeNotificationsRequest(url: requestURL)
            if page == 1,
               shouldUseConditionalRequest,
               let lastModifiedValue = cachedFeed.lastModifiedValue {
                request.setValue(lastModifiedValue, forHTTPHeaderField: "If-Modified-Since")
            }

            let (data, response) = try await session.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let status = httpResponse?.statusCode ?? 0
            DebugTrace.log(
                "fetch response scope=\(Self.debugName(for: scope)) page=\(page) status=\(status) " +
                "ifModified=\(request.value(forHTTPHeaderField: "If-Modified-Since") ?? "nil")"
            )

            if page == 1 {
                updatePollingHeaders(from: httpResponse, scope: scope)
            }

            switch status {
            case 200...299:
                if page == 1,
                   shouldUseConditionalRequest {
                    DebugTrace.log(
                        "fetch conditional-hit scope=\(Self.debugName(for: scope)) " +
                        "decoded.count=pending refetch-full-snapshot=true"
                    )
                    shouldUseConditionalRequest = false
                    apiItems.removeAll()
                    lastModifiedFromResponse = nil
                    page = 1
                    currentURL = notificationsURL(all: all, page: 1, since: since)
                    continue
                }

                if page == 1 {
                    lastModifiedFromResponse = httpResponse?.value(forHTTPHeaderField: "Last-Modified")
                }

                let pageItems = try JSONDecoder.github.decode([APINotification].self, from: data)
                DebugTrace.log(
                    "fetch page scope=\(Self.debugName(for: scope)) page=\(page) decoded.count=\(pageItems.count) " +
                    "decoded.top=\(Self.topIDs(in: pageItems.map(\.id))) link=\(httpResponse?.value(forHTTPHeaderField: "Link") ?? "nil")"
                )
                apiItems.append(contentsOf: pageItems)

                if let nextPageURL = nextPageURL(from: httpResponse),
                   maximumPages.map({ page < $0 }) ?? true {
                    currentURL = nextPageURL
                    page += 1
                    continue
                }

                if pageItems.count == notificationsPerPage,
                   maximumPages.map({ page < $0 }) ?? true {
                    page += 1
                    currentURL = notificationsURL(all: all, page: page, since: since)
                    continue
                }

                updateFeedCache(scope) { cache in
                    cache.lastModifiedValue = lastModifiedFromResponse
                }
                currentURL = nil

            case 304 where page == 1:
                DebugTrace.log(
                    "fetch not-modified scope=\(Self.debugName(for: scope)) cached.count=\(cachedFeed.notifications.count) " +
                    "top=\(Self.topIDs(in: cachedFeed.notifications))"
                )
                return cachedFeed.notifications
            case 401:
                throw APIError.unauthorized
            case 403:
                throw APIError.forbidden
            case 429:
                throw APIError.rateLimited
            default:
                throw APIError.httpError(status)
            }
        }

        var notifications = apiItems.compactMap { $0.toModel() }
        notifications.sort { $0.updatedAt > $1.updatedAt }
        let previousNotifications = Dictionary(uniqueKeysWithValues: cachedFeed.notifications.map { ($0.id, $0) })

        for index in notifications.indices {
            guard notifications[index].subjectURL != nil else { continue }

            if let previous = previousNotifications[notifications[index].id],
               previous.updatedAt == notifications[index].updatedAt {
                notifications[index].subjectState = previous.subjectState
                notifications[index].ciStatus = previous.ciStatus
            }
        }

        updateFeedCache(scope) { cache in
            cache.notifications = notifications
            cache.lastModifiedValue = lastModifiedFromResponse
        }
        DebugTrace.log(
            "fetch complete scope=\(Self.debugName(for: scope)) count=\(notifications.count) " +
            "top=\(Self.topIDs(in: notifications)) bodyHint=\(Self.debugFeedHint(for: notifications))"
        )
        return notifications
    }

    func resolveSubjectMetadata(
        for notifications: [GitHubNotification]
    ) async -> [String: GitHubNotification.SubjectMetadata] {
        let pendingSubjectNotifications = notifications
            .filter(Self.shouldResolveSubjectMetadata)
            .prefix(maxSubjectResolutionBatchSize)
        let candidateNotifications = Array(pendingSubjectNotifications)
        guard !candidateNotifications.isEmpty else { return [:] }

        let subjectRequestContext = SubjectRequestContext(token: token, session: session)
        let subjectMetadataByID = await Self.fetchSubjectMetadata(
            for: candidateNotifications,
            maxConcurrent: maxConcurrentSubjectRequests,
            context: subjectRequestContext
        )

        guard !subjectMetadataByID.isEmpty else { return [:] }

        for scope in FeedScope.allCases {
            updateFeedCache(scope) { cache in
                for index in cache.notifications.indices {
                    if let metadata = subjectMetadataByID[cache.notifications[index].id] {
                        cache.notifications[index].subjectState = metadata.state
                        cache.notifications[index].ciStatus = metadata.ciStatus
                    }
                }
            }
        }

        return subjectMetadataByID
    }

    // MARK: - Fetch subject metadata

    private static func fetchSubjectMetadata(
        for notifications: [GitHubNotification],
        maxConcurrent: Int,
        context: SubjectRequestContext
    ) async -> [String: GitHubNotification.SubjectMetadata] {
        guard !notifications.isEmpty else { return [:] }

        let concurrencyLimit = max(1, min(maxConcurrent, notifications.count))
        var iterator = notifications.makeIterator()
        var subjectMetadataByID: [String: GitHubNotification.SubjectMetadata] = [:]

        await withTaskGroup(of: (String, GitHubNotification.SubjectMetadata).self) { group in
            for _ in 0..<concurrencyLimit {
                guard let notification = iterator.next(),
                      let subjectURL = notification.subjectURL else {
                    break
                }

                let id = notification.id
                group.addTask {
                    let metadata = await Self.fetchSubjectMetadata(apiURL: subjectURL, context: context)
                    return (id, metadata)
                }
            }

            while let (id, metadata) = await group.next() {
                subjectMetadataByID[id] = metadata

                guard let notification = iterator.next(),
                      let subjectURL = notification.subjectURL else {
                    continue
                }

                let id = notification.id
                group.addTask {
                    let metadata = await Self.fetchSubjectMetadata(apiURL: subjectURL, context: context)
                    return (id, metadata)
                }
            }
        }

        return subjectMetadataByID
    }

    private static func fetchSubjectMetadata(
        apiURL: String,
        context: SubjectRequestContext
    ) async -> GitHubNotification.SubjectMetadata {
        guard let url = URL(string: apiURL) else { return .init(state: .unknown, ciStatus: nil) }
        do {
            let data = try await request(url: url, token: context.token, session: context.session)
            let subject = try JSONDecoder.github.decode(APISubjectState.self, from: data)
            let resolvedState = subject.resolvedState
            let ciStatus: GitHubNotification.CIStatus?
            if resolvedState == .open, let headSHA = subject.head?.sha {
                ciStatus = await fetchCIStatus(subjectURL: url, headSHA: headSHA, context: context)
            } else {
                ciStatus = nil
            }
            return .init(state: resolvedState, ciStatus: ciStatus)
        } catch {
            return .init(state: .unknown, ciStatus: nil)
        }
    }

    private static func fetchCIStatus(
        subjectURL: URL,
        headSHA: String,
        context: SubjectRequestContext
    ) async -> GitHubNotification.CIStatus? {
        let repositoryAPIURL = subjectURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        var checkRunsComponents = URLComponents(
            url: repositoryAPIURL
                .appendingPathComponent("commits")
                .appendingPathComponent(headSHA)
                .appendingPathComponent("check-runs"),
            resolvingAgainstBaseURL: false
        )
        checkRunsComponents?.queryItems = [URLQueryItem(name: "per_page", value: "100")]

        if let checkRunsURL = checkRunsComponents?.url,
           let data = try? await request(url: checkRunsURL, token: context.token, session: context.session),
           let response = try? JSONDecoder.github.decode(APICheckRunsResponse.self, from: data),
           let status = response.resolvedCIStatus {
            return status
        }

        let combinedStatusURL = repositoryAPIURL
            .appendingPathComponent("commits")
            .appendingPathComponent(headSHA)
            .appendingPathComponent("status")
        if let data = try? await request(url: combinedStatusURL, token: context.token, session: context.session),
           let response = try? JSONDecoder.github.decode(APICombinedStatus.self, from: data) {
            return response.resolvedCIStatus
        }

        return nil
    }

    private static func shouldResolveSubjectMetadata(_ notification: GitHubNotification) -> Bool {
        notification.needsSubjectMetadataResolution
    }

    private func fetchDependabotAlertsForRepository(_ repositoryFullName: String) async throws -> [GitHubNotification] {
        let parts = repositoryFullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return [] }
        var components = URLComponents(url: baseURL.appendingPathComponent("repos/\(parts[0])/\(parts[1])/dependabot/alerts"), resolvingAgainstBaseURL: false)!
        components.queryItems = Self.dependabotAlertsQueryItems
        let url = components.url!
        let data = try await request(url: url)
        let alerts = try JSONDecoder.github.decode([APIDependabotAlert].self, from: data)
        return alerts.compactMap {
            $0.toModel(
                fallbackRepositoryFullName: repositoryFullName,
                fallbackRepositoryHTMLURL: "https://github.com/\(repositoryFullName)"
            )
        }
    }

    private func fetchDependabotAlertsForRepositories(_ repositories: [String]) async throws -> [GitHubNotification] {
        let concurrencyLimit = max(1, min(maxConcurrentSecurityRequests, repositories.count))
        var iterator = repositories.makeIterator()
        var collectedAlerts: [GitHubNotification] = []

        try await withThrowingTaskGroup(of: [GitHubNotification].self) { group in
            for _ in 0..<concurrencyLimit {
                guard let repository = iterator.next() else { break }
                group.addTask { [weak self] in
                    guard let self else { return [] }
                    return try await self.fetchDependabotAlertsForRepositoryIgnoringUnsupported(repository)
                }
            }

            while let nextAlerts = try await group.next() {
                collectedAlerts.append(contentsOf: nextAlerts)

                guard let repository = iterator.next() else { continue }
                group.addTask { [weak self] in
                    guard let self else { return [] }
                    return try await self.fetchDependabotAlertsForRepositoryIgnoringUnsupported(repository)
                }
            }
        }

        return collectedAlerts
    }

    private func fetchDependabotAlertsForRepositoryIgnoringUnsupported(_ repositoryFullName: String) async throws -> [GitHubNotification] {
        do {
            return try await fetchDependabotAlertsForRepository(repositoryFullName)
        } catch APIError.forbidden {
            DebugTrace.log("security fetch skipped repo=\(repositoryFullName) reason=forbidden")
            return []
        } catch APIError.httpError(let status) where status == 404 {
            DebugTrace.log("security fetch skipped repo=\(repositoryFullName) reason=http-\(status)")
            return []
        }
    }

    // MARK: - Mark as read

    func markAsRead(threadId: String) async throws {
        let traceID = UUID().uuidString
        let url = baseURL.appendingPathComponent("notifications/threads/\(threadId)")
        var req = makeRequest(url: url)
        req.httpMethod = "PATCH"
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        logActionResponse(traceID: traceID, action: "mark-read", step: "patch-thread", threadId: threadId, request: req, response: response, data: data)
        guard (200...299).contains(status) || status == 304 else {
            throw APIError.markReadFailed(status)
        }
        invalidateFeedCaches(FeedScope.allCases)
    }

    func markAsDone(notification: GitHubNotification) async throws {
        let traceID = UUID().uuidString
        let url = baseURL.appendingPathComponent("notifications/threads/\(notification.threadId)")
        var req = makeRequest(url: url)
        req.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        logActionResponse(traceID: traceID, action: "done", step: "delete-thread", threadId: notification.threadId, request: req, response: response, data: data)
        guard (200...299).contains(status) || status == 304 else {
            throw APIError.httpError(status)
        }
        invalidateFeedCaches(FeedScope.allCases)
    }

    func unsubscribe(notification: GitHubNotification) async throws {
        let traceID = UUID().uuidString
        let subscriptionURL = baseURL.appendingPathComponent("notifications/threads/\(notification.threadId)/subscription")
        var subscriptionRequest = makeRequest(url: subscriptionURL)
        subscriptionRequest.httpMethod = "PUT"
        subscriptionRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        subscriptionRequest.httpBody = try JSONEncoder().encode(ThreadSubscriptionRequest(ignored: true))
        let (subscriptionData, subscriptionResponse) = try await session.data(for: subscriptionRequest)
        let subscriptionStatus = (subscriptionResponse as? HTTPURLResponse)?.statusCode ?? 0
        logActionResponse(traceID: traceID, action: "unsubscribe", step: "ignore-thread", threadId: notification.threadId, request: subscriptionRequest, response: subscriptionResponse, data: subscriptionData)
        guard (200...299).contains(subscriptionStatus) || subscriptionStatus == 304 else {
            throw APIError.httpError(subscriptionStatus)
        }

        let doneURL = baseURL.appendingPathComponent("notifications/threads/\(notification.threadId)")
        var doneRequest = makeRequest(url: doneURL)
        doneRequest.httpMethod = "DELETE"
        let (doneData, doneResponse) = try await session.data(for: doneRequest)
        let doneStatus = (doneResponse as? HTTPURLResponse)?.statusCode ?? 0
        logActionResponse(traceID: traceID, action: "unsubscribe", step: "remove-from-inbox", threadId: notification.threadId, request: doneRequest, response: doneResponse, data: doneData)
        guard (200...299).contains(doneStatus) || doneStatus == 304 else {
            throw APIError.httpError(doneStatus)
        }

        invalidateFeedCaches(FeedScope.allCases)
    }

    func restoreSubscription(threadId: String, notification _: GitHubNotification) async throws {
        let traceID = UUID().uuidString
        let url = baseURL.appendingPathComponent("notifications/threads/\(threadId)/subscription")
        var req = makeRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(ThreadSubscriptionRequest(ignored: false))

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        logActionResponse(traceID: traceID, action: "restore-subscription", step: "restore-thread", threadId: threadId, request: req, response: response, data: data)
        guard (200...299).contains(status) else {
            throw APIError.httpError(status)
        }

        invalidateFeedCaches(FeedScope.allCases)
    }

    // MARK: - Validate token

    func validateToken() async throws -> String {
        let url = baseURL.appendingPathComponent("user")
        let data = try await request(url: url)
        let user = try JSONDecoder.github.decode(APIUser.self, from: data)
        return user.login
    }

    func suggestedRefreshDelayNanoseconds() -> UInt64 {
        let nextRefreshAt = cachedFeeds.values
            .map(\.nextNotificationsRefreshAt)
            .min() ?? .distantPast
        let secondsUntilRefresh = nextRefreshAt.timeIntervalSinceNow
        let delaySeconds = secondsUntilRefresh > 0 ? secondsUntilRefresh : defaultPollInterval
        return UInt64(delaySeconds * 1_000_000_000)
    }

    // MARK: - Private

    private func makeRequest(url: URL) -> URLRequest {
        Self.makeRequest(url: url, token: token)
    }

    private func makeNotificationsRequest(url: URL) -> URLRequest {
        var req = makeRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return req
    }

    private func request(url: URL) async throws -> Data {
        try await Self.request(url: url, token: token, session: session)
    }

    private static func makeRequest(url: URL, token: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return req
    }

    private static func request(
        url: URL,
        token: String,
        session: any NetworkSession
    ) async throws -> Data {
        let req = makeRequest(url: url, token: token)
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        switch status {
        case 200...299:
            return data
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        case 429:
            throw APIError.rateLimited
        default:
            throw APIError.httpError(status)
        }
    }

    private func updatePollingHeaders(from response: HTTPURLResponse?, scope: FeedScope) {
        guard let response else { return }

        updateFeedCache(scope) { cache in
            if let pollInterval = response.value(forHTTPHeaderField: "X-Poll-Interval"),
               let seconds = TimeInterval(pollInterval) {
                cache.nextNotificationsRefreshAt = Date().addingTimeInterval(seconds)
            } else {
                cache.nextNotificationsRefreshAt = Date()
            }
        }
    }

    private func feedCache(for scope: FeedScope) -> FeedCache {
        cachedFeeds[scope] ?? FeedCache()
    }

    private func updateFeedCache(_ scope: FeedScope, mutate: (inout FeedCache) -> Void) {
        var cache = feedCache(for: scope)
        mutate(&cache)
        cachedFeeds[scope] = cache
    }

    private func invalidateFeedCaches(_ scopes: some Sequence<FeedScope>) {
        for scope in scopes {
            updateFeedCache(scope) { cache in
                cache.notifications = []
                cache.nextNotificationsRefreshAt = .distantPast
                cache.lastModifiedValue = nil
            }
        }
    }

    private func logActionResponse(
        traceID: String,
        action: String,
        step: String,
        threadId: String,
        request: URLRequest,
        response: URLResponse,
        data: Data
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        DebugTrace.log(
            "action trace=\(traceID) kind=\(action) step=\(step) thread=\(threadId) " +
            "method=\(request.httpMethod ?? "GET") path=\(request.url?.path ?? "unknown") " +
            "status=\(status) body=\(Self.debugSnippet(for: data))"
        )
    }

    private static func debugSnippet(for data: Data, limit: Int = 160) -> String {
        guard !data.isEmpty else { return "empty" }
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if text.count <= limit {
            return text
        }
        return String(text.prefix(limit)) + "..."
    }

    private static func topIDs(in notifications: [GitHubNotification], limit: Int = 10) -> String {
        let ids = notifications.prefix(limit).map(\.id)
        return ids.isEmpty ? "none" : ids.joined(separator: ",")
    }

    private static func topIDs(in ids: [String], limit: Int = 10) -> String {
        let top = ids.prefix(limit)
        return top.isEmpty ? "none" : top.joined(separator: ",")
    }

    private static func debugFeedHint(for notifications: [GitHubNotification], limit: Int = 5) -> String {
        let preview = notifications.prefix(limit).map {
            "\($0.id)@\(ISO8601DateFormatter().string(from: $0.updatedAt))"
        }
        return preview.isEmpty ? "none" : preview.joined(separator: ",")
    }

    private static func debugName(for scope: FeedScope) -> String {
        switch scope {
        case .unread: return "unread"
        case .all: return "all"
        case .inbox: return "inbox"
        }
    }

    private func notificationsURL(all: Bool, page: Int, since: Date?) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("notifications"), resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "all", value: all ? "true" : "false"),
            URLQueryItem(name: "per_page", value: "\(notificationsPerPage)"),
            URLQueryItem(name: "page", value: "\(page)"),
        ]
        if let since {
            queryItems.append(
                URLQueryItem(
                    name: "since",
                    value: ISO8601DateFormatter().string(from: since)
                )
            )
        }
        components.queryItems = queryItems
        return components.url!
    }

    private func nextPageURL(from response: HTTPURLResponse?) -> URL? {
        guard let linkHeader = response?.value(forHTTPHeaderField: "Link") else {
            return nil
        }

        for component in linkHeader.split(separator: ",") {
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains("rel=\"next\"") else { continue }
            guard let start = trimmed.firstIndex(of: "<"),
                  let end = trimmed.firstIndex(of: ">"),
                  start < end else {
                continue
            }

            let urlString = String(trimmed[trimmed.index(after: start)..<end])
            return URL(string: urlString)
        }

        return nil
    }

    private static let dependabotAlertsQueryItems = [
        URLQueryItem(name: "state", value: "open"),
        URLQueryItem(name: "sort", value: "updated"),
        URLQueryItem(name: "direction", value: "desc"),
        URLQueryItem(name: "per_page", value: "100"),
    ]

    private static func sortedAndDedupedAlerts(_ alerts: [GitHubNotification]) -> [GitHubNotification] {
        let deduped = Dictionary(alerts.map { ($0.id, $0) }, uniquingKeysWith: { lhs, rhs in
            lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
        })
        return deduped.values.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id > rhs.id
        }
    }

    private static func recentAlerts(
        from alerts: [GitHubNotification],
        lookbackInterval: TimeInterval,
        now: Date = Date()
    ) -> [GitHubNotification] {
        let cutoff = now.addingTimeInterval(-lookbackInterval)
        return alerts.filter { $0.updatedAt >= cutoff }
    }

    // MARK: - Error

    enum APIError: LocalizedError {
        case unauthorized
        case forbidden
        case rateLimited
        case httpError(Int)
        case markReadFailed(Int)

        var errorDescription: String? {
            switch self {
            case .unauthorized: "Token is invalid or expired"
            case .forbidden: "Access forbidden — check token scopes"
            case .rateLimited: "GitHub API rate limit exceeded"
            case .httpError(let code): "GitHub API error (\(code))"
            case .markReadFailed(let code): "Failed to mark as read (\(code))"
            }
        }
    }
}

// MARK: - API response models

private struct APINotification: Decodable {
    private static let updatedAtFormatter = ISO8601DateFormatter()

    let id: String
    let unread: Bool
    let reason: String
    let updatedAt: String
    let subject: Subject
    let repository: Repository

    struct Subject: Decodable {
        let title: String
        let url: String?
        let type: String
    }

    struct Repository: Decodable {
        let fullName: String
        let htmlUrl: String
    }

    func toModel() -> GitHubNotification? {
        let reason = mapReason(reason)
        let type = mapType(subject.type, reason: reason)
        let date = Self.updatedAtFormatter.date(from: updatedAt) ?? Date()
        let webURL = buildWebURL(type: type)

        return GitHubNotification(
            id: id,
            threadId: id,
            title: subject.title,
            repository: repository.fullName,
            reason: reason,
            type: type,
            updatedAt: date,
            isUnread: unread,
            url: webURL,
            subjectURL: subject.url,
            subjectState: .unknown
        )
    }

    private func buildWebURL(type: GitHubNotification.SubjectType) -> URL {
        if type == .securityAlert,
           let advisoryURL = buildSecurityAlertURL() {
            return advisoryURL
        }

        if let apiURLString = subject.url,
           let apiURL = URL(string: apiURLString) {
            let path = apiURL.pathComponents
            if path.count >= 6 {
                let owner = path[2]
                let repo = path[3]
                let typeSegment = path[4]
                let number = path[5]
                let webType: String
                switch typeSegment {
                case "pulls": webType = "pull"
                case "issues": webType = "issues"
                case "commits": webType = "commit"
                case "releases": webType = "releases/tag"
                default: webType = typeSegment
                }
                if let url = URL(string: "https://github.com/\(owner)/\(repo)/\(webType)/\(number)") {
                    return url
                }
            }
        }
        return URL(string: repository.htmlUrl) ?? URL(string: "https://github.com")!
    }

    private func buildSecurityAlertURL() -> URL? {
        if let titleToken = subject.title
            .split(separator: " ")
            .first(where: { $0.hasPrefix("GHSA-") }),
           let url = URL(string: "https://github.com/advisories/\(titleToken)") {
            return url
        }

        return URL(string: repository.htmlUrl + "/security")
    }

    private func mapReason(_ reason: String) -> GitHubNotification.Reason {
        switch reason {
        case "mention": .mentioned
        case "review_requested": .reviewRequested
        case "assign": .assigned
        case "subscribed": .subscribed
        case "ci_activity": .ciActivity
        case "author": .author
        case "comment": .comment
        case "state_change": .stateChange
        case "security_alert": .securityAlert
        default: .subscribed
        }
    }

    private func mapType(
        _ type: String,
        reason: GitHubNotification.Reason
    ) -> GitHubNotification.SubjectType {
        switch type {
        case "PullRequest": .pullRequest
        case "Issue": .issue
        case "Release": .release
        case "Discussion": .discussion
        case "Commit": .commit
        case "RepositoryVulnerabilityAlert", "RepositoryAdvisory": .securityAlert
        default:
            reason == .securityAlert ? .securityAlert : .issue
        }
    }
}

private struct APISubjectState: Decodable {
    struct Head: Decodable {
        let sha: String
    }

    let state: String?
    let merged: Bool?
    let mergedAt: String?
    let draft: Bool?
    let stateReason: String?
    let head: Head?

    var resolvedState: GitHubNotification.SubjectState {
        if merged == true || mergedAt != nil {
            return .merged
        }
        if draft == true {
            return .draft
        }
        switch state {
        case "open":
            return .open
        case "closed":
            return stateReason == "not_planned" ? .closedNotPlanned : .closed
        default:
            return .unknown
        }
    }
}

private struct APICheckRunsResponse: Decodable {
    struct CheckRun: Decodable {
        let status: String
        let conclusion: String?
    }

    let checkRuns: [CheckRun]

    var resolvedCIStatus: GitHubNotification.CIStatus? {
        guard !checkRuns.isEmpty else { return nil }

        if checkRuns.contains(where: { $0.status != "completed" }) {
            return .pending
        }

        let failureConclusions: Set<String> = [
            "action_required",
            "cancelled",
            "failure",
            "stale",
            "startup_failure",
            "timed_out",
        ]

        if checkRuns.contains(where: {
            guard let conclusion = $0.conclusion else { return true }
            return failureConclusions.contains(conclusion)
        }) {
            return .failure
        }

        return .success
    }
}

private struct APICombinedStatus: Decodable {
    let state: String

    var resolvedCIStatus: GitHubNotification.CIStatus? {
        switch state {
        case "success":
            return .success
        case "failure", "error":
            return .failure
        case "pending":
            return .pending
        default:
            return nil
        }
    }
}

private struct APIUser: Decodable {
    let login: String
}

private struct ThreadSubscriptionRequest: Encodable {
    let ignored: Bool
}

private struct APIDependabotAlert: Decodable {
    private static let updatedAtFormatter = ISO8601DateFormatter()

    struct Repository: Decodable {
        let fullName: String
        let htmlUrl: String
    }

    struct Dependency: Decodable {
        struct Package: Decodable {
            let name: String?
        }

        let package: Package?
    }

    struct SecurityAdvisory: Decodable {
        let ghsaId: String?
        let summary: String?
    }

    let number: Int
    let htmlUrl: String
    let updatedAt: String
    let repository: Repository?
    let dependency: Dependency?
    let securityAdvisory: SecurityAdvisory?

    func toModel(
        fallbackRepositoryFullName: String? = nil,
        fallbackRepositoryHTMLURL: String? = nil
    ) -> GitHubNotification? {
        let repositoryFullName = repository?.fullName ?? fallbackRepositoryFullName
        let repositoryHTMLURL = repository?.htmlUrl ?? fallbackRepositoryHTMLURL
        guard let repositoryFullName,
              let repositoryHTMLURL,
              let url = URL(string: htmlUrl.isEmpty ? repositoryHTMLURL : htmlUrl) else {
            return nil
        }

        let updated = Self.updatedAtFormatter.date(from: updatedAt) ?? Date()
        let summary = securityAdvisory?.summary ?? dependency?.package?.name.map { "Dependabot alert for \($0)" } ?? "Dependabot alert"
        let title: String
        if let advisoryID = securityAdvisory?.ghsaId, !advisoryID.isEmpty {
            title = "\(advisoryID) \(summary)"
        } else {
            title = summary
        }

        return GitHubNotification(
            id: "dependabot:\(repositoryFullName):\(number)",
            threadId: "dependabot:\(repositoryFullName):\(number)",
            title: title,
            repository: repositoryFullName,
            reason: .securityAlert,
            type: .securityAlert,
            updatedAt: updated,
            isUnread: true,
            url: url,
            subjectURL: nil,
            subjectState: .open,
            source: .dependabotAlert
        )
    }
}

extension JSONDecoder {
    static let github: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
