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
        nsView.shortcut = shortcut
        nsView.colorScheme = colorScheme
    }
}

final class RecorderField: NSView {
    var onChange: ((AppPreferences.GlobalShortcut) -> Void)?
    var shortcut = AppPreferences.GlobalShortcut.commandQuote {
        didSet {
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
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

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.alignment = .center
        textField.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        addSubview(textField)

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

        if isRecording {
            backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14)
            borderColor = NSColor.controlAccentColor
            textField.stringValue = "Type shortcut"
        } else {
            backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08)
            borderColor = NSColor.separatorColor.withAlphaComponent(0.7)
            textField.stringValue = shortcut.displayText
        }

        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderColor = borderColor.cgColor
        textField.textColor = isRecording ? NSColor.controlAccentColor : NSColor.labelColor
    }
}
