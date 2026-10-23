import SwiftUI

/// Positions for every node in the map, computed once per layout pass.
nonisolated struct NetworkMapLayout {
    struct PeerNode: Identifiable {
        let peer: PeerConfiguration
        let position: CGPoint
        var id: UUID { peer.id }
    }

    struct TunnelNode: Identifiable {
        let tunnel: Tunnel
        let position: CGPoint
        let peers: [PeerNode]
        let hiddenPeerCount: Int
        var id: UUID { tunnel.id }
    }

    static let maxPeersPerTunnel = 4
    static let deviceRadius: CGFloat = 26
    static let tunnelNodeRadius: CGFloat = 20
    static let peerNodeRadius: CGFloat = 8

    let center: CGPoint
    let tunnelRadius: CGFloat
    let peerRadius: CGFloat
    let tunnelNodes: [TunnelNode]

    init(tunnels: [Tunnel], size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let base = min(size.width, size.height)
        let tunnelRadius = base * 0.26
        let peerRadius = base * 0.44
        self.center = center
        self.tunnelRadius = tunnelRadius
        self.peerRadius = peerRadius

        func point(angle: Double, radius: CGFloat) -> CGPoint {
            CGPoint(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius)
        }

        let count = max(tunnels.count, 1)
        let sector = count == 1 ? Double.pi * 0.8 : (2 * .pi / Double(count)) * 0.78

        tunnelNodes = tunnels.enumerated().map { index, tunnel in
            let angle = -Double.pi / 2 + Double(index) * 2 * .pi / Double(count)
            let shown = Array(tunnel.configuration.peers.prefix(Self.maxPeersPerTunnel))
            let peers = shown.enumerated().map { peerIndex, peer in
                let fraction = shown.count == 1 ? 0.5 : Double(peerIndex) / Double(shown.count - 1)
                let peerAngle = angle - sector / 2 + fraction * sector
                return PeerNode(peer: peer, position: point(angle: peerAngle, radius: peerRadius))
            }
            return TunnelNode(tunnel: tunnel,
                              position: point(angle: angle, radius: tunnelRadius),
                              peers: peers,
                              hiddenPeerCount: tunnel.configuration.peers.count - shown.count)
        }
    }
}

