import AppKit

struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    /// CGEventFlags raw value, already narrowed to the device-independent bits.
    var modifiers: UInt64
    var display: String

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }
}

/// Captures the next key combination the user presses.
///
/// A local monitor is used rather than a text field so modifier-only presses
/// can be ignored and the raw key code kept; what gets replayed later has to be
/// the key code, not the character it produced.
enum ShortcutRecorder {
    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    @MainActor
    static func record(title: String) -> Shortcut? {
        let alert = NSAlert()
        alert.messageText = "\(title)のショートカット"
        alert.informativeText = """
        割り当てたいキーの組み合わせを押してください。

        修飾キーだけでは確定しません。Esc で取り消します。
        """
        alert.addButton(withTitle: "取り消す")

        var captured: Shortcut?
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Esc
                NSApp.stopModal(withCode: .cancel)
                return nil
            }
            guard !modifierKeyCodes.contains(event.keyCode) else { return nil }
            captured = make(from: event)
            NSApp.stopModal(withCode: .OK)
            return nil
        }
        defer { NSEvent.removeMonitor(monitor) }

        // An accessory app is not frontmost, so it would not see key events.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .OK ? captured : nil
    }

    private static func make(from event: NSEvent) -> Shortcut {
        var flags: CGEventFlags = []
        let m = event.modifierFlags
        if m.contains(.control) { flags.insert(.maskControl) }
        if m.contains(.option)  { flags.insert(.maskAlternate) }
        if m.contains(.shift)   { flags.insert(.maskShift) }
        if m.contains(.command) { flags.insert(.maskCommand) }
        if m.contains(.function) { flags.insert(.maskSecondaryFn) }

        return Shortcut(keyCode: event.keyCode,
                        modifiers: flags.rawValue,
                        display: describe(event: event, modifiers: m))
    }

    private static func describe(event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option)  { text += "⌥" }
        if modifiers.contains(.shift)   { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + keyName(for: event)
    }

    private static func keyName(for event: NSEvent) -> String {
        let named: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let name = named[event.keyCode] { return name }
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            return chars.uppercased()
        }
        return "key \(event.keyCode)"
    }
}
