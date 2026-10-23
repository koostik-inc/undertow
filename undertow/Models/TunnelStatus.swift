import Foundation

/// Lifecycle state of a tunnel, mirroring `NEVPNStatus`.
nonisolated enum TunnelStatus: String, CaseIterable, Hashable, Sendable, Codable {
    case disconnected
    case connecting
    case connected
    case reasserting
    case disconnecting
    case invalid

    var displayName: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reasserting: return "Reconnecting"
        case .disconnecting: return "Disconnecting"
        case .invalid: return "Unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .disconnected: return "circle"
        case .connecting, .reasserting: return "arrow.triangle.2.circlepath"
        case .connected: return "checkmark.circle.fill"
        case .disconnecting: return "xmark.circle"
        case .invalid: return "exclamationmark.triangle.fill"
        }
    }

    /// True while the tunnel is up or in the process of coming up or down.
    var isActive: Bool {
        switch self {
        case .connecting, .connected, .reasserting, .disconnecting: return true
        case .disconnected, .invalid: return false
        }
    }

    var isTransitioning: Bool {
        switch self {
        case .connecting, .reasserting, .disconnecting: return true
        case .connected, .disconnected, .invalid: return false
        }
    }
}

/// Live counters for one peer, as reported by the backend.
nonisolated struct PeerRuntimeStatistics: Hashable, Sendable {
    /// WireGuard drops a session whose last handshake is older than this.
    static let handshakeValidity: TimeInterval = 180

    var publicKey: WireGuardKey
    var endpoint: String?
    var lastHandshake: Date?
    var receivedBytes: UInt64
    var sentBytes: UInt64

    /// True when the peer completed a handshake recently enough that traffic can flow.
    var hasRecentHandshake: Bool {
        guard let lastHandshake else { return false }
        return Date.now.timeIntervalSince(lastHandshake) < Self.handshakeValidity
    }
}

/// A snapshot of a tunnel's cumulative counters at a point in time.
nonisolated struct TunnelRuntimeStatistics: Hashable, Sendable {
    var timestamp: Date
    var connectedSince: Date?
    var receivedBytes: UInt64
    var sentBytes: UInt64
    var peers: [PeerRuntimeStatistics]

    /// The most recent handshake across all peers.
    var lastHandshake: Date? {
        peers.compactMap(\.lastHandshake).max()
    }
}
