import Foundation
import Observation
import SwiftUI
import os

/// A user-facing error wrapper suitable for `.alert(item:)`.
nonisolated struct PresentableError: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}

/// The app's single source of truth for tunnels, their live status, and throughput history.
@Observable
@MainActor
final class TunnelManager {
    private(set) var tunnels: [Tunnel] = []
    private(set) var statuses: [UUID: TunnelStatus] = [:]
    private(set) var statistics: [UUID: TunnelRuntimeStatistics] = [:]
    private(set) var histories: [UUID: ThroughputHistory] = [:]
    /// Combined throughput of every tunnel, for the overview.
    private(set) var aggregateHistory = ThroughputHistory()
    /// Tunnels with an in-flight connect/disconnect request.
    private(set) var busyTunnelIDs: Set<UUID> = []
    var presentedError: PresentableError?

    let backend: any TunnelBackend
    private let persistence: TunnelPersistence
    private var monitorTask: Task<Void, Never>?
    private var isStarted = false

    init(backend: any TunnelBackend, persistence: TunnelPersistence) {
        self.backend = backend
        self.persistence = persistence
    }

    /// Picks the backend from the user's preference and the build's capabilities.
    static func makeBackend(for preference: TunnelBackendKind) -> any TunnelBackend {
        switch preference {
        case .simulated:
            return SimulatedTunnelBackend()
        case .networkExtension:
            return NetworkExtensionTunnelBackend()
        case .automatic:
            return NetworkExtensionTunnelBackend.isAvailable
                ? NetworkExtensionTunnelBackend()
                : SimulatedTunnelBackend()
        }
    }

    // MARK: - Lifecycle

    /// Loads saved tunnels, wires up the backend, and begins polling. Safe to call once.
    func start() async {
        guard !isStarted else { return }
        isStarted = true

        var loadSucceeded = false
        do {
            tunnels = try persistence.load()
            loadSucceeded = true
        } catch {
            report(error, title: "Couldn't Load Tunnels")
        }

        await backend.prepare()
        // Only prune when the store loaded; an empty list from a failed load must not wipe the system.
        if loadSucceeded {
            await backend.pruneOrphans(keeping: Set(tunnels.map(\.id)))
        }
        backend.statusDidChange = { [weak self] id, status in
            guard let self else { return }
            self.statuses[id] = status
            if !status.isActive {
                self.statistics[id] = nil
                self.histories[id]?.resetBaseline()
            }
        }

        for tunnel in tunnels {
            statuses[tunnel.id] = backend.status(for: tunnel.id)
            histories[tunnel.id] = ThroughputHistory()
            // Push tunnels the backend doesn't have yet or holds in an outdated form (for
            // example after editing the saved file, or when migrating configuration storage).
            if !backend.isSynchronized(tunnel) {
                await synchronize(tunnel)
            }
        }

        startMonitoring()
    }

