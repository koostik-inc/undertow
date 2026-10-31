import SwiftUI

/// A sidebar row: a clickable connection indicator, name, and a sparkline.
struct TunnelRowView: View {
    @Environment(TunnelManager.self) private var manager
    let tunnel: Tunnel

    private var status: TunnelStatus { manager.status(for: tunnel.id) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                Task { await manager.toggle(tunnel) }
            } label: {
                Image(systemName: status.isActive ? "network.badge.shield.half.filled" : "network.slash")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(status.isActive ? .white : .secondary)
                    .frame(width: 25, height: 25)
                    .background(status.isActive ? Color.blue : Color.gray.opacity(0.25), in: .circle)
            }
            .buttonStyle(.plain)
            .frame(width: 25, height: 25)
            .disabled(manager.isBusy(tunnel.id) || status == .invalid)
            .help(status.isActive ? "Disconnect" : "Connect")
            .accessibilityLabel(status.isActive ? "Disconnect" : "Connect")

            Text(tunnel.name)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if status.isActive {
                SparklineView(samples: manager.history(for: tunnel.id).samples)
                    .frame(width: 56, height: 18)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tunnel.name), \(status.displayName)")
    }
}
