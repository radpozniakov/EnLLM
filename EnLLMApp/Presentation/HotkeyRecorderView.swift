import AppKit
import EnLLMCore
import EnLLMPlatform
import SwiftUI

struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var definition: HotkeyDefinition
    let action: AppAction
    let onBegin: (AppAction) -> Void
    let onEnd: () -> Void
    /// Forwards a raw captured combination to the model, which validates it and
    /// returns whether it was accepted (so the field can end or continue recording).
    let onCapture: (UInt32, UInt32, AppAction) -> Bool
    let onCancel: (AppAction) -> Void

    func makeNSView(context: Context) -> RecorderField {
        let view = RecorderField()
        view.onCapture = { onCapture($0, $1, action) }
        view.onCancel = { onCancel(action) }
        view.onBegin = { onBegin(action) }
        view.onEnd = onEnd
        view.setAccessibilityLabel("\(action.title) shortcut recorder")
        return view
    }

    func updateNSView(_ view: RecorderField, context: Context) {
        view.stringValue = HotkeyFormatter.string(for: definition)
    }
}

final class RecorderField: NSTextField {
    /// Returns true when the model accepted the capture (recording should end).
    var onCapture: ((UInt32, UInt32) -> Bool)?
    var onCancel: (() -> Void)?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBezeled = true
        bezelStyle = .roundedBezel
        alignment = .center
        focusRingType = .exterior
        toolTip = "Click, then press a key with Command, Option, Control, or Shift. Press Escape to cancel."
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { let value = super.becomeFirstResponder(); if value { onBegin?() }; return value }
    override func resignFirstResponder() -> Bool { let value = super.resignFirstResponder(); onEnd?(); return value }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        // Escape cancels and restores the previously displayed shortcut.
        if event.keyCode == 53 { onCancel?(); window?.makeFirstResponder(nil); return }
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { modifiers |= HotkeyDefinition.commandModifier }
        if event.modifierFlags.contains(.option) { modifiers |= HotkeyDefinition.optionModifier }
        if event.modifierFlags.contains(.control) { modifiers |= HotkeyDefinition.controlModifier }
        if event.modifierFlags.contains(.shift) { modifiers |= HotkeyDefinition.shiftModifier }
        // The model owns validation, duplicate rejection, and the single draft update.
        let accepted = onCapture?(UInt32(event.keyCode), modifiers) ?? false
        if accepted { window?.makeFirstResponder(nil) } else { NSSound.beep() }
    }
}
