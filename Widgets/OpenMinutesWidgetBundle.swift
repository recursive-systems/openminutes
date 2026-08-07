import SwiftUI
import WidgetKit

@main
struct OpenMinutesWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordControl()
        LockScreenRecordWidget()
        RecordingLiveActivity()
    }
}
