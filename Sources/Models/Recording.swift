import Foundation
import SwiftData

enum ProcessingStatus: String, Codable {
    case pending            // recorded, pipeline not started
    case downloadingAssets  // speech model downloading (first run / new locale)
    case transcribing
    case summarizing
    case exporting
    case done
    case failed

    var isUnfinished: Bool {
        switch self {
        case .pending, .downloadingAssets, .transcribing, .summarizing, .exporting: true
        case .done, .failed: false
        }
    }
}

@Model
final class Recording {
    static let defaultTitlePrefix = "Recording "

    @Attribute(.unique) var id: UUID
    var title: String
    /// File name within `audioDirectory`. Stored relative because the app
    /// sandbox container path changes between installs.
    var audioFileName: String
    var createdAt: Date
    var duration: TimeInterval
    var transcript: String?
    var summary: String?
    /// Why the summary was skipped (Foundation Models unavailable) — set so
    /// the user always gets an explanation, never a silent gap (PRD B2).
    var summarySkippedReason: String?
    /// Name of this recording's folder in the export destination. Each
    /// recording exports as a folder, so audio and transcript travel
    /// together instead of two loose files sorting apart in a shared list.
    var exportedFolderName: String?
    /// Processing finished but export couldn't run (folder revoked/needs
    /// re-pick); cleared by the next successful export.
    var exportPending: Bool = false
    /// True while the recording still has its placeholder title and should get
    /// one best-effort AI title after transcription. Cleared by generated
    /// titles and manual renames; unlike the visible title string, this is not
    /// sensitive to locale, timezone, or 12/24-hour clock changes.
    var titleNeedsGeneration: Bool = false
    /// BCP-47 tag of the locale the transcript was produced in, written to
    /// the exported file's `language` key. Nil for recordings made before
    /// language selection existed, and for audio-only recordings that never
    /// produced a transcript — the default satisfies SwiftData's lightweight
    /// migration for existing stores.
    var transcriptLanguage: String?
    /// Speaker ID → display name, for this recording only. Renaming
    /// "Speaker 2" to a real name annotates this file and nothing else: no
    /// voiceprint for anyone but the enrolled owner is ever persisted, so
    /// the app cannot recognise that person in a later recording. That is
    /// deliberate — see `VoiceEnrollment`.
    var speakerNames: [String: String] = [:]
    /// Timed lines with their speaker, kept so renaming a speaker can
    /// re-render the transcript without re-transcribing. `transcript` stays
    /// the rendered form everything else reads.
    var transcriptLines: [TranscriptLine] = []
    /// The opaque string another app passed in `openminutes://record?ref=`,
    /// written back unchanged as the exported file's `ref` key. The app never
    /// interprets it or shows it as anything but a reference. Nil for every
    /// recording nobody asked for, which also satisfies lightweight migration.
    var ref: String?
    private var statusRaw: String
    var failureReason: String?

    var status: ProcessingStatus {
        get { ProcessingStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var audioURL: URL { Self.audioDirectory.appending(path: audioFileName) }

    /// Application Support, not Documents. `UIFileSharingEnabled` exposes
    /// Documents in the Files app, and this is internal storage with opaque
    /// UUID names — showing it to users invites them to move or delete files
    /// the database still points at. Documents is for their exports.
    static var audioDirectory: URL {
        let support = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let dir = support.appending(path: "audio", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func defaultTitle(for date: Date) -> String {
        "\(defaultTitlePrefix)\(date.formatted(date: .abbreviated, time: .shortened))"
    }

    init(
        id: UUID = UUID(),
        title: String,
        audioFileName: String,
        createdAt: Date = .now,
        duration: TimeInterval,
        transcript: String? = nil,
        summary: String? = nil,
        exportedFolderName: String? = nil,
        titleNeedsGeneration: Bool = true,
        transcriptLanguage: String? = nil,
        speakerNames: [String: String] = [:],
        transcriptLines: [TranscriptLine] = [],
        ref: String? = nil,
        status: ProcessingStatus = .pending,
        failureReason: String? = nil
    ) {
        self.transcriptLanguage = transcriptLanguage
        self.speakerNames = speakerNames
        self.transcriptLines = transcriptLines
        self.ref = ref
        self.id = id
        self.title = title
        self.audioFileName = audioFileName
        self.createdAt = createdAt
        self.duration = duration
        self.transcript = transcript
        self.summary = summary
        self.exportedFolderName = exportedFolderName
        self.titleNeedsGeneration = titleNeedsGeneration
        self.statusRaw = status.rawValue
        self.failureReason = failureReason
    }
}
