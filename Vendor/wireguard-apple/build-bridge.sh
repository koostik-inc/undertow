#!/bin/sh
# Builds libwg-go.a for the WireGuardGoBridge* external-build targets.
#
# Xcode launches external build tools with a minimal PATH, and macOS's GNU make 3.81
# evaluates `$(shell go env GOROOT)` with the environment make was started in, so Go must
# be on PATH *before* make runs. Add the usual Go install locations, then hand off to make
# with whatever action Xcode requested (build or clean). Build settings such as ARCHS,
# PLATFORM_NAME, SDKROOT, CONFIGURATION_BUILD_DIR, and CONFIGURATION_TEMP_DIR arrive via
# the environment because the target has "Pass build settings in environment" enabled.
set -eu

export PATH="/usr/local/go/bin:/usr/local/bin:/opt/homebrew/bin:$HOME/go/bin:$PATH"

if ! command -v go >/dev/null 2>&1; then
    echo "error: Go toolchain not found. Install Go (https://go.dev/dl) or add it to PATH in Vendor/wireguard-apple/build-bridge.sh" >&2
    exit 1
fi

cd "$(dirname "$0")/Sources/WireGuardKitGo"
exec /usr/bin/make "$@"
