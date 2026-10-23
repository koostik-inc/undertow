import Foundation

/// Problems found while reading a wg-quick configuration. Line numbers are 1-based.
nonisolated enum WireGuardConfigParseError: LocalizedError, Equatable {
    case malformedLine(Int)
    case unknownSection(Int, name: String)
    case keyOutsideSection(Int, key: String)
    case unknownKey(Int, key: String)
    case invalidValue(Int, key: String, value: String)
    case duplicateInterface(Int)
    case missingInterface
    case missingPrivateKey
    case missingPeerPublicKey

    var errorDescription: String? {
        switch self {
        case .malformedLine(let line):
            return "Line \(line): expected “Key = Value” or a [Section] header."
        case .unknownSection(let line, let name):
            return "Line \(line): unknown section “[\(name)]”."
        case .keyOutsideSection(let line, let key):
            return "Line \(line): “\(key)” must appear inside a section."
        case .unknownKey(let line, let key):
            return "Line \(line): unknown key “\(key)”."
        case .invalidValue(let line, let key, let value):
            return "Line \(line): “\(value)” is not a valid \(key)."
        case .duplicateInterface(let line):
            return "Line \(line): only one [Interface] section is allowed."
        case .missingInterface:
            return "The configuration has no [Interface] section."
        case .missingPrivateKey:
            return "The [Interface] section needs a PrivateKey."
        case .missingPeerPublicKey:
            return "Every [Peer] section needs a PublicKey."
        }
    }
}

