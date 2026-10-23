import Foundation

/// The wire format shared between the app and a packet tunnel provider extension.
///
/// The extension receives `Request` values via `handleAppMessage` and answers with
/// JSON-encoded `StatisticsResponse` payloads. Keeping this in one file lets a future
/// extension target include it verbatim.
nonisolated enum TunnelProviderMessage {

    /// Keys stored in `NETunnelProviderProtocol.providerConfiguration`.
    ///
    /// The configuration text itself is never stored here: it lives in the keychain and the
    /// extension reaches it through `NETunnelProviderProtocol.passwordReference`.
    enum ConfigurationKey {
        static let tunnelID = "tunnelID"
        /// SHA-256 of the stored wg-quick text, so the app can tell when the system copy is stale.
        static let configurationDigest = "configurationDigest"
    }

    enum Request: String, Codable, Sendable {
        case statistics
    }

    struct PeerStatistics: Codable, Sendable {
        var publicKey: String
        var endpoint: String?
        var lastHandshake: Date?
        var receivedBytes: UInt64
        var sentBytes: UInt64
    }

    struct StatisticsResponse: Codable, Sendable {
        var connectedSince: Date?
        var peers: [PeerStatistics]
    }
}
