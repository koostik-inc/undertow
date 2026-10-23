import Foundation

/// Stores the tunnel list as JSON in the app's Application Support directory.
nonisolated struct TunnelPersistence: Sendable {
    let fileURL: URL

    /// The default on-disk location inside the app container.
    static func standard() -> TunnelPersistence {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil,
                                                 create: true))
            ?? FileManager.default.temporaryDirectory
        let directory = base.appending(path: "Undertow", directoryHint: .isDirectory)
        return TunnelPersistence(fileURL: directory.appending(path: "tunnels.json"))
    }

    /// A throwaway store for previews and tests.
    static func ephemeral() -> TunnelPersistence {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Undertow-\(UUID().uuidString)", directoryHint: .isDirectory)
        return TunnelPersistence(fileURL: directory.appending(path: "tunnels.json"))
    }

    func load() throws -> [Tunnel] {
        // `path()` percent-encodes by default ("Application%20Support"), which made this check
        // fail for every real user and silently start each launch with no tunnels.
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Tunnel].self, from: data)
    }

    func save(_ tunnels: [Tunnel]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(tunnels)
        // Private keys live in this file, so write atomically and keep it protected on iOS.
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