/// A live topology of this device, its tunnels, and their peers.
///
/// Edges, traffic particles, and labels are drawn in a Canvas; the nodes themselves are
/// interactive Liquid Glass views layered on top so they can be tapped and refract the map.
struct NetworkMapView: View {
    @Environment(TunnelManager.self) private var manager
    var highlightedTunnelID: UUID?
    var onSelectTunnel: (UUID) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 10) {
            map
            legend
        }
    }

    private var map: some View {
        GeometryReader { proxy in
            let layout = NetworkMapLayout(tunnels: manager.tunnels, size: proxy.size)
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    Canvas { context, size in
                        drawLinks(in: &context, layout: layout,
                                  time: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }

                GlassEffectContainer(spacing: 20) {
                    ZStack {
                        deviceNode(at: layout.center)
                        ForEach(layout.tunnelNodes) { node in
                            let status = manager.status(for: node.tunnel.id)
                            let runtimePeers = manager.statistics[node.tunnel.id]?.peers ?? []
                            ForEach(node.peers) { peerNode in
                                let runtime = runtimePeers.first { $0.publicKey == peerNode.peer.publicKey }
                                peerNodeView(peerNode, isFresh: status == .connected && runtime?.hasRecentHandshake == true)
                            }
                            tunnelNodeView(node, status: status)
                        }
                    }
                }
            }
        }
        .overlay {
            if manager.tunnels.isEmpty {
                Text("Add a tunnel to see your network.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Glass nodes

    private func deviceNode(at center: CGPoint) -> some View {
        Image(systemName: "laptopcomputer")
            .font(.title3.weight(.medium))
            .foregroundStyle(.primary)
            .frame(width: NetworkMapLayout.deviceRadius * 2, height: NetworkMapLayout.deviceRadius * 2)
            .glassEffect(.regular, in: .circle)
            .position(center)
            .accessibilityLabel("This device")
    }

    private func tunnelNodeView(_ node: NetworkMapLayout.TunnelNode, status: TunnelStatus) -> some View {
        let radius = NetworkMapLayout.tunnelNodeRadius
        let isHighlighted = node.tunnel.id == highlightedTunnelID
        return Button {
            onSelectTunnel(node.tunnel.id)
        } label: {
            Image(systemName: status == .connected ? "lock.fill" : "lock.open")
                .font(.body.weight(.semibold))
                .foregroundStyle(status.color)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: radius * 2, height: radius * 2)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(status.color.opacity(status == .connected ? 0.4 : 0.15)).interactive(), in: .circle)
        .overlay {
            if isHighlighted {
                Circle()
                    .stroke(node.tunnel.accentColor.opacity(0.9), lineWidth: 2)
                    .padding(-5)
            }
        }
        .position(node.position)
        .help(node.tunnel.name)
        .accessibilityLabel("\(node.tunnel.name), \(status.displayName)")
    }

    private func peerNodeView(_ node: NetworkMapLayout.PeerNode, isFresh: Bool) -> some View {
        let radius = NetworkMapLayout.peerNodeRadius
        let color = isFresh ? TunnelStatus.connected.color : Color.secondary
        return Circle()
            .fill(color.opacity(isFresh ? 1 : 0.5))
            .frame(width: 6, height: 6)
            .frame(width: radius * 2, height: radius * 2)
            .glassEffect(.regular.tint(isFresh ? color.opacity(0.35) : .clear), in: .circle)
            .position(node.position)
            .accessibilityLabel("\(node.peer.displayLabel), \(isFresh ? "handshake recent" : "no recent handshake")")
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(color: TrafficColor.download, label: "Download")
            legendItem(color: TrafficColor.upload, label: "Upload")
            legendItem(color: TunnelStatus.connected.color, label: "Connected")
            legendItem(color: TunnelStatus.connecting.color, label: "Connecting")
            legendItem(color: TunnelStatus.disconnected.color, label: "Disconnected")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }

    // MARK: - Canvas: rings, edges, particles, labels

    private func drawLinks(in context: inout GraphicsContext, layout: NetworkMapLayout, time: TimeInterval) {
        drawGuideRings(in: &context, layout: layout)

        for node in layout.tunnelNodes {
            let status = manager.status(for: node.tunnel.id)
            let latest = manager.history(for: node.tunnel.id).latest
            let received = status == .connected ? (latest?.receivedBytesPerSecond ?? 0) : 0
            let sent = status == .connected ? (latest?.sentBytesPerSecond ?? 0) : 0

            drawEdge(in: &context, from: layout.center, to: node.position, status: status, primary: true)
            for peerNode in node.peers {
                drawEdge(in: &context, from: node.position, to: peerNode.position, status: status, primary: false)
            }

            if status == .connected {
                let seed = Double(node.tunnel.id.uuid.1) / 255
                // Download flows toward the device, upload away from it.
                drawParticles(in: &context, from: node.position, to: layout.center, rate: received,
                              color: TrafficColor.download, lane: 4, time: time, seed: seed)
                drawParticles(in: &context, from: layout.center, to: node.position, rate: sent,
                              color: TrafficColor.upload, lane: -4, time: time, seed: seed + 0.37)
                let peerCount = Double(max(node.peers.count, 1))
                for (index, peerNode) in node.peers.enumerated() {
                    let peerSeed = seed + Double(index) * 0.21
                    drawParticles(in: &context, from: peerNode.position, to: node.position, rate: received / peerCount,
                                  color: TrafficColor.download, lane: 3, time: time, seed: peerSeed)
                    drawParticles(in: &context, from: node.position, to: peerNode.position, rate: sent / peerCount,
                                  color: TrafficColor.upload, lane: -3, time: time, seed: peerSeed + 0.5)
                }
            }

            drawTunnelLabels(in: &context, node: node, status: status, latest: latest)
            for peerNode in node.peers {
                drawPeerLabel(in: &context, node: peerNode, center: layout.center)
            }
        }

        context.draw(Text("This device").font(.caption).foregroundStyle(.secondary),
                     at: CGPoint(x: layout.center.x, y: layout.center.y + NetworkMapLayout.deviceRadius + 8),
                     anchor: .top)
    }

    private func drawGuideRings(in context: inout GraphicsContext, layout: NetworkMapLayout) {
        for radius in [layout.tunnelRadius, layout.peerRadius] {
            let rect = CGRect(x: layout.center.x - radius, y: layout.center.y - radius,
                              width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect),
                           with: .color(.secondary.opacity(0.14)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
        }
    }

    private func drawEdge(in context: inout GraphicsContext, from a: CGPoint, to b: CGPoint, status: TunnelStatus, primary: Bool) {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        let connected = status == .connected
        let color = connected ? status.color.opacity(primary ? 0.6 : 0.45) : Color.secondary.opacity(primary ? 0.4 : 0.3)
        let style = connected
            ? StrokeStyle(lineWidth: primary ? 2 : 1.5)
            : StrokeStyle(lineWidth: 1, dash: [3, 4])
        context.stroke(path, with: .color(color), style: style)
    }

    private func drawParticles(in context: inout GraphicsContext, from a: CGPoint, to b: CGPoint, rate: Double,
                               color: Color, lane: CGFloat, time: TimeInterval, seed: Double) {
        guard rate > 256 else { return }
        // Log scale so a 10x change in bandwidth reads as a clear but bounded change on screen.
        let magnitude = log10(rate / 1024 + 1)
        let count = Int(min(7, max(1, magnitude * 2)))
        let speed = 0.25 + min(1.2, magnitude * 0.35)
        let radius = 2.2 + min(1.8, magnitude * 0.5)

        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(hypot(dx, dy), 1)
        let normal = CGPoint(x: -dy / length * lane, y: dx / length * lane)

        for index in 0..<count {
            let t = (time * speed + Double(index) / Double(count) + seed).truncatingRemainder(dividingBy: 1)
            let p = CGPoint(x: a.x + dx * t + normal.x, y: a.y + dy * t + normal.y)
            let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.9)))
        }
    }

    private func drawTunnelLabels(in context: inout GraphicsContext, node: NetworkMapLayout.TunnelNode,
                                  status: TunnelStatus, latest: ThroughputSample?) {
        let radius = NetworkMapLayout.tunnelNodeRadius
        let position = node.position
        let title = node.hiddenPeerCount > 0
            ? "\(node.tunnel.name)  +\(node.hiddenPeerCount) peers"
            : node.tunnel.name
        context.draw(Text(title).font(.caption.weight(.semibold)).foregroundStyle(.primary),
                     at: CGPoint(x: position.x, y: position.y + radius + 6), anchor: .top)

        if status == .connected, let latest {
            let rates = "↓ \(ByteFormatting.rate(latest.receivedBytesPerSecond))  ↑ \(ByteFormatting.rate(latest.sentBytesPerSecond))"
            context.draw(Text(rates).font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                         at: CGPoint(x: position.x, y: position.y + radius + 22), anchor: .top)
        } else if status != .disconnected {
            context.draw(Text(status.displayName).font(.caption2).foregroundStyle(status.color),
                         at: CGPoint(x: position.x, y: position.y + radius + 22), anchor: .top)
        }
    }

    private func drawPeerLabel(in context: inout GraphicsContext, node: NetworkMapLayout.PeerNode, center: CGPoint) {
        let radius = NetworkMapLayout.peerNodeRadius
        let position = node.position
        // Push the label outward from the center so it never overlaps the edge.
        let dx = position.x - center.x, dy = position.y - center.y
        let length = max(hypot(dx, dy), 1)
        let direction = CGPoint(x: dx / length, y: dy / length)
        let labelPoint = CGPoint(x: position.x + direction.x * (radius + 6), y: position.y + direction.y * (radius + 6))
        let anchor = UnitPoint(x: 0.5 - direction.x * 0.5, y: 0.5 - direction.y * 0.5)
        context.draw(Text(node.peer.displayLabel).font(.caption2).foregroundStyle(.secondary),
                     at: labelPoint, anchor: anchor)
    }
}

#Preview {
    NetworkMapView()
        .environment(TunnelManager.preview())
        .frame(width: 600, height: 440)
        .padding()
        .background(AmbientBackground())
}
