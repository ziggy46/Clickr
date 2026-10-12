import AppKit
import SwiftUI

/// The Siri Remote template icon shown in the menu bar (Section 5.1).
struct MenuBarIcon: View {
    var body: some View {
        Image(nsImage: Self.templateImage)
    }

    /// `MenuBarExtra` labels don't reliably honor `.frame`, so size the NSImage itself.
    static let templateImage: NSImage = {
        let image = (NSImage(named: "RemoteIcon")?.copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: 11, height: 19)
        image.isTemplate = true
        image.accessibilityDescription = "Clickr"
        return image
    }()
}
