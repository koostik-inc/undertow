import Foundation

/// An IP address with a CIDR prefix length, e.g. `10.0.0.2/32` or `fd00::1/128`.
nonisolated struct IPAddressRange: Hashable, Codable, Sendable, CustomStringConvertible {
    var address: String
    var prefixLength: UInt8

    var isIPv6: Bool { address.contains(":") }

    init(address: String, prefixLength: UInt8) {
        self.address = address
        self.prefixLength = prefixLength
    }

    /// Parses `address[/prefix]`. A missing prefix means a single host.
    init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        let address = parts[0]
        let isIPv6 = address.contains(":")
        guard Self.isPlausibleAddress(address, ipv6: isIPv6) else { return nil }
        let maxPrefix: UInt8 = isIPv6 ? 128 : 32
        if parts.count == 2 {
            guard let prefix = UInt8(parts[1]), prefix <= maxPrefix else { return nil }
            self.init(address: address, prefixLength: prefix)
        } else {
            self.init(address: address, prefixLength: maxPrefix)
        }
    }

    var description: String { "\(address)/\(prefixLength)" }

    /// The address as raw network-order bytes (4 for IPv4, 16 for IPv6), or nil if unparsable.
    var addressBytes: [UInt8]? {
        if isIPv6 {
            var raw = in6_addr()
            guard inet_pton(AF_INET6, address, &raw) == 1 else { return nil }
            return withUnsafeBytes(of: raw) { Array($0) }
        }
        var raw = in_addr()
        guard inet_pton(AF_INET, address, &raw) == 1 else { return nil }
        return withUnsafeBytes(of: raw) { Array($0) }
    }

    /// True when `host` (an IPv4 or IPv6 literal) falls inside this range.
    func contains(_ host: String) -> Bool {
        guard let network = addressBytes,
              let target = IPAddressRange(address: host, prefixLength: 0).addressBytes,
              network.count == target.count else {
            return false
        }
        var remainingBits = Int(prefixLength)
        for (networkByte, targetByte) in zip(network, target) {
            guard remainingBits > 0 else { return true }
            let mask = UInt8(truncatingIfNeeded: remainingBits >= 8 ? 0xFF : 0xFF << (8 - remainingBits))
            if networkByte & mask != targetByte & mask { return false }
            remainingBits -= 8
        }
        return true
    }

    /// Lightweight syntactic validation; the kernel/backend performs the real check.
    private static func isPlausibleAddress(_ address: String, ipv6: Bool) -> Bool {
        if ipv6 {
            let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
            return address.unicodeScalars.allSatisfy { allowed.contains($0) } && address.contains(":")
        }
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard let value = Int(octet) else { return false }
            return (0...255).contains(value)
        }
    }
}

/// A peer endpoint: `host:port` for IPv4 and hostnames, `[host]:port` for IPv6.
nonisolated struct Endpoint: Hashable, Codable, Sendable, CustomStringConvertible {
    var host: String
    var port: UInt16

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("[") {
            // IPv6 literal: [addr]:port
            guard let closing = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            let remainder = trimmed[trimmed.index(after: closing)...]
            guard remainder.hasPrefix(":"), let port = UInt16(remainder.dropFirst()), !host.isEmpty else {
                return nil
            }
            self.init(host: host, port: port)
        } else {
            guard let colon = trimmed.lastIndex(of: ":") else { return nil }
            let host = String(trimmed[..<colon])
            guard !host.isEmpty, !host.contains(":"), let port = UInt16(trimmed[trimmed.index(after: colon)...]) else {
                return nil
            }
            self.init(host: host, port: port)
        }
    }

    var description: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

/// The `[Interface]` section of a WireGuard configuration.
nonisolated struct InterfaceConfiguration: Hashable, Codable, Sendable {
    var privateKey: WireGuardKey
    var addresses: [IPAddressRange] = []
    var listenPort: UInt16?
    var mtu: UInt16?
    var dnsServers: [String] = []
    var dnsSearchDomains: [String] = []

    var publicKey: WireGuardKey? { privateKey.derivedPublicKey() }

    init(privateKey: WireGuardKey = .generatePrivateKey()) {
        self.privateKey = privateKey
    }
}

/// A `[Peer]` section of a WireGuard configuration.
nonisolated struct PeerConfiguration: Hashable, Codable, Sendable, Identifiable {
    var id = UUID()
    var publicKey: WireGuardKey
    var preSharedKey: WireGuardKey?
    var allowedIPs: [IPAddressRange] = []
    var endpoint: Endpoint?
    var persistentKeepAlive: UInt16?

    init(publicKey: WireGuardKey) {
        self.publicKey = publicKey
    }

    /// A short display label: the endpoint host when present, otherwise the abbreviated key.
    var displayLabel: String {
        endpoint?.host ?? publicKey.abbreviated
    }

    /// True when any allowed range covers the whole address space (a full-tunnel peer).
    var routesAllTraffic: Bool {
        allowedIPs.contains { $0.prefixLength == 0 }
    }
}

/// A complete WireGuard configuration: one interface and any number of peers.
nonisolated struct TunnelConfiguration: Hashable, Codable, Sendable {
    var interface: InterfaceConfiguration
    var peers: [PeerConfiguration] = []

    init(interface: InterfaceConfiguration = InterfaceConfiguration(), peers: [PeerConfiguration] = []) {
        self.interface = interface
        self.peers = peers
    }

    /// DNS servers that no peer's AllowedIPs cover.
    ///
    /// While the tunnel is up, the system sends every DNS query to these servers, but only
    /// AllowedIPs are routed through the tunnel. A DNS server outside them is unreachable,
    /// which takes all name resolution on the device down. This is the most common cause of
    /// "everything stopped working after connecting".
    var unreachableDNSServers: [String] {
        interface.dnsServers.filter { server in
            !peers.contains { peer in peer.allowedIPs.contains { $0.contains(server) } }
        }
    }
}
