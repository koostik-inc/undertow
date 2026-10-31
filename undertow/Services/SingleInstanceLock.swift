import Foundation
import os

/// An exclusive, process-lifetime advisory lock on a file, used to guarantee that only one
/// copy of the app runs at a time.
///
/// `flock(2)` locks belong to the open file description, so the kernel releases the lock the
/// moment the owning process exits for any reason (quit, crash, Xcode's stop button). A second
/// process that fails to acquire it knows another instance is alive; there is no stale-lock
/// state to clean up and no window in which two launches can both believe they are first.
nonisolated final class SingleInstanceLock {
    private static let logger = Logger(subsystem: "io.craterlabs.undertow", category: "SingleInstanceLock")

    let fileURL: URL
    private var descriptor: Int32 = -1

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    deinit {
        release()
    }

    /// The lock file inside the app's container, shared by every copy with this bundle identifier.
    static func standard() -> SingleInstanceLock {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil,
                                                 create: true))
            ?? FileManager.default.temporaryDirectory
        let directory = base.appending(path: "Undertow", directoryHint: .isDirectory)
        return SingleInstanceLock(fileURL: directory.appending(path: ".instance.lock"))
    }

    var isHeld: Bool { descriptor >= 0 }

    /// Takes the lock without blocking. Returns true when this process now holds it.
    ///
    /// If the lock file cannot be created at all, the lock is treated as acquired so a
    /// filesystem problem never prevents the app from launching.
    @discardableResult
    func acquire() -> Bool {
        if isHeld { return true }

        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let path = fileURL.path(percentEncoded: false)
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            Self.logger.error("Could not open instance lock at \(path, privacy: .public): errno \(errno)")
            return true
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd
        return true
    }

    /// Gives the lock up early. Normally the kernel does this at process exit.
    func release() {
        guard isHeld else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
