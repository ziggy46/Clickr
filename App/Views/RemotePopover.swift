import SwiftUI

/// Popover content. For now it just lists discovered TVs; the Glass and Fallback
/// remote designs replace this in Milestone 8.
struct RemotePopover: View {
    let model: RemoteViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.devices.isEmpty {
                Text("No Apple TV found")
                    .font(.system(size: 16, weight: .semibold))
                Text("Make sure your Mac and Apple TV are on the same network.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.devices) { device in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name)
                            .font(.system(size: 16, weight: .semibold))
                        Text(device.modelName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 308, alignment: .leading)
    }
}
