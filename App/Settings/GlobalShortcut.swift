import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key combination that opens the remote from anywhere. Uses the Carbon hot key API,
/// which needs no accessibility permission.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String
}

@MainActor
final class GlobalShortcut {
    static let shared = GlobalShortcut()

    private static let defaultsKey = "GlobalShortcut"
    private var hotKey: EventHotKeyRef?
    private var handlerInstalled = false

    private(set) var combo: KeyCombo?

    /// Loads the saved shortcut and registers it.
    func start() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey) {
            combo = try? JSONDecoder().decode(KeyCombo.self, from: data)
        }
        register()
    }

    func set(_ newCombo: KeyCombo?) {
        combo = newCombo
        if let newCombo, let data = try? JSONEncoder().encode(newCombo) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
        register()
    }

    private func register() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        guard let combo else { return }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x434C_4B52), id: 1) // "CLKR"
        RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKey)
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { StatusItemMenu.togglePopover() }
            }
            return noErr
        }, 1, &pressed, nil, nil)
    }
}

/// Click to record, then press the shortcut. Esc cancels. Needs ⌘, ⌥ or ⌃.
struct ShortcutRecorder: View {
    @State private var combo = GlobalShortcut.shared.combo
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button(isRecording ? "Type a shortcut…" : (combo?.display ?? "Record Shortcut")) {
                isRecording ? stopRecording() : startRecording()
            }
            if combo != nil, !isRecording {
                Button("Clear") { save(nil) }
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated { record(event) }
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.subtracting(.shift).isEmpty else {
            NSSound.beep()
            return
        }
        save(KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: Self.carbon(flags), display: Self.display(event, flags)))
        stopRecording()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func save(_ newCombo: KeyCombo?) {
        GlobalShortcut.shared.set(newCombo)
        combo = newCombo
    }

    private static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static func display(_ event: NSEvent, _ flags: NSEvent.ModifierFlags) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        let names: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        ]
        let key = names[Int(event.keyCode)] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        return text + key
    }
}
