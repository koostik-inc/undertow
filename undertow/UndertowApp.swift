import SwiftUI

/// User defaults keys shared between the app and Settings.
nonisolated enum SettingsKey {
    static let backendPreference = "backendPreference"
}

@main
struct UndertowApp: App {
    @State private var manager = TunnelManager.makeDefault()

    var body: some Scene {
        mainWindow
        #if os(macOS)
        menuBarExtra
        Settings {
            SettingsView()
                .environment(manager)
        }
        #endif
    }

    private var mainWindow: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(manager)
                .task { await manager.start() }
        }
    }

    #if os(macOS)
    private var menuBarExtra: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(manager)
                .task { await manager.start() }
        } label: {
            Label("Undertow", systemImage: manager.connectedTunnelCount > 0 ? "lock.shield.fill" : "lock.shield")
        }
        .menuBarExtraStyle(.window)
    }
    #endif
}

extension TunnelManager {
    /// Builds the production manager using the backend chosen in Settings.
    static func makeDefault() -> TunnelManager {
        let raw = UserDefaults.standard.string(forKey: SettingsKey.backendPreference) ?? ""
        let preference = TunnelBackendKind(rawValue: raw) ?? .automatic
        return TunnelManager(backend: makeBackend(for: preference), persistence: .standard())
    }
}
