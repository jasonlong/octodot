import SwiftUI

struct NotificationListView: View {
    let notifications: [GitHubNotification]
    let selectedIndex: Int
    let groupByRepo: Bool
    let onSelect: (Int) -> Void

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

    private func isFirstInRepo(index: Int) -> Bool {
        index == 0 || notifications[index].repository != notifications[index - 1].repository
    }
}
