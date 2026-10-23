# Vendored WireGuardKit

Trimmed copy of https://git.zx2c4.com/wireguard-apple at commit 2fec12a6e1f6e3460b6ee483aa00ad29cddadab1
(Sources/WireGuardKit, Sources/WireGuardKitC, Sources/WireGuardKitGo, Package.swift, COPYING).

Local changes:
- Package.swift: swift-tools-version raised from 5.3 to 5.5 so the `.iOS(.v15)` platform
  declaration is valid; upstream's manifest fails to load in current SwiftPM.
- Sources/WireGuardKitC/WireGuardKitC.h: added `#include <sys/types.h>` so `u_int32_t`, `u_char`,
  and `u_int16_t` are declared under Xcode 27's strict module import checking.
- build-bridge.sh: wrapper that puts Go on PATH before invoking the Makefile (macOS GNU make 3.81
  evaluates `$(shell go env GOROOT)` with the parent environment).

- Sources/WireGuardKit/WireGuardAdapter.swift: `tunnelFileDescriptor` falls back to
  `packetFlow.value(forKeyPath: "socket.fileDescriptor")` when no kernel-control utun socket is found;
  on macOS 26 the scan comes up empty and the adapter failed with `cannotLocateTunnelFileDescriptor`.

The Go bridge (libwg-go.a) is built by the `WireGuardGoBridgemacOS` external-build target,
which runs this directory's Makefile with Go from /usr/local/go/bin.
