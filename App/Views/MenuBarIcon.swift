import AppKit
import Session
import SwiftUI

/// The Siri Remote icon in the menu bar (Section 5.1), dimmed or badged by connection state.
struct MenuBarIcon: View {
    let state: ConnectionState

    var body: some View {
        Image(nsImage: Self.image(for: state))
    }

    // MenuBarExtra labels don't reliably honor `.frame` or `.opacity`, so each state is
    // its own NSImage at the right size.
    static func image(for state: ConnectionState) -> NSImage {
        switch state {
        case .connected: connected
        case .needsPairing: needsPairing
        case .disconnected, .connecting: dimmed
        }
    }

    static let iconSize = NSSize(width: 11, height: 19)

    private static let remote: NSImage = {
        let image = (NSImage(named: "RemoteIcon")?.copy() as? NSImage) ?? NSImage()
        image.size = iconSize
        return image
    }()

    private static let connected = template { remote.draw(in: NSRect(origin: .zero, size: iconSize)) }

    private static let dimmed = template {
        remote.draw(in: NSRect(origin: .zero, size: iconSize), from: .zero, operation: .sourceOver, fraction: 0.4)
    }

    /// Not a template image, so the dot can stay blue. The remote is tinted at draw time with
    /// the menu bar's label color, which follows the menu bar's light or dark appearance.
    /// The canvas is 1 pt wider so the dot isn't clipped.
    private static let needsPairing: NSImage = {
        let size = NSSize(width: iconSize.width + 1, height: iconSize.height)
        let image = NSImage(size: size, flipped: false) { _ in
            let iconRect = NSRect(origin: .zero, size: iconSize)
            remote.draw(in: iconRect)
            NSColor.labelColor.set()
            iconRect.fill(using: .sourceAtop)

            // Centered on the body's top-right corner (the body is x 2...11, y 1...23 of the
            // 14 x 24 viewBox).
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let blue = isDark ? NSColor(red: 10 / 255, green: 132 / 255, blue: 1, alpha: 1)
                              : NSColor(red: 10 / 255, green: 108 / 255, blue: 1, alpha: 1)
            blue.setFill()
            NSBezierPath(ovalIn: NSRect(x: 7, y: size.height - 5, width: 5, height: 5)).fill()
            return true
        }
        image.accessibilityDescription = "Clickr, needs pairing"
        return image
    }()

    private static func template(_ draw: @escaping () -> Void) -> NSImage {
        let image = NSImage(size: iconSize, flipped: false) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Clickr"
        return image
    }
}
