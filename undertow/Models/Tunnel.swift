import Foundation

/// A saved tunnel: a user-facing name plus its WireGuard configuration and app-level options.
///
/// Live state (status, counters, throughput) is kept by `TunnelManager`, keyed by `id`,
/// so this value stays a plain, persistable record.
nonisolated struct Tunnel: Identifiable, Hashable, Codable, Sendable {
    /// Interface names are limited to 15 characters on every platform WireGuard runs on.
    static let maximumNameLength = 15

    var id: UUID
    var name: String
    var configuration: TunnelConfiguration
    var connectOnDemand: Bool
    var createdAt: Date

    init(id: UUID = UUID(),
         name: String,
         configuration: TunnelConfiguration,
         connectOnDemand: Bool = false,
         createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.configuration = configuration
        self.connectOnDemand = connectOnDemand
        self.createdAt = createdAt
    }

    /// The first peer endpoint, for compact summaries.
    var primaryEndpointDescription: String? {
        configuration.peers.lazy.compactMap(\.endpoint).first?.description
    }

    /// Returns a description of what is wrong with a proposed name, or nil when it is acceptable.
    ///
    /// Names follow interface naming rules: 1 to 15 characters drawn from letters, digits, and `_ = + . -`.
    static func validateName(_ proposed: String) -> String? {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Give the tunnel a name."
        }
        if trimmed.count > maximumNameLength {
            return "Names can be at most \(maximumNameLength) characters."
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_=+.-"))
        if trimmed.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "Names may only contain letters, numbers, and _ = + . -"
        }
        return nil
    }
}
