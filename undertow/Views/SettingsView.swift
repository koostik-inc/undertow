import SwiftUI

/// Backend selection and build information.
struct SettingsView: View {
    @Environment(TunnelManager.self) private var manager
    @AppStorage(SettingsKey.backendPreference) private var backendPreference = TunnelBackendKind.automatic.rawValue

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                Picker("Preferred backend", selection: $backendPreference) {
                    ForEach(TunnelBackendKind.allCases) { kind in
                        Text(kind.displayName).tag(kind.rawValue)
                    }
                }
                LabeledContent("Active backend", value: manager.backend.kind.displayName)
                LabeledContent("Packet tunnel extension",
                               value: NetworkExtensionTunnelBackend.isExtensionBundled ? "Bundled" : "Not bundled")
                LabeledContent("Network Extension entitlement",
                               value: NetworkExtensionTunnelBackend.hasPacketTunnelEntitlement ? "Granted" : "Missing")
                #if os(macOS)
                LabeledContent("System extension", value: SystemExtensionActivationStatus.shared.state.displayName)
                #endif
            } header: {
                Text("Tunnel Engine")
            } footer: {
                Text("The backend preference takes effect the next time Undertow launches. The Network Extension backend requires the bundled packet tunnel system extension “\(NetworkExtensionTunnelBackend.providerBundleIdentifier)”, which must be approved in System Settings → Privacy & Security after installing a Developer ID–signed build.")
            }

            Section("About") {
                LabeledContent("Version", value: version)
                LabeledContent("Configuration format", value: "wg-quick (.conf)")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(macOS)
        .frame(width: 480)
        #endif
    }
}

#Preview {
    SettingsView()
        .environment(TunnelManager.preview())
}
