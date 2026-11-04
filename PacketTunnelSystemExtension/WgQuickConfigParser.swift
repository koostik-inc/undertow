import Foundation
import WireGuardKit

/// Problems found while turning wg-quick text into a WireGuardKit configuration.
enum WgQuickParseError: LocalizedError {
    case missingInterface
    case missingPrivateKey
    case missingPeerPublicKey
    case unexpectedLine(Int)
    case invalidValue(Int, key: String)

    var errorDescription: String? {
        switch self {
        case .missingInterface: return "no [Interface] section"
        case .missingPrivateKey: return "[Interface] has no PrivateKey"
        case .missingPeerPublicKey: return "a [Peer] has no PublicKey"
        case .unexpectedLine(let line): return "unexpected text on line \(line)"
        case .invalidValue(let line, let key): return "invalid \(key) on line \(line)"
        }
    }
}

/// Parses the wg-quick `.conf` format that the host app stores in the provider configuration.
///
/// WireGuardKit ships only the model types; upstream keeps its wg-quick parser in the app
/// layer, so the extension carries this compact equivalent. Keys are case-insensitive and
/// wg-quick hooks (PreUp, PostUp, Table, …) are ignored because a Network Extension cannot run them.
enum WgQuickConfigParser {
    static func parse(_ text: String, name: String?) throws -> TunnelConfiguration {
        enum Section { case none, interface, peer }

        var section = Section.none
        var sawInterface = false

        var privateKey: PrivateKey?
        var addresses: [IPAddressRange] = []
        var listenPort: UInt16?
        var mtu: UInt16?
        var dnsServers: [DNSServer] = []
        var dnsSearch: [String] = []

        var peers: [PeerConfiguration] = []
        var peerPublicKey: PublicKey?
        var peerPreSharedKey: PreSharedKey?
        var peerAllowedIPs: [IPAddressRange] = []
        var peerEndpoint: Endpoint?
        var peerKeepAlive: UInt16?
        var inPeer = false

        func finishPeer() throws {
            guard inPeer else { return }
            guard let key = peerPublicKey else { throw WgQuickParseError.missingPeerPublicKey }
            var peer = PeerConfiguration(publicKey: key)
            peer.preSharedKey = peerPreSharedKey
            peer.allowedIPs = peerAllowedIPs
            peer.endpoint = peerEndpoint
            peer.persistentKeepAlive = peerKeepAlive
            peers.append(peer)
            peerPublicKey = nil
            peerPreSharedKey = nil
            peerAllowedIPs = []
            peerEndpoint = nil
            peerKeepAlive = nil
            inPeer = false
        }

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = index + 1
            var line = rawLine
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw WgQuickParseError.unexpectedLine(lineNumber) }
                switch line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased() {
                case "interface":
                    try finishPeer()
                    sawInterface = true
                    section = .interface
                case "peer":
                    try finishPeer()
                    inPeer = true
                    section = .peer
                default:
                    throw WgQuickParseError.unexpectedLine(lineNumber)
                }
                continue
            }

            guard let equals = line.firstIndex(of: "=") else { throw WgQuickParseError.unexpectedLine(lineNumber) }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let list = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            func invalid() -> WgQuickParseError { .invalidValue(lineNumber, key: key) }

            switch (section, key.lowercased()) {
            case (.interface, "privatekey"):
                guard let parsed = PrivateKey(base64Key: value) else { throw invalid() }
                privateKey = parsed
            case (.interface, "address"):
                addresses += try list.map { entry in
                    guard let range = IPAddressRange(from: entry) else { throw invalid() }
                    return range
                }
            case (.interface, "listenport"):
                guard let port = UInt16(value) else { throw invalid() }
                listenPort = port
            case (.interface, "mtu"):
                guard let parsed = UInt16(value) else { throw invalid() }
                mtu = parsed
            case (.interface, "dns"):
                for entry in list {
                    if let server = DNSServer(from: entry) {
                        dnsServers.append(server)
                    } else {
                        dnsSearch.append(entry)
                    }
                }
            case (.interface, "table"), (.interface, "preup"), (.interface, "postup"),
                 (.interface, "predown"), (.interface, "postdown"), (.interface, "saveconfig"), (.interface, "fwmark"):
                continue

            case (.peer, "publickey"):
                guard let parsed = PublicKey(base64Key: value) else { throw invalid() }
                peerPublicKey = parsed
            case (.peer, "presharedkey"):
                guard let parsed = PreSharedKey(base64Key: value) else { throw invalid() }
                peerPreSharedKey = parsed
            case (.peer, "allowedips"):
                peerAllowedIPs += try list.map { entry in
                    guard let range = IPAddressRange(from: entry) else { throw invalid() }
                    return range
                }
            case (.peer, "endpoint"):
                guard let parsed = Endpoint(from: value) else { throw invalid() }
                peerEndpoint = parsed
            case (.peer, "persistentkeepalive"):
                if value.lowercased() == "off" {
                    peerKeepAlive = nil
                } else {
                    guard let seconds = UInt16(value) else { throw invalid() }
                    peerKeepAlive = seconds
                }

            default:
                throw WgQuickParseError.unexpectedLine(lineNumber)
            }
        }

        try finishPeer()
        guard sawInterface else { throw WgQuickParseError.missingInterface }
        guard let privateKey else { throw WgQuickParseError.missingPrivateKey }

        var interface = InterfaceConfiguration(privateKey: privateKey)
        interface.addresses = addresses
        interface.listenPort = listenPort
        interface.mtu = mtu
        interface.dns = dnsServers
        interface.dnsSearch = dnsSearch

        return TunnelConfiguration(name: name, interface: interface, peers: peers)
    }
}
