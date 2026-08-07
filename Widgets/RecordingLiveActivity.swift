import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen banner + Dynamic Island for an in-progress recording.
/// The interval timer renders client-side (zero updates while recording);
/// the stop button runs StopAndProcessIntent in the app process.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            HStack(spacing: 12) {
                StateIcon(isPaused: context.state.isPaused)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.isPaused ? "Paused" : "Recording")
                        .font(.headline)
                    ElapsedView(state: context.state)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(intent: StopAndProcessIntent()) {
                    Image(systemName: "stop.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StateIcon(isPaused: context.state.isPaused)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.isPaused ? "Paused" : "Recording")
                            .font(.headline)
                        ElapsedView(state: context.state)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: StopAndProcessIntent()) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            } compactLeading: {
                StateIcon(isPaused: context.state.isPaused)
            } compactTrailing: {
                ElapsedView(state: context.state)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 44)
            } minimal: {
                StateIcon(isPaused: context.state.isPaused)
            }
        }
    }
}

private struct StateIcon: View {
    let isPaused: Bool
    var body: some View {
        Image(systemName: isPaused ? "pause.circle.fill" : "record.circle.fill")
            .foregroundStyle(isPaused ? .orange : .red)
    }
}

private struct ElapsedView: View {
    let state: RecordingActivityAttributes.ContentState
    var body: some View {
        if state.isPaused {
            // Frozen elapsed time at pause (startedAt was adjusted to now-elapsed).
            Text(Duration.seconds(Date.now.timeIntervalSince(state.startedAt))
                .formatted(.time(pattern: .minuteSecond)))
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
        }
    }
}
