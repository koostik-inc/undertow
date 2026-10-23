import SwiftUI

/// Everything about one tunnel: controls, live statistics, throughput, peers, and interface.
struct TunnelDetailView: View {
    @Environment(TunnelManager.self) private var manager
    let tunnelID: UUID
    var onDeleted: () -> Void = {}

    @State private var isEditing = false
    @State private var isConfirmingDelete = false
    @State private var isExporting = false
    @State private var window: ChartWindow = .oneMinute

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        if let tunnel = manager.tunnel(withID: tunnelID) {
            content(for: tunnel)
        } else {
            ContentUnavailableView("Tunnel Not Found", systemImage: "questionmark.circle")
        }
    }

    @ViewBuilder
    private func content(for tunnel: Tunnel) -> some View {
        let status = manager.status(for: tunnel.id)
        let statistics = manager.statistics[tunnel.id]
        let history = manager.history(for: tunnel.id)

        ScrollView {
            GlassEffectContainer(spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    header(for: tunnel, status: status)
                    statsGrid(status: status, statistics: statistics, latest: history.latest)

                    Card("Throughput", systemImage: "chart.xyaxis.line") {
                        ThroughputChartView(samples: history.samples, window: window)
                            .frame(height: 220)
                    } accessory: {
                        Picker("Window", selection: $window) {
                            ForEach(ChartWindow.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 150)
                    }

                    Card("Peers", systemImage: "person.2") {
                        if tunnel.configuration.peers.isEmpty {
                            Text("No peers configured. Edit the tunnel to add one.")
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(tunnel.configuration.peers) { peer in
                                    PeerRow(peer: peer,
                                            runtime: statistics?.peers.first { $0.publicKey == peer.publicKey },
                                            isConnected: status == .connected)
                                    if peer.id != tunnel.configuration.peers.last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }

                    Card("Interface", systemImage: "network") {
                        interfaceDetails(for: tunnel)
                        let unreachable = tunnel.configuration.unreachableDNSServers
                        if !unreachable.isEmpty {
                            Label("DNS server\(unreachable.count == 1 ? "" : "s") \(unreachable.joined(separator: ", ")) \(unreachable.count == 1 ? "is" : "are") not inside any peer's Allowed IPs. While connected, all DNS lookups on this Mac will fail. Add the server to Allowed IPs or remove the DNS entry.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding()
            }
        }
        .background(AmbientBackground(tint: tunnel.accentColor, secondaryTint: status.color))
        .navigationTitle(tunnel.name)
        .toolbar {
            ToolbarItemGroup {
                Button("Edit", systemImage: "pencil") { isEditing = true }
                Menu {
                    Button("Duplicate", systemImage: "plus.square.on.square") {
                        Task { await manager.duplicate(tunnel) }
                    }
                    Button("Export…", systemImage: "square.and.arrow.up") { isExporting = true }
                    Button("Copy Configuration", systemImage: "doc.on.doc") {
                        Pasteboard.copy(manager.configurationText(for: tunnel))
                    }
                    Divider()
                    Button("Delete…", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            TunnelEditorView(mode: .edit(tunnel))
        }
        .fileExporter(isPresented: $isExporting,
                      document: WireGuardConfigDocument(text: manager.configurationText(for: tunnel)),
                      contentType: .wireGuardConfiguration,
                      defaultFilename: "\(tunnel.name).conf") { _ in }
        .confirmationDialog("Delete “\(tunnel.name)”?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete Tunnel", role: .destructive) {
                Task {
                    await manager.delete(tunnel)
                    onDeleted()
                }
            }
        } message: {
            Text("This disconnects the tunnel and removes its configuration and keys from this device.")
        }
    }

    // MARK: - Sections

    private func header(for tunnel: Tunnel, status: TunnelStatus) -> some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(tunnel.accentColor.opacity(0.18))
                    .frame(width: 56, height: 56)
                Image(systemName: status == .connected ? "lock.fill" : "lock.open")
                    .font(.title2)
                    .foregroundStyle(tunnel.accentColor)
                    .contentTransition(.symbolEffect(.replace))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(tunnel.name)
                    .font(.title2.weight(.bold))
                if let endpoint = tunnel.primaryEndpointDescription {
                    Text(endpoint)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    StatusBadge(status: status)
                    if tunnel.connectOnDemand {
                        TagPill(title: "On demand", systemImage: "bolt.fill")
                    }
                }
                if manager.isAwaitingHandshake(tunnel.id) {
                    Label("No handshake from the peer yet. Routed traffic and tunnel DNS are on hold until it answers; check the endpoint or disconnect.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            connectButton(for: tunnel, status: status)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func connectButton(for tunnel: Tunnel, status: TunnelStatus) -> some View {
        let busy = manager.isBusy(tunnel.id) || status.isTransitioning
        let label = HStack(spacing: 8) {
            if busy {
                ProgressView().controlSize(.small)
            }
            Text(status.isActive ? "Disconnect" : "Connect")
        }
        .frame(minWidth: 100)

        Group {
            if status.isActive {
                Button { Task { await manager.toggle(tunnel) } } label: { label }
                    .buttonStyle(.glass)
            } else {
                Button { Task { await manager.toggle(tunnel) } } label: { label }
                    .buttonStyle(.glassProminent)
            }
        }
        .controlSize(.large)
        .disabled(manager.isBusy(tunnel.id) || status == .invalid)
        .keyboardShortcut(.return, modifiers: .command)
    }

    private func statsGrid(status: TunnelStatus, statistics: TunnelRuntimeStatistics?, latest: ThroughputSample?) -> some View {
        LazyVGrid(columns: columns, spacing: 12) {
            StatTile(title: "Download", systemImage: "arrow.down.circle", tint: TrafficColor.download,
                     text: ByteFormatting.rate(status == .connected ? (latest?.receivedBytesPerSecond ?? 0) : 0))
            StatTile(title: "Upload", systemImage: "arrow.up.circle", tint: TrafficColor.upload,
                     text: ByteFormatting.rate(status == .connected ? (latest?.sentBytesPerSecond ?? 0) : 0))
            StatTile(title: "Received", systemImage: "tray.and.arrow.down",
                     text: ByteFormatting.bytes(statistics?.receivedBytes ?? 0))
            StatTile(title: "Sent", systemImage: "tray.and.arrow.up",
                     text: ByteFormatting.bytes(statistics?.sentBytes ?? 0))
            StatTile(title: "Uptime", systemImage: "clock") {
                if let since = statistics?.connectedSince, status == .connected {
                    Text(since, style: .timer)
                } else {
                    Text("—")
                }
            }
            StatTile(title: "Last Handshake", systemImage: "hand.raised") {
                if let handshake = statistics?.lastHandshake, status == .connected {
                    Text("\(handshake, style: .relative) ago")
                } else {
                    Text("—")
                }
            }
        }
    }

    private func interfaceDetails(for tunnel: Tunnel) -> some View {
        let interface = tunnel.configuration.interface
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
            detailRow("Public key") {
                HStack(spacing: 6) {
                    Text(interface.publicKey?.base64Key ?? "Invalid private key")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    if let key = interface.publicKey?.base64Key {
                        CopyButton(text: key)
                    }
                }
            }
            detailRow("Addresses") {
                Text(interface.addresses.isEmpty ? "—" : interface.addresses.map(\.description).joined(separator: ", "))
                    .font(.callout.monospaced())
            }
            detailRow("DNS") {
                let entries = interface.dnsServers + interface.dnsSearchDomains
                Text(entries.isEmpty ? "System default" : entries.joined(separator: ", "))
                    .font(.callout.monospaced())
            }
            detailRow("Listen port") {
                Text(interface.listenPort.map(String.init) ?? "Automatic").font(.callout.monospaced())
            }
            detailRow("MTU") {
                Text(interface.mtu.map(String.init) ?? "Automatic").font(.callout.monospaced())
            }
            detailRow("Backend") {
                Text(manager.backend.kind.displayName).font(.callout)
            }
        }
    }

    private func detailRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

/// One peer with its configuration and live counters.
struct PeerRow: View {
    let peer: PeerConfiguration
    let runtime: PeerRuntimeStatistics?
    let isConnected: Bool

    private var isFresh: Bool { isConnected && runtime?.hasRecentHandshake == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isFresh ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(isFresh ? TunnelStatus.connected.color : .secondary)
                    .accessibilityLabel(isFresh ? "Handshake recent" : "No recent handshake")
                Text(peer.displayLabel)
                    .font(.body.weight(.medium))
                if peer.routesAllTraffic {
                    TagPill(title: "Full tunnel")
                }
                Spacer()
                if let runtime, isConnected {
                    Text("↓ \(ByteFormatting.bytes(runtime.receivedBytes))  ↑ \(ByteFormatting.bytes(runtime.sentBytes))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Public key").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    HStack(spacing: 6) {
                        Text(peer.publicKey.base64Key).font(.caption.monospaced()).textSelection(.enabled)
                        CopyButton(text: peer.publicKey.base64Key)
                    }
                }
                GridRow {
                    Text("Endpoint").foregroundStyle(.secondary)
                    Text(peer.endpoint?.description ?? "Roaming (no fixed endpoint)").font(.caption.monospaced())
                }
                GridRow {
                    Text("Allowed IPs").foregroundStyle(.secondary)
                    Text(peer.allowedIPs.isEmpty ? "—" : peer.allowedIPs.map(\.description).joined(separator: ", "))
                        .font(.caption.monospaced())
                }
                GridRow {
                    Text("Keepalive").foregroundStyle(.secondary)
                    Text(peer.persistentKeepAlive.map { "every \($0) s" } ?? "Off").font(.caption)
                }
                GridRow {
                    Text("Handshake").foregroundStyle(.secondary)
                    if let handshake = runtime?.lastHandshake, isConnected {
                        Text("\(handshake, style: .relative) ago").font(.caption)
                    } else {
                        Text("Never").font(.caption)
                    }
                }
            }
            .font(.caption)
        }
    }
}

/// A borderless copy-to-clipboard button with brief confirmation.
struct CopyButton: View {
    let text: String
    @State private var didCopy = false

    var body: some View {
        Button {
            Pasteboard.copy(text)
            didCopy = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                didCopy = false
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help("Copy")
        .accessibilityLabel(didCopy ? "Copied" : "Copy")
    }
}

#Preview {
    let manager = TunnelManager.preview()
    return NavigationStack {
        TunnelDetailView(tunnelID: manager.tunnels[0].id)
            .environment(manager)
    }
    .frame(width: 760, height: 900)
}
