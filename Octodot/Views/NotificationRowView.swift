import SwiftUI

struct NotificationRowView: View {
    let notification: GitHubNotification
    let isSelected: Bool
    let isChecked: Bool
    let onToggleCheck: () -> Void
    let onActivate: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            Button(action: onActivate) {
                rowContent
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Opens the notification in your browser")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            CheckableIconButton(
                notification: notification,
                isChecked: isChecked,
                onToggle: onToggleCheck
            )
        }
        .frame(height: 44)
        .background(isSelected ? Color.primary.opacity(0.1) : Color.clear)
        .overlay(HoverBackground())
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Color.clear
                .frame(width: 40, height: 44)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                repositoryLabel
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

            VStack(alignment: .trailing, spacing: 2) {
                Text(notification.reason.rawValue)
                    .font(.system(size: 10))
                    .foregroundStyle(notification.reason.tintColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(notification.reason.badgeBackgroundColor?.opacity(0.14) ?? Color.clear)
                    )

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
                            .accessibilityHidden(true)
                    }

                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(Self.relativeTimeText(from: notification.updatedAt, now: context.date))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .frame(minWidth: 58, alignment: .trailing)
            .padding(.trailing, 10)
        }
        .frame(height: 44)
        .contentShape(Rectangle())
    }

    private var accessibilityLabel: String {
        var parts = [notification.title, notification.repository, notification.reason.rawValue]
        if let referenceNumber = notification.displayReferenceNumber {
            parts[1] += referenceNumber
        }
        return parts.joined(separator: ", ")
    }

    private var accessibilityValue: String {
        var values = [notification.isUnread ? "Unread" : "Read"]
        if isChecked {
            values.append("Selected for bulk actions")
        }
        return values.joined(separator: ", ")
    }

    private var repositoryLabel: Text {
        if let referenceNumber = notification.displayReferenceNumber {
            return Text(notification.repository) + Text(referenceNumber).foregroundColor(Color.secondary.opacity(0.7))
        }

        return Text(notification.repository)
    }

    static func relativeTimeText(from updatedAt: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(updatedAt)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }
}

private struct CheckableIconButton: View {
    let notification: GitHubNotification
    let isChecked: Bool
    let onToggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 0) {
                Circle()
                    .fill(notification.isUnread ? Color(red: 0.039, green: 0.518, blue: 1.0) : Color.clear)
                    .frame(width: 6, height: 6)
                    .frame(maxWidth: .infinity)

                iconContent
                    .frame(width: 14, height: 14)
                    .frame(width: 20)
            }
            .frame(width: 40, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(isChecked ? "Remove from bulk actions" : "Select for bulk actions")
        .accessibilityHint(notification.title)
    }

    @ViewBuilder
    private var iconContent: some View {
        if isChecked {
            Image(systemName: "checkmark.square.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(Color.accentColor)
        } else if isHovering {
            Image(systemName: "square")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
        } else if notification.needsSubjectMetadataResolution {
            Circle()
                .fill(Color.primary.opacity(0.06))
        } else {
            Image(notification.iconName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(notification.iconColor)
                .opacity(notification.isUnread ? 1.0 : 0.5)
        }
    }
}

private struct HoverBackground: View {
    @State private var isHovered = false

    var body: some View {
        Rectangle()
            .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            .allowsHitTesting(false)
            .onHover { isHovered = $0 }
    }
}
