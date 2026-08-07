import SwiftUI
import WidgetKit

/// Classic Lock Screen accessory widget. Accessory families can't run
/// intents in place, so it deep-links into the app, which starts recording
/// on arrival (handled in ContentView.onOpenURL).
struct LockScreenRecordWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.recursivesystems.openminutes.lockscreen",
                            provider: StaticEntryProvider()) { _ in
            LockScreenRecordView()
        }
        .configurationDisplayName("Start Recording")
        .description("Tap to start an OpenMinutes recording.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

private struct LockScreenRecordView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                Image(systemName: "record.circle.fill")
                    .font(.title)
            default:
                HStack {
                    Image(systemName: "record.circle.fill")
                    Text("Record")
                        .font(.headline)
                }
            }
        }
        .widgetURL(URL(string: "openminutes://record"))
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

/// Single static entry; the widget never changes over time.
struct StaticEntryProvider: TimelineProvider {
    struct Entry: TimelineEntry { let date: Date }
    func placeholder(in context: Context) -> Entry { Entry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}
