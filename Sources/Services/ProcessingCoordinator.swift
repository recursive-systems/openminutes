import BackgroundTasks
import Foundation
import OSLog
import SwiftData
import UIKit

/// Runs the post-recording pipeline: transcribe -> optionally summarize/title -> export.
/// All on-device; failures are per-stage and non-fatal (a failed summary
/// still yields an exported transcript).
///
/// App-level: status is persisted on the Recording model, so a kill/relaunch
/// mid-processing is picked up by `resumeUnfinished()` at the stage it
/// stopped at (existing transcript/summary are not redone).
@MainActor
@Observable
final class ProcessingCoordinator {
    static let backgroundTaskID = "dev.recursivesystems.openminutes.processing"

    private let context: ModelContext
    private let exporter: any Exporting
    private let transcriber: any Transcribing
    private let summarizer: any Summarizing
    private let summariesEnabled: () -> Bool
    private let contentPreference: () -> RecordingContentPreference
    private let transcriptionLocale: () -> Locale
    private let diarizer: (any Diarizing)?
    private let speakerLabelsEnabled: () -> Bool
    private let speakerMode: () -> SpeakerPreferences.Mode
    private let backgroundContinuation = BackgroundContinuation()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var inFlight: Set<UUID> = []
    /// Tail of the pipeline chain; each enqueued task awaits it so
    /// recordings process one at a time.
    private var lastEnqueued: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.recursivesystems.openminutes", category: "processing")

    /// Set when a SwiftData save fails (realistically: the disk is full).
    /// Resume-on-launch reads persisted status, so a failed save silently
    /// loses work — the UI has to say so. A flag, not the error text: the
    /// detail goes to the log, where it is useful, rather than to a user
    /// who cannot act on SwiftData's wording.
    private(set) var persistenceFailed = false

    /// Live download progress while any recording is in .downloadingAssets;
    /// rendered by RecordingRow.
    private(set) var assetDownloadProgress: Progress?

    init(
        context: ModelContext,
        exporter: any Exporting,
        transcriber: any Transcribing = OnDeviceTranscriber(),
        summarizer: any Summarizing = SummaryService(),
        summariesEnabled: @escaping () -> Bool = { SummaryPreferences.isEnabled },
        contentPreference: @escaping () -> RecordingContentPreference = { RecordingContentPreference.current },
        transcriptionLocale: @escaping () -> Locale = { TranscriptionLanguage.current() },
        diarizer: (any Diarizing)? = nil,
        speakerLabelsEnabled: @escaping () -> Bool = { SpeakerPreferences.isEnabled },
        speakerMode: @escaping () -> SpeakerPreferences.Mode = { SpeakerPreferences.mode }
    ) {
        self.context = context
        self.exporter = exporter
        self.transcriber = transcriber
        self.summarizer = summarizer
        self.summariesEnabled = summariesEnabled
        self.contentPreference = contentPreference
        self.transcriptionLocale = transcriptionLocale
        self.diarizer = diarizer
        self.speakerLabelsEnabled = speakerLabelsEnabled
        self.speakerMode = speakerMode
    }

    /// Tracked entry point: one task per recording, cancellable as a group.
    /// Tasks chain on the previous one so pipeline work runs serially —
    /// interleaved transcriptions burn battery without finishing sooner.
    func enqueue(_ recording: Recording) {
        enqueue(recording) { coordinator in
            await coordinator.process(recording)
        }
    }

    private func enqueue(
        _ recording: Recording,
        run: @escaping @MainActor (ProcessingCoordinator) async -> Void
    ) {
        guard tasks[recording.id] == nil else { return }
        let id = recording.id
        let previous = lastEnqueued
        let task = Task { [weak self] in
            await previous?.value
            if !Task.isCancelled, let self {
                await run(self)
            }
            self?.tasks[id] = nil
        }
        tasks[id] = task
        lastEnqueued = task
    }

    /// Call before deleting a recording: stops its pipeline work so the
    /// coordinator never mutates a deleted model. Safe when not in flight.
    func cancelProcessing(for recording: Recording) {
        tasks[recording.id]?.cancel()
        tasks[recording.id] = nil
    }

    /// Re-enqueues every recording stranded mid-pipeline by a previous launch.
    func resumeUnfinished() {
        let all = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        for recording in all where recording.status.isUnfinished {
            enqueue(recording)
        }
    }

    func retry(_ recording: Recording) {
        enqueue(recording)
    }

    /// Re-tries titles left behind by a failed best-effort title call — the
    /// pipeline continues past that failure (Foundation Models rate-limits
    /// backgrounded apps, and export must not wait on it), so the placeholder
    /// would otherwise stick forever on a finished recording. Called on
    /// launch and on every return to the foreground; a success rewrites the
    /// existing export so the folder name and frontmatter carry the title.
    func retryPendingTitles() {
        let all = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        for recording in all
        where recording.titleNeedsGeneration
            && !recording.status.isUnfinished
            && recording.transcript != nil {
            enqueue(recording) { coordinator in
                await coordinator.generateTitle(for: recording)
            }
        }
    }

