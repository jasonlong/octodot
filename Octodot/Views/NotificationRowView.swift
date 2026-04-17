import AppKit
import SwiftUI

struct NotificationRowView: View, Equatable {
    let notification: GitHubNotification
    let isSelected: Bool
    let isChecked: Bool
    let onToggleCheck: () -> Void

    static func == (lhs: NotificationRowView, rhs: NotificationRowView) -> Bool {
        lhs.notification == rhs.notification
            && lhs.isSelected == rhs.isSelected
            && lhs.isChecked == rhs.isChecked
    }

    var body: some View {
        HStack(spacing: 8) {
            CheckableIconView(
                notification: notification,
                isChecked: isChecked,
                onToggle: onToggleCheck
            )

            // Content
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

            // Right side: reason + time
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
        .contentShape(Rectangle())
        .background(isSelected ? Color.primary.opacity(0.1) : Color.clear)
        .overlay(HoverBackground())
    }

    private var relativeTime: String {
        Self.relativeTimeText(from: notification.updatedAt)
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

private struct CheckableIconView: View {
    let notification: GitHubNotification
    let isChecked: Bool
    let onToggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(notification.isUnread ? Color(red: 0.039, green: 0.518, blue: 1.0) : Color.clear)
                .frame(width: 6, height: 6)
                .frame(maxWidth: .infinity)

            iconContent
                .frame(width: iconRenderSize, height: iconRenderSize)
                .frame(width: 20)
        }
        .frame(width: 40, height: 44)
        .contentShape(Rectangle())
        .background(HoverDetector { isHovering = $0 })
        .onTapGesture { onToggle() }
    }

    private var iconRenderSize: CGFloat {
        isChecked ? 16 : 14
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

private struct HoverDetector: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onHoverChange = onHover
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onHoverChange = onHover
    }

    final class TrackingView: NSView {
        var onHoverChange: ((Bool) -> Void)?
        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let newArea = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(newArea)
            trackingArea = newArea
            syncHoverStateToCursor()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                deliverHoverChange(false)
            } else {
                syncHoverStateToCursor()
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChange?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChange?(false)
        }

        private func syncHoverStateToCursor() {
            guard let window else {
                deliverHoverChange(false)
                return
            }
            let mouseInWindow = window.mouseLocationOutsideOfEventStream
            let mouseInView = convert(mouseInWindow, from: nil)
            let isInside = visibleRect.contains(mouseInView)
            if !isInside {
                deliverHoverChange(false)
            }
        }

        private func deliverHoverChange(_ isHovering: Bool) {
            DispatchQueue.main.async { [weak self] in
                self?.onHoverChange?(isHovering)
            }
        }
    }
}
