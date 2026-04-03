import Foundation
import SwiftUI

struct GitHubNotification: Identifiable, Hashable {
    let id: String
    let threadId: String
    let title: String
    let repository: String
    let reason: Reason
    let type: SubjectType
    let updatedAt: Date
    var isUnread: Bool
    let url: URL
    let subjectURL: String?
    var subjectState: SubjectState

    var iconName: String {
        switch type {
        case .pullRequest:
            switch subjectState {
            case .merged: "octicon-merge"
            case .closed: "octicon-pull-request-closed"
            case .draft: "octicon-pull-request"
            default: "octicon-pull-request"
            }
        case .issue:
            switch subjectState {
            case .closed: "octicon-issue-closed"
            case .closedNotPlanned: "octicon-skip"
            default: "octicon-issue"
            }
        case .release: "octicon-tag"
        case .discussion: "octicon-discussion"
        case .commit: "octicon-commit"
        case .securityAlert: "octicon-issue"
        }
    }

    var iconColor: Color {
        switch type {
        case .pullRequest:
            switch subjectState {
            case .merged: .purple
            case .closed: .red
            case .draft: .gray
            default: .green
            }
        case .issue:
            switch subjectState {
            case .closed: .purple
            case .closedNotPlanned: .gray
            default: .green
            }
        case .release: .blue
        case .discussion: .yellow
        case .commit: .gray
        case .securityAlert: .orange
        }
    }

    var activityIdentity: String {
        let milliseconds = Int(updatedAt.timeIntervalSince1970 * 1_000)
        return "\(threadId)|\(milliseconds)"
    }

    func matchesActivity(as other: GitHubNotification) -> Bool {
        activityIdentity == other.activityIdentity
    }

    enum SubjectState: String, Hashable, Codable {
        case open
        case closed
        case merged
        case draft
        case closedNotPlanned
        case unknown
    }

    enum Reason: String, CaseIterable, Codable {
        case mentioned = "Mentioned"
        case reviewRequested = "Review requested"
        case assigned = "Assigned"
        case subscribed = "Subscribed"
        case ciActivity = "CI activity"
        case author = "Author"
        case comment = "Comment"
        case stateChange = "State change"
        case securityAlert = "Security alert"

        var isDirectlyInvolved: Bool {
            self == .mentioned || self == .assigned
        }

        var tintColor: Color? {
            switch self {
            case .securityAlert:
                return .orange
            case .mentioned, .assigned:
                return .green
            default:
                return nil
            }
        }
    }

    enum SubjectType: String, CaseIterable, Codable {
        case pullRequest = "Pull Request"
        case issue = "Issue"
        case release = "Release"
        case discussion = "Discussion"
        case commit = "Commit"
        case securityAlert = "Security Alert"
    }
}
