import Foundation

protocol NetworkSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: NetworkSession {}

actor GitHubAPIClient {
    private let baseURL = URL(string: "https://api.github.com")!
    private let notificationsPerPage = 100
    private let defaultPollInterval: TimeInterval = 60
    private let maxConcurrentSubjectRequests: Int
    private let maxSubjectResolutionBatchSize = 40
    private let session: any NetworkSession
    private var token: String

    private enum FeedScope: CaseIterable {
        case unread
        case all

        init(all: Bool) {
            self = all ? .all : .unread
        }
    }

    private struct FeedCache {
        var notifications: [GitHubNotification] = []
        var lastModifiedValue: String?
        var nextNotificationsRefreshAt = Date.distantPast
    }

    private var cachedFeeds: [FeedScope: FeedCache] = [:]

    private struct SubjectRequestContext: Sendable {
        let token: String
        let session: any NetworkSession
    }

    init(
        token: String,
        session: any NetworkSession = URLSession.shared,
        maxConcurrentSubjectRequests: Int = 6
    ) {
        self.token = token
        self.session = session
        self.maxConcurrentSubjectRequests = max(1, maxConcurrentSubjectRequests)
    }

    func updateToken(_ token: String) {
        self.token = token
    }

    // MARK: - Fetch notifications

    func fetchNotifications(all: Bool = false, force: Bool = false) async throws -> [GitHubNotification] {
        let scope = FeedScope(all: all)
        let cachedFeed = feedCache(for: scope)
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
        var currentURL: URL? = notificationsURL(all: all, page: page)

        while let requestURL = currentURL {
            var request = makeNotificationsRequest(url: requestURL)
            if page == 1,
               !force,
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
                if page == 1 {
                    lastModifiedFromResponse = httpResponse?.value(forHTTPHeaderField: "Last-Modified")
                }

                let pageItems = try JSONDecoder.github.decode([APINotification].self, from: data)
                apiItems.append(contentsOf: pageItems)

                if let nextPageURL = nextPageURL(from: httpResponse) {
                    currentURL = nextPageURL
                    page += 1
                    continue
                }

                if pageItems.count == notificationsPerPage {
                    page += 1
                    currentURL = notificationsURL(all: all, page: page)
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
            }
        }

        updateFeedCache(scope) { cache in
            cache.notifications = notifications
            cache.lastModifiedValue = lastModifiedFromResponse
        }
        DebugTrace.log(
            "fetch complete scope=\(Self.debugName(for: scope)) count=\(notifications.count) " +
            "top=\(Self.topIDs(in: notifications))"
        )
        return notifications
    }

    func resolveSubjectStates(
        for notifications: [GitHubNotification]
    ) async -> [String: GitHubNotification.SubjectState] {
        let pendingSubjectNotifications = notifications
            .filter(Self.shouldResolveSubjectState)
            .prefix(maxSubjectResolutionBatchSize)
        let candidateNotifications = Array(pendingSubjectNotifications)
        guard !candidateNotifications.isEmpty else { return [:] }

        let subjectRequestContext = SubjectRequestContext(token: token, session: session)
        let subjectStatesByID = await Self.fetchSubjectStates(
            for: candidateNotifications,
            maxConcurrent: maxConcurrentSubjectRequests,
            context: subjectRequestContext
        )

        guard !subjectStatesByID.isEmpty else { return [:] }

        for scope in FeedScope.allCases {
            updateFeedCache(scope) { cache in
                for index in cache.notifications.indices {
                    if let state = subjectStatesByID[cache.notifications[index].id] {
                        cache.notifications[index].subjectState = state
                    }
                }
            }
        }

        return subjectStatesByID
    }

    // MARK: - Fetch subject state

    private static func fetchSubjectStates(
        for notifications: [GitHubNotification],
        maxConcurrent: Int,
        context: SubjectRequestContext
    ) async -> [String: GitHubNotification.SubjectState] {
        guard !notifications.isEmpty else { return [:] }

        let concurrencyLimit = max(1, min(maxConcurrent, notifications.count))
        var iterator = notifications.makeIterator()
        var subjectStatesByID: [String: GitHubNotification.SubjectState] = [:]

        await withTaskGroup(of: (String, GitHubNotification.SubjectState).self) { group in
            for _ in 0..<concurrencyLimit {
                guard let notification = iterator.next(),
                      let subjectURL = notification.subjectURL else {
                    break
                }

                let id = notification.id
                group.addTask {
                    let state = await Self.fetchSubjectState(apiURL: subjectURL, context: context)
                    return (id, state)
                }
            }

            while let (id, state) = await group.next() {
                subjectStatesByID[id] = state

                guard let notification = iterator.next(),
                      let subjectURL = notification.subjectURL else {
                    continue
                }

                let id = notification.id
                group.addTask {
                    let state = await Self.fetchSubjectState(apiURL: subjectURL, context: context)
                    return (id, state)
                }
            }
        }

        return subjectStatesByID
    }

    private static func fetchSubjectState(
        apiURL: String,
        context: SubjectRequestContext
    ) async -> GitHubNotification.SubjectState {
        guard let url = URL(string: apiURL) else { return .unknown }
        do {
            let data = try await request(url: url, token: context.token, session: context.session)
            let subject = try JSONDecoder.github.decode(APISubjectState.self, from: data)
            if subject.merged == true {
                return .merged
            }
            switch subject.state {
            case "open": return .open
            case "closed":
                if subject.stateReason == "not_planned" {
                    return .closedNotPlanned
                }
                return .closed
            default: return .unknown
            }
        } catch {
            return .unknown
        }
    }

    private static func shouldResolveSubjectState(_ notification: GitHubNotification) -> Bool {
        guard notification.subjectURL != nil,
              notification.subjectState == .unknown,
              notification.isUnread else {
            return false
        }

        switch notification.type {
        case .pullRequest, .issue:
            return true
        case .release, .discussion, .commit:
            return false
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
        updateFeedCache(.all) { cache in
            if let index = cache.notifications.firstIndex(where: { $0.threadId == threadId }) {
                cache.notifications[index].isUnread = false
            }
        }
        updateFeedCache(.unread) { cache in
            cache.notifications.removeAll { $0.threadId == threadId }
        }
        invalidateFeedCaches([.all, .unread])
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
        removeActivity(notification, from: FeedScope.allCases)
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

        removeActivity(notification, from: FeedScope.allCases)
        invalidateFeedCaches(FeedScope.allCases)
    }

    func restoreSubscription(threadId: String, notification: GitHubNotification, originalIndex: Int) async throws {
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

        updateFeedCache(.all) { cache in
            upsertThread(notification, originalIndex: originalIndex, into: &cache.notifications)
        }
        updateFeedCache(.unread) { cache in
            if notification.isUnread {
                upsertThread(notification, originalIndex: originalIndex, into: &cache.notifications)
            } else {
                cache.notifications.removeAll { $0.threadId == threadId }
            }
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
                cache.nextNotificationsRefreshAt = .distantPast
                cache.lastModifiedValue = nil
            }
        }
    }

    private func removeActivity(_ notification: GitHubNotification, from scopes: some Sequence<FeedScope>) {
        for scope in scopes {
            updateFeedCache(scope) { cache in
                cache.notifications.removeAll { $0.matchesActivity(as: notification) }
            }
        }
    }

    private func upsertThread(
        _ notification: GitHubNotification,
        originalIndex: Int,
        into notifications: inout [GitHubNotification]
    ) {
        if let index = notifications.firstIndex(where: { $0.threadId == notification.threadId }) {
            notifications[index] = notification
        } else {
            let insertAt = min(max(0, originalIndex), notifications.count)
            notifications.insert(notification, at: insertAt)
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

    private static func debugName(for scope: FeedScope) -> String {
        switch scope {
        case .unread: return "unread"
        case .all: return "all"
        }
    }

    private func notificationsURL(all: Bool, page: Int) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("notifications"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "all", value: all ? "true" : "false"),
            URLQueryItem(name: "per_page", value: "\(notificationsPerPage)"),
            URLQueryItem(name: "page", value: "\(page)"),
        ]
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
        let type = mapType(subject.type)
        let date = Self.updatedAtFormatter.date(from: updatedAt) ?? Date()
        let webURL = buildWebURL()

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

    private func buildWebURL() -> URL {
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
        default: .subscribed
        }
    }

    private func mapType(_ type: String) -> GitHubNotification.SubjectType {
        switch type {
        case "PullRequest": .pullRequest
        case "Issue": .issue
        case "Release": .release
        case "Discussion": .discussion
        case "Commit": .commit
        default: .issue
        }
    }
}

private struct APISubjectState: Decodable {
    let state: String?
    let merged: Bool?
    let stateReason: String?
}

private struct APIUser: Decodable {
    let login: String
}

private struct ThreadSubscriptionRequest: Encodable {
    let ignored: Bool
}

extension JSONDecoder {
    static let github: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
