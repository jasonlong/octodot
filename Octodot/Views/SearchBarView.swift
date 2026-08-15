import AppKit
import SwiftUI

struct SearchBarView: View {
    @Binding var query: String
    let isFocused: Bool
    let onSubmit: (PanelInput.SearchSubmitTrigger) -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            SearchTextFieldRepresentable(
                query: $query,
                isFocused: isFocused,
                onSubmit: onSubmit,
                onCancel: onCancel
            )
            .frame(height: 18)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
    }
}

private struct SearchTextFieldRepresentable: NSViewRepresentable {
    @Binding var query: String
    let isFocused: Bool
    let onSubmit: (PanelInput.SearchSubmitTrigger) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(query: $query, onSubmit: onSubmit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> SearchTextField {
        let textField = SearchTextField()
        textField.isBordered = false
        textField.focusRingType = .none
        textField.drawsBackground = false
        textField.font = .systemFont(ofSize: 13)
        textField.placeholderString = "Filter notifications…"
        textField.delegate = context.coordinator
        textField.stringValue = query
        textField.setAccessibilityLabel("Filter notifications")
        context.coordinator.update(
            query: $query,
            isFocused: isFocused,
            onSubmit: onSubmit,
            onCancel: onCancel
        )
        return textField
    }

    func updateNSView(_ nsView: SearchTextField, context: Context) {
        context.coordinator.update(
            query: $query,
            isFocused: isFocused,
            onSubmit: onSubmit,
            onCancel: onCancel
        )
        nsView.delegate = context.coordinator
        if nsView.stringValue != query {
            nsView.stringValue = query
        }
        updateFocus(for: nsView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ nsView: SearchTextField, coordinator: Coordinator) {
        coordinator.isFocused = false
        nsView.delegate = nil
    }

    private func updateFocus(for textField: SearchTextField, coordinator: Coordinator) {
        guard let window = textField.window else { return }
        let firstResponder = window.firstResponder
        let fieldEditor = window.fieldEditor(false, for: textField)
        let isCurrentlyFocused = firstResponder === textField || firstResponder === fieldEditor

        if isFocused && !isCurrentlyFocused {
            DispatchQueue.main.async { [weak textField, weak coordinator] in
                guard let textField,
                      let coordinator,
                      coordinator.isFocused,
                      textField.window === window else {
                    return
                }
                window.makeFirstResponder(textField)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var query: String
        var isFocused = false
        private var onSubmit: (PanelInput.SearchSubmitTrigger) -> Void
        private var onCancel: () -> Void

        init(
            query: Binding<String>,
            onSubmit: @escaping (PanelInput.SearchSubmitTrigger) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self._query = query
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func update(
            query: Binding<String>,
            isFocused: Bool,
            onSubmit: @escaping (PanelInput.SearchSubmitTrigger) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self._query = query
            self.isFocused = isFocused
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            query = textField.stringValue
        }

        func control(
            _ control: NSControl,
            textView _: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertParagraphSeparator(_:)):
                onSubmit(.returnKey)
                return true
            case #selector(NSResponder.insertTab(_:)),
                 #selector(NSResponder.insertBacktab(_:)):
                onSubmit(.tab)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
                return true
            default:
                return false
            }
        }
    }
}

private final class SearchTextField: NSTextField {}
