import AppKit
import SwiftUI

struct HotkeyRecorderView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var shortcut: AppPreferences.GlobalShortcut

    func makeNSView(context: Context) -> RecorderField {
        let view = RecorderField()
        view.onChange = { newShortcut in
            shortcut = newShortcut
        }
        view.shortcut = shortcut
        view.colorScheme = colorScheme
        return view
    }

    func updateNSView(_ nsView: RecorderField, context: Context) {
        nsView.onChange = { newShortcut in
            shortcut = newShortcut
        }
        if nsView.shortcut != shortcut {
            nsView.shortcut = shortcut
        }
        if nsView.colorScheme != colorScheme {
            nsView.colorScheme = colorScheme
        }
    }
}

final class RecorderField: NSView {
    var onChange: ((AppPreferences.GlobalShortcut) -> Void)?
    var shortcut = AppPreferences.GlobalShortcut.commandQuote {
        didSet {
            guard shortcut != oldValue else { return }
            updateAppearance()
        }
    }
    var colorScheme: ColorScheme? {
        didSet {
            switch colorScheme {
            case .dark:
                appearance = NSAppearance(named: .darkAqua)
            case .light:
                appearance = NSAppearance(named: .aqua)
            case nil:
                appearance = nil
            @unknown default:
                appearance = nil
            }
            updateAppearance()
        }
    }

    private let textField = NSTextField(labelWithString: "")
    private var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            updateAppearance()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            updateAppearance()
        }
        return didBecomeFirstResponder
    }

    override func mouseDown(with event: NSEvent) {
        guard window?.makeFirstResponder(self) == true else { return }
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder {
            isRecording = false
            updateAppearance()
        }
        return didResignFirstResponder
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            if [36, 49, 76].contains(event.keyCode) {
                isRecording = true
            } else {
                super.keyDown(with: event)
            }
            return
        }

        if event.keyCode == 53 {
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        }

        let modifierFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let candidate = AppPreferences.GlobalShortcut(keyCode: event.keyCode, modifierFlags: modifierFlags)

        guard candidate.isValid else {
            NSSound.beep()
            return
        }

        shortcut = candidate
        onChange?(candidate)
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    override func accessibilityPerformPress() -> Bool {
        guard window?.makeFirstResponder(self) == true else { return false }
        isRecording = true
        return true
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.alignment = .center
        textField.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        textField.setAccessibilityElement(false)
        addSubview(textField)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Global shortcut")
        setAccessibilityHelp("Press to record a new shortcut. Escape cancels recording.")

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            textField.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            heightAnchor.constraint(equalToConstant: 34),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 132)
        ])

        updateAppearance()
    }

    private func updateAppearance() {
        let backgroundColor: NSColor
        let borderColor: NSColor
        let isFocused = window?.firstResponder === self

        if isRecording {
            backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14)
            borderColor = NSColor.controlAccentColor
            textField.stringValue = "Type shortcut"
        } else if isFocused {
            backgroundColor = NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.08)
            borderColor = NSColor.keyboardFocusIndicatorColor
            textField.stringValue = shortcut.displayText
        } else {
            backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08)
            borderColor = NSColor.separatorColor.withAlphaComponent(0.7)
            textField.stringValue = shortcut.displayText
        }

        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderColor = borderColor.cgColor
        textField.textColor = isRecording ? NSColor.controlAccentColor : NSColor.labelColor
        setAccessibilityValue(isRecording ? "Recording" : shortcut.displayText)
    }
}
