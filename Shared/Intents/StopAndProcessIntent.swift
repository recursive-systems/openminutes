import AppIntents
import Foundation

/// Stops the active recording and kicks off transcribe → summarize → export.
/// Reachable from the Live Activity's stop button, Siri, and Shortcuts.
struct StopAndProcessIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Stop OpenMinutes Recording"
    static let description = IntentDescription("Stops the current recording and processes it.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if APP_TARGET
        let services = AppServices.shared
        guard services.recorder.state != .idle, let finished = await services.finishRecording() else {
            return .result(dialog: "No recording in progress.")
        }
        services.container.mainContext.insert(finished)
        try? services.container.mainContext.save()
        services.bootstrapAfterLaunch()
        services.processor.enqueue(finished)
        return .result(dialog: "Recording saved. Transcribing now.")
        #else
        return .result(dialog: "")
        #endif
    }
}
