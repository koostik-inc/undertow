#if os(macOS)
import Foundation
import Observation
import SystemExtensions
import os

/// Activation state of the bundled packet tunnel system extension.
nonisolated enum SystemExtensionActivationState: Equatable, Sendable {
    /// No activation request has been submitted yet.
    case notRequested
    /// Submitted; possibly waiting on approval in System Settings → Privacy & Security.
    case pending
    case active
    /// Activation succeeded, but won't take effect until the next restart.
    case needsReboot
    case failed(String)

    var displayName: String {
        switch self {
        case .notRequested: return "Not requested"
        case .pending: return "Waiting for approval"
        case .active: return "Active"
        case .needsReboot: return "Active after restart"
        case .failed: return "Failed"
        }
    }
}

/// Observable holder for the current activation state, read by `SettingsView`.
@MainActor
@Observable
final class SystemExtensionActivationStatus {
    static let shared = SystemExtensionActivationStatus()

    private(set) var state: SystemExtensionActivationState = .notRequested

    fileprivate func update(_ newState: SystemExtensionActivationState) {
        state = newState
    }

    private init() {}
}

/// Requests activation of the packet tunnel system extension through `SystemExtensions.framework`.
///
/// Activation can require the person to approve the extension in System Settings → Privacy &
/// Security, which may take an arbitrary amount of time (or never happen), so this never blocks
/// its caller — it only publishes state through `SystemExtensionActivationStatus.shared`, which
/// `NETunnelProviderManager` configuration (loaded/saved independently) doesn't need to wait on.
@MainActor
final class SystemExtensionActivator: NSObject, OSSystemExtensionRequestDelegate {
    private static let logger = Logger(subsystem: "io.craterlabs.undertow", category: "SystemExtensionActivator")

    func activate(identifier: String) {
        SystemExtensionActivationStatus.shared.update(.pending)
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            switch result {
            case .completed:
                SystemExtensionActivationStatus.shared.update(.active)
            case .willCompleteAfterReboot:
                SystemExtensionActivationStatus.shared.update(.needsReboot)
            @unknown default:
                SystemExtensionActivationStatus.shared.update(.active)
            }
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            Self.logger.error("System extension activation failed: \(error.localizedDescription, privacy: .public)")
            SystemExtensionActivationStatus.shared.update(.failed(error.localizedDescription))
            ErrorNotifier.post(title: "Couldn't Activate the Packet Tunnel Extension",
                               message: error.localizedDescription)
        }
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            SystemExtensionActivationStatus.shared.update(.pending)
        }
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }
}
#endif
