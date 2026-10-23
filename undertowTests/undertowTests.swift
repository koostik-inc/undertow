import Testing
import Foundation
@testable import undertow

@Suite("WireGuard configuration parsing")
struct WireGuardConfigFileTests {
    static let sample = """
    [Interface]
    # A comment line
    PrivateKey = \(WireGuardKey.generatePrivateKey().base64Key)
    Address = 10.0.0.2/32, fd00::2/128
    DNS = 1.1.1.1, example.internal
    ListenPort = 51820
    MTU = 1420

    [Peer]
    PublicKey = \(WireGuardKey.generatePrivateKey().derivedPublicKey()!.base64Key)
    PresharedKey = \(WireGuardKey.generatePresharedKey().base64Key)
    AllowedIPs = 0.0.0.0/0, ::/0
    Endpoint = vpn.example.com:51820
    PersistentKeepalive = 25

    [Peer]
    PublicKey = \(WireGuardKey.generatePrivateKey().derivedPublicKey()!.base64Key)
    AllowedIPs = 192.168.1.0/24
    Endpoint = [2001:db8::1]:443
    """

    @Test("Parses interface and peers")
    func parsesSample() throws {
        let config = try WireGuardConfigFile.parse(Self.sample)
        #expect(config.interface.addresses.map(\.description) == ["10.0.0.2/32", "fd00::2/128"])
        #expect(config.interface.dnsServers == ["1.1.1.1"])
        #expect(config.interface.dnsSearchDomains == ["example.internal"])
        #expect(config.interface.listenPort == 51820)
        #expect(config.interface.mtu == 1420)
        #expect(config.peers.count == 2)
        #expect(config.peers[0].endpoint?.description == "vpn.example.com:51820")
        #expect(config.peers[0].persistentKeepAlive == 25)
        #expect(config.peers[0].preSharedKey != nil)
        #expect(config.peers[0].routesAllTraffic)
        #expect(config.peers[1].endpoint?.host == "2001:db8::1")
        #expect(config.peers[1].endpoint?.port == 443)
        #expect(!config.peers[1].routesAllTraffic)
    }

    @Test("Serialization round-trips")
    func roundTrips() throws {
        let config = try WireGuardConfigFile.parse(Self.sample)
        let text = WireGuardConfigFile.serialize(config)
        let reparsed = try WireGuardConfigFile.parse(text)
        #expect(reparsed.interface == config.interface)
        #expect(reparsed.peers.map(\.publicKey) == config.peers.map(\.publicKey))
        #expect(reparsed.peers.map(\.allowedIPs) == config.peers.map(\.allowedIPs))
        #expect(reparsed.peers.map(\.endpoint) == config.peers.map(\.endpoint))
    }

    @Test("Rejects a missing private key")
    func missingPrivateKey() {
        let text = "[Interface]\nAddress = 10.0.0.1/24\n"
        #expect(throws: WireGuardConfigParseError.missingPrivateKey) {
            try WireGuardConfigFile.parse(text)
        }
    }

    @Test("Rejects a peer without a public key")
    func missingPeerKey() {
        let text = """
        [Interface]
        PrivateKey = \(WireGuardKey.generatePrivateKey().base64Key)
        [Peer]
        AllowedIPs = 0.0.0.0/0
        """
        #expect(throws: WireGuardConfigParseError.missingPeerPublicKey) {
            try WireGuardConfigFile.parse(text)
        }
    }

    @Test("Reports the line of an invalid value")
    func invalidValueLine() {
        let text = """
        [Interface]
        PrivateKey = not-a-key
        """
        #expect(throws: WireGuardConfigParseError.invalidValue(2, key: "PrivateKey", value: "not-a-key")) {
            try WireGuardConfigFile.parse(text)
        }
    }

    @Test("Ignores wg-quick hooks it cannot honor")
    func ignoresHooks() throws {
        let text = """
        [Interface]
        PrivateKey = \(WireGuardKey.generatePrivateKey().base64Key)
        PostUp = iptables -A FORWARD -i %i -j ACCEPT
        Table = off
        """
        let config = try WireGuardConfigFile.parse(text)
        #expect(config.peers.isEmpty)
    }
}

@Suite("Keys and addresses")
struct KeyAndAddressTests {
    @Test("Public key derivation is deterministic")
    func publicKeyDerivation() {
        let privateKey = WireGuardKey.generatePrivateKey()
        let first = privateKey.derivedPublicKey()
        let second = privateKey.derivedPublicKey()
        #expect(first != nil)
        #expect(first == second)
        #expect(first != privateKey)
    }