    /// Exports recordings stranded by a revoked folder (PRD C5) — call
    /// after the user picks a (new) folder.
    func exportPendingRecordings() {
        let all = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        for recording in all where recording.exportPending {
            enqueue(recording)
        }
    }

    // MARK: - Background processing (BGProcessingTask)

    /// Cooperative cancellation: in-flight work stops at the next stage
    /// boundary; persisted statuses mean resume-on-launch finishes the rest.
    func cancelInFlight() {
        for task in tasks.values { task.cancel() }
    }

    /// Drains all unfinished recordings sequentially (battery-gentle) —
    /// the BGProcessingTask body.
    func runUnfinishedToCompletion() async {
        resumeUnfinished()
        while let task = tasks.values.first {
            await task.value
        }
    }

    /// True while any recording still needs pipeline work — the BGTask's
    /// honest success criterion (expiration can cut the drain short).
    var hasUnfinishedWork: Bool {
        let all = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        return all.contains { $0.status.isUnfinished }
    }

    /// Schedule an opportunistic background slot when the app backgrounds
    /// with work outstanding.
    func scheduleBackgroundProcessingIfNeeded() {
        let all = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        guard all.contains(where: { $0.status.isUnfinished }) else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskID)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    func process(_ recording: Recording) async {
        guard !inFlight.contains(recording.id) else { return }
        inFlight.insert(recording.id)
        backgroundContinuation.begin()
        defer {
            inFlight.remove(recording.id)
            backgroundContinuation.end()
        }

        recording.failureReason = nil
        let preference = contentPreference()
        /// Whether *this* run is the one that turned audio into a transcript.
        /// Discarding audio is only ever a consequence of that conversion —
        /// see the discard at the end of this method.
        var transcribedNow = false

        if preference.includesTranscript, recording.transcript == nil {
            recording.status = .transcribing
            save()
            do {
                // First run (or new locale) downloads the speech model; the
                // progress callback only fires when a download actually starts.
                let locale = transcriptionLocale()
                try await transcriber.ensureAssetsInstalled(locale: locale) { progress in
                    guard !wasDeleted(recording) else { return }
                    recording.status = .downloadingAssets
                    assetDownloadProgress = progress
                    save()
                }
                guard !wasDeleted(recording) else {
                    assetDownloadProgress = nil
                    return
                }
                if recording.status == .downloadingAssets {
                    assetDownloadProgress = nil
                    recording.status = .transcribing
                    save()
                }
                let lines = try await transcriber.transcribe(
                    fileAt: recording.audioURL, locale: locale, duration: recording.duration)
                guard !wasDeleted(recording) else { return }
                // Speakers are additive: any failure here leaves an
                // unlabelled transcript rather than no transcript.
                let speakers = await attributeSpeakers(for: recording, lines: lines)
                guard !wasDeleted(recording) else { return }
                recording.speakerNames = speakers.names
                recording.transcriptLines = lines.enumerated().map { index, line in
                    TranscriptLine(start: line.start, end: line.end, text: line.text,
                                   speakerID: index < speakers.ids.count ? speakers.ids[index] : nil,
                                   words: line.words)
                }
                recording.transcript = TranscriptRenderer.markdown(
                    lines: recording.transcriptLines, names: speakers.names)
                recording.transcriptLanguage = TranscriptionLanguage.tag(for: locale)
                transcribedNow = true
                save()
            } catch {
                assetDownloadProgress = nil
                if Task.isCancelled || wasDeleted(recording) { return }   // status persists; resume finishes
                fail(recording, "Transcription failed: \(error.localizedDescription)")
                return
            }
        }

        if Task.isCancelled || wasDeleted(recording) { return }   // BG slot expired; resume-on-launch continues

        let shouldGenerateSummaries = preference.includesTranscript && summariesEnabled()

        if !shouldGenerateSummaries {
            if recording.summarySkippedReason != nil {
                recording.summarySkippedReason = nil
                save()
            }
        } else if recording.summary == nil, let transcript = recording.transcript {
            recording.status = .summarizing
            save()
            do {
                let summary = try await summarizer.summarize(transcript: transcript)
                guard !wasDeleted(recording) else { return }
                recording.summary = summary
                recording.summarySkippedReason = nil
            } catch let error as SummaryService.SummaryError {
                // Deterministic unavailability — record the specific reason
                // (PRD B2: graceful skip with explanation).
                guard !wasDeleted(recording) else { return }
                recording.summarySkippedReason = error.localizedDescription
            } catch {
                // Foundation Models rate-limits backgrounded apps: leave the
                // status for resume-on-launch instead of recording a bogus skip.
                if UIApplication.shared.applicationState == .background { return }
                guard !wasDeleted(recording) else { return }
                recording.summarySkippedReason = error.localizedDescription
            }
            save()
        }

        if preference.includesTranscript,
           recording.titleNeedsGeneration,
           let transcript = recording.transcript {
            do {
                let title = try await summarizer.title(
                    transcript: transcript,
                    summary: recording.summary
                )
                if !title.isEmpty, !wasDeleted(recording), recording.titleNeedsGeneration {
                    recording.title = title
                    recording.titleNeedsGeneration = false
                    save()
                }
            } catch {
                // Best-effort here — export must not wait on Foundation
                // Models (which rate-limits backgrounded apps). The flag
                // stays set; retryPendingTitles() finishes the job the next
                // time the app is in the foreground.
                log.error("Title generation failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if Task.isCancelled || wasDeleted(recording) { return }

        // No destination chosen yet is not a failure; re-export after
        // choosing one is a separate action (PRD C5). Nothing gates export —
        // the app is free and tips unlock nothing.
        if exporter.isConfigured {
            recording.status = .exporting
            save()
            do {
                let url = try await exporter.export(recording)
                guard !wasDeleted(recording) else { return }
                // The folder is the export unit; url points inside it.
                recording.exportedFolderName = url.deletingLastPathComponent().lastPathComponent
                recording.exportPending = false
            } catch ExportService.ExportError.folderRevoked {
                // Transcript/summary succeeded — don't alarm the user. The
                // re-pick banner + exportPendingRecordings() finish the job.
                guard !wasDeleted(recording) else { return }
                recording.exportPending = true
            } catch {
                fail(recording, "Export failed: \(error.localizedDescription)")
                return
            }
        }

        guard !wasDeleted(recording) else { return }

        // Only the run that produced the transcript may discard the audio.
        // `process()` re-runs for a retry, a deferred export, or a speaker
        // rename, and gating on the preference alone meant any of those
        // deleted the audio of a recording made back when the preference
        // still said to keep it. Renaming a label is not consent to destroy
        // a recording. Settings has an explicit bulk reclaim for that.
        if transcribedNow, !preference.includesAudio, recording.transcript != nil {
            discardAudio(for: recording)
        }

        recording.status = .done
        save()
    }

    /// Late title pass for a finished recording: the pipeline's title stage,
    /// re-run alone, then a rewrite of the existing export so the visible
    /// folder name carries the generated title.
    private func generateTitle(for recording: Recording) async {
        guard !inFlight.contains(recording.id) else { return }
        guard recording.titleNeedsGeneration,
              !wasDeleted(recording),
              let transcript = recording.transcript else { return }
        inFlight.insert(recording.id)
        backgroundContinuation.begin()
        defer {
            inFlight.remove(recording.id)
            backgroundContinuation.end()
        }
        do {
            let title = try await summarizer.title(transcript: transcript, summary: recording.summary)
            guard !title.isEmpty, !wasDeleted(recording), recording.titleNeedsGeneration else { return }
            recording.title = title
            recording.titleNeedsGeneration = false
            save()
        } catch {
            log.error("Title retry failed: \(error.localizedDescription, privacy: .public)")
            return   // still pending; the next foreground pass retries
        }
        // Rewrite an existing export under the new title; a recording that
        // was never exported keeps waiting for its normal export trigger.
        guard exporter.isConfigured, recording.exportedFolderName != nil else { return }
        do {
            let url = try await exporter.export(recording)
            guard !wasDeleted(recording) else { return }
            recording.exportedFolderName = url.deletingLastPathComponent().lastPathComponent
            save()
        } catch ExportService.ExportError.folderRevoked {
            guard !wasDeleted(recording) else { return }
            recording.exportPending = true
            save()
        } catch {
            // The previous export still exists under the placeholder name;
            // the next re-export pass catches up.
        }
    }

    private func fail(_ recording: Recording, _ reason: String) {
        guard !wasDeleted(recording) else { return }
        recording.status = .failed
        recording.failureReason = reason
        save()
    }

    /// Swipe-to-delete can race the pipeline; a deleted model must not be
    /// mutated (SwiftData invalidates its backing store).
    private func wasDeleted(_ recording: Recording) -> Bool {
        recording.isDeleted || recording.modelContext == nil
    }

    /// Persisted statuses are the crash-safety backbone (resume-on-launch
    /// reads them), so a failed save is surfaced, never swallowed.
    private func save() {
        do {
            try context.save()
            persistenceFailed = false
        } catch {
            persistenceFailed = true
            log.error("SwiftData save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Runs diarization and maps its clusters onto stable speaker IDs.
    ///
    /// Every failure path returns empty rather than throwing: speaker labels
    /// are an enhancement, and losing a transcript because the diarizer had a
    /// bad day would be a far worse outcome than losing the labels.
    private func attributeSpeakers(
        for recording: Recording, lines: [TimedLine]
    ) async -> (ids: [String?], names: [String: String]) {
        guard speakerLabelsEnabled(), let diarizer, !lines.isEmpty else {
            return ([], [:])
        }
        let mode = speakerMode()
        let enrolled = VoiceEnrollment.embedding()
        // Only-me mode has nothing to say without an enrolled voice: every
        // line would come back "Other", which is worse than no labels.
        guard mode == .everyone || enrolled != nil else {
            log.info("Only-me speaker labels skipped: no voice enrolled")
            return ([], [:])
        }
        // The pipeline installs the models itself rather than trusting that
        // something else already did. `isReady` lives in memory only, so
        // gating on it meant labels ran exactly once — in the launch where
        // the user enrolled — and silently stopped after the next cold start.
        // The call is cheap when the models are already loaded.
        do {
            try await diarizer.ensureModelsInstalled { _ in }
        } catch {
            log.error("Speaker labels skipped: \(error.localizedDescription, privacy: .public)")
            return ([], [:])
        }
        let turns: [SpeakerTurn]
        do {
            turns = try await diarizer.diarize(
                fileAt: recording.audioURL,
                enrolledOwner: enrolled
            )
        } catch {
            log.error("Diarization failed: \(error.localizedDescription, privacy: .public)")
            return ([], [:])
        }
        guard !turns.isEmpty else { return ([], [:]) }

        // Remap the diarizer's cluster IDs to stable ones. The owner keeps
        // s1 when enrolled; everyone else is numbered by first appearance so
        // the labels read in the order a person hears them.
        var mapping: [String: String] = [:]
        var nextCluster = 0
        for turn in turns.sorted(by: { $0.start < $1.start }) where mapping[turn.speakerID] == nil {
            if turn.speakerID == SpeakerIdentity.ownerID {
                mapping[turn.speakerID] = SpeakerIdentity.ownerID
            } else if mode == .onlyMe {
                // Every other voice collapses into one label, so the
                // clustering's least reliable judgement — telling other
                // people apart — never reaches the transcript.
                mapping[turn.speakerID] = SpeakerIdentity.othersID
            } else {
                mapping[turn.speakerID] = SpeakerIdentity.id(forClusterIndex: nextCluster)
                nextCluster += 1
            }
        }
        let stable = turns.map {
            SpeakerTurn(speakerID: mapping[$0.speakerID] ?? $0.speakerID, start: $0.start, end: $0.end)
        }
        let ids = SpeakerAttribution.attribute(lines: lines, turns: stable)

        var names: [String: String] = [:]
        for id in Set(ids.compactMap { $0 }) {
            if id == SpeakerIdentity.ownerID {
                names[id] = VoiceEnrollment.displayName()
                    ?? SpeakerIdentity.defaultLabel(for: id, isOwner: true)
            } else if mode == .onlyMe {
                names[id] = SpeakerIdentity.othersLabel
            } else {
                names[id] = SpeakerIdentity.defaultLabel(for: id, isOwner: false)
            }
        }
        return (ids, names)
    }

    /// Re-renders the transcript after a speaker is renamed. Cheap and local:
    /// the stored lines already hold the timings and speaker IDs, so nothing
    /// is transcribed again.
    func renameSpeaker(_ id: String, to name: String, in recording: Recording) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, recording.speakerNames[id] != nil else { return }
        recording.speakerNames[id] = trimmed
        if !recording.transcriptLines.isEmpty {
            recording.transcript = TranscriptRenderer.markdown(
                lines: recording.transcriptLines, names: recording.speakerNames)
        }
        save()
        // The name is in the exported file too, so it is stale until rewritten.
        if exporter.isConfigured { enqueue(recording) }
    }

    private func discardAudio(for recording: Recording) {
        try? FileManager.default.removeItem(at: recording.audioURL)
    }

    /// Reclaims space by deleting the audio file while keeping the recording
    /// and its transcript. Only offered where a transcript exists — without
    /// one this would destroy the recording's entire content.
    func deleteAudioKeepingTranscript(for recording: Recording) {
        guard recording.transcript != nil else { return }
        discardAudio(for: recording)
    }

    /// Bulk version for Settings. Returns how many files were removed so the
    /// caller can report it rather than appearing to do nothing.
    @discardableResult
    func deleteAllAudioKeepingTranscripts() -> Int {
        let descriptor = FetchDescriptor<Recording>()
        let all = (try? context.fetch(descriptor)) ?? []
        var removed = 0
        for recording in all where recording.transcript != nil {
            let path = recording.audioURL.path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            discardAudio(for: recording)
            removed += 1
        }
        return removed
    }
}
