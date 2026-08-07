import Foundation
import SwiftData
import Testing
@testable import OpenMinutes

// MARK: - Fakes

@MainActor
private final class FakeTranscriber: Transcribing {
    /// Raw line text; the coordinator renders the "[HH:MM:SS] …" form.
    var transcript = "Hello team, quick standup."
    var error: Error?
    private(set) var transcribeCallCount = 0
    /// What the coordinator actually asked for, so tests can prove the
    /// configured language reaches both stages.
    private(set) var assetLocales: [Locale] = []
    private(set) var transcribeLocales: [Locale] = []

    func ensureAssetsInstalled(locale: Locale, onProgress: (Progress) -> Void) async throws {
        assetLocales.append(locale)
    }

    func transcribe(fileAt url: URL, locale: Locale, duration: TimeInterval) async throws -> [TimedLine] {
        transcribeCallCount += 1
        transcribeLocales.append(locale)
        if let error { throw error }
        return [TimedLine(start: 0, end: duration, text: transcript)]
    }
}

@MainActor
private final class FakeSummarizer: Summarizing {
    var summary = "- Discussed the launch checklist."
    var title = "Launch Checklist Standup"
    var error: Error?
    var beforeReturningTitle: (() async -> Void)?
    private(set) var summarizeCallCount = 0
    private(set) var titleCallCount = 0

    func summarize(transcript: String) async throws -> String {
        summarizeCallCount += 1
        if let error { throw error }
        return summary
    }

    func title(transcript: String, summary: String?) async throws -> String {
        titleCallCount += 1
        if let error { throw error }
        await beforeReturningTitle?()
        return title
    }
}

/// Writes real markdown through MarkdownDocument/ExportFilename — the same
/// format path as ExportService, minus the security-scoped bookmark (which
/// cannot exist for a plain temp URL in tests).
@MainActor
private final class FakeExporter: Exporting {
    let folder: URL
    var isConfigured = true
    var error: Error?
    /// Mirrors what the coordinator was given, since the real service reads
    /// the global preference and the harness injects one.
    var contentPreference: RecordingContentPreference = .transcriptsOnly
    private(set) var exportCallCount = 0

