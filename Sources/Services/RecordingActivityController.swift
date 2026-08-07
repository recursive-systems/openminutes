import ActivityKit
import Foundation

/// Starts/updates/ends the recording Live Activity. Mandatory while
/// recording via AudioRecordingIntent (the system stops the recording
/// otherwise) and the PRD A3 background-recording indicator.
///
/// Activity instances aren't Sendable, so nothing is stored here: each
/// operation resolves the current activity via the static `activities`
/// list inside a detached task — only Sendable values cross isolation.
@MainActor
final class RecordingActivityController {

    func start(startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        Task.detached {
            // Never leave a stale activity behind from a previous recording.
            for activity in Activity<RecordingActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            let content = ActivityContent(
                state: RecordingActivityAttributes.ContentState(startedAt: startedAt, isPaused: false),
                staleDate: nil
            )
            _ = try? Activity.request(attributes: RecordingActivityAttributes(), content: content)
        }
    }

    func setPaused(_ paused: Bool, startedAt: Date) {
        Task.detached {
            let content = ActivityContent(
                state: RecordingActivityAttributes.ContentState(startedAt: startedAt, isPaused: paused),
                staleDate: nil
            )
            for activity in Activity<RecordingActivityAttributes>.activities {
                await activity.update(content)
            }
        }
    }

    func end() {
        Task.detached {
            for activity in Activity<RecordingActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
