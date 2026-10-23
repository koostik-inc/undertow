import Foundation

/// A backend that models tunnel lifecycle and traffic without touching the network.
///
/// Used in previews, tests, and builds that do not bundle a packet tunnel extension.
/// Traffic follows a mean-reverting random walk with occasional bursts so charts and
/// the network map look like a real, busy link.
@MainActor
final class SimulatedTunnelBackend: TunnelBackend {
    let kind: TunnelBackendKind = .simulated
    var statusDidChange: ((UUID, TunnelStatus) -> Void)?

    private struct PeerSimulation {
        var receivedBytes: Double = 0
        var sentBytes: Double = 0
        var lastHandshake: Date
        var nextHandshakeInterval: TimeInterval = .random(in: 100...140)
        var weight: Double
    }

    private struct Session {
        var status: TunnelStatus = .disconnected
        var connectedSince: Date?
        var lastUpdate: Date = .now
        var peers: [WireGuardKey: PeerSimulation] = [:]
        var peerOrder: [WireGuardKey] = []

        // Log-space throughput levels (natural log of bytes per second).
        var receiveLevel: Double
        var sendLevel: Double
        let receiveTarget: Double
        let sendTarget: Double
        var burstSecondsRemaining: Double = 0
        var transitionTask: Task<Void, Never>?
    }

    private var tunnels: [UUID: Tunnel] = [:]
    private var sessions: [UUID: Session] = [:]

    /// Shortens connect/disconnect delays, handy for tests and previews.
    var transitionDuration: ClosedRange<Double> = 0.6...1.6

    func prepare() async {}

    func synchronize(_ tunnel: Tunnel) async throws {
        tunnels[tunnel.id] = tunnel
        if var session = sessions[tunnel.id] {
            // Keep counters for peers that still exist; add new peers.
            let keys = tunnel.configuration.peers.map(\.publicKey)
            session.peerOrder = keys
            for key in keys where session.peers[key] == nil {
                session.peers[key] = PeerSimulation(lastHandshake: .now, weight: .random(in: 0.3...1.0))
            }
            session.peers = session.peers.filter { keys.contains($0.key) }
            sessions[tunnel.id] = session
        }
    }

    func isSynchronized(_ tunnel: Tunnel) -> Bool {
        tunnels[tunnel.id] == tunnel
    }

    func pruneOrphans(keeping tunnelIDs: Set<UUID>) async {
        for id in sessions.keys where !tunnelIDs.contains(id) {
            sessions[id]?.transitionTask?.cancel()
            sessions[id] = nil
            tunnels[id] = nil
        }
    }

    func remove(_ tunnel: Tunnel) async throws {
        sessions[tunnel.id]?.transitionTask?.cancel()
        sessions[tunnel.id] = nil
        tunnels[tunnel.id] = nil
    }

