import SwiftUI

struct NotificationListView: View {
    private static let scrollCoordinateSpace = "notification-list-scroll"
    static let downwardContextAnchor = UnitPoint(x: 0.5, y: 0.35)

    let notifications: [GitHubNotification]
    let selectedNotificationID: String?
    let checkedIDs: Set<String>
    let groupByRepo: Bool
    let jumpToTopRequestID: Int
    let onSelect: (String) -> Void
    let onOpen: (String) -> Void
    let onToggleCheck: (String) -> Void
    let onDone: (String) -> Bool
    let onUnsubscribe: (String) -> Bool
    let onNotificationVisible: (String) -> Void

    enum ListItem: Equatable, Identifiable {
        case repositoryHeader(name: String, isFirst: Bool)
        case notification(GitHubNotification, isSelected: Bool)

        var id: String {
            switch self {
            case .repositoryHeader(let name, _):
                return "repo:\(name)"
            case .notification(let notification, _):
                return notification.id
            }
        }
    }

    struct ScrollRequest: Equatable {
        let selectedNotificationID: String
        let targetID: String
        let topTargetID: String
        let visibleIDs: [String]
        let jumpToTopRequestID: Int
    }

    @State private var knownRowFrames: [String: CGRect] = [:]
    @State private var previousScrollRequest: ScrollRequest?
    @State private var pendingPointerActionID: String?

    private var listItems: [ListItem] {
        Self.listItems(
            notifications: notifications,
            selectedNotificationID: selectedNotificationID,
            groupByRepo: groupByRepo
        )
    }

