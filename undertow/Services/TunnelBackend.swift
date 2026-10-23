import Foundation

/// Which engine drives tunnels. `automatic` picks the system VPN when the app can use it.
nonisolated enum TunnelBackendKind: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case networkExtension
    case simulated

    var id: Self { self }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .networkExtension: return "System VPN (Network Extension)"
        case .simulated: return "Simulated"
        }
    }
}

nonisolated enum TunnelBackendError: LocalizedError {
    /// No packet tunnel extension is bundled, so the system VPN cannot run WireGuard.
    case extensionUnavailable
    /// The tunnel has not been saved to the system yet.
    case notInstalled
    /// A system error, already turned into text.
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .extensionUnavailable:
            return "This build has no packet tunnel extension, so the system VPN cannot run this tunnel. Switch to the simulated backend in Settings or add the extension target."
        case .notInstalled:
            return "The tunnel has not been installed in the system VPN settings yet. Edit and save it to install it."
        case .underlying(let message):
            return message
        }
    }
}

/// The engine that brings tunnels up and down and reports their counters.
///
/// `NetworkExtensionTunnelBackend` drives the system VPN stack through a packet tunnel
/// provider. `SimulatedTunnelBackend` models the same lifecycle and traffic locally so
/// the whole app works, and can be previewed and tested, without the extension.
@MainActor
protocol TunnelBackend: AnyObject {
    var kind: TunnelBackendKind { get }

    /// Called whenever a tunnel's status changes outside a direct request (e.g. system events).
    var statusDidChange: ((UUID, TunnelStatus) -> Void)? { get set }

    /// One-time setup, such as loading existing system VPN configurations.
    func prepare() async

    /// Installs or updates the tunnel's configuration in the engine.
    func synchronize(_ tunnel: Tunnel) async throws

    /// True when the engine already holds exactly this tunnel; false means `synchronize` is needed.
    func isSynchronized(_ tunnel: Tunnel) -> Bool

    /// Removes the tunnel from the engine.
    func remove(_ tunnel: Tunnel) async throws

    /// Removes engine state for tunnels the app no longer knows about (for example a
    /// tunnel deleted while the engine was unreachable). Engines without persistent state do nothing.
    func pruneOrphans(keeping tunnelIDs: Set<UUID>) async

    func start(_ tunnel: Tunnel) async throws
    func stop(_ tunnel: Tunnel) async throws

    func status(for tunnelID: UUID) -> TunnelStatus

    /// Current cumulative counters, or nil when the tunnel is not active.
    func statistics(for tunnelID: UUID) async -> TunnelRuntimeStatistics?
}
