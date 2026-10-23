import Foundation

/// Validation failures when turning editor text fields into a configuration.
nonisolated enum TunnelDraftError: LocalizedError {
    case name(String)
    case privateKey
    case address(String)
    case listenPort
    case mtu
    case peerPublicKey(Int)
    case peerPreSharedKey(Int)
    case peerAllowedIP(Int, String)
    case peerEndpoint(Int)
    case peerKeepAlive(Int)

    var errorDescription: String? {
        switch self {
        case .name(let reason): return reason
        case .privateKey: return "The private key must be a base64-encoded 32-byte key."
        case .address(let value): return "“\(value)” is not a valid interface address."
        case .listenPort: return "The listen port must be a number between 1 and 65535."
        case .mtu: return "The MTU must be a number between 576 and 65535."
        case .peerPublicKey(let index): return "Peer \(index + 1) needs a valid base64 public key."
        case .peerPreSharedKey(let index): return "Peer \(index + 1) has an invalid pre-shared key."
        case .peerAllowedIP(let index, let value): return "Peer \(index + 1): “\(value)” is not a valid allowed IP range."
        case .peerEndpoint(let index): return "Peer \(index + 1) needs an endpoint like host:port."
        case .peerKeepAlive(let index): return "Peer \(index + 1): keepalive must be a number of seconds."
        }
    }
}

/// Editable string fields for one peer.
nonisolated struct PeerDraft: Identifiable, Hashable {
    var id = UUID()
    var publicKey = ""
    var preSharedKey = ""
    var allowedIPs = ""
    var endpoint = ""
    var persistentKeepAlive = ""

    init() {}

    init(_ peer: PeerConfiguration) {
        id = peer.id
        publicKey = peer.publicKey.base64Key
        preSharedKey = peer.preSharedKey?.base64Key ?? ""
        allowedIPs = peer.allowedIPs.map(\.description).joined(separator: ", ")
        endpoint = peer.endpoint?.description ?? ""
        persistentKeepAlive = peer.persistentKeepAlive.map(String.init) ?? ""
    }

    func build(index: Int) throws -> PeerConfiguration {
        guard let key = WireGuardKey(base64: publicKey) else { throw TunnelDraftError.peerPublicKey(index) }
        var peer = PeerConfiguration(publicKey: key)
        peer.id = id

        let psk = preSharedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !psk.isEmpty {
            guard let pskKey = WireGuardKey(base64: psk) else { throw TunnelDraftError.peerPreSharedKey(index) }
            peer.preSharedKey = pskKey
        }

        peer.allowedIPs = try TunnelDraft.splitList(allowedIPs).map { entry in
            guard let range = IPAddressRange(parsing: entry) else { throw TunnelDraftError.peerAllowedIP(index, entry) }
            return range
        }

        let endpointText = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !endpointText.isEmpty {
            guard let parsed = Endpoint(parsing: endpointText) else { throw TunnelDraftError.peerEndpoint(index) }
            peer.endpoint = parsed
        }

        let keepAlive = persistentKeepAlive.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keepAlive.isEmpty, keepAlive.lowercased() != "off" {
            guard let seconds = UInt16(keepAlive) else { throw TunnelDraftError.peerKeepAlive(index) }
            peer.persistentKeepAlive = seconds
        }
        return peer
    }
}

/// Editable string fields for a whole tunnel; converted to a configuration on save.
nonisolated struct TunnelDraft: Hashable {
    var name = ""
    var privateKey = WireGuardKey.generatePrivateKey().base64Key
    var addresses = ""
    var listenPort = ""
    var mtu = ""
    var dns = ""
    var connectOnDemand = false
    var peers: [PeerDraft] = []

    init() {}

    init(tunnel: Tunnel) {
        name = tunnel.name
        connectOnDemand = tunnel.connectOnDemand
        apply(tunnel.configuration)
    }

    /// Replaces the interface and peer fields with values from a parsed configuration.
    mutating func apply(_ configuration: TunnelConfiguration) {
        let interface = configuration.interface
        privateKey = interface.privateKey.base64Key
        addresses = interface.addresses.map(\.description).joined(separator: ", ")
        listenPort = interface.listenPort.map(String.init) ?? ""
        mtu = interface.mtu.map(String.init) ?? ""
        dns = (interface.dnsServers + interface.dnsSearchDomains).joined(separator: ", ")
        peers = configuration.peers.map(PeerDraft.init)
    }

    var derivedPublicKey: String? {
        WireGuardKey(base64: privateKey)?.derivedPublicKey()?.base64Key
    }

    func validatedName() throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Tunnel.validateName(trimmed) { throw TunnelDraftError.name(problem) }
        return trimmed
    }

    func buildConfiguration() throws -> TunnelConfiguration {
        guard let key = WireGuardKey(base64: privateKey) else { throw TunnelDraftError.privateKey }
        var interface = InterfaceConfiguration(privateKey: key)

        interface.addresses = try Self.splitList(addresses).map { entry in
            guard let range = IPAddressRange(parsing: entry) else { throw TunnelDraftError.address(entry) }
            return range
        }

        let portText = listenPort.trimmingCharacters(in: .whitespaces)
        if !portText.isEmpty {
            guard let port = UInt16(portText), port > 0 else { throw TunnelDraftError.listenPort }
            interface.listenPort = port
        }

        let mtuText = mtu.trimmingCharacters(in: .whitespaces)
        if !mtuText.isEmpty {
            guard let value = UInt16(mtuText), value >= 576 else { throw TunnelDraftError.mtu }
            interface.mtu = value
        }

        for entry in Self.splitList(dns) {
            if IPAddressRange(parsing: entry) != nil {
                interface.dnsServers.append(entry)
            } else {
                interface.dnsSearchDomains.append(entry)
            }
        }

        let builtPeers = try peers.enumerated().map { index, peer in try peer.build(index: index) }
        return TunnelConfiguration(interface: interface, peers: builtPeers)
    }

    /// Splits comma-, space-, or newline-separated entries.
    static func splitList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
