import SwiftUI
import UniformTypeIdentifiers

/// Sidebar destinations.
enum SidebarItem: Hashable {
    case overview
    case tunnel(UUID)
}

/// The main window: tunnel list on the left, overview or tunnel detail on the right.
struct ContentView: View {
    @Environment(TunnelManager.self) private var manager

    @State private var selection: SidebarItem? = .overview
    @State private var editorMode: TunnelEditorMode?
    @State private var isImporting = false
    @State private var importError: PresentableError?
    @State private var tunnelPendingDelete: Tunnel?
    #if !os(macOS)
    @State private var isShowingSettings = false
    #endif

    /// Import problems and backend errors share one alert.
    private var activeError: PresentableError? {
        importError ?? manager.presentedError
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .sheet(item: $editorMode) { mode in
            TunnelEditorView(mode: mode) { tunnel in
                selection = .tunnel(tunnel.id)
            }
        }
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: [.wireGuardConfiguration, .plainText, .data],
                      allowsMultipleSelection: true) { result in
            Task { await importFiles(result) }
        }
        .confirmationDialog("Delete “\(tunnelPendingDelete?.name ?? "")”?",
                            isPresented: Binding(get: { tunnelPendingDelete != nil },
                                                 set: { if !$0 { tunnelPendingDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: tunnelPendingDelete) { tunnel in
            Button("Delete Tunnel", role: .destructive) {
                Task {
                    await manager.delete(tunnel)
                    if selection == .tunnel(tunnel.id) { selection = .overview }
                }
            }
        } message: { _ in
            Text("This disconnects the tunnel and removes its configuration and keys from this device.")
        }
        .alert(activeError?.title ?? "Error",
               isPresented: Binding(get: { activeError != nil },
                                    set: { if !$0 { importError = nil; manager.presentedError = nil } }),
               presenting: activeError) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
        #if !os(macOS)
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingSettings = false }
                        }
                    }
            }
        }
        #endif
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("Overview", systemImage: "map")
                    .tag(SidebarItem.overview)
            }
            Section("Tunnels") {
                ForEach(manager.tunnels) { tunnel in
                    TunnelRowView(tunnel: tunnel)
                        .tag(SidebarItem.tunnel(tunnel.id))
                        .contextMenu { contextMenu(for: tunnel) }
                }
                .onMove { source, destination in
                    manager.move(fromOffsets: source, toOffset: destination)
                }
                if manager.tunnels.isEmpty {
                    Text("No tunnels yet")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Undertow")
        .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                addMenu
            }
            #if !os(macOS)
            ToolbarItem(placement: .secondaryAction) {
                Button("Settings", systemImage: "gear") { isShowingSettings = true }
            }
            #endif
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await importURLs(urls) }
            return true
        }
        .safeAreaInset(edge: .bottom) {
            backendFooter
        }
    }

    private var addMenu: some View {
        Menu {
            Button("New Tunnel…", systemImage: "plus") { editorMode = .create(initialText: nil) }
            Button("Import from File…", systemImage: "doc.badge.plus") { isImporting = true }
            Button("Import from Clipboard", systemImage: "doc.on.clipboard") { importFromClipboard() }
        } label: {
            Label("Add Tunnel", systemImage: "plus")
        } primaryAction: {
            editorMode = .create(initialText: nil)
        }
        .help("Add a tunnel")
    }

    @ViewBuilder
    private func contextMenu(for tunnel: Tunnel) -> some View {
        let status = manager.status(for: tunnel.id)
        Button(status.isActive ? "Disconnect" : "Connect",
               systemImage: status.isActive ? "stop.circle" : "play.circle") {
            Task { await manager.toggle(tunnel) }
        }
        .disabled(manager.isBusy(tunnel.id) || status == .invalid)
        Divider()
        Button("Edit…", systemImage: "pencil") { editorMode = .edit(tunnel) }
        Button("Duplicate", systemImage: "plus.square.on.square") {
            Task { await manager.duplicate(tunnel) }
        }
        Button("Copy Configuration", systemImage: "doc.on.doc") {
            Pasteboard.copy(manager.configurationText(for: tunnel))
        }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { tunnelPendingDelete = tunnel }
    }

    private var backendFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: manager.backend.kind == .simulated ? "testtube.2" : "shield.lefthalf.filled")
            Text(manager.backend.kind == .simulated ? "Simulated backend" : "System VPN backend")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .help(manager.backend.kind == .simulated
              ? "No packet tunnel extension is bundled, so traffic is simulated. See Settings."
              : "Tunnels run through the system Network Extension.")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .tunnel(let id):
            TunnelDetailView(tunnelID: id) {
                selection = .overview
            }
        case .overview, .none:
            OverviewView(onSelectTunnel: { selection = .tunnel($0) },
                         onAddTunnel: { editorMode = .create(initialText: nil) })
        }
    }

    // MARK: - Importing

    private func importFromClipboard() {
        guard let text = Pasteboard.readString(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            importError = PresentableError(title: "Clipboard Is Empty",
                                           message: "Copy a WireGuard configuration first, then try again.")
            return
        }
        editorMode = .create(initialText: text)
    }

    private func importFiles(_ result: Result<[URL], Error>) async {
        switch result {
        case .failure(let error):
            importError = PresentableError(title: "Import Failed", message: error.localizedDescription)
        case .success(let urls):
            await importURLs(urls)
        }
    }

    private func importURLs(_ urls: [URL]) async {
        var lastImported: Tunnel?
        var failures: [String] = []

        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                lastImported = try await manager.importConfiguration(
                    text: text,
                    suggestedName: url.deletingPathExtension().lastPathComponent
                )
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if let lastImported {
            selection = .tunnel(lastImported.id)
        }
        if !failures.isEmpty {
            importError = PresentableError(title: failures.count == 1 ? "Import Failed" : "Some Imports Failed",
                                           message: failures.joined(separator: "\n"))
        }
    }
}

#Preview {
    ContentView()
        .environment(TunnelManager.preview())
        .frame(width: 1100, height: 760)
}
