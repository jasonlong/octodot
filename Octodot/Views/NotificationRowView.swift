import SwiftUI

struct NotificationRowView: View {
    let notification: GitHubNotification
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Unread indicator
            Rectangle()
                .fill(notification.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 3)

            HStack(spacing: 10) {
                // Type icon
                Image(notification.iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundStyle(notification.iconColor)
                    .frame(width: 20, alignment: .center)

                // Content
                VStack(alignment: .leading, spacing: 2) {
                    Text(notification.repository)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(notification.title)
                        .font(.system(size: 13, weight: notification.isUnread ? .medium : .regular))
                        .foregroundStyle(notification.isUnread ? .primary : .secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                // Right side: reason + time
                VStack(alignment: .trailing, spacing: 2) {
                    Text(notification.reason.rawValue)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    Text(relativeTime)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(height: 44)
        .background(isSelected ? Color.white.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
    }

    private var relativeTime: String {
        let interval = Date().timeIntervalSince(notification.updatedAt)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }
}
