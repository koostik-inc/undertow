import Foundation
import Security

/// Stores wg-quick configuration text (which contains private keys) in the data-protection
/// keychain instead of the system VPN preferences, where it would be readable in plaintext.
///
/// Items live in the keychain access group shared by the app and the packet tunnel extension
/// (the first entry of both targets' `keychain-access-groups` entitlement), so neither side
/// has to name the group explicitly. The app hands the extension a persistent reference via
/// `NETunnelProviderProtocol.passwordReference`; the extension resolves it with `load(reference:)`.
///
/// This file is compiled into both the app and the extension.
nonisolated enum TunnelConfigurationKeychain {
    private static let service = "io.craterlabs.undertow.tunnel-configuration"

    enum KeychainError: LocalizedError {
        case itemNotFound
        case invalidData
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .itemNotFound:
                return "The tunnel configuration is missing from the keychain."
            case .invalidData:
                return "The tunnel configuration in the keychain is not readable."
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
                return "Keychain error \(status): \(message)"
            }
        }
    }

    /// Saves the configuration and returns a persistent reference to it.
    ///
    /// When `existingReference` still points at a live item, the item is updated in place so
    /// the reference stored in the VPN preferences stays valid.
    static func store(_ text: String, tunnelID: UUID, name: String, replacing existingReference: Data?) throws -> Data {
        let data = Data(text.utf8)

        if let existingReference, (try? load(reference: existingReference)) != nil {
            let query: [CFString: Any] = [
                kSecValuePersistentRef: existingReference,
                kSecUseDataProtectionKeychain: true,
            ]
            let attributes: [CFString: Any] = [
                kSecValueData: data,
                kSecAttrLabel: label(for: name),
            ]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
            return existingReference
        }

        // Keep (service, account) unique even if a stale item survived an earlier failure.
        delete(tunnelID: tunnelID)

        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: tunnelID.uuidString,
            kSecAttrLabel: label(for: name),
            kSecAttrDescription: "wg-quick configuration",
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable: false,
            kSecUseDataProtectionKeychain: true,
            kSecValueData: data,
            kSecReturnPersistentRef: true,
        ]
        var result: CFTypeRef?
        let status = SecItemAdd(attributes as CFDictionary, &result)
        guard status == errSecSuccess, let reference = result as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return reference
    }

    /// Resolves a persistent reference back into configuration text.
    static func load(reference: Data) throws -> String {
        let query: [CFString: Any] = [
            kSecValuePersistentRef: reference,
            kSecReturnData: true,
            kSecUseDataProtectionKeychain: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw KeychainError.itemNotFound }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return text
    }

    /// Removes the item for a tunnel, if any. Safe to call when nothing is stored.
    static func delete(tunnelID: UUID) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: tunnelID.uuidString,
            kSecUseDataProtectionKeychain: true,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Removes the item behind a persistent reference, if it still exists.
    static func delete(reference: Data) {
        let query: [CFString: Any] = [
            kSecValuePersistentRef: reference,
            kSecUseDataProtectionKeychain: true,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func label(for name: String) -> String {
        "Undertow tunnel: \(name)"
    }
}