    @Test("Base64 keys must be exactly 32 bytes")
    func keyLength() {
        #expect(WireGuardKey(base64: Data(repeating: 1, count: 31).base64EncodedString()) == nil)
        #expect(WireGuardKey(base64: Data(repeating: 1, count: 32).base64EncodedString()) != nil)
        #expect(WireGuardKey(base64: "definitely not base64!!") == nil)
    }

    @Test("Address ranges default to host prefixes", arguments: [
        ("10.0.0.1", "10.0.0.1/32"),
        ("10.0.0.0/8", "10.0.0.0/8"),
        ("fd00::1", "fd00::1/128"),
        ("::/0", "::/0"),
    ])
    func addressRanges(input: String, expected: String) {
        #expect(IPAddressRange(parsing: input)?.description == expected)
    }

    @Test("Invalid address ranges are rejected", arguments: ["10.0.0.256/32", "10.0.0.1/33", "fd00::1/129", "hello"])
    func invalidAddresses(input: String) {
        #expect(IPAddressRange(parsing: input) == nil)
    }

    @Test("Address ranges contain hosts by prefix", arguments: [
        ("192.168.10.0/24", "192.168.10.77", true),
        ("192.168.10.0/24", "192.168.3.1", false),
        ("0.0.0.0/0", "8.8.8.8", true),
        ("10.0.0.0/9", "10.127.255.255", true),
        ("10.0.0.0/9", "10.128.0.1", false),
        ("fd00::/8", "fdbd:14b6::1", true),
        ("fd00::/8", "2001:db8::1", false),
        ("192.168.3.1/32", "fdbd::1", false),
    ])
    func rangeContainment(range: String, host: String, expected: Bool) {
        #expect(IPAddressRange(parsing: range)?.contains(host) == expected)
    }

    @Test("Flags DNS servers that no peer routes")
    func unreachableDNS() {
        var interface = InterfaceConfiguration()
        interface.dnsServers = ["192.168.3.1", "192.168.10.1"]
        var peer = PeerConfiguration(publicKey: WireGuardKey.generatePrivateKey().derivedPublicKey()!)
        peer.allowedIPs = [IPAddressRange(parsing: "192.168.10.0/24")!]
        let configuration = TunnelConfiguration(interface: interface, peers: [peer])
        #expect(configuration.unreachableDNSServers == ["192.168.3.1"])

        peer.allowedIPs.append(IPAddressRange(parsing: "192.168.3.1/32")!)
        #expect(TunnelConfiguration(interface: interface, peers: [peer]).unreachableDNSServers.isEmpty)
    }

    @Test("Endpoints parse hostnames, IPv4, and bracketed IPv6")
    func endpoints() {
        #expect(Endpoint(parsing: "vpn.example.com:51820")?.description == "vpn.example.com:51820")
        #expect(Endpoint(parsing: "203.0.113.5:443")?.port == 443)
        #expect(Endpoint(parsing: "[2001:db8::1]:51820")?.description == "[2001:db8::1]:51820")
        #expect(Endpoint(parsing: "no-port") == nil)
        #expect(Endpoint(parsing: "2001:db8::1:51820") == nil)
    }
}

@Suite("Throughput history")
struct ThroughputHistoryTests {
    private func statistics(at seconds: TimeInterval, received: UInt64, sent: UInt64) -> TunnelRuntimeStatistics {
        TunnelRuntimeStatistics(timestamp: Date(timeIntervalSinceReferenceDate: seconds),
                                connectedSince: nil,
                                receivedBytes: received,
                                sentBytes: sent,
                                peers: [])
    }

    @Test("Derives rates from cumulative counters")
    func derivesRates() {
        var history = ThroughputHistory()
        history.record(statistics(at: 0, received: 1_000, sent: 500))
        history.record(statistics(at: 2, received: 5_000, sent: 1_500))
        let latest = try! #require(history.latest)
        #expect(latest.receivedBytesPerSecond == 2_000)
        #expect(latest.sentBytesPerSecond == 500)
    }

    @Test("Treats counter resets as idle rather than negative")
    func counterReset() {
        var history = ThroughputHistory()
        history.record(statistics(at: 0, received: 9_000, sent: 9_000))
        history.record(statistics(at: 1, received: 100, sent: 100))
        #expect(history.latest?.receivedBytesPerSecond == 0)
        #expect(history.latest?.sentBytesPerSecond == 0)
    }

