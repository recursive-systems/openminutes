import Foundation

/// Seams over the pipeline stages so ProcessingCoordinator is testable on
/// simulator/CI — SpeechTranscriber assets, Foundation Models, and
/// security-scoped bookmarks only work on device. Production conformances
/// are the real services; everything stays on the main actor because
/// Recording (a SwiftData model) is not Sendable.

@MainActor
protocol Transcribing {
    /// Installs speech model assets for `locale` if needed; `onProgress`
    /// fires only when a download actually starts.
    func ensureAssetsInstalled(locale: Locale, onProgress: (Progress) -> Void) async throws
    /// Timed lines rather than rendered markdown: speaker attribution needs
    /// the spans, and rendering is a separate, pure step (TranscriptRenderer).
    /// `duration` is passed for stages that need the recording's length; the
    /// line spans themselves come from the engine, not from it.
    func transcribe(fileAt url: URL, locale: Locale, duration: TimeInterval) async throws -> [TimedLine]
}

/// Speaker diarization. Optional at every level: unavailable models, a
/// failed pass, or a user who never turned it on all produce a transcript
/// without speaker labels rather than no transcript.
@MainActor
protocol Diarizing {
    /// False when the models are not installed yet, so the pipeline can skip
    /// the stage instead of forcing a download mid-processing.
    var isReady: Bool { get }
    func ensureModelsInstalled(onProgress: (Progress) -> Void) async throws
    /// `enrolledOwner` seeds the clustering with the owner's voiceprint so
    /// their turns come back under `SpeakerIdentity.ownerID` instead of an
    /// arbitrary slot.
    func diarize(fileAt url: URL, enrolledOwner: [Float]?) async throws -> [SpeakerTurn]
    /// Voiceprint for the dominant speaker in a sample the owner recorded of
    /// themselves. Throws when the sample has no usable speech.
    func enrollmentEmbedding(fileAt url: URL) async throws -> [Float]
}

@MainActor
protocol Summarizing {
    func summarize(transcript: String) async throws -> String
    func title(transcript: String, summary: String?) async throws -> String
}

@MainActor
protocol Exporting {
    var isConfigured: Bool { get }
    @discardableResult
    func export(_ recording: Recording) async throws -> URL
}

/// Production transcription: TranscriptionAssets + TranscriptionService.
@MainActor
struct OnDeviceTranscriber: Transcribing {
    func ensureAssetsInstalled(locale: Locale, onProgress: (Progress) -> Void) async throws {
        try await TranscriptionAssets.ensureInstalled(for: locale, onProgress: onProgress)
    }

    func transcribe(fileAt url: URL, locale: Locale, duration: TimeInterval) async throws -> [TimedLine] {
        try await TranscriptionService().transcribe(fileAt: url, locale: locale).map { segment in
            TimedLine(
                start: segment.start,
                end: segment.end,
                text: segment.text,
                words: segment.tokens.map { TimedWord(text: $0.text, start: $0.start, end: $0.end) }
            )
        }
    }
}

extension SummaryService: Summarizing {}

extension ExportService: Exporting {}
