import Foundation

extension Tunnel {
    /// Realistic sample tunnels for previews. Keys are freshly generated each time.
    nonisolated static func sampleTunnels() -> [Tunnel] {
        func peer(host: String, port: UInt16, allowed: [String], keepAlive: UInt16? = 25) -> PeerConfiguration {
            var peer = PeerConfiguration(publicKey: WireGuardKey.generatePrivateKey().derivedPublicKey()!)
            peer.endpoint = Endpoint(host: host, port: port)
            peer.allowedIPs = allowed.compactMap { IPAddressRange(parsing: $0) }
            peer.persistentKeepAlive = keepAlive
            return peer
        }

        var home = InterfaceConfiguration()
        home.addresses = [IPAddressRange(parsing: "10.8.0.2/32")!, IPAddressRange(parsing: "fd42:42:42::2/128")!]
        home.dnsServers = ["10.8.0.1"]

        var office = InterfaceConfiguration()
        office.addresses = [IPAddressRange(parsing: "172.16.4.10/32")!]
        office.dnsServers = ["172.16.0.53"]
        office.dnsSearchDomains = ["corp.example"]
        office.mtu = 1380

        var lab = InterfaceConfiguration()
        lab.addresses = [IPAddressRange(parsing: "192.168.77.5/24")!]
        lab.listenPort = 51820

        return [
            Tunnel(name: "home",
                   configuration: TunnelConfiguration(interface: home, peers: [
                       peer(host: "home.example.net", port: 51820, allowed: ["0.0.0.0/0", "::/0"]),
                   ])),
            Tunnel(name: "office",
                   configuration: TunnelConfiguration(interface: office, peers: [
                       peer(host: "vpn-a.corp.example", port: 51820, allowed: ["172.16.0.0/16"]),
                       peer(host: "vpn-b.corp.example", port: 51821, allowed: ["10.200.0.0/16"]),
                   ]),
                   connectOnDemand: true),
            Tunnel(name: "lab",
                   configuration: TunnelConfiguration(interface: lab, peers: [
                       peer(host: "203.0.113.7", port: 51820, allowed: ["192.168.77.0/24"], keepAlive: nil),
                       peer(host: "198.51.100.21", port: 51820, allowed: ["192.168.78.0/24"], keepAlive: nil),
                       peer(host: "198.51.100.22", port: 51820, allowed: ["192.168.79.0/24"], keepAlive: nil),
                   ])),
        ]
    }
}

extension TunnelManager {
    /// A manager backed by the simulator with sample tunnels, two of them connected.
    static func preview() -> TunnelManager {
        let backend = SimulatedTunnelBackend()
        backend.transitionDuration = 0.1...0.3
        let persistence = TunnelPersistence.ephemeral()
        let samples = Tunnel.sampleTunnels()
        // Save first so `start()` reloads these exact tunnels; seed so previews can index them immediately.
        try? persistence.save(samples)
        let manager = TunnelManager(backend: backend, persistence: persistence)
        manager.seedForPreview(samples)
        Task {
            await manager.start()
            await manager.connect(samples[0])
            await manager.connect(samples[1])
        }
        return manager
    }
}
