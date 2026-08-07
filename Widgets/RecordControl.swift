import AppIntents
import SwiftUI
import WidgetKit

/// The load-bearing piece of PRD C4: a Control is what users assign to the
/// Action Button, Control Center, and the Lock Screen control slots.
struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.recursivesystems.openminutes.record") {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Start Recording", systemImage: "record.circle.fill")
            }
        }
        .displayName("Start Recording")
        .description("Start an OpenMinutes recording.")
    }
}
