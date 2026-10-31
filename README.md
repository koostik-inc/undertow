# Undertow

A native SwiftUI WireGuard client for macOS, with a menu bar extra, live throughput charts, and a network map of your tunnels and peers.

Undertow stores tunnels in the standard wg-quick `.conf` format. You can import existing configs, edit them in a form-based editor, and export them again. On macOS the app brings tunnels up through the system VPN stack, using a bundled packet tunnel extension built on [WireGuardKit](https://git.zx2c4.com/wireguard-apple) (wireguard-go). The app also has a **simulated backend** that models connections and traffic locally, so the UI can be developed, previewed, and tested without a Network Extension entitlement.

## Features

- Import `.conf` files (several at once) or a config from the clipboard, or create tunnels from scratch with generated keys
- Form editor with per-field validation for interface and peer settings (keys, addresses, allowed IPs, endpoints, MTU, listen port, preshared keys, keepalive)
- Duplicate, reorder, and delete tunnels; export any tunnel back to wg-quick text, or copy keys and config to the clipboard
- Connect and disconnect from the main window or the menu bar (per-tunnel toggles and **Disconnect All**), with an optional connect-on-demand setting
- Per-tunnel and combined throughput charts, sparklines, per-peer handshake and transfer stats
- An overview with a network map of active tunnels and their peers
- A warning in the editor and detail view when a DNS server isn't routed through any peer
- Failures (connect, disconnect, import, saving) and tunnels that get no handshake within 15 seconds are reported as macOS notifications rather than in-app alerts
- A Settings pane for choosing the backend (Automatic, System VPN, Simulated) and checking the extension and entitlement status

## Requirements

| Tool | Version |
|---|---|
| macOS | 26.6.2 or later (deployment target) |
| Xcode | 27.0 or later |
| Go | Any recent toolchain (tested with 1.27), needed to build `libwg-go.a` |
| Apple Developer Program | Paid membership, needed for the **Network Extension (Packet Tunnel)** entitlement |

Without the entitlement, the app still builds and runs, but **Automatic** falls back to the simulated backend.

## Getting started

1. Install Go from <https://go.dev/dl>. The bridge build script looks in `/usr/local/go/bin`, `/usr/local/bin`, `/opt/homebrew/bin`, and `~/go/bin`.
2. Open `undertow.xcodeproj` in Xcode.
3. Under *Signing & Capabilities*, set your own team for the `undertow` and `PacketTunnel` targets. If you change the bundle identifier, the extension's identifier must stay `<app bundle id>.PacketTunnel`, because the app derives the provider identifier from its own.
4. Build and run the `undertow` scheme for **My Mac**.

The first build compiles wireguard-go through the `WireGuardGoBridgemacOS` external-build target, so it takes noticeably longer than later builds.

Undertow runs as a single instance. A second copy brings the running one to the front and quits, so if **Run** in Xcode seems to exit immediately, another copy is probably already running.

From the command line:

```sh
xcodebuild build -project undertow.xcodeproj -scheme undertow -destination 'platform=macOS'
```

### Running the tests

The tests use Swift Testing and live in `undertowTests/`:

```sh
xcodebuild test -project undertow.xcodeproj -scheme undertowTests -destination 'platform=macOS'
```

They cover config parsing and serialization, key and address validation (including DNS reachability through peers), throughput rate calculation, editor draft validation, persistence, the single-instance lock, and the simulated backend lifecycle.

## Security notes

- Tunnel configurations (including private keys) are stored in the data-protection keychain, in a keychain access group shared by the app and the extension. The system VPN preferences hold only a keychain reference and a digest.
- The app's own tunnel list (`tunnels.json` in Application Support) still contains private keys and is written with complete file protection inside the sandbox container.
- A tunnel whose DNS server is not inside any peer's Allowed IPs will take down DNS for the whole machine while connected; the editor and detail view warn about this.

## How it works

```
┌──────────────── undertow.app ────────────────┐      ┌──── PacketTunnel.appex ────┐
│ SwiftUI views                                │      │ PacketTunnelProvider       │
│      │                                       │      │   WgQuickConfigParser      │
│ TunnelManager (@Observable, polls 1 Hz)      │      │   WireGuardAdapter         │
│      │                                       │      │     (WireGuardKit / Go)    │
│ TunnelBackend ─┬─ NetworkExtensionBackend ───┼─────▶│                            │
│                └─ SimulatedTunnelBackend     │ IPC  │                            │
│ TunnelPersistence → tunnels.json             │      │                            │
│ TunnelConfigurationKeychain ─────────────────┼─────▶│ (loads config by reference)│
└──────────────────────────────────────────────┘      └────────────────────────────┘
```

- **`TunnelManager`** is the single source of truth for the tunnel list, live status, counters, and throughput history. It polls the backend once a second, persists tunnels, and delegates connection work to a `TunnelBackend`. At launch it re-synchronizes any tunnel whose system copy is out of date.
- **`NetworkExtensionTunnelBackend`** stores each tunnel as an `NETunnelProviderManager`. The wg-quick text goes in the data-protection keychain (`TunnelConfigurationKeychain`), and the manager holds only a persistent keychain reference in `passwordReference`, plus the tunnel's UUID and a SHA-256 digest of the config in `providerConfiguration`. Statistics come from the extension through `sendProviderMessage`.
- **`PacketTunnelProvider`** loads the wg-quick text from the keychain, parses it into WireGuardKit types, starts the adapter, and answers statistics requests by parsing wireguard-go's UAPI output.
- **`TunnelProviderMessage`** and **`TunnelConfigurationKeychain`** define the app ↔ extension contract. Each is one file that compiles into both targets.
- **`SimulatedTunnelBackend`** produces realistic, bursty traffic with a mean-reverting random walk. Previews, tests, and builds without the extension or entitlement use it.
- **`ErrorNotifier`** delivers operation failures as macOS notifications, and **`SingleInstanceLock`** keeps a second copy of the app from running.

Tunnels, including their private keys, are saved as JSON at `~/Library/Containers/io.craterlabs.undertow/Data/Library/Application Support/Undertow/tunnels.json`. The file is written atomically with complete file protection.

## Project layout

```
undertow/                 App target (SwiftUI)
  Models/                 Tunnel, WireGuard config types, keys, status, throughput history
  Services/               TunnelManager, backends, persistence, keychain, IPC message types,
                          notifications, single-instance lock, preview data
  Views/                  Sidebar, Overview (network map), Detail, Editor, Components, Settings, Menu bar
PacketTunnel/             Packet tunnel provider extension (macOS)
undertowTests/            Swift Testing suites
Vendor/wireguard-apple/   Trimmed, locally patched WireGuardKit (see VENDOR.md)
```

## Limitations

- wg-quick hooks and routing options (`PreUp`, `PostUp`, `PreDown`, `PostDown`, `Table`, `SaveConfig`, `FwMark`) are ignored, because a Network Extension cannot run shell commands or manage routing tables.
- Connect on demand has no paused state: the system reconnects an on-demand tunnel almost immediately. Disconnecting such a tunnel therefore also turns its connect-on-demand setting off, and the toggle shows this.
- The packet tunnel extension and Go bridge build for macOS only. The app target also lists iOS and visionOS as supported platforms, but on those platforms it runs with the simulated backend.
- Changing the backend preference only takes effect after a relaunch.

## Authors

Undertow is developed by Khalid Eidoo, Koostik Inc.

## License

Undertow is licensed under the [Apache License 2.0](LICENSE).

The vendored WireGuardKit is under the MIT license (see `Vendor/wireguard-apple/COPYING`).
