import SwiftUI

struct NotificationListView: View {
    let notifications: [GitHubNotification]
    let selectedNotificationID: String?
    let groupByRepo: Bool
    let onSelect: (String) -> Void

    struct ScrollRequest: Equatable {
        let targetID: String
        let visibleIDs: [String]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(notifications.enumerated()), id: \.element.id) { pair in
                        if groupByRepo && isFirstInRepo(index: pair.offset) {
                            Text(pair.element.repository)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.top, pair.offset == 0 ? 4 : 12)
                                .padding(.bottom, 4)
                        }

                        NotificationRowView(
                            notification: pair.element,
                            isSelected: pair.element.id == selectedNotificationID
                        )
                        .id(pair.element.id)
                        .onTapGesture { onSelect(pair.element.id) }
                    }
                }
            }
            .task(id: Self.scrollRequest(selectedNotificationID: selectedNotificationID, notifications: notifications)) {
                guard let scrollRequest = Self.scrollRequest(
                    selectedNotificationID: selectedNotificationID,
                    notifications: notifications
                ) else {
                    return
                }

                await Task.yield()
                proxy.scrollTo(scrollRequest.targetID)
            }
        }
    }

    static func scrollRequest(
        selectedNotificationID: String?,
        notifications: [GitHubNotification]
    ) -> ScrollRequest? {
        guard let selectedNotificationID,
              notifications.contains(where: { $0.id == selectedNotificationID }) else {
            return nil
        }

        return ScrollRequest(
            targetID: selectedNotificationID,
            visibleIDs: notifications.map(\.id)
        )
    }

    private func isFirstInRepo(index: Int) -> Bool {
        index == 0 || notifications[index].repository != notifications[index - 1].repository
    }
}
