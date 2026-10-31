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

        GeometryReader { proxy in
            ScrollView {
                GlassEffectContainer(spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        header(for: tunnel, status: status)

                        HStack(alignment: .top, spacing: 16) {
                            statsGrid(status: status, statistics: statistics, latest: history.latest)
                                .frame(maxWidth: .infinity)

                            Card("Throughput", systemImage: "chart.xyaxis.line", collapsible: true) {
                                ThroughputChartView(samples: history.samples, window: window)
                                    .frame(height: 165)
                            } accessory: {
                                Picker("Window", selection: $window) {
                                    ForEach(ChartWindow.allCases) { Text($0.label).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 150)
                            }
                            .frame(maxWidth: .infinity)
                        }

                        // `maxHeight: .infinity` lets this row absorb the slack from the
                        // VStack's `minHeight` below, so the Peers/Interface cards reach the
                        // bottom of the window even when their content is short — lining their
                        // bottom edge up with the sidebar's, which always fills the full height.
                        HStack(alignment: .top, spacing: 16) {
                            Card("Peers", systemImage: "person.2", collapsible: true) {
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
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            Card("Interface", systemImage: "network", collapsible: true) {
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
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .padding()
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
            }
        }
        .background(AmbientBackground(tint: tunnel.accentColor, secondaryTint: status.color))
        .toolbar {
            ToolbarItemGroup {
                Button(status.isActive ? "Disconnect" : "Connect",
                       systemImage: status.isActive ? "stop.circle" : "play.circle") {
                    Task { await manager.toggle(tunnel) }
                }
                .disabled(manager.isBusy(tunnel.id) || status == .invalid)
                .help(status.isActive ? "Disconnect" : "Connect")
                Button("Edit", systemImage: "pencil") { isEditing = true }
                    .help("Edit")
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    Task { await manager.duplicate(tunnel) }
                }
                .help("Duplicate")
                Button("Export…", systemImage: "square.and.arrow.up") { isExporting = true }
                    .help("Export")
                Button("Copy Configuration", systemImage: "doc.on.doc") {
                    Pasteboard.copy(manager.configurationText(for: tunnel))
                }
                .help("Copy Configuration")
                Button("Delete…", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                    .help("Delete")
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
                    onDemandToggle(for: tunnel)
                }
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }

    /// A pill beside the status badge that both shows and toggles Connect on Demand, so it can
    /// be flipped without opening the editor.
    private func onDemandToggle(for tunnel: Tunnel) -> some View {
        let isOn = tunnel.connectOnDemand
        return Button {
            var updated = tunnel
            updated.connectOnDemand.toggle()
            Task { await manager.update(updated) }
        } label: {
            Label("On demand", systemImage: isOn ? "bolt.fill" : "bolt.slash")
                .contentTransition(.symbolEffect(.replace))
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(isOn ? .green : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .glassEffect(isOn ? .regular.tint(.green.opacity(0.3)) : .regular, in: .capsule)
        .buttonStyle(.plain)
        .disabled(manager.isBusy(tunnel.id))
        .help(isOn
              ? "Connect on demand is on. macOS automatically reconnects this tunnel while you're online. Click to turn it off."
              : "Connect on demand is off. Click to turn it on.")
        .accessibilityLabel("Connect on demand")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double-tap to turn \(isOn ? "off" : "on")")
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
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    if let key = interface.publicKey?.base64Key {
                        CopyButton(text: key)
                    }
                }
            }
            detailRow("Addresses") {
                Text(interface.addresses.isEmpty ? "—" : interface.addresses.map(\.description).joined(separator: ", "))
                    .font(.caption.monospaced())
            }
            detailRow("DNS") {
                let entries = interface.dnsServers + interface.dnsSearchDomains
                Text(entries.isEmpty ? "System default" : entries.joined(separator: ", "))
                    .font(.caption.monospaced())
            }
            detailRow("Listen port") {
                Text(interface.listenPort.map(String.init) ?? "Automatic").font(.caption.monospaced())
            }
            detailRow("MTU") {
                Text(interface.mtu.map(String.init) ?? "Automatic").font(.caption.monospaced())
            }
            detailRow("Backend") {
                Text(manager.backend.kind.displayName).font(.caption)
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
        .font(.caption)
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
