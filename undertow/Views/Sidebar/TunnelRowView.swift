import SwiftUI

/// A sidebar row: status, name, live rates or endpoint, a sparkline, and a connect switch.
struct TunnelRowView: View {
    @Environment(TunnelManager.self) private var manager
    let tunnel: Tunnel

    private var status: TunnelStatus { manager.status(for: tunnel.id) }

    private var subtitle: String {
        if manager.isAwaitingHandshake(tunnel.id) {
            return "No handshake yet"
        }
        if status == .connected, let latest = manager.history(for: tunnel.id).latest {
            return "↓ \(ByteFormatting.rate(latest.receivedBytesPerSecond))  ↑ \(ByteFormatting.rate(latest.sentBytesPerSecond))"
        }
        if status.isTransitioning {
            return status.displayName
        }
        return tunnel.primaryEndpointDescription ?? "No peers"
    }

    private var isOn: Binding<Bool> {
        Binding(
            get: { status.isActive },
            set: { _ in Task { await manager.toggle(tunnel) } }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: status)
            VStack(alignment: .leading, spacing: 2) {
                Text(tunnel.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if status.isActive {
                SparklineView(samples: manager.history(for: tunnel.id).samples)
                    .frame(width: 56, height: 18)
            }
            Toggle("Connected", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(manager.isBusy(tunnel.id) || status == .invalid)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tunnel.name), \(status.displayName)")
    }
}
