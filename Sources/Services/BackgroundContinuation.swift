import UIKit

/// Reference-counted wrapper around UIApplication.beginBackgroundTask:
/// an in-flight pipeline gets the system's grace period (~30s+) when the
/// app backgrounds, so short transcriptions finish instead of stalling
/// until the next launch.
@MainActor
final class BackgroundContinuation {
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var activeCount = 0

    func begin() {
        activeCount += 1
        guard taskID == .invalid else { return }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "processing") {
            // Expiration is delivered on the main thread.
            MainActor.assumeIsolated { [weak self] in
                self?.expire()
            }
        }
    }

    func end() {
        activeCount = max(0, activeCount - 1)
        if activeCount == 0 { finish() }
    }

    private func expire() {
        activeCount = 0
        finish()
    }

    private func finish() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }
}
