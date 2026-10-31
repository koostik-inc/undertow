import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

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
    @State private var tunnelPendingDelete: Tunnel?
    #if !os(macOS)
    @State private var isShowingSettings = false
    #endif

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        // Wide enough that the tunnel detail header's status and on-demand pills always have
        // room to sit side by side at their natural size, so they can never be squeezed into
        // wrapping their text onto a second line.
        .frame(minWidth: 560)
        // Without an explicit title, the window falls back to showing the app's display name.
        .navigationTitle("")
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

    /// Matches the native sidebar's own unfocused-window selection color, so the highlight looks
    /// the same whether or not Undertow is the active app. `List`'s built-in `selection:` binding
    /// draws its own focused-window highlight (a solid accent fill with inverted white text) that
    /// can't be recolored, so selection is tracked and drawn manually instead.
    #if os(macOS)
    private static let selectedRowBackground = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    #else
    private static let selectedRowBackground = Color(.systemGray5)
    #endif

    private var sidebar: some View {
        List {
            Section {
                sidebarRow(isSelected: selection == .overview) {
                    Label("Overview", systemImage: "map")
                } onSelect: {
                    selection = .overview
                }
            }
            Section("Tunnels") {
                ForEach(manager.tunnels) { tunnel in
                    sidebarRow(isSelected: selection == .tunnel(tunnel.id)) {
                        TunnelRowView(tunnel: tunnel)
                    } onSelect: {
                        selection = .tunnel(tunnel.id)
                    }
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

    /// A tappable sidebar row with a manually drawn selection background, since `List`'s own
    /// `selection:` highlight can't be recolored (see `selectedRowBackground`). Tints the row's
    /// label text and icon blue when selected, matching Mail's sidebar treatment; this only
    /// affects content that doesn't already set its own explicit foreground color, so
    /// `TunnelRowView`'s connect/disconnect button (which colors itself by connection state,
    /// not by sidebar selection) is unaffected.
    private func sidebarRow<Content: View>(isSelected: Bool,
                                            @ViewBuilder content: () -> Content,
                                            onSelect: @escaping () -> Void) -> some View {
        content()
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Self.selectedRowBackground : Color.clear)
                    .padding(.horizontal, 8)
            )
            .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            ErrorNotifier.post(title: "Clipboard Is Empty",
                              message: "Copy a WireGuard configuration first, then try again.")
            return
        }
        editorMode = .create(initialText: text)
    }

    private func importFiles(_ result: Result<[URL], Error>) async {
        switch result {
        case .failure(let error):
            ErrorNotifier.post(title: "Import Failed", message: error.localizedDescription)
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
            ErrorNotifier.post(title: failures.count == 1 ? "Import Failed" : "Some Imports Failed",
                              message: failures.joined(separator: "\n"))
        }
    }
}

#Preview {
    ContentView()
        .environment(TunnelManager.preview())
        .frame(width: 1100, height: 760)
}
