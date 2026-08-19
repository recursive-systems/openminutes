import Foundation
import SwiftData

/// App-level service container: the single source of truth for service
/// instances shared by the SwiftUI graph AND App Intents (which can run in
/// this process before any scene exists — Action Button cold start).
///
/// `init` must stay allocation-only: an AudioRecordingIntent needs
/// `AppServices.shared.recorder.start()` to run before the SwiftUI graph
/// loads. Anything slow (legacy migration, pipeline resume) belongs in
/// `bootstrapAfterLaunch()`, which intents call only after recording starts.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let container: ModelContainer
    let recorder: RecorderService
    let audioImporter: AudioImportService
    let exporter: ExportService
    let tipJar: TipJar
    let processor: ProcessingCoordinator
    let diarizer: SpeakerDiarizer
    let live: LiveTranscriptionService
    let liveActivity: RecordingActivityController

    private var bootstrapped = false

    private init() {
        do {
            // cloudKitDatabase: .none is load-bearing, not a default. The
            // iCloud entitlement exists purely so export can write into the
            // app's iCloud Drive container; SwiftData otherwise reads that
            // entitlement as consent to sync the store to CloudKit, which
            // both violates the zero-network rule and hard-fails at launch
            // (Recording has non-optional attributes and a unique id, and
            // CloudKit permits neither).
            container = try ModelContainer(
                for: Recording.self,
                configurations: ModelConfiguration(cloudKitDatabase: .none)
            )
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
        recorder = RecorderService()
        audioImporter = AudioImportService()
        exporter = ExportService()
        tipJar = TipJar()
        diarizer = SpeakerDiarizer()
        live = LiveTranscriptionService()
        processor = ProcessingCoordinator(
            context: container.mainContext,
            exporter: exporter,
            diarizer: diarizer
        )
        liveActivity = RecordingActivityController()

        // The Live Activity must track every recording (AudioRecordingIntent
        // kills recordings without one), so wire it here — before any intent
        // can possibly call recorder.start().
        // Live transcription rides the recorder's buffers. Wired here so the
        // recorder stays AVFoundation-pure and knows nothing about Speech.
        recorder.bufferHandler = { [live] buffer in live.append(buffer) }

        recorder.activityHandler = { [liveActivity] event in
            switch event {
            case .started(let startedAt):
                liveActivity.start(startedAt: startedAt)
            case .paused(let adjustedStart):
                liveActivity.setPaused(true, startedAt: adjustedStart)
            case .resumed(let adjustedStart):
                liveActivity.setPaused(false, startedAt: adjustedStart)
            case .stopped:
                liveActivity.end()
            }
        }
    }

    /// Idempotent; called from the scene's `.task` and from intents after
    /// the time-critical work is done.
    func bootstrapAfterLaunch() {
        guard !bootstrapped else { return }
        bootstrapped = true
        LegacyStoreMigrator.migrateIfNeeded(into: container.mainContext)
        processor.resumeUnfinished()
        processor.retryPendingTitles()
    }
}