    func start(_ tunnel: Tunnel) async throws {
        tunnels[tunnel.id] = tunnel
        var session = sessions[tunnel.id] ?? makeSession(for: tunnel)
        session.transitionTask?.cancel()
        session.status = .connecting
        sessions[tunnel.id] = session
        statusDidChange?(tunnel.id, .connecting)

        let delay = Double.random(in: transitionDuration)
        let id = tunnel.id
        sessions[id]?.transitionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.completeConnection(for: id)
        }
    }

    func stop(_ tunnel: Tunnel) async throws {
        guard var session = sessions[tunnel.id] else { return }
        session.transitionTask?.cancel()
        session.status = .disconnecting
        sessions[tunnel.id] = session
        statusDidChange?(tunnel.id, .disconnecting)

        let id = tunnel.id
        sessions[id]?.transitionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.4))
            guard !Task.isCancelled, let self else { return }
            self.sessions[id]?.status = .disconnected
            self.sessions[id]?.connectedSince = nil
            self.statusDidChange?(id, .disconnected)
        }
    }

    func status(for tunnelID: UUID) -> TunnelStatus {
        sessions[tunnelID]?.status ?? .disconnected
    }

    func statistics(for tunnelID: UUID) async -> TunnelRuntimeStatistics? {
        guard var session = sessions[tunnelID], session.status.isActive else { return nil }
        let now = Date.now
        if session.status == .connected {
            advance(&session, to: now)
        }
        session.lastUpdate = now
        sessions[tunnelID] = session

        let peers = session.peerOrder.compactMap { key -> PeerRuntimeStatistics? in
            guard let sim = session.peers[key] else { return nil }
            let endpoint = tunnels[tunnelID]?.configuration.peers.first { $0.publicKey == key }?.endpoint?.description
            return PeerRuntimeStatistics(publicKey: key,
                                         endpoint: endpoint,
                                         lastHandshake: session.status == .connected ? sim.lastHandshake : nil,
                                         receivedBytes: UInt64(sim.receivedBytes),
                                         sentBytes: UInt64(sim.sentBytes))
        }
        return TunnelRuntimeStatistics(timestamp: now,
                                       connectedSince: session.connectedSince,
                                       receivedBytes: peers.reduce(0) { $0 + $1.receivedBytes },
                                       sentBytes: peers.reduce(0) { $0 + $1.sentBytes },
                                       peers: peers)
    }

    // MARK: - Simulation

    private func makeSession(for tunnel: Tunnel) -> Session {
        // Each tunnel gets its own typical bandwidth so the map and charts differ per tunnel.
        let receiveTarget = log(Double.random(in: 40_000...3_000_000))
        let sendTarget = log(Double.random(in: 8_000...600_000))
        var session = Session(receiveLevel: receiveTarget, sendLevel: sendTarget,
                              receiveTarget: receiveTarget, sendTarget: sendTarget)
        session.peerOrder = tunnel.configuration.peers.map(\.publicKey)
        for key in session.peerOrder {
            session.peers[key] = PeerSimulation(lastHandshake: .now, weight: .random(in: 0.3...1.0))
        }
        return session
    }

    private func completeConnection(for id: UUID) {
        guard var session = sessions[id], session.status == .connecting else { return }
        let now = Date.now
        session.status = .connected
        session.connectedSince = now
        session.lastUpdate = now
        for key in session.peerOrder {
            session.peers[key]?.lastHandshake = now
        }
        sessions[id] = session
        statusDidChange?(id, .connected)
    }

    private func advance(_ session: inout Session, to now: Date) {
        let elapsed = max(0, min(now.timeIntervalSince(session.lastUpdate), 5))
        guard elapsed > 0 else { return }

        // Mean-reverting random walk in log space keeps rates positive and plausible.
        func step(_ level: inout Double, toward target: Double) {
            level += (target - level) * 0.08 * elapsed + Double.random(in: -0.3...0.3) * elapsed.squareRoot()
        }
        step(&session.receiveLevel, toward: session.receiveTarget)
        step(&session.sendLevel, toward: session.sendTarget)

        // Occasional bursts, like a download kicking off.
        if session.burstSecondsRemaining > 0 {
            session.burstSecondsRemaining -= elapsed
        } else if Double.random(in: 0...1) < 0.03 * elapsed {
            session.burstSecondsRemaining = .random(in: 3...12)
        }
        let burstMultiplier = session.burstSecondsRemaining > 0 ? 4.0 : 1.0

        let receiveRate = exp(session.receiveLevel) * burstMultiplier
        let sendRate = exp(session.sendLevel) * (session.burstSecondsRemaining > 0 ? 1.5 : 1.0)

        let totalWeight = session.peers.values.reduce(0) { $0 + $1.weight }
        for key in session.peerOrder {
            guard var sim = session.peers[key] else { continue }
            let share = totalWeight > 0 ? sim.weight / totalWeight : 1
            sim.receivedBytes += receiveRate * share * elapsed
            sim.sentBytes += sendRate * share * elapsed
            // WireGuard rekeys roughly every two minutes while traffic flows.
            if now.timeIntervalSince(sim.lastHandshake) > sim.nextHandshakeInterval {
                sim.lastHandshake = now
                sim.nextHandshakeInterval = .random(in: 100...140)
            }
            session.peers[key] = sim
        }
    }
}
