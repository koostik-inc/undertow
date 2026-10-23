import Foundation
import CryptoKit

/// A 32-byte Curve25519 key as used by WireGuard. Stored raw, exchanged as base64.
nonisolated struct WireGuardKey: Hashable, Sendable {
    static let byteCount = 32

    let rawValue: Data

    /// Creates a key from exactly 32 raw bytes.
    init?(data: Data) {
        guard data.count == Self.byteCount else { return nil }
        rawValue = data
    }

    /// Creates a key from its base64 representation as found in `.conf` files.
    init?(base64 string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed), data.count == Self.byteCount else { return nil }
        rawValue = data
    }

    private init(unchecked data: Data) {
        rawValue = data
    }

    /// The base64 form used in configuration files and the UI.
    var base64Key: String { rawValue.base64EncodedString() }

    /// A short, human-friendly prefix used in labels where the full key would be noise.
    var abbreviated: String { String(base64Key.prefix(8)) + "…" }

    /// Generates a fresh Curve25519 private key suitable for a WireGuard interface.
    static func generatePrivateKey() -> WireGuardKey {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return WireGuardKey(unchecked: key.rawRepresentation)
    }

    /// Generates 32 random bytes for use as a peer preshared key.
    static func generatePresharedKey() -> WireGuardKey {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return WireGuardKey(unchecked: Data(bytes))
    }

    /// Derives the public key when this key is a private key. Returns nil if the bytes are not a valid scalar.
    func derivedPublicKey() -> WireGuardKey? {
        guard let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawValue) else { return nil }
        return WireGuardKey(data: privateKey.publicKey.rawRepresentation)
    }
}

extension WireGuardKey: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let key = WireGuardKey(base64: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Value is not a base64-encoded 32-byte key.")
        }
        self = key
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(base64Key)
    }
}
