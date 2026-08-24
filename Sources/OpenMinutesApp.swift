import BackgroundTasks
import SwiftData
import SwiftUI

@main
struct OpenMinutesApp: App {
    private let services = AppServices.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Must register before launch finishes. Opportunistic third layer:
        // beginBackgroundTask continuation and resume-on-launch are the
        // guarantees; this lets long jobs finish overnight.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: ProcessingCoordinator.backgroundTaskID,
            using: nil
        ) { task in
            guard let task = task as? BGProcessingTask else { return }
            Task { @MainActor in
                let processor = AppServices.shared.processor
                task.expirationHandler = {
                    Task { @MainActor in processor.cancelInFlight() }
                }
                await processor.runUnfinishedToCompletion()
                // Expiration can cut the drain short (cancelled tasks still
                // resolve): report success honestly so iOS reschedules.
                task.setTaskCompleted(success: !processor.hasUnfinishedWork)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.recordRed)   // brand accent everywhere (matches icon + site)
                .environment(services.recorder)
                .environment(services.audioImporter)
                .environment(services.exporter)
                .environment(services.processor)
                .environment(services.tipJar)
                .environment(services.live)
                .task {
                    #if DEBUG
                    if DemoSeed.isRequested { DemoSeed.populate(services.container.mainContext) }
                    #endif
                    services.bootstrapAfterLaunch()
                }
        }
        .modelContainer(services.container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Titles whose Foundation Models call failed while the app
                // was backgrounded get their retry here.
                services.processor.retryPendingTitles()
                if services.recorder.state == .idle {
                    Task { await services.exporter.markAbandonedLiveTranscripts() }
                }
            }
            if phase == .background {
                services.processor.scheduleBackgroundProcessingIfNeeded()
            }
        }
    }
}
