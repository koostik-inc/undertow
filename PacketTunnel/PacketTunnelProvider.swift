import NetworkExtension
import WireGuardKit
import os

/// Errors raised before the WireGuard adapter is even started.
enum PacketTunnelProviderError: LocalizedError {
    case missingConfiguration
    case keychain(String)
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "The tunnel has no WireGuard configuration reference."
        case .keychain(let reason):
            return "The WireGuard configuration could not be read from the keychain: \(reason)"
        case .invalidConfiguration(let reason):
            return "The WireGuard configuration is invalid: \(reason)"
        }
    }
}

/// Runs a WireGuard tunnel inside the system VPN using WireGuardKit (wireguard-go).
///
/// The host app keeps the wg-quick configuration text in the keychain and passes a persistent
/// reference in `NETunnelProviderProtocol.passwordReference`. It asks for live counters with
/// `TunnelProviderMessage.Request.statistics`, which this provider answers with a
/// JSON-encoded `TunnelProviderMessage.StatisticsResponse`.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "io.craterlabs.undertow.PacketTunnel", category: "Tunnel")
    private let stateLock = NSLock()
    private var _connectedSince: Date?

    private var connectedSince: Date? {
        get { stateLock.withLock { _connectedSince } }
        set { stateLock.withLock { _connectedSince = newValue } }
    }

    private lazy var adapter = WireGuardAdapter(with: self) { [weak self] level, message in
        switch level {
        case .verbose:
            self?.logger.debug("\(message, privacy: .public)")
        case .error:
            self?.logger.error("\(message, privacy: .public)")
        }
    }

    // MARK: - Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let protocolConfiguration = protocolConfiguration as? NETunnelProviderProtocol,
              let reference = protocolConfiguration.passwordReference else {
            logger.error("Start requested without a keychain reference to the configuration")
            completionHandler(PacketTunnelProviderError.missingConfiguration)
            return
        }

        let wgQuickConfig: String
        do {
            wgQuickConfig = try TunnelConfigurationKeychain.load(reference: reference)
        } catch {
            logger.error("Keychain lookup failed: \(error.localizedDescription, privacy: .public)")
            completionHandler(PacketTunnelProviderError.keychain(error.localizedDescription))
            return
        }

        let tunnelConfiguration: TunnelConfiguration
        do {
            tunnelConfiguration = try WgQuickConfigParser.parse(wgQuickConfig, name: protocolConfiguration.providerConfiguration?[TunnelProviderMessage.ConfigurationKey.tunnelID] as? String)
        } catch {
            logger.error("Rejected configuration: \(error.localizedDescription, privacy: .public)")
            completionHandler(PacketTunnelProviderError.invalidConfiguration(error.localizedDescription))
            return
        }

        logger.notice("Starting tunnel with \(tunnelConfiguration.peers.count) peer(s)")
        adapter.start(tunnelConfiguration: tunnelConfiguration) { [weak self] error in
            if let error {
                self?.logger.error("Adapter failed to start: \(Self.describe(error), privacy: .public)")
                completionHandler(error)
            } else {
                self?.connectedSince = Date()
                self?.logger.notice("Tunnel is up")
                completionHandler(nil)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.notice("Stopping tunnel (reason \(reason.rawValue))")
        adapter.stop { [weak self] error in
            if let error {
                self?.logger.error("Adapter failed to stop cleanly: \(error.localizedDescription, privacy: .public)")
            }
            self?.connectedSince = nil
            completionHandler()
        }
    }

    // MARK: - App messages

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let request = try? JSONDecoder().decode(TunnelProviderMessage.Request.self, from: messageData) else {
            logger.error("Ignoring unrecognized app message")
            completionHandler?(nil)
            return
        }

        switch request {
        case .statistics:
            let connectedSince = self.connectedSince
            adapter.getRuntimeConfiguration { settings in
                let response = TunnelProviderMessage.StatisticsResponse(
                    connectedSince: connectedSince,
                    peers: Self.parsePeerStatistics(fromUAPI: settings ?? "")
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                completionHandler?(try? encoder.encode(response))
            }
        }
    }

    /// Human-readable text for adapter errors, which otherwise log as opaque enum indices.
    private static func describe(_ error: WireGuardAdapterError) -> String {
        switch error {
        case .cannotLocateTunnelFileDescriptor:
            return "cannot locate the utun file descriptor"
        case .invalidState:
            return "adapter is in an invalid state for this operation"
        case .dnsResolution(let failures):
            return "DNS resolution failed for " + failures.map { "\($0.address): \($0.errorDescription ?? "unknown error")" }.joined(separator: ", ")
        case .setNetworkSettings(let underlying):
            return "setting network settings failed: \(underlying.localizedDescription)"
        case .startWireGuardBackend(let code):
            return "wireguard-go failed to start (code \(code))"
        }
    }

    // MARK: - UAPI parsing

    /// Parses wireguard-go's `get=1` response: one `key=value` per line, where each
    /// `public_key` line (hex encoded) begins a new peer block.
    static func parsePeerStatistics(fromUAPI text: String) -> [TunnelProviderMessage.PeerStatistics] {
        var peers: [TunnelProviderMessage.PeerStatistics] = []
        var current: TunnelProviderMessage.PeerStatistics?

        func flush() {
            if let current { peers.append(current) }
            current = nil
        }

        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals]
            let value = String(line[line.index(after: equals)...])

            switch key {
            case "public_key":
                flush()
                guard let keyData = Data(hexEncoded: value) else { continue }
                current = TunnelProviderMessage.PeerStatistics(publicKey: keyData.base64EncodedString(),
                                                               endpoint: nil,
                                                               lastHandshake: nil,
                                                               receivedBytes: 0,
                                                               sentBytes: 0)
            case "endpoint":
                current?.endpoint = value
            case "last_handshake_time_sec":
                if let seconds = TimeInterval(value), seconds > 0 {
                    current?.lastHandshake = Date(timeIntervalSince1970: seconds)
                }
            case "rx_bytes":
                current?.receivedBytes = UInt64(value) ?? 0
            case "tx_bytes":
                current?.sentBytes = UInt64(value) ?? 0
            default:
                continue
            }
        }
        flush()
        return peers
    }
}

private extension Data {
    /// Decodes a lowercase or uppercase hex string; returns nil on odd length or bad digits.
    init?(hexEncoded text: String) {
        guard text.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
