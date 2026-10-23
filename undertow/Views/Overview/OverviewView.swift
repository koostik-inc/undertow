import SwiftUI

/// Dashboard: headline numbers, the live network map, and combined throughput.
struct OverviewView: View {
    @Environment(TunnelManager.self) private var manager
    var onSelectTunnel: (UUID) -> Void
    var onAddTunnel: () -> Void

    @State private var window: ChartWindow = .oneMinute

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    if manager.tunnels.isEmpty {
                        emptyState
                    } else {
                        statTiles
                        Card("Network Map", systemImage: "point.3.connected.trianglepath.dotted") {
                            NetworkMapView(onSelectTunnel: onSelectTunnel)
                                .frame(height: 400)
                        } accessory: {
                            Text("\(manager.connectedTunnelCount) of \(manager.tunnels.count) connected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Card("Combined Throughput", systemImage: "chart.xyaxis.line") {
                            ThroughputChartView(samples: manager.aggregateHistory.samples, window: window)
                                .frame(height: 220)
                        } accessory: {
                            windowPicker
                        }
                    }
                }
                .padding()
            }
        }
        .background(AmbientBackground())
        .navigationTitle("Overview")
    }

    private var statTiles: some View {
        let latest = manager.aggregateHistory.latest
        return LazyVGrid(columns: columns, spacing: 12) {
            StatTile(title: "Connected", systemImage: "lock.shield", tint: TunnelStatus.connected.color,
                     text: "\(manager.connectedTunnelCount) of \(manager.tunnels.count)")
            StatTile(title: "Download", systemImage: "arrow.down.circle", tint: TrafficColor.download,
                     text: ByteFormatting.rate(latest?.receivedBytesPerSecond ?? 0))
            StatTile(title: "Upload", systemImage: "arrow.up.circle", tint: TrafficColor.upload,
                     text: ByteFormatting.rate(latest?.sentBytesPerSecond ?? 0))
            StatTile(title: "Transferred", systemImage: "arrow.up.arrow.down",
                     text: ByteFormatting.bytes(manager.totalReceivedBytes + manager.totalSentBytes))
        }
    }

    private var windowPicker: some View {
        Picker("Window", selection: $window) {
            ForEach(ChartWindow.allCases) { window in
                Text(window.label).tag(window)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 150)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Tunnels", systemImage: "network.slash")
        } description: {
            Text("Import a WireGuard configuration file or create a tunnel to get started.")
        } actions: {
            Button("Add Tunnel", action: onAddTunnel)
                .buttonStyle(.glassProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }
}

#Preview {
    NavigationStack {
        OverviewView(onSelectTunnel: { _ in }, onAddTunnel: {})
            .environment(TunnelManager.preview())
    }
    .frame(width: 760, height: 900)
}
