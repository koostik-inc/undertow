import CryptoKit
import Foundation
import NetworkExtension
import Security

/// A backend that drives tunnels through the system VPN stack using a packet tunnel
/// provider extension built on WireGuardKit.
///
/// Each tunnel is stored as an `NETunnelProviderManager`. The wg-quick text (which holds the
/// private key) lives in the keychain; the manager only carries a persistent keychain
/// reference in `passwordReference` plus a digest so the app can detect stale system copies.
/// Statistics are requested through `TunnelProviderMessage`.
@MainActor
final class NetworkExtensionTunnelBackend: TunnelBackend {
    let kind: TunnelBackendKind = .networkExtension
    var statusDidChange: ((UUID, TunnelStatus) -> Void)?

    /// The bundle identifier the packet tunnel extension is expected to use.
    static var providerBundleIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "undertow") + ".PacketTunnel"
    }

    /// True when a packet tunnel extension ships inside this app bundle.
    nonisolated static var isExtensionBundled: Bool {
        var candidates: [URL] = []
        if let plugIns = Bundle.main.builtInPlugInsURL {
            candidates.append(plugIns)
        }
        #if os(macOS)
        candidates.append(Bundle.main.bundleURL.appending(path: "Contents/Library/SystemExtensions"))
        #endif
        for directory in candidates {
            guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                continue
            }
            if items.contains(where: { $0.pathExtension == "appex" || $0.pathExtension == "systemextension" }) {
                return true
            }
        }
        return false
    }

    /// True when this process is signed with the packet tunnel entitlement.
    ///
    /// On macOS the entitlement can be read from the running task. iOS does not expose
    /// that API, but an extension cannot be installed there without it, so bundling is enough.
    nonisolated static var hasPacketTunnelEntitlement: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.networking.networkextension" as CFString, nil),
              let providers = value as? [String] else {
            return false
        }
        return providers.contains { $0.hasPrefix("packet-tunnel-provider") }
        #else
        return true
        #endif
    }

    /// True when the system VPN can actually be used: an extension is bundled and the app is entitled.
    nonisolated static var isAvailable: Bool {
        isExtensionBundled && hasPacketTunnelEntitlement
    }

    private var managers: [UUID: NETunnelProviderManager] = [:]
    private var lastKnownStatuses: [UUID: TunnelStatus] = [:]
    private var observer: NSObjectProtocol?

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func prepare() async {
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            for manager in all {
                if let id = Self.tunnelID(of: manager) {
                    managers[id] = manager
                    lastKnownStatuses[id] = Self.status(from: manager.connection.status)
                }
            }
        } catch {
            // Without the entitlement this fails; the UI shows tunnels as unavailable.
        }

        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange,
                                                          object: nil,
                                                          queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refreshStatuses()
            }
        }
    }

    // MARK: - Installation

    func isSynchronized(_ tunnel: Tunnel) -> Bool {
        guard let manager = managers[tunnel.id],
              let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol,
              protocolConfiguration.passwordReference != nil,
              let digest = protocolConfiguration.providerConfiguration?[TunnelProviderMessage.ConfigurationKey.configurationDigest] as? String else {
            return false
        }
        return digest == Self.digest(of: WireGuardConfigFile.serialize(tunnel.configuration))
            && manager.localizedDescription == tunnel.name
            && manager.isOnDemandEnabled == tunnel.connectOnDemand
    }

    func synchronize(_ tunnel: Tunnel) async throws {
        guard Self.isExtensionBundled else { throw TunnelBackendError.extensionUnavailable }

        let manager = managers[tunnel.id] ?? NETunnelProviderManager()
        let existingReference = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.passwordReference
        let configurationText = WireGuardConfigFile.serialize(tunnel.configuration)

        // Private keys go to the keychain; the system preferences only get a reference.
        let reference: Data
        do {
            reference = try TunnelConfigurationKeychain.store(configurationText,
                                                              tunnelID: tunnel.id,
                                                              name: tunnel.name,
                                                              replacing: existingReference)
        } catch {
            throw TunnelBackendError.underlying(error.localizedDescription)
        }

        let protocolConfiguration = NETunnelProviderProtocol()
        protocolConfiguration.providerBundleIdentifier = Self.providerBundleIdentifier
        protocolConfiguration.serverAddress = tunnel.configuration.peers.first?.endpoint?.description ?? "WireGuard"
        protocolConfiguration.passwordReference = reference
        protocolConfiguration.providerConfiguration = [
            TunnelProviderMessage.ConfigurationKey.tunnelID: tunnel.id.uuidString,
            TunnelProviderMessage.ConfigurationKey.configurationDigest: Self.digest(of: configurationText),
        ]

        manager.protocolConfiguration = protocolConfiguration
        manager.localizedDescription = tunnel.name
        manager.isEnabled = true
        manager.isOnDemandEnabled = tunnel.connectOnDemand
        if tunnel.connectOnDemand {
            let rule = NEOnDemandRuleConnect()
            rule.interfaceTypeMatch = .any
            manager.onDemandRules = [rule]
        } else {
            manager.onDemandRules = nil
        }

        do {
            try await manager.saveToPreferences()
            // Reloading after a save avoids the well-known stale-configuration error on first start.
            try await manager.loadFromPreferences()
        } catch {
            throw TunnelBackendError.underlying(error.localizedDescription)
        }
        managers[tunnel.id] = manager
        lastKnownStatuses[tunnel.id] = Self.status(from: manager.connection.status)
    }

    func remove(_ tunnel: Tunnel) async throws {
        defer { TunnelConfigurationKeychain.delete(tunnelID: tunnel.id) }
        guard let manager = managers[tunnel.id] else { return }
        if let reference = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.passwordReference {
            TunnelConfigurationKeychain.delete(reference: reference)
        }
        do {
            try await manager.removeFromPreferences()
        } catch {
            throw TunnelBackendError.underlying(error.localizedDescription)
        }
        managers[tunnel.id] = nil
        lastKnownStatuses[tunnel.id] = nil
    }

    func pruneOrphans(keeping tunnelIDs: Set<UUID>) async {
        for (id, manager) in managers where !tunnelIDs.contains(id) {
            if let reference = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.passwordReference {
                TunnelConfigurationKeychain.delete(reference: reference)
            }
            TunnelConfigurationKeychain.delete(tunnelID: id)
            // Best effort: a failure here just leaves the stale entry for the next launch.
            try? await manager.removeFromPreferences()
            managers[id] = nil
            lastKnownStatuses[id] = nil
        }
    }

    // MARK: - Connection control

    func start(_ tunnel: Tunnel) async throws {
        guard Self.isExtensionBundled else { throw TunnelBackendError.extensionUnavailable }
        guard let manager = managers[tunnel.id] else { throw TunnelBackendError.notInstalled }
        do {
            try manager.connection.startVPNTunnel()
        } catch {
            throw TunnelBackendError.underlying(error.localizedDescription)
        }
        refreshStatuses()
    }

    func stop(_ tunnel: Tunnel) async throws {
        guard let manager = managers[tunnel.id] else { throw TunnelBackendError.notInstalled }
        // Connect on Demand has no "stay off but keep it armed" state: the moment on-demand is
        // enabled, the system tends to reconnect almost immediately while the Mac is online —
        // even a bare re-save of the on-demand configuration itself can trigger it, not just
        // new traffic. So a disconnect can't be trusted to stick here; see
        // `TunnelManager.disconnect(_:)`, which turns the tunnel's on-demand *preference* off
        // first (visibly, in the UI) before this is ever called, whenever it's on.
        manager.connection.stopVPNTunnel()
        refreshStatuses()
    }

    func status(for tunnelID: UUID) -> TunnelStatus {
        guard let manager = managers[tunnelID] else {
            return Self.isExtensionBundled ? .disconnected : .invalid
        }
        return Self.status(from: manager.connection.status)
    }

    func statistics(for tunnelID: UUID) async -> TunnelRuntimeStatistics? {
        guard let manager = managers[tunnelID],
              let session = manager.connection as? NETunnelProviderSession,
              session.status == .connected || session.status == .reasserting else {
            return nil
        }
        guard let request = try? JSONEncoder().encode(TunnelProviderMessage.Request.statistics) else { return nil }

        // Race the provider reply against a deadline: an unresponsive extension must not
        // stall the app's polling loop, which would freeze every status in the UI.
        let response: Data? = await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    do {
                        try session.sendProviderMessage(request) { data in
                            continuation.resume(returning: data)
                        }
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let response else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(TunnelProviderMessage.StatisticsResponse.self, from: response) else {
            return nil
        }
        return decoded.asRuntimeStatistics()
    }

    // MARK: - Helpers

    private func refreshStatuses() {
        for (id, manager) in managers {
            let status = Self.status(from: manager.connection.status)
            if lastKnownStatuses[id] != status {
                lastKnownStatuses[id] = status
                statusDidChange?(id, status)
            }
        }
    }

    private static func tunnelID(of manager: NETunnelProviderManager) -> UUID? {
        guard let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol,
              let raw = protocolConfiguration.providerConfiguration?[TunnelProviderMessage.ConfigurationKey.tunnelID] as? String else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    /// Hex SHA-256 of the configuration text, stored alongside the keychain reference.
    nonisolated static func digest(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func status(from status: NEVPNStatus) -> TunnelStatus {
        switch status {
        case .invalid: return .invalid
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .connected: return .connected
        case .reasserting: return .reasserting
        case .disconnecting: return .disconnecting
        @unknown default: return .invalid
        }
    }
}

extension TunnelProviderMessage.StatisticsResponse {
    /// Converts the provider's reply into the app's runtime statistics model.
    nonisolated func asRuntimeStatistics(at timestamp: Date = .now) -> TunnelRuntimeStatistics {
        let peerStats = peers.compactMap { peer -> PeerRuntimeStatistics? in
            guard let key = WireGuardKey(base64: peer.publicKey) else { return nil }
            return PeerRuntimeStatistics(publicKey: key,
                                         endpoint: peer.endpoint,
                                         lastHandshake: peer.lastHandshake,
                                         receivedBytes: peer.receivedBytes,
                                         sentBytes: peer.sentBytes)
        }
        return TunnelRuntimeStatistics(
            timestamp: timestamp,
            connectedSince: connectedSince,
            receivedBytes: peerStats.reduce(0) { $0 + $1.receivedBytes },
            sentBytes: peerStats.reduce(0) { $0 + $1.sentBytes },
            peers: peerStats
        )
    }
}
