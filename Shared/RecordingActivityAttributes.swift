import ActivityKit
import Foundation

/// Live Activity payload for an in-progress recording. Compiled into the app
/// (which starts/updates the activity) and the widget extension (which
/// renders it).
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Adjusted on resume so `Text(timerInterval:)` stays correct across
        /// pauses (startedAt = now - elapsed).
        var startedAt: Date
        var isPaused: Bool
    }
}
