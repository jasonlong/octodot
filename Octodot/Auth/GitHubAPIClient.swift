import Foundation

actor GitHubAPIClient {
    private let baseURL = URL(string: "https://api.github.com")!
    private var token: String

    init(token: String) {
        self.token = token
    }

    func updateToken(_ token: String) {
        self.token = token
    }

    // MARK: - Fetch notifications

    func fetchNotifications(all: Bool = false) async throws -> [GitHubNotification] {
        var components = URLComponents(url: baseURL.appendingPathComponent("notifications"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "all", value: all ? "true" : "false"),
            URLQueryItem(name: "per_page", value: "50"),
        ]

        let data = try await request(url: components.url!)
        let items = try JSONDecoder.github.decode([APINotification].self, from: data)
        var notifications = items.compactMap { $0.toModel() }

        // Fetch subject states concurrently
        await withTaskGroup(of: (String, GitHubNotification.SubjectState).self) { group in
            for notification in notifications where notification.subjectURL != nil {
                let subjectURL = notification.subjectURL!
                let id = notification.id
                group.addTask { [self] in
                    let state = await self.fetchSubjectState(apiURL: subjectURL)
                    return (id, state)
                }
            }

            for await (id, state) in group {
                if let index = notifications.firstIndex(where: { $0.id == id }) {
                    notifications[index].subjectState = state
                }
            }
        }

        return notifications
    }

    // MARK: - Fetch subject state

    private func fetchSubjectState(apiURL: String) async -> GitHubNotification.SubjectState {
        guard let url = URL(string: apiURL) else { return .unknown }
        do {
            let data = try await request(url: url)
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

    // MARK: - Mark as read

    func markAsRead(threadId: String) async throws {
        let url = baseURL.appendingPathComponent("notifications/threads/\(threadId)")
        var req = makeRequest(url: url)
        req.httpMethod = "PATCH"
        let (_, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) || status == 304 else {
            throw APIError.markReadFailed(status)
        }
    }

    // MARK: - Validate token

    func validateToken() async throws -> String {
        let url = baseURL.appendingPathComponent("user")
        let data = try await request(url: url)
        let user = try JSONDecoder.github.decode(APIUser.self, from: data)
        return user.login
    }

    // MARK: - Private

    private func makeRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return req
    }

    private func request(url: URL) async throws -> Data {
        let req = makeRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: req)
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
        let date = ISO8601DateFormatter().date(from: updatedAt) ?? Date()
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

extension JSONDecoder {
    static let github: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
