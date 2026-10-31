import SwiftUI

/// Whether the editor creates a new tunnel (optionally seeded with pasted text) or edits one.
enum TunnelEditorMode: Identifiable {
    case create(initialText: String?)
    case edit(Tunnel)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let tunnel): return tunnel.id.uuidString
        }
    }
}

/// Create or edit a tunnel either field-by-field or as raw wg-quick text.
struct TunnelEditorView: View {
    @Environment(TunnelManager.self) private var manager
    @Environment(\.dismiss) private var dismiss

    let mode: TunnelEditorMode
    var onSaved: (Tunnel) -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case form = "Fields"
        case text = "Text"
        var id: String { rawValue }
    }

    @State private var draft: TunnelDraft
    @State private var tab: Tab
    @State private var rawText: String
    @State private var isSaving = false
    @State private var isPrivateKeyVisible = false

    init(mode: TunnelEditorMode, onSaved: @escaping (Tunnel) -> Void = { _ in }) {
        self.mode = mode
        self.onSaved = onSaved
        switch mode {
        case .create(let initialText):
            draft = TunnelDraft()
            rawText = initialText ?? ""
            tab = initialText == nil ? .form : .text
        case .edit(let tunnel):
            draft = TunnelDraft(tunnel: tunnel)
            rawText = WireGuardConfigFile.serialize(tunnel.configuration)
            tab = .form
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// Switching tabs converts between fields and text, surfacing errors instead of losing data.
    private var tabSelection: Binding<Tab> {
        Binding(get: { tab }, set: { switchTab(to: $0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("e.g. home or office"))
                        .autocorrectionDisabled()
                    Toggle("Connect on demand", isOn: $draft.connectOnDemand)
                } footer: {
                    Text("Names follow interface rules: up to 15 letters, numbers, or _ = + . -")
                }

                Section {
                    Picker("Editor", selection: tabSelection) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                switch tab {
                case .form:
                    interfaceSection
                    peerSections
                case .text:
                    Section {
                        TextEditor(text: $rawText)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .frame(minHeight: 280)
                    } footer: {
                        Text("Paste a wg-quick configuration. PreUp/PostUp style hooks are ignored.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit Tunnel" : "New Tunnel")
            .toolbar {
                ToolbarItem {
                    Button("Generate Keys") {
                        draft.privateKey = WireGuardKey.generatePrivateKey().base64Key
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") { save() }
                        .disabled(isSaving)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 700, minHeight: 620, idealHeight: 760)
        #endif
    }

    // MARK: - Sections

    /// DNS servers in the draft that no peer routes, computed from the current fields.
    private var unreachableDNSServers: [String] {
        (try? draft.buildConfiguration())?.unreachableDNSServers ?? []
    }

    private var interfaceSection: some View {
        Section {
            interfaceFields
        } header: {
            Text("Interface")
        } footer: {
            if !unreachableDNSServers.isEmpty {
                Label("\(unreachableDNSServers.joined(separator: ", ")) is not covered by any peer's Allowed IPs, so DNS will stop working while this tunnel is connected.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var interfaceFields: some View {
        Group {
            LabeledContent("Private key") {
                HStack {
                    Group {
                        if isPrivateKeyVisible {
                            TextField("", text: $draft.privateKey)
                        } else {
                            SecureField("", text: $draft.privateKey)
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(minWidth: 380, maxWidth: .infinity)

                    Button(isPrivateKeyVisible ? "Hide Private Key" : "Show Private Key",
                           systemImage: isPrivateKeyVisible ? "eye.slash" : "eye") {
                        isPrivateKeyVisible.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help(isPrivateKeyVisible ? "Hide Private Key" : "Show Private Key")
                    .frame(width: 28, alignment: .center)
                }
            }
            LabeledContent("Public key") {
                HStack(spacing: 6) {
                    Text(draft.derivedPublicKey ?? "Invalid private key")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    if let publicKey = draft.derivedPublicKey {
                        CopyButton(text: publicKey)
                            .frame(width: 28, alignment: .center)
                    }
                }
                .foregroundStyle(.primary)
            }
            LabeledContent("Addresses") {
                TextField("", text: $draft.addresses, prompt: Text("10.0.0.2/32, fd00::2/128"))
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
            }
            TextField("DNS servers", text: $draft.dns, prompt: Text("1.1.1.1, example.internal"))
                .autocorrectionDisabled()
            TextField("Listen port", text: $draft.listenPort, prompt: Text("Automatic"))
            TextField("MTU", text: $draft.mtu, prompt: Text("Automatic"))
        }
    }

    private var peerSections: some View {
        Group {
            ForEach($draft.peers) { $peer in
                let index = draft.peers.firstIndex { $0.id == peer.id } ?? 0
                Section {
                    LabeledContent("Public key") {
                        TextField("", text: $peer.publicKey)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Pre-shared key") {
                        HStack {
                            TextField("", text: $peer.preSharedKey, prompt: Text("Optional"))
                                .font(.system(.body, design: .monospaced))
                                .autocorrectionDisabled()
                            Button("Generate") {
                                peer.preSharedKey = WireGuardKey.generatePresharedKey().base64Key
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                    }
                    TextField("Endpoint", text: $peer.endpoint, prompt: Text("vpn.example.com:51820"))
                        .autocorrectionDisabled()
                    LabeledContent("Allowed IPs") {
                        TextField("", text: $peer.allowedIPs, prompt: Text("0.0.0.0/0, ::/0"))
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                    }
                    TextField("Persistent keepalive", text: $peer.persistentKeepAlive, prompt: Text("Off"))
                } header: {
                    HStack {
                        Text("Peer \(index + 1)")
                        Spacer()
                        Button("Remove", systemImage: "minus.circle", role: .destructive) {
                            draft.peers.removeAll { $0.id == peer.id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
            }
            Section {
                Button("Add Peer", systemImage: "plus.circle") {
                    draft.peers.append(PeerDraft())
                }
            }
        }
    }

    // MARK: - Actions

    private func switchTab(to newTab: Tab) {
        guard newTab != tab else { return }
        do {
            switch newTab {
            case .text:
                rawText = WireGuardConfigFile.serialize(try draft.buildConfiguration())
            case .form:
                draft.apply(try WireGuardConfigFile.parse(rawText))
            }
            tab = newTab
        } catch {
            ErrorNotifier.post(title: "Can't Switch Editor", message: error.localizedDescription)
        }
    }

    private func save() {
        do {
            let name = try draft.validatedName()
            let configuration: TunnelConfiguration
            switch tab {
            case .form: configuration = try draft.buildConfiguration()
            case .text: configuration = try WireGuardConfigFile.parse(rawText)
            }

            isSaving = true
            Task {
                let saved: Tunnel
                switch mode {
                case .create:
                    saved = Tunnel(name: name, configuration: configuration, connectOnDemand: draft.connectOnDemand)
                    await manager.add(saved)
                case .edit(let existing):
                    var updated = existing
                    updated.name = name
                    updated.configuration = configuration
                    updated.connectOnDemand = draft.connectOnDemand
                    saved = updated
                    await manager.update(updated)
                }
                isSaving = false
                onSaved(manager.tunnel(withID: saved.id) ?? saved)
                dismiss()
            }
        } catch {
            ErrorNotifier.post(title: "Invalid Configuration", message: error.localizedDescription)
        }
    }
}

#Preview("New") {
    TunnelEditorView(mode: .create(initialText: nil))
        .environment(TunnelManager.preview())
}

#Preview("Edit") {
    let manager = TunnelManager.preview()
    return TunnelEditorView(mode: .edit(manager.tunnels[0]))
        .environment(manager)
}
