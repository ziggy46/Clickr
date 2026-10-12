import Session
import SwiftUI

/// Keyboard control while the popover has focus (Section 5.6).
struct RemoteKeyboardShortcuts: ViewModifier {
    let model: RemoteViewModel
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.onKeyPress(phases: [.down, .repeat]) { press in
            guard isEnabled, let button = button(for: press) else { return .ignored }
            // Only the arrows (and ⌘ arrows for volume) repeat while held.
            if press.phase == .repeat, !Self.repeatingKeys.contains(press.key) {
                return .handled
            }
            model.press(button)
            return .handled
        }
    }

    private static let repeatingKeys: Set<KeyEquivalent> = [.upArrow, .downArrow, .leftArrow, .rightArrow]

    private func button(for press: KeyPress) -> RemoteButton? {
        let command = press.modifiers.contains(.command)
        switch press.key {
        case .upArrow: return command ? .volumeUp : .up
        case .downArrow: return command ? .volumeDown : .down
        case .leftArrow: return .left
        case .rightArrow: return .right
        case .return: return .select
        case .escape: return .menu
        case .space: return .playPause
        default:
            return press.characters.lowercased() == "h" && press.modifiers.isEmpty ? .home : nil
        }
    }
}
