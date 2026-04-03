import SwiftUI

struct NotificationListView: View {
    let notifications: [GitHubNotification]
    let selectedNotificationID: String?
    let groupByRepo: Bool
    let onSelect: (String) -> Void
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
        let targetID: String
        let visibleIDs: [String]
    }

    private var listItems: [ListItem] {
        Self.listItems(
            notifications: notifications,
            selectedNotificationID: selectedNotificationID,
            groupByRepo: groupByRepo
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(listItems, id: \.id) { item in
                        listItemView(item)
                    }
                }
            }
            .task(id: Self.scrollRequest(
                selectedNotificationID: selectedNotificationID,
                notifications: notifications,
                groupByRepo: groupByRepo
            )) {
                guard let scrollRequest = Self.scrollRequest(
                    selectedNotificationID: selectedNotificationID,
                    notifications: notifications,
                    groupByRepo: groupByRepo
                ) else {
                    return
                }

                await Task.yield()
                proxy.scrollTo(scrollRequest.targetID)
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
                isSelected: isSelected
            )
            .id(notification.id)
            .onTapGesture { onSelect(notification.id) }
            .onAppear { onNotificationVisible(notification.id) }
        }
    }

    static func scrollRequest(
        selectedNotificationID: String?,
        notifications: [GitHubNotification],
        groupByRepo: Bool
    ) -> ScrollRequest? {
        guard let selectedNotificationID,
              let selectedIndex = notifications.firstIndex(where: { $0.id == selectedNotificationID }) else {
            return nil
        }

        let targetID: String
        if groupByRepo,
           selectedIndex == 0 || notifications[selectedIndex - 1].repository != notifications[selectedIndex].repository {
            targetID = "repo:\(notifications[selectedIndex].repository)"
        } else {
            targetID = selectedNotificationID
        }

        return ScrollRequest(
            targetID: targetID,
            visibleIDs: notifications.map(\.id)
        )
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