    @Test("Keeps only the most recent samples")
    func capacity() {
        var history = ThroughputHistory(capacity: 3)
        for second in 0..<10 {
            history.recordIdle(at: Date(timeIntervalSinceReferenceDate: TimeInterval(second)))
        }
        #expect(history.samples.count == 3)
        #expect(history.samples.first?.timestamp == Date(timeIntervalSinceReferenceDate: 7))
    }
}

@Suite("Tunnel drafts")
struct TunnelDraftTests {
    @Test("Builds a configuration from fields")
    func buildsConfiguration() throws {
        var draft = TunnelDraft()
        draft.name = "office"
        draft.addresses = "10.1.0.2/32 fd01::2/128"
        draft.dns = "10.1.0.1, corp.example"
        draft.listenPort = "51820"
        var peer = PeerDraft()
        peer.publicKey = WireGuardKey.generatePrivateKey().derivedPublicKey()!.base64Key
        peer.allowedIPs = "10.1.0.0/16"
        peer.endpoint = "vpn.corp.example:51820"
        peer.persistentKeepAlive = "25"
        draft.peers = [peer]

        let configuration = try draft.buildConfiguration()
        #expect(try draft.validatedName() == "office")
        #expect(configuration.interface.addresses.count == 2)
        #expect(configuration.interface.dnsServers == ["10.1.0.1"])
        #expect(configuration.interface.dnsSearchDomains == ["corp.example"])
        #expect(configuration.peers.first?.persistentKeepAlive == 25)
    }

    @Test("Rejects invalid names", arguments: ["", "this-name-is-far-too-long", "bad name!"])
    func rejectsNames(name: String) {
        var draft = TunnelDraft()
        draft.name = name
        #expect(throws: TunnelDraftError.self) { try draft.validatedName() }
    }

    @Test("Reports which peer has a bad key")
    func peerKeyError() {
        var draft = TunnelDraft()
        var good = PeerDraft()
        good.publicKey = WireGuardKey.generatePrivateKey().derivedPublicKey()!.base64Key
        var bad = PeerDraft()
        bad.publicKey = "nope"
        draft.peers = [good, bad]
        #expect(throws: TunnelDraftError.self) { try draft.buildConfiguration() }
    }

    @Test("Sanitizes imported file names")
    func sanitizedNames() {
        #expect(Tunnel.sanitizedName(from: "My Home VPN") == "My-Home-VPN")
        #expect(Tunnel.sanitizedName(from: "a-very-long-configuration-name") == "a-very-long-con")
        #expect(Tunnel.sanitizedName(from: "***") == "wg0")
    }
}

@Suite("Persistence")
struct TunnelPersistenceTests {
    @Test("Round-trips through a directory whose name contains a space")
    func roundTripWithSpaceInPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Undertow Test \(UUID().uuidString)", directoryHint: .isDirectory)
        let store = TunnelPersistence(fileURL: directory.appending(path: "tunnels.json"))
        defer { try? FileManager.default.removeItem(at: directory) }

        let tunnels = Tunnel.sampleTunnels()
        try store.save(tunnels)
        let loaded = try store.load()
        #expect(loaded.map(\.id) == tunnels.map(\.id))
        #expect(loaded.map(\.name) == tunnels.map(\.name))
        #expect(loaded.first?.configuration == tunnels.first?.configuration)
    }

    @Test("Loading a missing file yields an empty list")
    func missingFile() throws {
        let store = TunnelPersistence.ephemeral()
        #expect(try store.load().isEmpty)
    }
}

@Suite("Simulated backend")
@MainActor
struct SimulatedBackendTests {
    @Test("Connects, reports statistics, and disconnects")
    func lifecycle() async throws {
        let backend = SimulatedTunnelBackend()
        backend.transitionDuration = 0.01...0.02
        let tunnel = Tunnel.sampleTunnels()[0]
        try await backend.synchronize(tunnel)

        try await backend.start(tunnel)
        #expect(backend.status(for: tunnel.id) == .connecting)
        try await Task.sleep(for: .milliseconds(150))
        #expect(backend.status(for: tunnel.id) == .connected)

        let first = try #require(await backend.statistics(for: tunnel.id))
        try await Task.sleep(for: .milliseconds(50))
        let second = try #require(await backend.statistics(for: tunnel.id))
        #expect(second.receivedBytes >= first.receivedBytes)
        #expect(second.peers.count == tunnel.configuration.peers.count)
        #expect(second.connectedSince != nil)

        try await backend.stop(tunnel)
        try await Task.sleep(for: .milliseconds(600))
        #expect(backend.status(for: tunnel.id) == .disconnected)
        #expect(await backend.statistics(for: tunnel.id) == nil)
    }
}
