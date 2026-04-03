import SwiftUI

struct NotificationRowView: View, Equatable {
    let notification: GitHubNotification
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Dot + icon in a fixed-width block
            HStack(spacing: 0) {
                Circle()
                    .fill(notification.isUnread ? Color(red: 0.039, green: 0.518, blue: 1.0) : Color.clear)
                    .frame(width: 6, height: 6)
                    .frame(maxWidth: .infinity)

                Image(notification.iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundStyle(notification.iconColor)
                    .opacity(notification.isUnread ? 1.0 : 0.5)
            }
            .frame(width: 40)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                Text(notification.repository)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(notification.title)
                    .font(.system(size: 13, weight: notification.isUnread ? .medium : .regular))
                    .foregroundStyle(notification.isUnread ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)

            Spacer(minLength: 2)

            // Right side: reason + time
            VStack(alignment: .trailing, spacing: 2) {
                Text(notification.reason.rawValue)
                    .font(.system(size: 10))
                    .foregroundStyle(notification.reason.tintColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                HStack(spacing: 4) {
                    if let ciIconName = notification.ciStatusIconName,
                       let ciColor = notification.ciStatusColor,
                       notification.type == .pullRequest,
                       notification.subjectState == .open {
                        Image(ciIconName)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 10, height: 10)
                            .foregroundStyle(ciColor)
                    }

                    Text(relativeTime)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(minWidth: 58, alignment: .trailing)
            .padding(.trailing, 10)
        }
        .frame(height: 44)
        .background(isSelected ? Color.primary.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
    }

    private var relativeTime: String {
        Self.relativeTimeText(from: notification.updatedAt)
    }

    static func relativeTimeText(from updatedAt: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(updatedAt)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }
}
