import Foundation

protocol NetworkSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func downloadFile(for request: URLRequest) async throws -> (URL, URLResponse)
}

extension NetworkSession {
    func downloadFile(for request: URLRequest) async throws -> (URL, URLResponse) {
        let (data, response) = try await data(for: request)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.octodot.network-stub.\(UUID().uuidString)")
        try data.write(to: fileURL, options: .atomic)
        return (fileURL, response)
    }
}

extension URLSession: NetworkSession {
    func downloadFile(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await download(for: request)
    }
}

actor GitHubAPIClient {
    static let subjectMetadataWarningMessage = "Some pull request status data couldn't be loaded."

    private let baseURL = URL(string: "https://api.github.com")!
    private let notificationsPerPage = 100
    private let maximumNotificationsPages = 100
    private let defaultPollInterval: TimeInterval = 60
    private let maximumPollInterval: TimeInterval = 60 * 60
    private let defaultRecentInboxMaxPages = 2
    private let maxConcurrentSubjectRequests: Int
    private let maxSubjectResolutionBatchSize = 40
    private static let requiredClassicTokenScopes: Set<String> = ["notifications", "repo"]
    private let session: any NetworkSession
    private var token: String
    private var credentialGeneration = UUID()

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
        var hasFetchedSuccessfully = false
        var lastModifiedValue: String?
        var nextNotificationsRefreshAt = Date.distantPast
    }

    private var cachedFeeds: [FeedScope: FeedCache] = [:]
    private var latestFeedRequestIDs: [FeedScope: UUID] = [:]
    private var latestSubjectMetadataRequestID = UUID()
    private var nonFatalWarningMessage: String?

    private struct SubjectRequestContext: Sendable {
        let token: String
        let session: any NetworkSession
    }

    private let useGraphQLForSubjectMetadata: Bool

    init(
        token: String,
        session: any NetworkSession = URLSession.shared,
        maxConcurrentSubjectRequests: Int = 6,
        useGraphQLForSubjectMetadata: Bool = true
    ) {
        self.token = Self.sanitizedToken(token)
        self.session = session
        self.maxConcurrentSubjectRequests = max(1, maxConcurrentSubjectRequests)
        self.useGraphQLForSubjectMetadata = useGraphQLForSubjectMetadata
    }

    func updateToken(_ token: String) {
        self.token = Self.sanitizedToken(token)
        credentialGeneration = UUID()
        cachedFeeds.removeAll()
        invalidateFeedRequests(FeedScope.allCases)
        latestSubjectMetadataRequestID = UUID()
        nonFatalWarningMessage = nil
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

    private func fetchNotifications(
        scope: FeedScope,
        all: Bool,
        since: Date?,
        force: Bool,
        maxPages: Int?
    ) async throws -> [GitHubNotification] {
        try Task.checkCancellation()
        let cachedFeed = feedCache(for: scope)
        var shouldUseConditionalRequest = !force &&
            cachedFeed.hasFetchedSuccessfully &&
            cachedFeed.lastModifiedValue != nil
        DebugTrace.log(
            "fetch start scope=\(Self.debugName(for: scope)) force=\(force) " +
            "cached.count=\(cachedFeed.notifications.count) ifModified=\(cachedFeed.lastModifiedValue ?? "nil")"
        )

        if !force,
           cachedFeed.hasFetchedSuccessfully,
           Date() < cachedFeed.nextNotificationsRefreshAt {
            DebugTrace.log(
                "fetch cache-hit scope=\(Self.debugName(for: scope)) count=\(cachedFeed.notifications.count) " +
                "top=\(Self.topIDs(in: cachedFeed.notifications))"
            )
            return cachedFeed.notifications
        }

        let requestID = beginFeedRequest(for: scope)
        let requestGeneration = credentialGeneration
        let requestToken = token
        var apiItems: [APINotification] = []
        var lastModifiedFromResponse: String?
        var page = 1
        let maximumPages = min(
            maxPages.map { max(1, $0) } ?? maximumNotificationsPages,
            maximumNotificationsPages
        )
        var currentURL: URL? = notificationsURL(all: all, page: page, since: since)

        while let requestURL = currentURL {
            try Task.checkCancellation()
            guard Self.isTrustedGitHubAPIURL(requestURL) else {
                throw APIError.untrustedGitHubAPIURL
            }

            var request = Self.makeNotificationsRequest(url: requestURL, token: requestToken)
            if page == 1,
               shouldUseConditionalRequest,
               let lastModifiedValue = cachedFeed.lastModifiedValue {
                request.setValue(lastModifiedValue, forHTTPHeaderField: "If-Modified-Since")
            }

            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard requestGeneration == credentialGeneration else {
                throw APIError.staleCredentialResponse
            }
            let httpResponse = try Self.validatedGitHubAPIResponse(response)
            let status = httpResponse.statusCode
            DebugTrace.log(
                "fetch response scope=\(Self.debugName(for: scope)) page=\(page) status=\(status) " +
                "ifModified=\(request.value(forHTTPHeaderField: "If-Modified-Since") ?? "nil")"
            )

            if page == 1 {
                updatePollingHeaders(from: httpResponse, scope: scope, requestID: requestID)
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
                    try Task.checkCancellation()
                    continue
                }

                if page == 1 {
                    lastModifiedFromResponse = httpResponse.value(forHTTPHeaderField: "Last-Modified")
                }

                let pageItems = try JSONDecoder.github.decode([APINotification].self, from: data)
                DebugTrace.log(
                    "fetch page scope=\(Self.debugName(for: scope)) page=\(page) decoded.count=\(pageItems.count) " +
                    "decoded.top=\(Self.topIDs(in: pageItems.map(\.id))) link=\(httpResponse.value(forHTTPHeaderField: "Link") ?? "nil")"
                )
                apiItems.append(contentsOf: pageItems)

                if let nextPageURL = try nextPageURL(from: httpResponse),
                   page < maximumPages {
                    try Task.checkCancellation()
                    currentURL = nextPageURL
                    page += 1
                    continue
                }

                if pageItems.count == notificationsPerPage,
                   page < maximumPages {
                    try Task.checkCancellation()
                    page += 1
                    currentURL = notificationsURL(all: all, page: page, since: since)
                    continue
                }

                updateFeedCache(scope, for: requestID) { cache in
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
            case 403 where Self.isRateLimitedResponse(httpResponse):
                throw APIError.rateLimited
            case 403:
                throw APIError.forbidden
            case 429:
                throw APIError.rateLimited
            default:
                throw APIError.httpError(status)
            }
        }

        try Task.checkCancellation()
        var seenNotificationIDs = Set<String>()
        var notifications = apiItems
            .compactMap { $0.toModel() }
            .filter { seenNotificationIDs.insert($0.id).inserted }
        notifications.sort { $0.updatedAt > $1.updatedAt }
        let previousNotifications = cachedFeed.notifications.reduce(into: [String: GitHubNotification]()) {
            $0[$1.id] = $1
        }

        for index in notifications.indices {
            guard notifications[index].subjectURL != nil else { continue }

            if let previous = previousNotifications[notifications[index].id],
               previous.updatedAt == notifications[index].updatedAt {
                notifications[index].url = previous.url
                notifications[index].subjectState = previous.subjectState
                notifications[index].ciStatus = previous.ciStatus
                notifications[index].hasResolvedCIStatus = previous.hasResolvedCIStatus
                notifications[index].openerLogin = previous.openerLogin
                notifications[index].openerAvatarURL = previous.openerAvatarURL
                notifications[index].hasResolvedOpener = previous.hasResolvedOpener
            }
        }

        updateFeedCache(scope, for: requestID) { cache in
            cache.notifications = notifications
            cache.hasFetchedSuccessfully = true
            cache.lastModifiedValue = lastModifiedFromResponse
        }
        DebugTrace.log(
            "fetch complete scope=\(Self.debugName(for: scope)) count=\(notifications.count) " +
            "top=\(Self.topIDs(in: notifications)) bodyHint=\(Self.debugFeedHint(for: notifications))"
        )
        return notifications
    }

    func resolveSubjectMetadata(
        for notifications: [GitHubNotification],
        forceOpenPullRequestRefresh: Bool = false
    ) async -> [String: GitHubNotification.SubjectMetadata] {
        let requestID = UUID()
        latestSubjectMetadataRequestID = requestID
        nonFatalWarningMessage = nil
        let pendingSubjectNotifications = notifications
            .filter {
                Self.shouldResolveSubjectMetadata($0) || (
                    forceOpenPullRequestRefresh &&
                    $0.type == .pullRequest &&
                    $0.subjectState == .open
                )
            }
            .prefix(maxSubjectResolutionBatchSize)
        let candidateNotifications = Array(pendingSubjectNotifications)
        guard !candidateNotifications.isEmpty else { return [:] }

        let context = SubjectRequestContext(token: token, session: session)
        let requestGeneration = credentialGeneration

        var result: SubjectMetadataBatchResult
        if useGraphQLForSubjectMetadata {
            let graphQLCandidates = candidateNotifications.filter {
                $0.type == .pullRequest || $0.type == .issue
            }
            let restCandidates = candidateNotifications.filter { $0.type == .release }
            result = await Self.fetchSubjectMetadataViaGraphQL(
                for: graphQLCandidates,
                context: context
            )
            if result.metadataByID.isEmpty && !graphQLCandidates.isEmpty {
                DebugTrace.log("graphql subject metadata failed, falling back to REST")
                result = await Self.fetchSubjectMetadata(
                    for: graphQLCandidates,
                    maxConcurrent: maxConcurrentSubjectRequests,
                    context: context
                )
            }
            let restResult = await Self.fetchSubjectMetadata(
                for: restCandidates,
                maxConcurrent: maxConcurrentSubjectRequests,
                context: context
            )
            result.metadataByID.merge(restResult.metadataByID) { _, restMetadata in restMetadata }
            result.failureCount += restResult.failureCount
        } else {
            result = await Self.fetchSubjectMetadata(
                for: candidateNotifications,
                maxConcurrent: maxConcurrentSubjectRequests,
                context: context
            )
        }

        guard requestGeneration == credentialGeneration,
              requestID == latestSubjectMetadataRequestID,
              !Task.isCancelled else { return [:] }

        if result.failureCount > 0 {
            nonFatalWarningMessage = Self.subjectMetadataWarningMessage
            DebugTrace.log("subject metadata degraded failures=\(result.failureCount)")
        }

        let subjectMetadataByID = result.metadataByID

        guard !subjectMetadataByID.isEmpty else { return [:] }

        for scope in FeedScope.allCases {
            updateFeedCache(scope) { cache in
                for index in cache.notifications.indices {
                    if let metadata = subjectMetadataByID[cache.notifications[index].id] {
                        cache.notifications[index].apply(metadata)
                    }
                }
            }
        }

        return subjectMetadataByID
    }

    func takeNonFatalWarningMessage() -> String? {
        defer { nonFatalWarningMessage = nil }
        return nonFatalWarningMessage
    }

    // MARK: - Fetch subject metadata

    private struct SubjectMetadataBatchResult {
        var metadataByID: [String: GitHubNotification.SubjectMetadata] = [:]
        var failureCount = 0
    }

    private struct SubjectMetadataRequestResult {
        let metadata: GitHubNotification.SubjectMetadata
        let hadFailure: Bool
    }

    private static func fetchSubjectMetadata(
        for notifications: [GitHubNotification],
        maxConcurrent: Int,
        context: SubjectRequestContext
    ) async -> SubjectMetadataBatchResult {
        guard !notifications.isEmpty else { return SubjectMetadataBatchResult() }

        let concurrencyLimit = max(1, min(maxConcurrent, notifications.count))
        var iterator = notifications.makeIterator()
        var batchResult = SubjectMetadataBatchResult()

        await withTaskGroup(of: (String, SubjectMetadataRequestResult).self) { group in
            for _ in 0..<concurrencyLimit {
                guard let notification = iterator.next(),
                      notification.subjectURL != nil else {
                    break
                }

                let id = notification.id
                group.addTask {
                    let metadata = await Self.fetchSubjectMetadata(
                        notification: notification,
                        context: context
                    )
                    return (id, metadata)
                }
            }

            while let (id, metadata) = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                batchResult.metadataByID[id] = metadata.metadata
                if metadata.hadFailure {
                    batchResult.failureCount += 1
                }

                guard let notification = iterator.next(),
                      notification.subjectURL != nil else {
                    continue
                }

                let id = notification.id
                group.addTask {
                    let metadata = await Self.fetchSubjectMetadata(
                        notification: notification,
                        context: context
                    )
                    return (id, metadata)
                }
            }
        }

        return batchResult
    }

    private static func fetchSubjectMetadata(
        notification: GitHubNotification,
        context: SubjectRequestContext
    ) async -> SubjectMetadataRequestResult {
        let apiURL = notification.subjectURL ?? ""
        guard let subjectRef = parseSubjectRef(from: notification),
              let url = trustedGitHubAPIURL(from: apiURL) else {
            DebugTrace.log("subject metadata rejected invalid url=\(apiURL)")
            return .init(metadata: .init(state: .unknown, ciStatus: nil), hadFailure: true)
        }
        do {
            let data = try await request(url: url, token: context.token, session: context.session)
            let subject = try JSONDecoder.github.decode(APISubjectState.self, from: data)
            if notification.type == .release {
                guard let releaseURL = trustedReleaseWebURL(
                    subject.htmlUrl,
                    tagName: subject.tagName,
                    subjectRef: subjectRef
                ) else {
                    return .init(metadata: .init(state: .unknown, ciStatus: nil), hadFailure: true)
                }
                return .init(
                    metadata: .init(state: .unknown, ciStatus: nil, webURL: releaseURL),
                    hadFailure: false
                )
            }
            let resolvedState = subject.resolvedState
            let openerLogin = subject.user?.login
            let openerAvatarURL = subject.user?.avatarUrl
            let ciStatusResult: CIStatusFetchResult
            if resolvedState == .open, let headSHA = subject.head?.sha {
                ciStatusResult = await fetchCIStatus(subjectURL: url, headSHA: headSHA, context: context)
            } else {
                ciStatusResult = .status(nil)
            }

            switch ciStatusResult {
            case .status(let ciStatus):
                return .init(
                    metadata: .init(
                        state: resolvedState,
                        ciStatus: ciStatus,
                        hasResolvedCIStatus: notification.type == .pullRequest,
                        openerLogin: openerLogin,
                        openerAvatarURL: openerAvatarURL,
                        hasResolvedOpener: true
                    ),
                    hadFailure: false
                )
            case .degraded:
                return .init(
                    metadata: .init(
                        state: resolvedState,
                        ciStatus: nil,
                        hasResolvedCIStatus: false,
                        openerLogin: openerLogin,
                        openerAvatarURL: openerAvatarURL,
                        hasResolvedOpener: true
                    ),
                    hadFailure: true
                )
            }
        } catch {
            DebugTrace.log("subject metadata request failed url=\(apiURL) error=\(error.localizedDescription)")
            return .init(metadata: .init(state: .unknown, ciStatus: nil), hadFailure: true)
        }
    }

    private enum CIStatusFetchResult {
        case status(GitHubNotification.CIStatus?)
        case degraded
    }

    private static func fetchCIStatus(
        subjectURL: URL,
        headSHA: String,
        context: SubjectRequestContext
    ) async -> CIStatusFetchResult {
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

        if let checkRunsURL = checkRunsComponents?.url {
            do {
                let data = try await request(url: checkRunsURL, token: context.token, session: context.session)
                let response = try JSONDecoder.github.decode(APICheckRunsResponse.self, from: data)
                if let status = response.resolvedCIStatus {
                    return .status(status)
                }
            } catch {
                DebugTrace.log("ci check-runs request failed url=\(checkRunsURL.absoluteString) error=\(error.localizedDescription)")
            }
        }

        let combinedStatusURL = repositoryAPIURL
            .appendingPathComponent("commits")
            .appendingPathComponent(headSHA)
            .appendingPathComponent("status")
        do {
            let data = try await request(url: combinedStatusURL, token: context.token, session: context.session)
            let response = try JSONDecoder.github.decode(APICombinedStatus.self, from: data)
            return .status(response.resolvedCIStatus)
        } catch {
            DebugTrace.log("ci combined-status request failed url=\(combinedStatusURL.absoluteString) error=\(error.localizedDescription)")
            return .degraded
        }
    }

    private static func shouldResolveSubjectMetadata(_ notification: GitHubNotification) -> Bool {
        notification.needsSubjectMetadataResolution
    }

    // MARK: - GraphQL batch subject metadata

    private struct SubjectRef {
        let notificationID: String
        let owner: String
        let repo: String
        let type: GitHubNotification.SubjectType
        let number: Int
    }

    private static func parseSubjectRef(
        from notification: GitHubNotification
    ) -> SubjectRef? {
        guard let urlString = notification.subjectURL,
              let url = trustedGitHubAPIURL(from: urlString) else { return nil }
        let parts = url.pathComponents
        // ["", "repos", owner, repo, "pulls"|"issues", number]
        let expectedSubjectPath: String
        switch notification.type {
        case .pullRequest:
            expectedSubjectPath = "pulls"
        case .issue:
            expectedSubjectPath = "issues"
        case .release:
            expectedSubjectPath = "releases"
        default:
            return nil
        }
        guard parts.count == 6,
              parts[1] == "repos",
              parts[4] == expectedSubjectPath,
              url.query == nil,
              url.fragment == nil,
              Self.isSafePathComponent(parts[2]),
              Self.isSafePathComponent(parts[3]),
              let number = Int(parts[5]),
              number > 0 else { return nil }
        let owner = parts[2]
        let repo = parts[3]
        return SubjectRef(
            notificationID: notification.id,
            owner: owner,
            repo: repo,
            type: notification.type,
            number: number
        )
    }

    private static func trustedReleaseWebURL(
        _ url: URL?,
        tagName: String?,
        subjectRef: SubjectRef
    ) -> URL? {
        guard let url,
              let tagName,
              !tagName.isEmpty,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil else {
            return nil
        }

        let path = url.pathComponents
        guard path.count >= 6,
              path[1] == subjectRef.owner,
              path[2] == subjectRef.repo,
              path[3] == "releases",
              path[4] == "tag",
              path.dropFirst(5).joined(separator: "/") == tagName else {
            return nil
        }
        return url
    }

    private static func escapeGraphQL(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func buildGraphQLQuery(for refs: [SubjectRef]) -> String {
        var fields: [String] = []
        for (i, ref) in refs.enumerated() {
            let owner = escapeGraphQL(ref.owner)
            let repo = escapeGraphQL(ref.repo)
            switch ref.type {
            case .pullRequest:
                fields.append("""
                  n\(i): repository(owner: "\(owner)", name: "\(repo)") {
                    pullRequest(number: \(ref.number)) {
                      id
                      state
                      isDraft
                      mergedAt
                      author {
                        login
                        avatarUrl
                      }
                      commits(last: 1) {
                        nodes {
                          commit {
                            statusCheckRollup {
                              state
                            }
                          }
                        }
                      }
                    }
                  }
                """)
            case .issue:
                fields.append("""
                  n\(i): repository(owner: "\(owner)", name: "\(repo)") {
                    issue(number: \(ref.number)) {
                      id
                      state
                      stateReason
                      author {
                        login
                        avatarUrl
                      }
                    }
                  }
                """)
            default:
                continue
            }
        }
        return "{\n\(fields.joined(separator: "\n"))\n}"
    }

    private static func fetchSubjectMetadataViaGraphQL(
        for notifications: [GitHubNotification],
        context: SubjectRequestContext
    ) async -> SubjectMetadataBatchResult {
        let refs = notifications.compactMap { parseSubjectRef(from: $0) }
        guard !refs.isEmpty else { return SubjectMetadataBatchResult() }

        let query = buildGraphQLQuery(for: refs)
        let graphQLURL = URL(string: "https://api.github.com/graphql")!
        var req = URLRequest(url: graphQLURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(context.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Octodot", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = ["query": query]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        DebugTrace.log("graphql subject metadata start count=\(refs.count)")

        do {
            let (data, response) = try await context.session.data(for: req)
            try Task.checkCancellation()
            let httpResponse = try validatedGitHubAPIResponse(response)
            let status = httpResponse.statusCode
            guard (200...299).contains(status) else {
                DebugTrace.log("graphql subject metadata http error status=\(status)")
                return SubjectMetadataBatchResult()
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DebugTrace.log("graphql subject metadata parse error")
                return SubjectMetadataBatchResult()
            }
            if let errors = json["errors"] as? [Any], !errors.isEmpty {
                DebugTrace.log("graphql subject metadata returned errors")
                return SubjectMetadataBatchResult(failureCount: refs.count)
            }
            guard
                  let dataObj = json["data"] as? [String: Any] else {
                DebugTrace.log("graphql subject metadata parse error")
                return SubjectMetadataBatchResult()
            }

            var result = SubjectMetadataBatchResult()
            for (i, ref) in refs.enumerated() {
                guard let repoObj = dataObj["n\(i)"] as? [String: Any] else {
                    result.failureCount += 1
                    continue
                }

                let metadata: GitHubNotification.SubjectMetadata
                switch ref.type {
                case .pullRequest:
                    guard let pr = repoObj["pullRequest"] as? [String: Any] else {
                        result.failureCount += 1
                        continue
                    }
                    metadata = parsePullRequestMetadata(pr)
                case .issue:
                    guard let issue = repoObj["issue"] as? [String: Any] else {
                        result.failureCount += 1
                        continue
                    }
                    metadata = parseIssueMetadata(issue)
                default:
                    continue
                }
                result.metadataByID[ref.notificationID] = metadata
            }

            DebugTrace.log("graphql subject metadata complete resolved=\(result.metadataByID.count) failures=\(result.failureCount)")
            return result
        } catch {
            DebugTrace.log("graphql subject metadata request failed error=\(error.localizedDescription)")
            return SubjectMetadataBatchResult()
        }
    }

    private static func parsePullRequestMetadata(_ pr: [String: Any]) -> GitHubNotification.SubjectMetadata {
        let stateString = pr["state"] as? String ?? ""
        let isDraft = (pr["isDraft"] as? Bool) ?? (pr["draft"] as? Bool) ?? false
        let mergedAt = pr["mergedAt"] as? String

        let state: GitHubNotification.SubjectState
        if stateString == "MERGED" || mergedAt != nil {
            state = .merged
        } else if isDraft {
            state = .draft
        } else if stateString == "OPEN" {
            state = .open
        } else if stateString == "CLOSED" {
            state = .closed
        } else {
            state = .unknown
        }

        var ciStatus: GitHubNotification.CIStatus?
        if state == .open,
           let commits = pr["commits"] as? [String: Any],
           let nodes = commits["nodes"] as? [[String: Any]],
           let firstCommit = nodes.first,
           let commit = firstCommit["commit"] as? [String: Any],
           let rollup = commit["statusCheckRollup"] as? [String: Any],
           let rollupState = rollup["state"] as? String {
            switch rollupState {
            case "SUCCESS": ciStatus = .success
            case "FAILURE", "ERROR": ciStatus = .failure
            case "PENDING", "EXPECTED": ciStatus = .pending
            default: break
            }
        }

        let author = pr["author"] as? [String: Any]
        return GitHubNotification.SubjectMetadata(
            state: state,
            ciStatus: ciStatus,
            hasResolvedCIStatus: true,
            nodeID: pr["id"] as? String,
            openerLogin: author?["login"] as? String,
            openerAvatarURL: (author?["avatarUrl"] as? String).flatMap(URL.init(string:)),
            hasResolvedOpener: true
        )
    }

    private static func parseIssueMetadata(_ issue: [String: Any]) -> GitHubNotification.SubjectMetadata {
        let stateString = issue["state"] as? String ?? ""
        let stateReason = issue["stateReason"] as? String

        let state: GitHubNotification.SubjectState
        switch stateString {
        case "OPEN":
            state = .open
        case "CLOSED":
            state = stateReason == "NOT_PLANNED" ? .closedNotPlanned : .closed
        default:
            state = .unknown
        }

        let author = issue["author"] as? [String: Any]
        return GitHubNotification.SubjectMetadata(
            state: state,
            ciStatus: nil,
            nodeID: issue["id"] as? String,
            openerLogin: author?["login"] as? String,
            openerAvatarURL: (author?["avatarUrl"] as? String).flatMap(URL.init(string:)),
            hasResolvedOpener: true
        )
    }

    // MARK: - Mark as read

    func markAsRead(threadId: String) async throws {
        let traceID = UUID().uuidString
        let requestGeneration = credentialGeneration
        let url = try threadURL(threadId: threadId)
        var req = Self.makeRequest(url: url, token: token)
        req.httpMethod = "PATCH"
        let (data, response) = try await session.data(for: req)
        guard requestGeneration == credentialGeneration else {
            throw APIError.staleCredentialResponse
        }
        let status = try Self.validatedGitHubAPIResponse(response).statusCode
        logActionResponse(traceID: traceID, action: "mark-read", step: "patch-thread", threadId: threadId, request: req, response: response, data: data)
        guard status != 401 else {
            throw APIError.unauthorized
        }
        guard (200...299).contains(status) else {
            throw APIError.markReadFailed(status)
        }
        invalidateFeedCaches(FeedScope.allCases)
    }

    func markAsDone(notification: GitHubNotification) async throws {
        let traceID = UUID().uuidString
        let requestGeneration = credentialGeneration
        let url = try threadURL(threadId: notification.threadId)
        var req = Self.makeRequest(url: url, token: token)
        req.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: req)
        guard requestGeneration == credentialGeneration else {
            throw APIError.staleCredentialResponse
        }
        let status = try Self.validatedGitHubAPIResponse(response).statusCode
        logActionResponse(traceID: traceID, action: "done", step: "delete-thread", threadId: notification.threadId, request: req, response: response, data: data)
        guard status != 401 else {
            throw APIError.unauthorized
        }
        guard (200...299).contains(status) else {
            throw APIError.httpError(status)
        }
        invalidateFeedCaches(FeedScope.allCases)
    }

    func unsubscribe(notification: GitHubNotification) async throws {
        let traceID = UUID().uuidString
        let requestGeneration = credentialGeneration
        let operationToken = token

        // Use GraphQL updateSubscription(state: IGNORED) for a true mute.
        // The REST PUT ignored=true endpoint is documented but silently broken.
        if let nodeID = notification.graphQLNodeID {
            // Fast path: node ID was cached during subject metadata resolution
            do {
                try await ignoreViaGraphQLNodeID(nodeID, token: operationToken, traceID: traceID)
            } catch APIError.unauthorized {
                throw APIError.unauthorized
            } catch {
                DebugTrace.log("graphql ignore (cached) failed, falling back to REST thread=\(notification.threadId) error=\(error.localizedDescription)")
                try await ignoreViaREST(threadId: notification.threadId, token: operationToken, traceID: traceID)
            }
        } else if let ref = Self.parseSubjectRef(from: notification) {
            // Slow path: fetch node ID then mute
            do {
                try await ignoreViaGraphQL(ref: ref, token: operationToken, traceID: traceID)
            } catch APIError.unauthorized {
                throw APIError.unauthorized
            } catch {
                DebugTrace.log("graphql ignore failed, falling back to REST thread=\(notification.threadId) error=\(error.localizedDescription)")
                try await ignoreViaREST(threadId: notification.threadId, token: operationToken, traceID: traceID)
            }
        } else {
            try await ignoreViaREST(threadId: notification.threadId, token: operationToken, traceID: traceID)
        }
        guard requestGeneration == credentialGeneration else {
            throw APIError.staleCredentialResponse
        }
    }

    private func ignoreViaGraphQL(ref: SubjectRef, token: String, traceID: String) async throws {
        let typeField = ref.type == .pullRequest ? "pullRequest" : "issue"
        let owner = Self.escapeGraphQL(ref.owner)
        let repo = Self.escapeGraphQL(ref.repo)

        // Fetch the node ID
        let nodeQuery = """
        {
          repository(owner: "\(owner)", name: "\(repo)") {
            \(typeField)(number: \(ref.number)) {
              id
            }
          }
        }
        """

        let nodeData = try await graphQLRequest(query: nodeQuery, token: token)
        guard let repoObj = nodeData["repository"] as? [String: Any],
              let subjectObj = repoObj[typeField] as? [String: Any],
              let nodeId = subjectObj["id"] as? String else {
            throw APIError.graphQLNodeIDNotFound
        }

        try await ignoreViaGraphQLNodeID(nodeId, token: token, traceID: traceID)
    }

    private func ignoreViaGraphQLNodeID(_ nodeID: String, token: String, traceID: String) async throws {
        let mutationQuery = """
        mutation {
          updateSubscription(input: {subscribableId: "\(Self.escapeGraphQL(nodeID))", state: IGNORED}) {
            subscribable {
              ... on PullRequest { viewerSubscription }
              ... on Issue { viewerSubscription }
            }
          }
        }
        """

        let mutationData = try await graphQLRequest(query: mutationQuery, token: token)
        DebugTrace.log("graphql ignore success traceID=\(traceID) nodeId=\(nodeID) response=\(mutationData)")
    }

    private func ignoreViaREST(threadId: String, token: String, traceID: String) async throws {
        let subscriptionURL = try threadURL(threadId: threadId)
            .appendingPathComponent("subscription")
        var subscriptionRequest = Self.makeRequest(url: subscriptionURL, token: token)
        subscriptionRequest.httpMethod = "PUT"
        subscriptionRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        subscriptionRequest.httpBody = try JSONEncoder().encode(ThreadSubscriptionRequest(ignored: true))
        let (subscriptionData, subscriptionResponse) = try await session.data(for: subscriptionRequest)
        let subscriptionStatus = try Self.validatedGitHubAPIResponse(subscriptionResponse).statusCode
        logActionResponse(traceID: traceID, action: "unsubscribe", step: "ignore-thread-rest", threadId: threadId, request: subscriptionRequest, response: subscriptionResponse, data: subscriptionData)
        guard subscriptionStatus != 401 else {
            throw APIError.unauthorized
        }
        guard (200...299).contains(subscriptionStatus) else {
            throw APIError.httpError(subscriptionStatus)
        }
    }

    private func graphQLRequest(query: String, token: String) async throws -> [String: Any] {
        let graphQLURL = URL(string: "https://api.github.com/graphql")!
        var req = URLRequest(url: graphQLURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Octodot", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = ["query": query]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        let status = try Self.validatedGitHubAPIResponse(response).statusCode
        guard status != 401 else {
            throw APIError.unauthorized
        }
        guard (200...299).contains(status) else {
            throw APIError.httpError(status)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.graphQLParseError
        }

        if let errors = json["errors"] as? [Any], !errors.isEmpty {
            throw APIError.graphQLError
        }

        guard let dataObj = json["data"] as? [String: Any] else {
            throw APIError.graphQLParseError
        }

        return dataObj
    }

    // MARK: - Validate token

    func validateToken() async throws -> String {
        let url = baseURL.appendingPathComponent("user")
        let requestGeneration = credentialGeneration
        let request = Self.makeRequest(url: url, token: token)
        let (data, response) = try await session.data(for: request)
        guard requestGeneration == credentialGeneration else {
            throw APIError.staleCredentialResponse
        }
        let httpResponse = try Self.validatedGitHubAPIResponse(response)
        let status = httpResponse.statusCode

        switch status {
        case 200...299:
            try validateRequiredScopes(from: httpResponse)
            let user = try JSONDecoder.github.decode(APIUser.self, from: data)
            return user.login
        case 401:
            throw APIError.unauthorized
        case 403 where Self.isRateLimitedResponse(httpResponse):
            throw APIError.rateLimited
        case 403:
            throw APIError.forbidden
        case 429:
            throw APIError.rateLimited
        default:
            throw APIError.httpError(status)
        }
    }

    private func validateRequiredScopes(from response: HTTPURLResponse?) throws {
        guard let rawScopes = response?.value(forHTTPHeaderField: "X-OAuth-Scopes") else { return }
        let scopes = Self.parseOAuthScopes(rawScopes)

        let missing = Self.requiredClassicTokenScopes.subtracting(scopes).sorted()
        guard missing.isEmpty else {
            throw APIError.insufficientScopes(missing: missing)
        }
    }

    private static func parseOAuthScopes(_ rawScopes: String) -> Set<String> {
        Set(rawScopes
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
    }

    private static func isRateLimitedResponse(_ response: HTTPURLResponse?) -> Bool {
        guard let response else { return false }
        return response.value(forHTTPHeaderField: "Retry-After") != nil
            || response.value(forHTTPHeaderField: "X-RateLimit-Remaining")?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "0"
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

    private static func makeNotificationsRequest(url: URL, token: String) -> URLRequest {
        var req = makeRequest(url: url, token: token)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return req
    }

    private static func trustedGitHubAPIURL(from string: String) -> URL? {
        guard let url = URL(string: string), isTrustedGitHubAPIURL(url) else {
            return nil
        }
        return url
    }

    private static func isTrustedGitHubAPIURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "api.github.com"
            && url.user == nil
            && url.password == nil
            && url.port == nil
    }

    private static func sanitizedToken(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return ""
        }
        return trimmed
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 45
                || $0 == 46
                || $0 == 95
        }
    }

    private static func repositoryComponents(from fullName: String) -> (owner: String, repository: String)? {
        let components = fullName.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 2,
              isSafePathComponent(components[0]),
              isSafePathComponent(components[1]) else {
            return nil
        }
        return (components[0], components[1])
    }

    private func threadURL(threadId: String) throws -> URL {
        guard Self.isSafePathComponent(threadId) else {
            throw APIError.invalidThreadID
        }
        return baseURL
            .appendingPathComponent("notifications")
            .appendingPathComponent("threads")
            .appendingPathComponent(threadId)
    }

    private static func makeRequest(url: URL, token: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Octodot", forHTTPHeaderField: "User-Agent")
        return req
    }

    private static func validatedGitHubAPIResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse,
              let finalURL = httpResponse.url,
              isTrustedGitHubAPIURL(finalURL) else {
            throw APIError.untrustedGitHubAPIURL
        }
        return httpResponse
    }

    private static func request(
        url: URL,
        token: String,
        session: any NetworkSession
    ) async throws -> Data {
        guard isTrustedGitHubAPIURL(url) else {
            throw APIError.untrustedGitHubAPIURL
        }

        let req = makeRequest(url: url, token: token)
        let (data, response) = try await session.data(for: req)
        try Task.checkCancellation()
        let httpResponse = try validatedGitHubAPIResponse(response)
        let status = httpResponse.statusCode

        switch status {
        case 200...299:
            return data
        case 401:
            throw APIError.unauthorized
        case 403 where isRateLimitedResponse(httpResponse):
            throw APIError.rateLimited
        case 403:
            throw APIError.forbidden
        case 429:
            throw APIError.rateLimited
        default:
            throw APIError.httpError(status)
        }
    }

    private func updatePollingHeaders(
        from response: HTTPURLResponse?,
        scope: FeedScope,
        requestID: UUID
    ) {
        guard let response else { return }

        updateFeedCache(scope, for: requestID) { cache in
            if let pollInterval = response.value(forHTTPHeaderField: "X-Poll-Interval"),
               let seconds = TimeInterval(pollInterval),
               seconds.isFinite,
               seconds >= 0 {
                cache.nextNotificationsRefreshAt = Date().addingTimeInterval(
                    min(seconds, maximumPollInterval)
                )
            } else {
                cache.nextNotificationsRefreshAt = Date().addingTimeInterval(defaultPollInterval)
            }
        }
    }

    private func beginFeedRequest(for scope: FeedScope) -> UUID {
        let requestID = UUID()
        latestFeedRequestIDs[scope] = requestID
        return requestID
    }

    private func isLatestFeedRequest(_ requestID: UUID, for scope: FeedScope) -> Bool {
        latestFeedRequestIDs[scope] == requestID
    }

    private func invalidateFeedRequests(_ scopes: some Sequence<FeedScope>) {
        for scope in scopes {
            latestFeedRequestIDs[scope] = UUID()
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

    private func updateFeedCache(
        _ scope: FeedScope,
        for requestID: UUID,
        mutate: (inout FeedCache) -> Void
    ) {
        guard isLatestFeedRequest(requestID, for: scope) else { return }
        updateFeedCache(scope, mutate: mutate)
    }

    private func invalidateFeedCaches(_ scopes: some Sequence<FeedScope>) {
        for scope in scopes {
            latestFeedRequestIDs[scope] = UUID()
            updateFeedCache(scope) { cache in
                cache.notifications = []
                cache.hasFetchedSuccessfully = false
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

    private func nextPageURL(from response: HTTPURLResponse?) throws -> URL? {
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
            guard let url = Self.trustedGitHubAPIURL(from: urlString) else {
                DebugTrace.log("fetch rejected untrusted next page url=\(urlString)")
                throw APIError.untrustedGitHubAPIURL
            }
            return url
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
        case graphQLNodeIDNotFound
        case graphQLParseError
        case graphQLError
        case insufficientScopes(missing: [String])
        case untrustedGitHubAPIURL
        case invalidThreadID
        case staleCredentialResponse

        var errorDescription: String? {
            switch self {
            case .unauthorized: "Token is invalid or expired"
            case .forbidden: "Access forbidden — check token scopes"
            case .rateLimited: "GitHub API rate limit exceeded"
            case .httpError(let code): "GitHub API error (\(code))"
            case .markReadFailed(let code): "Failed to mark as read (\(code))"
            case .graphQLNodeIDNotFound: "Could not resolve subject for subscription update"
            case .graphQLParseError: "GraphQL response could not be parsed"
            case .graphQLError: "GitHub GraphQL request failed"
            case .insufficientScopes(let missing): "Token is missing required scopes: \(missing.joined(separator: ", "))"
            case .untrustedGitHubAPIURL: "GitHub API response referenced an unexpected URL"
            case .invalidThreadID: "Notification thread identifier is invalid"
            case .staleCredentialResponse: "Ignored a response for replaced credentials"
            }
        }
    }
}

// MARK: - API response models

private struct APINotification: Decodable {
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
        guard reason != "security_alert",
              let type = mapType(subject.type) else {
            return nil
        }
        let reason = mapReason(reason)
        guard let date = ISO8601DateFormatter().date(from: updatedAt) else {
            return nil
        }
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
           let apiURL = URL(string: apiURLString),
           apiURL.scheme?.lowercased() == "https",
           apiURL.host?.lowercased() == "api.github.com",
           apiURL.user == nil,
           apiURL.password == nil,
           apiURL.port == nil {
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
                default: webType = typeSegment
                }
                if let url = URL(string: "https://github.com/\(owner)/\(repo)/\(webType)/\(number)") {
                    return url
                }
            }
        }
        guard let repositoryURL = URL(string: repository.htmlUrl),
              repositoryURL.scheme?.lowercased() == "https",
              repositoryURL.host?.lowercased() == "github.com",
              repositoryURL.user == nil,
              repositoryURL.password == nil,
              repositoryURL.port == nil else {
            return URL(string: "https://github.com")!
        }
        return repositoryURL
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

    private func mapType(_ type: String) -> GitHubNotification.SubjectType? {
        switch type {
        case "PullRequest": .pullRequest
        case "Issue": .issue
        default: nil
        }
    }
}

private struct APISubjectState: Decodable {
    struct Head: Decodable {
        let sha: String
    }

    struct User: Decodable {
        let login: String
        let avatarUrl: URL?
    }

    let state: String?
    let merged: Bool?
    let mergedAt: String?
    let draft: Bool?
    let stateReason: String?
    let head: Head?
    let user: User?
    let tagName: String?
    let htmlUrl: URL?

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

extension JSONDecoder {
    static let github: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
