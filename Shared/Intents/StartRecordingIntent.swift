import AppIntents
import AVFAudio
import Foundation

/// "Start OpenMinutes recording" — Action Button, Control Center, Siri,
/// Shortcuts (PRD C4). AudioRecordingIntent runs in the app's process in the
/// background (no foregrounding), records while the device is locked, and
/// REQUIRES an active Live Activity or the system stops the recording —
/// the recorder's activity wiring handles that.
///
/// Cold start: the system launches the app in the background and calls
/// perform() before any scene exists, so this touches only AppServices
/// (allocation-only init) before recording starts.
struct StartRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start OpenMinutes Recording"
    static let description = IntentDescription("Starts recording a meeting or voice note.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if APP_TARGET
        let services = AppServices.shared

        // Cannot prompt for mic permission from a locked device; onboarding
        // secures it and this is the graceful fallback.
        guard AVAudioApplication.shared.recordPermission == .granted else {
            return .result(dialog: "Open OpenMinutes once to allow microphone access.")
        }
        guard services.recorder.state == .idle else {
            return .result(dialog: "Already recording.")
        }

        try await services.startRecording()
        services.bootstrapAfterLaunch()
        return .result(dialog: "Recording started.")
        #else
        // Never executes: the system routes AudioRecordingIntent to the app
        // process. This stub only satisfies the widget target's compiler.
        return .result(dialog: "")
        #endif
    }
}
