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
    var ciStatus: CIStatus?
    var graphQLNodeID: String?
    var source: Source = .thread

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
        case .securityAlert: "octicon-alert"
        }
    }

    var iconColor: Color {
        switch type {
        case .pullRequest:
            switch subjectState {
            case .merged: .purple
            case .closed: .red
            case .draft: .gray
            case .open: Color("OcticonGreen")
            case .unknown, .closedNotPlanned: .secondary
            }
        case .issue:
            switch subjectState {
            case .closed: .purple
            case .closedNotPlanned: .gray
            case .open: Color("OcticonGreen")
            case .unknown, .merged, .draft: .secondary
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

    var displayReferenceNumber: String? {
        let pathComponents = url.pathComponents

        switch type {
        case .pullRequest:
            guard let index = pathComponents.firstIndex(of: "pull"),
                  pathComponents.indices.contains(index + 1) else {
                return nil
            }
            return "#\(pathComponents[index + 1])"
        case .issue:
            guard let index = pathComponents.firstIndex(of: "issues"),
                  pathComponents.indices.contains(index + 1) else {
                return nil
            }
            return "#\(pathComponents[index + 1])"
        case .release, .discussion, .commit, .securityAlert:
            return nil
        }
    }

    func matchesActivity(as other: GitHubNotification) -> Bool {
        activityIdentity == other.activityIdentity
    }

    var needsSubjectMetadataResolution: Bool {
        guard subjectURL != nil else { return false }

        switch type {
        case .pullRequest:
            return subjectState == .unknown || (subjectState == .open && ciStatus == nil)
        case .issue:
            return subjectState == .unknown
        case .release, .discussion, .commit, .securityAlert:
            return false
        }
    }

    var ciStatusIconName: String? {
        switch ciStatus {
        case .success: "octicon-check"
        case .failure: "octicon-x"
        case .pending: "octicon-dot-fill"
        case nil: nil
        }
    }

    var ciStatusColor: Color? {
        switch ciStatus {
        case .success: .green
        case .failure: .red
        case .pending: .yellow
        case nil: nil
        }
    }

    enum SubjectState: String, Hashable, Codable {
        case open
        case closed
        case merged
        case draft
        case closedNotPlanned
        case unknown
    }

    enum CIStatus: String, Hashable, Codable {
        case success
        case failure
        case pending
    }

    struct SubjectMetadata: Hashable {
        var state: SubjectState
        var ciStatus: CIStatus?
        var nodeID: String? = nil
    }

    enum Source: String, Hashable, Codable {
        case thread
        case dependabotAlert
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
            self == .mentioned || self == .assigned || self == .author
        }

        var tintColor: Color? {
            switch self {
            case .mentioned, .assigned, .author:
                return Color("OcticonGreen")
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
