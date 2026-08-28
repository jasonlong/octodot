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
    var url: URL
    let subjectURL: String?
    var subjectState: SubjectState
    var ciStatus: CIStatus?
    var hasResolvedCIStatus = false
    var graphQLNodeID: String?
    var openerLogin: String?
    var openerAvatarURL: URL?
    var hasResolvedOpener = false
    var source: Source = .thread

    var isIssueOrPullRequest: Bool {
        type == .issue || type == .pullRequest
    }

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

    @discardableResult
    mutating func apply(_ metadata: SubjectMetadata) -> Bool {
        let resolvedNodeID = metadata.nodeID ?? graphQLNodeID
        let resolvedURL = metadata.webURL ?? url
        let resolvedOpenerLogin = metadata.openerLogin ?? openerLogin
        let resolvedOpenerAvatarURL = metadata.openerAvatarURL ?? openerAvatarURL
        let resolvedOpenerState = hasResolvedOpener || metadata.hasResolvedOpener
        guard subjectState != metadata.state ||
                ciStatus != metadata.ciStatus ||
                hasResolvedCIStatus != metadata.hasResolvedCIStatus ||
                graphQLNodeID != resolvedNodeID ||
                url != resolvedURL ||
                openerLogin != resolvedOpenerLogin ||
                openerAvatarURL != resolvedOpenerAvatarURL ||
                hasResolvedOpener != resolvedOpenerState else {
            return false
        }

        subjectState = metadata.state
        ciStatus = metadata.ciStatus
        hasResolvedCIStatus = metadata.hasResolvedCIStatus
        graphQLNodeID = resolvedNodeID
        url = resolvedURL
        openerLogin = resolvedOpenerLogin
        openerAvatarURL = resolvedOpenerAvatarURL
        hasResolvedOpener = resolvedOpenerState
        return true
    }

    var needsSubjectMetadataResolution: Bool {
        guard subjectURL != nil else { return false }

        switch type {
        case .pullRequest:
            return !hasResolvedOpener || subjectState == .unknown || (subjectState == .open && !hasResolvedCIStatus)
        case .issue:
            return !hasResolvedOpener || subjectState == .unknown
        case .release:
            guard let subjectURL,
                  let apiURL = URL(string: subjectURL) else {
                return false
            }
            return url.lastPathComponent == apiURL.lastPathComponent
        case .discussion, .commit, .securityAlert:
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
        var hasResolvedCIStatus = false
        var nodeID: String? = nil
        var webURL: URL? = nil
        var openerLogin: String? = nil
        var openerAvatarURL: URL? = nil
        var hasResolvedOpener = false
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

        var badgeBackgroundColor: Color? {
            switch self {
            case .mentioned, .assigned, .author:
                return Color(red: 0.18, green: 0.7, blue: 0.35)
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