/// Reads and writes the INI-style `.conf` format used by wg-quick and the WireGuard apps.
nonisolated enum WireGuardConfigFile {
    private enum Section {
        case none
        case interface
        case peer
    }

    /// Fields collected for the interface before the non-optional private key is known.
    private struct InterfaceDraft {
        var privateKey: WireGuardKey?
        var addresses: [IPAddressRange] = []
        var listenPort: UInt16?
        var mtu: UInt16?
        var dnsServers: [String] = []
        var dnsSearchDomains: [String] = []
    }

    /// Fields collected for a peer before the non-optional public key is known.
    private struct PeerDraft {
        var publicKey: WireGuardKey?
        var preSharedKey: WireGuardKey?
        var allowedIPs: [IPAddressRange] = []
        var endpoint: Endpoint?
        var persistentKeepAlive: UInt16?
    }

    /// wg-quick keys that only make sense on Linux. They are accepted and dropped so real files import cleanly.
    private static let ignoredInterfaceKeys: Set<String> = [
        "table", "preup", "postup", "predown", "postdown", "saveconfig", "fwmark",
    ]

    static func parse(_ text: String) throws -> TunnelConfiguration {
        var interface: InterfaceDraft?
        var peers: [PeerDraft] = []
        var currentPeer: PeerDraft?
        var section = Section.none

        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            var line = rawLine
            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw WireGuardConfigParseError.malformedLine(lineNumber) }
                if let peer = currentPeer {
                    peers.append(peer)
                    currentPeer = nil
                }
                let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                switch name.lowercased() {
                case "interface":
                    guard interface == nil else { throw WireGuardConfigParseError.duplicateInterface(lineNumber) }
                    interface = InterfaceDraft()
                    section = .interface
                case "peer":
                    currentPeer = PeerDraft()
                    section = .peer
                default:
                    throw WireGuardConfigParseError.unknownSection(lineNumber, name: name)
                }
                continue
            }

            guard let equals = line.firstIndex(of: "=") else {
                throw WireGuardConfigParseError.malformedLine(lineNumber)
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let listValues = value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            func invalid() -> WireGuardConfigParseError {
                .invalidValue(lineNumber, key: key, value: value)
            }

            switch section {
            case .none:
                throw WireGuardConfigParseError.keyOutsideSection(lineNumber, key: key)

            case .interface:
                switch key.lowercased() {
                case "privatekey":
                    guard let parsed = WireGuardKey(base64: value) else { throw invalid() }
                    interface?.privateKey = parsed
                case "address":
                    for item in listValues {
                        guard let range = IPAddressRange(parsing: item) else {
                            throw WireGuardConfigParseError.invalidValue(lineNumber, key: key, value: item)
                        }
                        interface?.addresses.append(range)
                    }
                case "listenport":
                    guard let port = UInt16(value) else { throw invalid() }
                    interface?.listenPort = port
                case "mtu":
                    guard let mtu = UInt16(value) else { throw invalid() }
                    interface?.mtu = mtu
                case "dns":
                    for item in listValues {
                        if IPAddressRange(parsing: item) != nil {
                            interface?.dnsServers.append(item)
                        } else {
                            interface?.dnsSearchDomains.append(item)
                        }
                    }
                default:
                    guard ignoredInterfaceKeys.contains(key.lowercased()) else {
                        throw WireGuardConfigParseError.unknownKey(lineNumber, key: key)
                    }
                }

            case .peer:
                switch key.lowercased() {
                case "publickey":
                    guard let parsed = WireGuardKey(base64: value) else { throw invalid() }
                    currentPeer?.publicKey = parsed
                case "presharedkey":
                    guard let parsed = WireGuardKey(base64: value) else { throw invalid() }
                    currentPeer?.preSharedKey = parsed
                case "allowedips":
                    for item in listValues {
                        guard let range = IPAddressRange(parsing: item) else {
                            throw WireGuardConfigParseError.invalidValue(lineNumber, key: key, value: item)
                        }
                        currentPeer?.allowedIPs.append(range)
                    }
                case "endpoint":
                    guard let endpoint = Endpoint(parsing: value) else { throw invalid() }
                    currentPeer?.endpoint = endpoint
                case "persistentkeepalive":
                    if value.lowercased() == "off" {
                        currentPeer?.persistentKeepAlive = nil
                    } else {
                        guard let seconds = UInt16(value) else { throw invalid() }
                        currentPeer?.persistentKeepAlive = seconds == 0 ? nil : seconds
                    }
                default:
                    throw WireGuardConfigParseError.unknownKey(lineNumber, key: key)
                }
            }
        }

        if let peer = currentPeer {
            peers.append(peer)
        }

        guard let interfaceDraft = interface else { throw WireGuardConfigParseError.missingInterface }
        guard let privateKey = interfaceDraft.privateKey else { throw WireGuardConfigParseError.missingPrivateKey }

        var builtInterface = InterfaceConfiguration(privateKey: privateKey)
        builtInterface.addresses = interfaceDraft.addresses
        builtInterface.listenPort = interfaceDraft.listenPort
        builtInterface.mtu = interfaceDraft.mtu
        builtInterface.dnsServers = interfaceDraft.dnsServers
        builtInterface.dnsSearchDomains = interfaceDraft.dnsSearchDomains

        let builtPeers = try peers.map { draft -> PeerConfiguration in
            guard let publicKey = draft.publicKey else { throw WireGuardConfigParseError.missingPeerPublicKey }
            var peer = PeerConfiguration(publicKey: publicKey)
            peer.preSharedKey = draft.preSharedKey
            peer.allowedIPs = draft.allowedIPs
            peer.endpoint = draft.endpoint
            peer.persistentKeepAlive = draft.persistentKeepAlive
            return peer
        }

        return TunnelConfiguration(interface: builtInterface, peers: builtPeers)
    }

    static func serialize(_ configuration: TunnelConfiguration) -> String {
        var lines: [String] = ["[Interface]"]
        let interface = configuration.interface
        lines.append("PrivateKey = \(interface.privateKey.base64Key)")
        if !interface.addresses.isEmpty {
            lines.append("Address = " + interface.addresses.map(\.description).joined(separator: ", "))
        }
        let dns = interface.dnsServers + interface.dnsSearchDomains
        if !dns.isEmpty {
            lines.append("DNS = " + dns.joined(separator: ", "))
        }
        if let port = interface.listenPort {
            lines.append("ListenPort = \(port)")
        }
        if let mtu = interface.mtu {
            lines.append("MTU = \(mtu)")
        }

        for peer in configuration.peers {
            lines.append("")
            lines.append("[Peer]")
            lines.append("PublicKey = \(peer.publicKey.base64Key)")
            if let key = peer.preSharedKey {
                lines.append("PresharedKey = \(key.base64Key)")
            }
            if !peer.allowedIPs.isEmpty {
                lines.append("AllowedIPs = " + peer.allowedIPs.map(\.description).joined(separator: ", "))
            }
            if let endpoint = peer.endpoint {
                lines.append("Endpoint = \(endpoint.description)")
            }
            if let keepAlive = peer.persistentKeepAlive {
                lines.append("PersistentKeepalive = \(keepAlive)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
