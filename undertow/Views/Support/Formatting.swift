import SwiftUI
import UniformTypeIdentifiers

/// Human-readable byte counts and rates, consistent across the app.
nonisolated enum ByteFormatting {
    static func bytes(_ value: UInt64) -> String {
        Int64(clamping: value).formatted(.byteCount(style: .binary, spellsOutZero: false))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let clamped = bytesPerSecond.isFinite ? max(0, bytesPerSecond) : 0
        return bytes(UInt64(clamped)) + "/s"
    }
}

/// Time windows offered by throughput charts.
nonisolated enum ChartWindow: String, CaseIterable, Identifiable, Sendable {
    case oneMinute
    case fiveMinutes

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        }
    }

    var label: String {
        switch self {
        case .oneMinute: return "1 min"
        case .fiveMinutes: return "5 min"
        }
    }
}

extension TunnelStatus {
    /// Status colors are reserved for state and always paired with an icon or label.
    var color: Color {
        switch self {
        case .connected: return .green
        case .connecting, .reasserting, .disconnecting: return .orange
        case .disconnected: return .secondary
        case .invalid: return .red
        }
    }
}

/// Fixed series colors shared by every chart and the network map.
nonisolated enum TrafficColor {
    static let download = Color.blue
    static let upload = Color.orange
}

extension Tunnel {
    private static let accentPalette: [Color] = [.indigo, .teal, .pink, .mint, .purple, .cyan, .brown]

    /// A stable per-tunnel accent derived from the identifier, not the list position.
    var accentColor: Color {
        Self.accentPalette[Int(id.uuid.0) % Self.accentPalette.count]
    }
}

/// Clipboard access that works on every supported platform.
@MainActor
enum Pasteboard {
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    static func readString() -> String? {
        #if os(macOS)
        return NSPasteboard.general.string(forType: .string)
        #else
        return UIPasteboard.general.string
        #endif
    }
}

extension UTType {
    /// WireGuard `.conf` files are plain text with a conventional extension.
    nonisolated static let wireGuardConfiguration = UTType(filenameExtension: "conf", conformingTo: .plainText) ?? .plainText
}

/// A plain-text document used to export tunnels via the system save panel.
nonisolated struct WireGuardConfigDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.wireGuardConfiguration, .plainText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
