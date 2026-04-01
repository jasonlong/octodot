import SwiftUI

struct NotificationListView: View {
    let notifications: [GitHubNotification]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(notifications.enumerated()), id: \.element.id) { pair in
                        NotificationRowView(
                            notification: pair.element,
                            isSelected: pair.offset == selectedIndex
                        )
                        .id(pair.element.id)
                        .onTapGesture { onSelect(pair.offset) }
                    }
                }
            }
            .onChange(of: selectedIndex) { _, newValue in
                guard newValue >= 0 && newValue < notifications.count else { return }
                proxy.scrollTo(notifications[newValue].id)
            }
        }
    }
}
