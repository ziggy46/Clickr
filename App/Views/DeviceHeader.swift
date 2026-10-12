import Discovery
import SwiftUI

/// Device name, connection status and the TV switcher (Section 5.2, item 1).
struct DeviceHeader: View {
    let model: RemoteViewModel
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                if let device = model.selectedDevice {
                    title(device.name)
                    status(for: device)
                } else {
                    title("No Apple TV found")
                    Text("Make sure your Mac and Apple TV are on the same network.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if model.selectedDevice != nil {
                    PowerButton(model: model)
                        .disabled(model.connectionState != .connected)
                }
                if model.devices.count > 1 {
                    switcher
                }
            }
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: theme.deviceNameSize, weight: .semibold))
            .foregroundStyle(theme.primaryText)
            .lineLimit(1)
    }

    @ViewBuilder
    private func status(for device: DiscoveredDevice) -> some View {
        HStack(spacing: 6) {
            switch model.connectionState {
            case .connected:
                dot(.statusConnected)
                statusText("Connected · \(model.isAsleep ? "Asleep" : device.modelName)")
            case .connecting:
                dot(.statusConnecting)
                statusText("Connecting…")
            case .disconnected, .needsPairing:
                dot(.statusDisconnected)
                HStack(spacing: 0) {
                    statusText("Not connected · ")
                    Button("Retry") { model.retry() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(theme.secondaryText)
    }

    private var switcher: some View {
        Menu {
            ForEach(model.devices) { device in
                Button(device.name) { model.select(device) }
            }
        } label: {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 18))
                .foregroundStyle(theme.isGlass ? theme.primaryText : theme.secondaryText)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .controlButtonStyle(theme, radius: theme.isGlass ? nil : 9, fallbackFill: .clear)
        .frame(width: 36, height: 36)
        .accessibilityLabel("Switch Apple TV")
    }
}
