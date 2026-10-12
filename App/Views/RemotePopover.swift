import SwiftUI

/// Popover content: the pairing view when the TV needs pairing, otherwise the remote in the
/// Glass or Fallback design.
struct RemotePopover: View {
    let model: RemoteViewModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var focused: Bool

    var body: some View {
        content
            .environment(\.remoteTheme, theme)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        if model.connectionState == .needsPairing, let device = model.selectedDevice {
            PairingView(model: model, deviceName: device.name)
                .windowBackgroundCleared(!theme.isGlass)
        } else {
            remote
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .modifier(RemoteKeyboardShortcuts(model: model, isEnabled: model.selectedDevice != nil))
                .onAppear { focused = true }
                .windowBackgroundCleared(!theme.isGlass)
        }
    }

    @ViewBuilder
    private var remote: some View {
        if theme.isGlass, #available(macOS 26, *) {
            GlassEffectContainer(spacing: 14) {
                GlassRemoteView(model: model)
            }
        } else {
            FallbackRemoteView(model: model)
        }
    }

    /// Glass on macOS 26 unless Reduce Transparency is on (Section 5.7).
    private var theme: RemoteTheme {
        var design: RemoteTheme.Design = .fallback
        if #available(macOS 26, *), !reduceTransparency {
            design = .glass
        }
        var increasedContrast = contrast == .increased
        #if DEBUG
        if let preview = PreviewOverrides.current {
            design = preview.design ?? design
            increasedContrast = increasedContrast || preview.increasedContrast
        }
        #endif
        return RemoteTheme(design: design, increasedContrast: increasedContrast)
    }
}

private extension View {
    /// For the fallback design, asks for no system window background so our flat panel is
    /// the popover's shape (macOS 15 and later; on 26 the system glass stays regardless).
    @ViewBuilder
    func windowBackgroundCleared(_ cleared: Bool) -> some View {
        if cleared, #available(macOS 15, *) {
            containerBackground(.clear, for: .window)
        } else {
            self
        }
    }
}