    /// Populates the tunnel list synchronously without persisting. Previews only; `start()`
    /// still runs afterwards and reloads the same tunnels from the preview store.
    func seedForPreview(_ seeded: [Tunnel]) {
        tunnels = seeded
        for tunnel in seeded {
            statuses[tunnel.id] = .disconnected
            histories[tunnel.id] = ThroughputHistory()
        }
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func poll() async {
        let now = Date.now
        var aggregateReceived = 0.0
        var aggregateSent = 0.0

        for tunnel in tunnels {
            let status = backend.status(for: tunnel.id)
            statuses[tunnel.id] = status
            var history = histories[tunnel.id] ?? ThroughputHistory()

            if status.isActive, let stats = await backend.statistics(for: tunnel.id) {
                statistics[tunnel.id] = stats
                history.record(stats)
            } else {
                if !status.isActive { statistics[tunnel.id] = nil }
                history.resetBaseline()
                history.recordIdle(at: now)
            }

            if let latest = history.latest {
                aggregateReceived += latest.receivedBytesPerSecond
                aggregateSent += latest.sentBytesPerSecond
            }
            histories[tunnel.id] = history
        }

        aggregateHistory.record(receivedBytesPerSecond: aggregateReceived, sentBytesPerSecond: aggregateSent, at: now)
    }

    // MARK: - Queries

    func tunnel(withID id: UUID) -> Tunnel? {
        tunnels.first { $0.id == id }
    }

    func status(for id: UUID) -> TunnelStatus {
        statuses[id] ?? .disconnected
    }

    func history(for id: UUID) -> ThroughputHistory {
        histories[id] ?? ThroughputHistory()
    }

    func isBusy(_ id: UUID) -> Bool {
        busyTunnelIDs.contains(id)
    }

    /// Seconds a connected tunnel may go without a handshake before the UI warns about it.
    static let handshakeGracePeriod: TimeInterval = 15

    /// True when the tunnel is up but no peer has completed a handshake for a while.
    ///
    /// WireGuard installs routes and DNS as soon as the interface comes up, so a tunnel that
    /// never handshakes silently black-holes whatever it routes. Surfacing this matters.
    func isAwaitingHandshake(_ id: UUID) -> Bool {
        guard status(for: id) == .connected, let stats = statistics[id], stats.lastHandshake == nil else {
            return false
        }
        let since = stats.connectedSince ?? stats.timestamp
        return Date.now.timeIntervalSince(since) > Self.handshakeGracePeriod
    }

    var activeTunnels: [Tunnel] {
        tunnels.filter { status(for: $0.id).isActive }
    }

    var connectedTunnelCount: Int {
        tunnels.filter { status(for: $0.id) == .connected }.count
    }

    var totalReceivedBytes: UInt64 {
        statistics.values.reduce(0) { $0 + $1.receivedBytes }
    }

    var totalSentBytes: UInt64 {
        statistics.values.reduce(0) { $0 + $1.sentBytes }
    }

    /// Exports a tunnel as wg-quick text.
    func configurationText(for tunnel: Tunnel) -> String {
        WireGuardConfigFile.serialize(tunnel.configuration)
    }

    // MARK: - Mutations

    func add(_ tunnel: Tunnel) async {
        var tunnel = tunnel
        tunnel.name = uniqueName(for: tunnel.name, excluding: tunnel.id)
        tunnels.append(tunnel)
        statuses[tunnel.id] = .disconnected
        histories[tunnel.id] = ThroughputHistory()
        persist()
        await synchronize(tunnel)
    }

    func update(_ tunnel: Tunnel) async {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        var tunnel = tunnel
        tunnel.name = uniqueName(for: tunnel.name, excluding: tunnel.id)
        tunnels[index] = tunnel
        persist()
        await synchronize(tunnel)
    }

    func delete(_ tunnel: Tunnel) async {
        if status(for: tunnel.id).isActive {
            try? await backend.stop(tunnel)
        }
        do {
            try await backend.remove(tunnel)
        } catch {
            report(error, title: "Couldn't Remove Tunnel")
        }
        tunnels.removeAll { $0.id == tunnel.id }
        statuses[tunnel.id] = nil
        statistics[tunnel.id] = nil
        histories[tunnel.id] = nil
        persist()
    }

    func duplicate(_ tunnel: Tunnel) async {
        var copy = tunnel
        copy.id = UUID()
        copy.createdAt = .now
        copy.connectOnDemand = false
        copy.name = uniqueName(for: tunnel.name, excluding: copy.id)
        await add(copy)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        tunnels.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// Parses wg-quick text and adds it as a new tunnel.
    @discardableResult
    func importConfiguration(text: String, suggestedName: String) async throws -> Tunnel {
        let configuration = try WireGuardConfigFile.parse(text)
        let tunnel = Tunnel(name: Tunnel.sanitizedName(from: suggestedName), configuration: configuration)
        await add(tunnel)
        return tunnel
    }

    // MARK: - Connection control

    func connect(_ tunnel: Tunnel) async {
        guard !busyTunnelIDs.contains(tunnel.id) else { return }
        busyTunnelIDs.insert(tunnel.id)
        defer { busyTunnelIDs.remove(tunnel.id) }
        do {
            try await backend.start(tunnel)
            statuses[tunnel.id] = backend.status(for: tunnel.id)
        } catch {
            report(error, title: "Couldn't Connect “\(tunnel.name)”")
        }
    }

    func disconnect(_ tunnel: Tunnel) async {
        guard !busyTunnelIDs.contains(tunnel.id) else { return }
        busyTunnelIDs.insert(tunnel.id)
        defer { busyTunnelIDs.remove(tunnel.id) }
        do {
            try await backend.stop(tunnel)
            statuses[tunnel.id] = backend.status(for: tunnel.id)
        } catch {
            report(error, title: "Couldn't Disconnect “\(tunnel.name)”")
        }
    }

    func toggle(_ tunnel: Tunnel) async {
        if status(for: tunnel.id).isActive {
            await disconnect(tunnel)
        } else {
            await connect(tunnel)
        }
    }

    func disconnectAll() async {
        for tunnel in activeTunnels {
            await disconnect(tunnel)
        }
    }

    // MARK: - Private

    private func synchronize(_ tunnel: Tunnel) async {
        do {
            try await backend.synchronize(tunnel)
        } catch {
            report(error, title: "Couldn't Install “\(tunnel.name)”")
        }
    }

    private func persist() {
        do {
            try persistence.save(tunnels)
        } catch {
            report(error, title: "Couldn't Save Tunnels")
        }
    }

    private func report(_ error: Error, title: String) {
        // Surface in the UI and persist to the unified log so failures can be diagnosed later.
        Self.logger.error("\(title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        presentedError = PresentableError(title: title, message: error.localizedDescription)
    }

    private static let logger = Logger(subsystem: "io.craterlabs.undertow", category: "TunnelManager")

    private func uniqueName(for proposed: String, excluding id: UUID) -> String {
        let base = Tunnel.sanitizedName(from: proposed)
        let taken = Set(tunnels.filter { $0.id != id }.map(\.name))
        guard taken.contains(base) else { return base }
        var counter = 2
        while true {
            let suffix = "-\(counter)"
            let candidate = String(base.prefix(15 - suffix.count)) + suffix
            if !taken.contains(candidate) { return candidate }
            counter += 1
        }
    }
}

extension Tunnel {
    /// Turns an arbitrary string (e.g. a filename) into a valid interface name.
    nonisolated static func sanitizedName(from proposed: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_=+.-"))
        var scalars = String.UnicodeScalarView()
        for scalar in proposed.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            if allowed.contains(scalar) {
                scalars.append(scalar)
            } else if scalar == " " {
                scalars.append("-")
            }
        }
        let cleaned = String(String(scalars).prefix(15))
        return cleaned.isEmpty ? "wg0" : cleaned
    }
}
