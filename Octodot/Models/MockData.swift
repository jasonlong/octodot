import Foundation

enum MockData {
    static func generateNotifications() -> [GitHubNotification] {
        let now = Date()
        return [
            GitHubNotification(
                id: "0", threadId: "0", title: "Test highlighted reason badges",
                repository: "acme/backend", reason: .mentioned, type: .issue,
                updatedAt: now.addingTimeInterval(-60), isUnread: true,
                url: URL(string: "https://github.com/acme/backend/issues/999")!,
                subjectURL: nil, subjectState: .open
            ),
            GitHubNotification(
                id: "1", threadId: "1", title: "Fix memory leak in WebSocket handler",
                repository: "acme/backend", reason: .reviewRequested, type: .pullRequest,
                updatedAt: now.addingTimeInterval(-120), isUnread: true,
                url: URL(string: "https://github.com/acme/backend/pull/1042")!,
                subjectURL: nil, subjectState: .open
            ),
            GitHubNotification(
                id: "2", threadId: "2", title: "Dashboard crashes on empty dataset",
                repository: "acme/web", reason: .mentioned, type: .issue,
                updatedAt: now.addingTimeInterval(-300), isUnread: true,
                url: URL(string: "https://github.com/acme/web/issues/891")!,
                subjectURL: nil, subjectState: .open
            ),
            GitHubNotification(
                id: "3", threadId: "3", title: "Add rate limiting to public API endpoints",
                repository: "acme/api-gateway", reason: .assigned, type: .pullRequest,
                updatedAt: now.addingTimeInterval(-600), isUnread: true,
                url: URL(string: "https://github.com/acme/api-gateway/pull/234")!,
                subjectURL: nil, subjectState: .merged
            ),
            GitHubNotification(
                id: "4", threadId: "4", title: "v2.4.0",
                repository: "vapor/vapor", reason: .subscribed, type: .release,
                updatedAt: now.addingTimeInterval(-1800), isUnread: true,
                url: URL(string: "https://github.com/vapor/vapor/releases/tag/2.4.0")!,
                subjectURL: nil, subjectState: .unknown
            ),
            GitHubNotification(
                id: "5", threadId: "5", title: "Migrate CI from CircleCI to GitHub Actions",
                repository: "acme/infrastructure", reason: .author, type: .pullRequest,
                updatedAt: now.addingTimeInterval(-2400), isUnread: true,
                url: URL(string: "https://github.com/acme/infrastructure/pull/89")!,
                subjectURL: nil, subjectState: .closed
            ),
            GitHubNotification(
                id: "6", threadId: "6", title: "RFC: New plugin architecture for v3",
                repository: "acme/core", reason: .mentioned, type: .discussion,
                updatedAt: now.addingTimeInterval(-3600), isUnread: true,
                url: URL(string: "https://github.com/acme/core/discussions/412")!,
                subjectURL: nil, subjectState: .unknown
            ),
            GitHubNotification(
                id: "7", threadId: "7", title: "Flaky test: test_concurrent_uploads",
                repository: "acme/storage", reason: .ciActivity, type: .issue,
                updatedAt: now.addingTimeInterval(-5400), isUnread: false,
                url: URL(string: "https://github.com/acme/storage/issues/203")!,
                subjectURL: nil, subjectState: .closed
            ),
            GitHubNotification(
                id: "8", threadId: "8", title: "Bump minimum Swift version to 5.9",
                repository: "pointfreeco/swift-composable-architecture", reason: .subscribed, type: .pullRequest,
                updatedAt: now.addingTimeInterval(-7200), isUnread: true,
                url: URL(string: "https://github.com/pointfreeco/swift-composable-architecture/pull/2801")!,
                subjectURL: nil, subjectState: .open
            ),
            GitHubNotification(
                id: "9", threadId: "9", title: "Add dark mode support to email templates",
                repository: "acme/notifications", reason: .reviewRequested, type: .pullRequest,
                updatedAt: now.addingTimeInterval(-10800), isUnread: true,
                url: URL(string: "https://github.com/acme/notifications/pull/67")!,
                subjectURL: nil, subjectState: .open
            ),
            GitHubNotification(
                id: "10", threadId: "10", title: "TypeError in checkout flow on Safari",
                repository: "acme/web", reason: .assigned, type: .issue,
                updatedAt: now.addingTimeInterval(-14400), isUnread: false,
                url: URL(string: "https://github.com/acme/web/issues/904")!,
                subjectURL: nil, subjectState: .closedNotPlanned
            ),
            GitHubNotification(
                id: "11", threadId: "11", title: "Refactor database connection pooling",
                repository: "acme/backend", reason: .comment, type: .pullRequest,
                updatedAt: now.addingTimeInterval(-18000), isUnread: true,
                url: URL(string: "https://github.com/acme/backend/pull/1038")!,
                subjectURL: nil, subjectState: .open
            ),
            GitHubNotification(
                id: "12", threadId: "12", title: "Update OpenAPI spec for v2 endpoints",
                repository: "acme/api-gateway", reason: .stateChange, type: .pullRequest,
                updatedAt: now.addingTimeInterval(-21600), isUnread: false,
                url: URL(string: "https://github.com/acme/api-gateway/pull/229")!,
                subjectURL: nil, subjectState: .merged
            ),
            GitHubNotification(
                id: "13", threadId: "13", title: "Add support for custom OAuth providers",
                repository: "acme/auth", reason: .author, type: .pullRequest,
                updatedAt: now.addingTimeInterval(-28800), isUnread: true,
                url: URL(string: "https://github.com/acme/auth/pull/156")!,
                subjectURL: nil, subjectState: .open
            ),
            GitHubNotification(
                id: "14", threadId: "14", title: "Security advisory: update dependency X",
                repository: "acme/web", reason: .subscribed, type: .commit,
                updatedAt: now.addingTimeInterval(-36000), isUnread: false,
                url: URL(string: "https://github.com/acme/web/commit/abc123")!,
                subjectURL: nil, subjectState: .unknown
            ),
            GitHubNotification(
                id: "15", threadId: "15", title: "Feature request: Webhook retry configuration",
                repository: "acme/webhooks", reason: .mentioned, type: .issue,
                updatedAt: now.addingTimeInterval(-43200), isUnread: true,
                url: URL(string: "https://github.com/acme/webhooks/issues/78")!,
                subjectURL: nil, subjectState: .open
            ),
        ]
    }
}