    var body: some View {
        let visibleNotificationIDs = notifications.map(\.id)
        let currentScrollRequest = Self.scrollRequest(
            selectedNotificationID: selectedNotificationID,
            notifications: notifications,
            groupByRepo: groupByRepo,
            jumpToTopRequestID: jumpToTopRequestID
        )

        GeometryReader { viewportGeometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(listItems, id: \.id) { item in
                            listItemView(item)
                                .id(item.id)
                        }
                    }
                }
                .coordinateSpace(.named(Self.scrollCoordinateSpace))
                .onPreferenceChange(NotificationListRowFramesPreferenceKey.self) { frames in
                    var updatedFrames = knownRowFrames
                    updatedFrames.merge(frames) { _, latest in latest }
                    if updatedFrames != knownRowFrames {
                        knownRowFrames = updatedFrames
                    }
                }
                .onChange(of: visibleNotificationIDs) { _, visibleIDs in
                    let visibleIDSet = Set(visibleIDs)
                    knownRowFrames = knownRowFrames.filter { visibleIDSet.contains($0.key) }
                }
                .task(id: currentScrollRequest) {
                    guard let scrollRequest = currentScrollRequest else {
                        previousScrollRequest = nil
                        pendingPointerActionID = nil
                        return
                    }

                    let priorRequest = previousScrollRequest
                    let priorRowFrame = priorRequest.flatMap {
                        knownRowFrames[$0.selectedNotificationID]
                    }
                    previousScrollRequest = scrollRequest

                    if Self.shouldSuppressScroll(
                        previous: priorRequest,
                        current: scrollRequest,
                        pointerActionID: pendingPointerActionID
                    ) {
                        pendingPointerActionID = nil
                        return
                    }

                    await Task.yield()
                    if Self.shouldAnchorTop(previous: priorRequest, current: scrollRequest) {
                        proxy.scrollTo(scrollRequest.topTargetID, anchor: .top)
                        return
                    }

                    let currentRowFrame = knownRowFrames[scrollRequest.selectedNotificationID]
                    let shouldRevealContext = Self.shouldRevealDownwardContext(
                        previous: priorRequest,
                        current: scrollRequest,
                        previousRowFrame: priorRowFrame,
                        currentRowFrame: currentRowFrame,
                        viewportHeight: viewportGeometry.size.height
                    )
                    if shouldRevealContext {
                        proxy.scrollTo(
                            scrollRequest.selectedNotificationID,
                            anchor: Self.downwardContextAnchor
                        )
                        return
                    }

                    proxy.scrollTo(scrollRequest.targetID)
                }
            }
        }
    }

    @ViewBuilder
    private func listItemView(_ item: ListItem) -> some View {
        switch item {
        case .repositoryHeader(let name, let isFirst):
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, isFirst ? 4 : 12)
                .padding(.bottom, 4)
        case .notification(let notification, let isSelected):
            NotificationRowView(
                notification: notification,
                isSelected: isSelected,
                isChecked: checkedIDs.contains(notification.id),
                onToggleCheck: { onToggleCheck(notification.id) },
                onDone: {
                    performPointerAction(id: notification.id, action: onDone)
                },
                onUnsubscribe: {
                    performPointerAction(id: notification.id, action: onUnsubscribe)
                },
                onActivate: {
                    Self.handleRowTap(
                        id: notification.id,
                        onSelect: onSelect,
                        onOpen: onOpen
                    )
                }
            )
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: NotificationListRowFramesPreferenceKey.self,
                        value: [
                            notification.id: geometry.frame(
                                in: .named(Self.scrollCoordinateSpace)
                            )
                        ]
                    )
                }
            }
            .onAppear { onNotificationVisible(notification.id) }
        }
    }

    static func handleRowTap(
        id: String,
        onSelect: (String) -> Void,
        onOpen: (String) -> Void
    ) {
        onSelect(id)
        onOpen(id)
    }

    static func scrollRequest(
        selectedNotificationID: String?,
        notifications: [GitHubNotification],
        groupByRepo: Bool,
        jumpToTopRequestID: Int = 0
    ) -> ScrollRequest? {
        guard let selectedNotificationID,
              notifications.contains(where: { $0.id == selectedNotificationID }) else {
            return nil
        }

        return ScrollRequest(
            selectedNotificationID: selectedNotificationID,
            targetID: selectedNotificationID,
            topTargetID: groupByRepo ? "repo:\(notifications[0].repository)" : notifications[0].id,
            visibleIDs: notifications.map(\.id),
            jumpToTopRequestID: jumpToTopRequestID
        )
    }

    static func shouldAnchorTop(previous: ScrollRequest?, current: ScrollRequest) -> Bool {
        guard let previous else { return false }
        return previous.jumpToTopRequestID != current.jumpToTopRequestID
    }

    static func shouldRevealDownwardContext(
        previous: ScrollRequest?,
        current: ScrollRequest,
        previousRowFrame: CGRect?,
        currentRowFrame: CGRect?,
        viewportHeight: CGFloat
    ) -> Bool {
        guard let previous,
              viewportHeight > 0,
              let previousIndex = previous.visibleIDs.firstIndex(of: previous.selectedNotificationID),
              let currentIndexInPreviousList = previous.visibleIDs.firstIndex(of: current.selectedNotificationID),
              currentIndexInPreviousList > previousIndex else {
            return false
        }

        guard let previousRowFrame else { return false }

        guard let currentRowFrame else {
            return true
        }
        if currentRowFrame.maxY > viewportHeight {
            return true
        }

        let bottomTolerance = max(12, previousRowFrame.height * 0.5)
        return previousRowFrame.maxY >= viewportHeight - bottomTolerance
    }

    static func shouldSuppressScroll(
        previous: ScrollRequest?,
        current: ScrollRequest,
        pointerActionID: String?
    ) -> Bool {
        guard let pointerActionID else { return false }
        return previous?.visibleIDs.contains(pointerActionID) == true &&
            !current.visibleIDs.contains(pointerActionID)
    }

    private func performPointerAction(id: String, action: (String) -> Bool) {
        pendingPointerActionID = id
        if !action(id) {
            pendingPointerActionID = nil
        }
    }

    static func listItems(
        notifications: [GitHubNotification],
        selectedNotificationID: String?,
        groupByRepo: Bool
    ) -> [ListItem] {
        guard groupByRepo else {
            return notifications.map {
                .notification($0, isSelected: $0.id == selectedNotificationID)
            }
        }

        var items: [ListItem] = []
        var previousRepository: String?

        for notification in notifications {
            if notification.repository != previousRepository {
                items.append(.repositoryHeader(
                    name: notification.repository,
                    isFirst: previousRepository == nil
                ))
                previousRepository = notification.repository
            }

            items.append(.notification(
                notification,
                isSelected: notification.id == selectedNotificationID
            ))
        }

        return items
    }
}

private struct NotificationListRowFramesPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, latest in latest }
    }
}
