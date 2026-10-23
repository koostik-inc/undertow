# CLAUDE.md

Undertow is a SwiftUI WireGuard client for macOS. It has an app target, a packet tunnel extension built on vendored WireGuardKit (wireguard-go), and Swift Testing unit tests. See README.md for the user-facing overview.

## Build and test

```sh
# Build the app (also builds the Go bridge and the PacketTunnel extension)
xcodebuild build -project undertow.xcodeproj -scheme undertow -destination 'platform=macOS'

# Run the unit tests
xcodebuild test -project undertow.xcodeproj -scheme undertowTests -destination 'platform=macOS'
```

- Only the `undertowTests` scheme is shared (`xcshareddata`). The `undertow` scheme lives in xcuserdata, so a fresh clone may need it recreated in Xcode.
- The Go toolchain must be installed. `Vendor/wireguard-apple/build-bridge.sh` adds the common Go install paths to PATH and runs the WireGuardKitGo Makefile. It is invoked by the `WireGuardGoBridgemacOS` legacy target.
- Running `xcodebuild` inside the Claude Code sandbox fails during package resolution (`permissionDenied`) and can leave a stray `27.0-27A266a/` cache directory in the repo root. Don't commit that directory. Run builds outside the sandbox when needed.

## Architecture

- `TunnelManager` (`undertow/Services/TunnelManager.swift`) is the single `@Observable` source of truth. Views read it through `@Environment(TunnelManager.self)`. It owns the tunnel list, statuses, statistics, and throughput histories, and it polls the backend once a second.
- `TunnelBackend` is the protocol for the connection engine. It has two implementations:
  - `NetworkExtensionTunnelBackend`: one `NETunnelProviderManager` per tunnel, matched to it by the `tunnelID` key in `providerConfiguration`.
  - `SimulatedTunnelBackend`: in-memory, with fake traffic. Used by previews, tests, and builds without the extension or entitlement. It keeps no state across launches, so `isSynchronized` is false at launch and `TunnelManager.start()` re-synchronizes every tunnel into it.
- `TunnelBackendKind.automatic` uses the NE backend only when `isExtensionBundled && hasPacketTunnelEntitlement` is true.
- `Tunnel` is a plain persistable record. Live state is stored in `TunnelManager` dictionaries keyed by `Tunnel.id` and never on the model itself.
- Persistence is `TunnelPersistence`, which writes JSON to Application Support. The file contains private keys, so keep the `.atomic, .completeFileProtection` write options. Tests and previews use `TunnelPersistence.ephemeral()`.

### App ↔ extension contract

- `undertow/Services/TunnelProviderMessage.swift` compiles into **both** the app and the `PacketTunnel` target, through a membership exception in the synchronized folder group in `project.pbxproj`. Keep it dependency-free (Foundation only), and change both sides together.
- The app stores the wg-quick text (from `WireGuardConfigFile.serialize`) in the data-protection keychain via `TunnelConfigurationKeychain` (also compiled into both targets) and puts only a persistent keychain reference in `NETunnelProviderProtocol.passwordReference`, plus `ConfigurationKey.tunnelID` and a SHA-256 `configurationDigest` in `providerConfiguration`. The extension loads the text with `TunnelConfigurationKeychain.load(reference:)` and parses it with `PacketTunnel/WgQuickConfigParser.swift`. Both targets declare the same `keychain-access-groups` entitlement (`$(AppIdentifierPrefix)io.craterlabs.undertow`); never put configuration text in `providerConfiguration`, it is readable in plaintext with `scutil --nc show`.
- `TunnelBackend.isSynchronized(_:)` compares the digest, name, and on-demand flag; `TunnelManager.start()` re-synchronizes any tunnel that is out of date, which is also how storage migrations roll out.
- **There are two wg-quick parsers.** `WireGuardConfigFile` in the app is strict, gives line-numbered errors, and produces the app's own model types. `WgQuickConfigParser` in the extension is lenient and produces WireGuardKit types. If you add support for a config key, update both, plus `serialize`.
- The `PacketTunnel` extension is sandboxed and needs `com.apple.security.network.client` and `com.apple.security.network.server` in addition to the packet-tunnel entitlement; without them wireguard-go cannot open UDP sockets and DNS resolution in the extension fails with "Operation not permitted".
- Diagnose extension failures with a live capture, not `log show` (which returns nothing on this machine): `log stream --info --predicate 'process == "PacketTunnel"'`. The adapter error "WireGuardAdapterError error 0" is `cannotLocateTunnelFileDescriptor`; see the vendored adapter patch in `Vendor/wireguard-apple/VENDOR.md`.
- The provider bundle ID is always `Bundle.main.bundleIdentifier + ".PacketTunnel"` (`io.craterlabs.undertow.PacketTunnel`).

### Type name collisions

The app defines its own `TunnelConfiguration`, `PeerConfiguration`, `InterfaceConfiguration`, `IPAddressRange`, and `Endpoint` (`undertow/Models/WireGuardConfiguration.swift`). WireGuardKit uses the same names. The app target must **not** import WireGuardKit. Only `PacketTunnel/` does.

## Conventions

- Swift settings: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and approachable concurrency. Model, value, and parsing types are explicitly marked `nonisolated` (for example `nonisolated struct Tunnel`). Follow that pattern for new non-UI types so they stay usable from tests and background contexts.
- Error enums conform to `LocalizedError` and use full-sentence, user-facing `errorDescription`s with curly quotes (“ ”). Errors reach the UI through `PresentableError` and `TunnelManager.presentedError`.
- Interface or tunnel names: at most 15 characters, from `[A-Za-z0-9_=+.-]`. Use `Tunnel.validateName` and `Tunnel.sanitizedName(from:)`.
- Platform-specific code is guarded with `#if os(macOS)`. The menu bar extra and Settings scene are macOS-only.
- Doc comments (`///`) on types and on non-obvious members. Use `// MARK: -` to section longer files.
- Tests use Swift Testing (`@Suite`, `@Test`, `#expect`), not XCTest. Generate keys with `WireGuardKey.generatePrivateKey()` instead of hardcoding them.
- Previews seed data with `Tunnel.sampleTunnels()` and `TunnelManager.seedForPreview(_:)` (`undertow/Services/PreviewData.swift`).

## Vendored WireGuardKit

`Vendor/wireguard-apple/` is a trimmed copy of upstream with local patches (listed in `VENDOR.md`). It is referenced as a local Swift package. If you change anything under it, record the change in `VENDOR.md`.
