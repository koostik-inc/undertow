import SwiftUI

/// User defaults keys shared between the app and Settings.
nonisolated enum SettingsKey {
    static let backendPreference = "backendPreference"
}

@main
struct UndertowApp: App {
    @State private var manager = TunnelManager.makeDefault()

    /// Held for the whole process lifetime; the kernel releases it when the process ends.
    private static let instanceLock = SingleInstanceLock.standard()

    init() {
        Self.yieldToExistingInstanceIfNeeded()
        // Apple requires the notification delegate to be assigned before launch finishes, so
        // this can't wait for a scene's `.task`. Authorization itself is requested later.
        ErrorNotifier.installDelegate()
    }

    /// Keeps Undertow single-instance. A second copy (for example one launched from Xcode
    /// while another is still running) would show a second menu bar icon and race the first
    /// for the tunnel store. The file lock is the authority, since it cannot race or go stale;
    /// the running-application lookup only serves to bring the existing window forward.
    private static func yieldToExistingInstanceIfNeeded() {
        #if os(macOS)
        // Xcode previews and hosted unit tests run this binary alongside the real app; they
        // are not user-facing instances and must never be turned away.
        let environment = ProcessInfo.processInfo.environment
        if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil {
            return
        }
        guard !instanceLock.acquire() else { return }
        if let bundleID = Bundle.main.bundleIdentifier {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?
                .activate()
        }
        exit(0)
        #endif
    }

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
                .task {
                    ErrorNotifier.requestAuthorizationIfNeeded()
                    await manager.start()
                }
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
