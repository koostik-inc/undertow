#if os(macOS)
import SwiftUI

/// Quick tunnel toggles from the menu bar.
struct MenuBarView: View {
    @Environment(TunnelManager.self) private var manager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Undertow", systemImage: "lock.shield")
                    .font(.headline)
                Spacer()
                Text("\(manager.connectedTunnelCount) connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if manager.tunnels.isEmpty {
                Text("No tunnels yet. Open Undertow to add one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ForEach(manager.tunnels) { tunnel in
                    row(for: tunnel)
                }
                .padding(.vertical, 4)
            }

            Divider()

            HStack {
                Button("Open Undertow") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                if !manager.activeTunnels.isEmpty {
                    Button("Disconnect All") {
                        Task { await manager.disconnectAll() }
                    }
                }
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 340)
    }

    private func row(for tunnel: Tunnel) -> some View {
        let status = manager.status(for: tunnel.id)
        let latest = manager.history(for: tunnel.id).latest
        return HStack(spacing: 10) {
            StatusDot(status: status, size: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(tunnel.name).font(.body.weight(.medium))
                if status == .connected, let latest {
                    Text("↓ \(ByteFormatting.rate(latest.receivedBytesPerSecond))  ↑ \(ByteFormatting.rate(latest.sentBytesPerSecond))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(status.isTransitioning ? status.displayName : (tunnel.primaryEndpointDescription ?? "No peers"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if status.isActive {
                SparklineView(samples: manager.history(for: tunnel.id).samples)
                    .frame(width: 48, height: 16)
            }
            Toggle("Connected", isOn: Binding(
                get: { status.isActive },
                set: { _ in Task { await manager.toggle(tunnel) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(manager.isBusy(tunnel.id) || status == .invalid)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}

#Preview {
    MenuBarView()
        .environment(TunnelManager.preview())
}
#endif
