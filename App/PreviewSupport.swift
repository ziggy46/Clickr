#if DEBUG
import AppKit
import Discovery
import MRP
import Network
import Session
import SwiftUI

/// Debug-only launch arguments for looking at every state and design on one machine,
/// without a TV or changing system settings. For example:
///
///   Clickr -ClickrPreviewState needsPairing -ClickrPreviewDesign fallback -ClickrPreviewWindow YES
///
/// - ClickrPreviewState: disconnected | connecting | needsPairing | connected | noDevice
/// - ClickrPreviewDesign: glass | fallback
/// - ClickrPreviewContrast: increased
/// - ClickrPreviewDevices: number of fake TVs (default 2)
/// - ClickrPreviewPairingFailed: YES to show the wrong-PIN message
/// - ClickrPreviewNowPlaying: YES to show a sample Now Playing card
/// - ClickrPreviewWindow: YES to also show the popover in a plain window behind all other
///   windows, so it can be captured with `screencapture -l <id>` without opening the menu.
struct PreviewOverrides {
    var state: ConnectionState
    var devices: [DiscoveredDevice]
    var pairingFailed: Bool
    var design: RemoteTheme.Design?
    var increasedContrast: Bool
    var showsWindow: Bool
    var nowPlaying: NowPlaying?

    static let current: PreviewOverrides? = {
        let defaults = UserDefaults.standard
        guard let stateName = defaults.string(forKey: "ClickrPreviewState") else { return nil }

        let requestedCount = defaults.string(forKey: "ClickrPreviewDevices").flatMap(Int.init) ?? 2
        let deviceCount = stateName == "noDevice" ? 0 : requestedCount
        let names = ["Living Room", "Bedroom", "Den"]
        let devices = (0..<min(deviceCount, names.count)).compactMap { index in
            DiscoveredDevice(
                name: names[index],
                endpoint: .service(name: names[index], type: "_companion-link._tcp", domain: "local.", interface: nil),
                txt: ["rpMd": "AppleTV11,1", "rpMRtID": "PREVIEW-\(index)"]
            )
        }
        let state: ConnectionState = switch stateName {
        case "connecting": .connecting
        case "needsPairing": .needsPairing
        case "connected": .connected
        default: .disconnected
        }
        return PreviewOverrides(
            state: state,
            devices: devices,
            pairingFailed: defaults.bool(forKey: "ClickrPreviewPairingFailed"),
            design: defaults.string(forKey: "ClickrPreviewDesign").map { $0 == "glass" ? .glass : .fallback },
            increasedContrast: defaults.string(forKey: "ClickrPreviewContrast") == "increased",
            showsWindow: defaults.bool(forKey: "ClickrPreviewWindow"),
            nowPlaying: defaults.bool(forKey: "ClickrPreviewNowPlaying") ? NowPlaying(
                state: .playing, title: "Episode 3", artist: "Some Show", appName: "TV",
                duration: 2700, elapsed: 1000, elapsedTimestamp: Date(), playbackRate: 1,
                artworkAvailable: false, itemID: "preview", location: 0
            ) : nil
        )
    }()
}

/// Shows the popover content in a borderless window at the back of the window stack and
/// prints its window number for `screencapture -l`.
@MainActor
enum PreviewWindow {
    private static var window: NSPanel?

    static func showIfRequested(model: RemoteViewModel) {
        guard PreviewOverrides.current?.showsWindow == true else { return }
        // Draw controls as if the window were active, like the real popover is.
        let hosting = NSHostingView(rootView: RemotePopover(model: model).environment(\.controlActiveState, .key))
        hosting.layoutSubtreeIfNeeded()

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.setFrameOrigin(NSPoint(x: 40, y: 40))
        panel.orderBack(nil)
        window = panel
        print("CLICKR_PREVIEW_WINDOW \(panel.windowNumber)")
        fflush(stdout)
    }
}
#endif

#if DEBUG
/// `-ClickrDumpIcons YES` draws each menu bar icon state on a light and a dark menu bar
/// background into the app's temporary folder, prints the path and quits. The template
/// variants are tinted the way the menu bar would tint them.
@MainActor
enum IconDump {
    static func runIfRequested() {
        guard UserDefaults.standard.bool(forKey: "ClickrDumpIcons") else { return }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ClickrIcons")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let appearances: [(String, NSAppearance.Name, NSColor)] = [
            ("light", .aqua, NSColor(white: 0.92, alpha: 1)),
            ("dark", .darkAqua, NSColor(white: 0.16, alpha: 1)),
        ]
        let states: [(String, ConnectionState)] = [("connected", .connected), ("dimmed", .disconnected), ("pairing", .needsPairing)]
        let scale: CGFloat = 8

        for (appearanceName, name, background) in appearances {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                for (stateName, state) in states {
                    let icon = MenuBarIcon.image(for: state)
                    let size = NSSize(width: 16 * scale, height: 22 * scale)
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    background.setFill()
                    NSRect(origin: .zero, size: size).fill()
                    let rect = NSRect(x: 2 * scale, y: 1.5 * scale, width: icon.size.width * scale, height: icon.size.height * scale)
                    if icon.isTemplate {
                        // Tint like the menu bar: label color through the image's alpha.
                        let tinted = NSImage(size: icon.size, flipped: false) { bounds in
                            icon.draw(in: bounds)
                            NSColor.labelColor.set()
                            bounds.fill(using: .sourceAtop)
                            return true
                        }
                        tinted.draw(in: rect)
                    } else {
                        icon.draw(in: rect)
                    }
                    NSGraphicsContext.restoreGraphicsState()
                    let url = directory.appendingPathComponent("\(stateName)-\(appearanceName).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
        print("CLICKR_ICONS \(directory.path)")
        fflush(stdout)
        exit(0)
    }
}
#endif