    init() {
        folder = FileManager.default.temporaryDirectory
            .appending(path: "export-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @discardableResult
    func export(_ recording: Recording) async throws -> URL {
        exportCallCount += 1
        if let error { throw error }

        let folderName: String
        if let existing = recording.exportedFolderName,
           FileManager.default.fileExists(atPath: folder.appending(path: existing).path(percentEncoded: false)) {
            folderName = existing
        } else {
            let base = ExportFilename.base(title: recording.title, recorded: recording.createdAt)
            folderName = ExportFilename.uniqueDirectory(base: base) { candidate in
                FileManager.default.fileExists(
                    atPath: folder.appending(path: candidate).path(percentEncoded: false))
            }
        }
        let recordingFolder = folder.appending(path: folderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true)
        let preference = contentPreference
        if preference.includesAudio {
            FileManager.default.createFile(
                atPath: recordingFolder.appending(path: ExportService.exportedAudioName)
                    .path(percentEncoded: false), contents: Data())
        }
        let document = MarkdownDocument(
            title: recording.title,
            recorded: recording.createdAt,
            duration: recording.duration,
            transcript: recording.transcript,
            summary: recording.summary,
            audioFileName: preference.includesAudio ? ExportService.exportedAudioName : nil,
            device: MarkdownDocument.currentDevice(),
            generator: MarkdownDocument.currentGenerator()
        )
        let url = recordingFolder.appending(path: ExportService.exportedTranscriptName)
        try Data(document.rendered().utf8).write(to: url, options: .atomic)
        return url
    }
}

@MainActor
private final class FakeDiarizer: Diarizing {
    /// Starts false, exactly like the real one. Hardcoding this to `true` is
    /// what let the pipeline ship depending on some *other* code path having
    /// installed the models first — the fake was the only thing in the system
    /// for which that was true.
    private(set) var isReady = false
    var turns: [SpeakerTurn] = []
    var error: Error?
    var installError: Error?
    private(set) var enrolledOwnerSeen: [Float]??
    private(set) var installCount = 0

    func ensureModelsInstalled(onProgress: (Progress) -> Void) async throws {
        installCount += 1
        if let installError { throw installError }
        isReady = true
    }

    func diarize(fileAt url: URL, enrolledOwner: [Float]?) async throws -> [SpeakerTurn] {
        guard isReady else { throw SpeakerDiarizer.DiarizationError.notReady }
        enrolledOwnerSeen = .some(enrolledOwner)
        if let error { throw error }
        return turns
    }

    func enrollmentEmbedding(fileAt url: URL) async throws -> [Float] { [0.1, 0.2] }
}

// MARK: - Harness

/// In-memory SwiftData + fake stages. Nothing gates export any more, so
/// there is no purchase state to set up.
@MainActor
private struct Pipeline {
    let context: ModelContext
    let coordinator: ProcessingCoordinator
    let transcriber = FakeTranscriber()
    let summarizer = FakeSummarizer()
    let exporter = FakeExporter()
    let diarizer = FakeDiarizer()

    private let container: ModelContainer

    init(
        summariesEnabled: Bool = true,
        contentPreference: RecordingContentPreference = .transcriptsOnly,
        transcriptionLocale: Locale = Locale(identifier: "en_US"),
        speakerLabels: Bool = false,
        speakerMode: SpeakerPreferences.Mode = .everyone
    ) throws {
        // cloudKitDatabase: .none for the same reason as the app container
        // (see AppServices): the iCloud entitlement otherwise makes SwiftData
        // enable CloudKit sync, which Recording's schema cannot satisfy.
        container = try ModelContainer(
            for: Recording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        context = container.mainContext

        exporter.contentPreference = contentPreference
        coordinator = ProcessingCoordinator(
            context: context,
            exporter: exporter,
            transcriber: transcriber,
            summarizer: summarizer,
            summariesEnabled: { summariesEnabled },
            contentPreference: { contentPreference },
            transcriptionLocale: { transcriptionLocale },
            diarizer: diarizer,
            speakerLabelsEnabled: { speakerLabels },
            speakerMode: { speakerMode }
        )
    }

    func insertRecording(
        transcript: String? = nil,
        summary: String? = nil,
        exportedFolderName: String? = nil,
        status: ProcessingStatus = .pending
    ) -> Recording {
        let createdAt = Date()
        let recording = Recording(
            title: Recording.defaultTitle(for: createdAt),
            audioFileName: "standup.m4a",
            createdAt: createdAt,
            duration: 90,
            transcript: transcript,
            summary: summary,
            exportedFolderName: exportedFolderName,
            status: status
        )
        context.insert(recording)
        return recording
    }
}

// MARK: - Tests

@MainActor
@Suite("Processing pipeline")
struct ProcessingCoordinatorTests {

    @Test func happyPathTranscribesSummarizesAndExports() async throws {
        let pipeline = try Pipeline()
        let recording = pipeline.insertRecording()

        await pipeline.coordinator.process(recording)

        #expect(recording.status == .done)
        #expect(recording.transcript == "[00:00:00] \(pipeline.transcriber.transcript)")
        #expect(recording.summary == pipeline.summarizer.summary)
        #expect(recording.title == pipeline.summarizer.title)
        #expect(recording.titleNeedsGeneration == false)
        #expect(recording.failureReason == nil)
        #expect(recording.exportPending == false)

        let folderName = try #require(recording.exportedFolderName)
        let exported = pipeline.exporter.folder
            .appending(path: folderName)
            .appending(path: ExportService.exportedTranscriptName)
        let rendered = try String(contentsOf: exported, encoding: .utf8)
        #expect(rendered.contains("openminutes: \(MarkdownDocument.formatVersion)"))
        #expect(rendered.contains("## Transcript"))
        #expect(rendered.contains(pipeline.summarizer.summary))

    }

    /// The configured language must reach the asset download and the
    /// transcription itself — disagreement there means downloading one model
    /// and transcribing with another.
    @Test func configuredLanguageReachesBothStagesAndIsRecorded() async throws {
        let spanish = Locale(identifier: "es_ES")
        let pipeline = try Pipeline(transcriptionLocale: spanish)
        let recording = pipeline.insertRecording()

        await pipeline.coordinator.process(recording)

        #expect(pipeline.transcriber.assetLocales == [spanish])
        #expect(pipeline.transcriber.transcribeLocales == [spanish])
        #expect(recording.transcriptLanguage == "es-ES")
    }

    @Test func speakerTurnsLabelTheTranscriptAndNameTheSpeakers() async throws {
        let pipeline = try Pipeline(speakerLabels: true)
        pipeline.transcriber.transcript = "Morning all."
        pipeline.diarizer.turns = [SpeakerTurn(speakerID: "spk_7", start: 0, end: 90)]
        let recording = pipeline.insertRecording()

        await pipeline.coordinator.process(recording)

        // The diarizer's own cluster ID is remapped to a stable one, and the
        // body carries the display name so a chunk of it stands alone. The
        // ID keeps the reserved owner slot out of the way (`s2`); the label
        // does not leak that offset to the reader, who has no Speaker 1 here.
        #expect(recording.transcript == "[00:00:00] Speaker 1: Morning all.")
        #expect(recording.speakerNames == ["s2": "Speaker 1"])
        #expect(recording.transcriptLines.map(\.speakerID) == ["s2"])
        // The pipeline installed the models itself. It used to require that
        // voice enrolment had already done so, in this launch, which meant
        // labels silently did nothing for anyone who never enrolled and
        // stopped working for everyone else after the next cold start.
        #expect(pipeline.diarizer.installCount == 1)
    }

    /// Models that cannot be installed cost the labels, never the transcript.
    @Test func transcriptSurvivesWhenSpeakerModelsCannotBeInstalled() async throws {
        let pipeline = try Pipeline(speakerLabels: true)
        pipeline.transcriber.transcript = "Morning all."
        pipeline.diarizer.turns = [SpeakerTurn(speakerID: "spk_7", start: 0, end: 90)]
        pipeline.diarizer.installError = SpeakerDiarizer.DiarizationError.modelsMissing
        let recording = pipeline.insertRecording()

        await pipeline.coordinator.process(recording)

        #expect(recording.transcript == "[00:00:00] Morning all.")
        #expect(recording.speakerNames.isEmpty)
        #expect(recording.status == .done)
    }

    /// Only-me mode collapses every non-owner cluster into one label, so the
    /// clustering's least reliable judgement never reaches the transcript.
    @Test func onlyMeModeCollapsesEveryoneElseIntoOther() async throws {
        let pipeline = try Pipeline(speakerLabels: true, speakerMode: .onlyMe)
        VoiceEnrollment.enroll(embedding: [0.1, 0.2])
        defer { VoiceEnrollment.forget() }
        pipeline.transcriber.transcript = "Morning all."
        pipeline.diarizer.turns = [
            SpeakerTurn(speakerID: "spk_3", start: 0, end: 30),
            SpeakerTurn(speakerID: "spk_9", start: 30, end: 90),
        ]
        let recording = pipeline.insertRecording()

        await pipeline.coordinator.process(recording)

        // Two distinct clusters, one label.
        #expect(recording.speakerNames == [SpeakerIdentity.othersID: "Other"])
    }

    /// Only-me mode has nothing to distinguish without an enrolled voice, and
    /// labelling every line "Other" would be worse than labelling none.
    @Test func onlyMeModeWritesNoLabelsWithoutEnrolment() async throws {
        VoiceEnrollment.forget()
        let pipeline = try Pipeline(speakerLabels: true, speakerMode: .onlyMe)
        pipeline.diarizer.turns = [SpeakerTurn(speakerID: "spk_3", start: 0, end: 90)]
        let recording = pipeline.insertRecording()

        await pipeline.coordinator.process(recording)

        #expect(recording.speakerNames.isEmpty)
        #expect(pipeline.diarizer.enrolledOwnerSeen == nil)   // never ran
        #expect(recording.transcript != nil)
    }

    /// Renaming re-renders from the stored lines — no re-transcription, and
    /// the body updates rather than only the frontmatter map.
    @Test func renamingASpeakerRewritesTheTranscript() async throws {
        let pipeline = try Pipeline(speakerLabels: true)
        pipeline.transcriber.transcript = "Morning all."
        pipeline.diarizer.turns = [SpeakerTurn(speakerID: "spk_7", start: 0, end: 90)]
        let recording = pipeline.insertRecording()
        await pipeline.coordinator.process(recording)
        let transcribeCallsBefore = pipeline.transcriber.transcribeCallCount

        pipeline.coordinator.renameSpeaker("s2", to: "Alex", in: recording)

        #expect(recording.transcript == "[00:00:00] Alex: Morning all.")
        #expect(recording.speakerNames["s2"] == "Alex")
        #expect(pipeline.transcriber.transcribeCallCount == transcribeCallsBefore)
    }

    /// An unknown or blank name must not corrupt a transcript.
    @Test func renamingIgnoresBlankNamesAndUnknownSpeakers() async throws {
        let pipeline = try Pipeline(speakerLabels: true)
        pipeline.diarizer.turns = [SpeakerTurn(speakerID: "spk_7", start: 0, end: 90)]
        let recording = pipeline.insertRecording()
        await pipeline.coordinator.process(recording)
        let original = recording.transcript

        pipeline.coordinator.renameSpeaker("s2", to: "   ", in: recording)
        pipeline.coordinator.renameSpeaker("s99", to: "Ghost", in: recording)

        #expect(recording.transcript == original)
        #expect(recording.speakerNames["s99"] == nil)
    }

    /// Speaker labels are an enhancement: a diarizer that throws must cost
    /// the labels, never the transcript.
    @Test func diarizationFailureStillProducesATranscript() async throws {
        struct Boom: Error {}
        let pipeline = try Pipeline(speakerLabels: true)
        pipeline.diarizer.error = Boom()
        let recording = pipeline.insertRecording()

        await pipeline.coordinator.process(recording)

        #expect(recording.status == .done)
        #expect(recording.transcript != nil)
        #expect(recording.speakerNames.isEmpty)
    }

    @Test func diarizationIsSkippedWhenTheFeatureIsOff() async throws {
        let pipeline = try Pipeline(speakerLabels: false)
        pipeline.diarizer.turns = [SpeakerTurn(speakerID: "spk_1", start: 0, end: 90)]
        let recording = pipeline.insertRecording()

        await pipeline.coordinator.process(recording)

        #expect(pipeline.diarizer.enrolledOwnerSeen == nil)   // never called
        #expect(recording.speakerNames.isEmpty)
    }

    @Test func summaryUnavailableSkipsWithReasonButStillExports() async throws {
        let pipeline = try Pipeline()
        let reason = "Turn on Apple Intelligence in Settings to get summaries."
        pipeline.summarizer.error = SummaryService.SummaryError.modelUnavailable(reason)
        let recording = pipeline.insertRecording()

        await pipeline.coordinator.process(recording)

        #expect(recording.status == .done)
        #expect(recording.summary == nil)
        #expect(recording.summarySkippedReason == reason)
        #expect(pipeline.summarizer.titleCallCount == 1)
        #expect(recording.title.hasPrefix(Recording.defaultTitlePrefix))
        #expect(recording.titleNeedsGeneration == true)
        #expect(recording.exportedFolderName != nil)
    }

    @Test func summariesDisabledByPreferenceSkipsSummaryButStillGeneratesTitle() async throws {
        let pipeline = try Pipeline(summariesEnabled: false)
        let recording = pipeline.insertRecording()

        await pipeline.coordinator.process(recording)

        #expect(recording.status == .done)
        #expect(recording.transcript == "[00:00:00] \(pipeline.transcriber.transcript)")
        #expect(recording.summary == nil)
        #expect(recording.summarySkippedReason == nil)
        #expect(pipeline.summarizer.summarizeCallCount == 0)
        #expect(pipeline.summarizer.titleCallCount == 1)
        #expect(recording.title == pipeline.summarizer.title)
        #expect(recording.titleNeedsGeneration == false)

        let folderName = try #require(recording.exportedFolderName)
        let exported = pipeline.exporter.folder
            .appending(path: folderName)
            .appending(path: ExportService.exportedTranscriptName)
        let rendered = try String(contentsOf: exported, encoding: .utf8)
        #expect(!rendered.contains("## Summary"))
        #expect(rendered.contains("## Transcript"))
    }

    @Test func audioOnlyPreferenceSkipsTranscriptionAndSummary() async throws {
        let pipeline = try Pipeline(contentPreference: .audioOnly)
        let recording = pipeline.insertRecording()

        await pipeline.coordinator.process(recording)

        #expect(recording.status == .done)
        #expect(recording.transcript == nil)
        #expect(recording.summary == nil)
        #expect(recording.title.hasPrefix(Recording.defaultTitlePrefix))
        #expect(pipeline.transcriber.transcribeCallCount == 0)
        #expect(pipeline.summarizer.summarizeCallCount == 0)
        #expect(pipeline.summarizer.titleCallCount == 0)
        #expect(pipeline.exporter.exportCallCount == 1)
    }

    @Test func transcriptsOnlyPreferenceDeletesAudioAfterProcessing() async throws {
        let pipeline = try Pipeline(contentPreference: .transcriptsOnly)
        let audioURL = Recording.audioDirectory.appending(path: "\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: audioURL)
        let recording = pipeline.insertRecording()
        recording.audioFileName = audioURL.lastPathComponent

        await pipeline.coordinator.process(recording)

        #expect(recording.status == .done)
        #expect(recording.transcript == "[00:00:00] \(pipeline.transcriber.transcript)")
        #expect(!FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)))
    }

    /// Re-processing an already-transcribed recording must leave its audio
    /// alone. `process()` runs again for a retry, a deferred export, and a
    /// speaker rename — and a recording made while the preference still said
    /// to keep audio would lose it to any of them. Renaming a speaker is not
    /// consent to delete a recording; Settings has an explicit bulk reclaim.
    @Test func reprocessingDoesNotDeleteAudioItDidNotJustTranscribe() async throws {
        let pipeline = try Pipeline(contentPreference: .transcriptsOnly)
        let audioURL = Recording.audioDirectory.appending(path: "\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: audioURL)
        let recording = pipeline.insertRecording(transcript: "[00:00:00] Already transcribed.")
        recording.audioFileName = audioURL.lastPathComponent

        await pipeline.coordinator.process(recording)

        #expect(recording.status == .done)
        #expect(FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)))
        try? FileManager.default.removeItem(at: audioURL)
    }

    @Test func disablingSummariesClearsPreviousSkippedReasonWithoutDeletingExistingSummary() async throws {
        let pipeline = try Pipeline(summariesEnabled: false)
        let recording = pipeline.insertRecording(
            transcript: "[00:00:00] Already transcribed.",
            summary: "- Existing summary.",
            status: .summarizing
        )
        recording.summarySkippedReason = "Turn on Apple Intelligence in Settings to get summaries."

        await pipeline.coordinator.process(recording)

        #expect(recording.status == .done)
        #expect(recording.summary == "- Existing summary.")
        #expect(recording.summarySkippedReason == nil)
        #expect(pipeline.summarizer.summarizeCallCount == 0)
        #expect(pipeline.summarizer.titleCallCount == 1)
        #expect(recording.title == pipeline.summarizer.title)
    }

    @Test func transcriptionFailureMarksFailedWithReason() async throws {
        let pipeline = try Pipeline()
        pipeline.transcriber.error = CocoaError(.fileReadNoSuchFile)
        let recording = pipeline.insertRecording()

        await pipeline.coordinator.process(recording)

        #expect(recording.status == .failed)
        #expect(recording.failureReason?.hasPrefix("Transcription failed:") == true)
        #expect(recording.transcript == nil)
        #expect(pipeline.exporter.exportCallCount == 0)
    }

    @Test func revokedFolderLeavesRecordingDoneWithExportPending() async throws {
        let pipeline = try Pipeline()
        pipeline.exporter.error = ExportService.ExportError.folderRevoked
        let recording = pipeline.insertRecording()

        await pipeline.coordinator.process(recording)

        #expect(recording.status == .done)
        #expect(recording.exportPending == true)
        #expect(recording.exportedFolderName == nil)
        #expect(recording.failureReason == nil)
        // The failed attempt must not burn a trial credit.
    }

    @Test func resumeSkipsTranscriptionWhenTranscriptExists() async throws {
        let pipeline = try Pipeline()
        let recording = pipeline.insertRecording(
            transcript: "[00:00:00] Already transcribed.",
            status: .transcribing
        )

        await pipeline.coordinator.process(recording)

        #expect(pipeline.transcriber.transcribeCallCount == 0)
        #expect(pipeline.summarizer.summarizeCallCount == 1)
        #expect(recording.status == .done)
        #expect(recording.transcript == "[00:00:00] Already transcribed.")
        #expect(recording.summary == pipeline.summarizer.summary)
        #expect(recording.title == pipeline.summarizer.title)
        #expect(recording.titleNeedsGeneration == false)
    }

    @Test func placeholderTitleGenerationDoesNotDependOnFormattedTitleMatch() async throws {
        let pipeline = try Pipeline()
        let recording = pipeline.insertRecording()
        recording.title = "Recording Jun 10, 2026, 15:04"

        await pipeline.coordinator.process(recording)

        #expect(recording.title == pipeline.summarizer.title)
        #expect(recording.titleNeedsGeneration == false)
    }

    @Test func customTitleIsNotOverwrittenByGeneratedTitle() async throws {
        let pipeline = try Pipeline()
        let recording = pipeline.insertRecording()
        recording.title = "Manual Client Debrief"
        recording.titleNeedsGeneration = false

        await pipeline.coordinator.process(recording)

        #expect(recording.title == "Manual Client Debrief")
        #expect(pipeline.summarizer.titleCallCount == 0)
    }

    @Test func inFlightManualRenameIsNotOverwrittenByGeneratedTitle() async throws {
        let pipeline = try Pipeline()
        let recording = pipeline.insertRecording()
        pipeline.summarizer.beforeReturningTitle = {
            recording.title = "Manual Client Debrief"
            recording.titleNeedsGeneration = false
        }

        await pipeline.coordinator.process(recording)

        #expect(recording.title == "Manual Client Debrief")
        #expect(recording.titleNeedsGeneration == false)
        #expect(pipeline.summarizer.titleCallCount == 1)
    }

    /// Each recording is its own folder, holding only what was kept.
    @Test func exportsAFolderContainingTranscriptAndAudio() async throws {
        let pipeline = try Pipeline(contentPreference: .audioAndTranscripts)
        let recording = pipeline.insertRecording()

        await pipeline.coordinator.process(recording)

        let folderName = try #require(recording.exportedFolderName)
        let folder = pipeline.exporter.folder.appending(path: folderName)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        #expect(contents.contains(ExportService.exportedTranscriptName))
    }

    /// Transcript-only keeps the audio out of the folder rather than leaving
    /// an empty slot for it.
    @Test func transcriptOnlyExportsNoAudioFile() async throws {
        let pipeline = try Pipeline(contentPreference: .transcriptsOnly)
        let recording = pipeline.insertRecording()

        await pipeline.coordinator.process(recording)

        let folderName = try #require(recording.exportedFolderName)
        let folder = pipeline.exporter.folder.appending(path: folderName)
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        #expect(contents.contains(ExportService.exportedTranscriptName))
        #expect(!contents.contains(ExportService.exportedAudioName))
    }

    @Test func reExportOverwritesInPlace() async throws {
        let pipeline = try Pipeline()
        let recording = pipeline.insertRecording()

        await pipeline.coordinator.process(recording)
        let firstFolderName = try #require(recording.exportedFolderName)

        await pipeline.coordinator.process(recording)

        #expect(pipeline.exporter.exportCallCount == 2)
        // Overwrites in place — no `-2` copy is minted.
        #expect(recording.exportedFolderName == firstFolderName)
        #expect(recording.status == .done)
    }

    @Test func unconfiguredExporterSkipsExportQuietly() async throws {
        let pipeline = try Pipeline()
        pipeline.exporter.isConfigured = false
        let recording = pipeline.insertRecording()

        await pipeline.coordinator.process(recording)

        #expect(recording.status == .done)
        #expect(recording.exportedFolderName == nil)
        #expect(pipeline.exporter.exportCallCount == 0)
    }
}
