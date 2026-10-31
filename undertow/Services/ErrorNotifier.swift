import Foundation
import UserNotifications
import os

/// Delivers error messages as macOS notifications instead of an in-app alert.
///
/// Operation failures (connect, disconnect, install, import, persistence, configuration
/// validation) call `post(title:message:)`. Nothing in the app's windows shows these; the
/// person sees a standard notification banner, and the full message stays in Notification
/// Center if they miss it. Callers should still log the underlying error themselves.
@MainActor
enum ErrorNotifier {
    // `Logger` is a plain Sendable value, so this can be read from the non-isolated,
    // @Sendable completion closures below without hopping back to the main actor.
    private nonisolated static let logger = Logger(subsystem: "io.craterlabs.undertow", category: "ErrorNotifier")
    private static let delegate = ForegroundPresentingDelegate()
    private static var didInstallDelegate = false
    private static var didRequestAuthorization = false

    /// True under Xcode Previews or the hosted unit test runner, which launch this same
    /// binary. Touching the system notification center there would be surprising and an
    /// authorization prompt would mean nothing, so every entry point no-ops in that case.
    private static var isInertEnvironment: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }

    /// Assigns the delegate that lets notifications appear as a banner while Undertow is
    /// frontmost. Apple requires the delegate be set before the app finishes launching, so
    /// call this from `UndertowApp.init()` rather than lazily from `post`.
    static func installDelegate() {
        guard !didInstallDelegate, !isInertEnvironment else { return }
        didInstallDelegate = true
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// Requests permission to show notifications. The system only prompts the person once;
    /// safe to call repeatedly or from more than one scene.
    static func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization, !isInertEnvironment else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                logger.notice("Notification authorization was denied; error messages will only appear in the log.")
            }
        }
    }

    /// Posts a one-shot notification for an error. Delivered immediately; each call gets its
    /// own identifier since every error is a distinct event the person should see once.
    static func post(title: String, message: String) {
        guard !isInertEnvironment else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Couldn't deliver notification \"\(title, privacy: .public)\": \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Lets error notifications appear as a banner even while Undertow is the frontmost app.
/// Without a delegate returning presentation options, foreground notifications are suppressed
/// by default, which would make errors invisible whenever someone is actually using the app.
private final class ForegroundPresentingDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
