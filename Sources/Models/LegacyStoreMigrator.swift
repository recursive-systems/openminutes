import Foundation
import SwiftData

/// One-time migration from the prototype's JSON-file persistence
/// (Documents/recordings.json) into SwiftData.
enum LegacyStoreMigrator {

    /// Shape of the prototype's Codable Recording struct.
    private struct LegacyRecording: Codable {
        let id: UUID
        var title: String
        var audioURL: URL
        var createdAt: Date
        var duration: TimeInterval
        var transcript: String?
        var summary: String?
        var exportedMarkdownURL: URL?
    }

    private static var legacyIndexURL: URL {
        URL.documentsDirectory.appending(path: "recordings.json")
    }

    @MainActor
    static func migrateIfNeeded(into context: ModelContext) {
        guard let data = try? Data(contentsOf: legacyIndexURL),
              let legacy = try? JSONDecoder().decode([LegacyRecording].self, from: data)
        else { return }

        for old in legacy {
            relocateAudio(named: old.audioURL.lastPathComponent, legacy: old.audioURL)
            let recording = Recording(
                id: old.id,
                title: old.title,
                audioFileName: old.audioURL.lastPathComponent,
                createdAt: old.createdAt,
                duration: old.duration,
                transcript: old.transcript,
                summary: old.summary,
                // The prototype wrote loose files; there is no folder to point at.
                exportedFolderName: nil,
                titleNeedsGeneration: false,
                // Untranscribed legacy recordings re-enter the pipeline via
                // resume-on-launch; transcribed ones are considered finished.
                status: old.transcript == nil ? .pending : .done
            )
            context.insert(recording)
        }

        guard (try? context.save()) != nil else { return }

        // Keep the original around (renamed) rather than deleting user data.
        let retired = legacyIndexURL.appendingPathExtension("migrated")
        try? FileManager.default.removeItem(at: retired)
        try? FileManager.default.moveItem(at: legacyIndexURL, to: retired)
    }

    /// Moves a prototype recording's audio into the directory `Recording`
    /// now resolves against.
    ///
    /// Only the file *name* survives migration, and audio has since moved
    /// from Documents into Application Support — so a migrated row would
    /// otherwise point at a path with nothing in it, and the recording would
    /// look present in the list while being gone. The stored URL is tried
    /// first but cannot be trusted on its own: it is absolute, and the
    /// sandbox container path changes on every reinstall.
    private static func relocateAudio(named name: String, legacy: URL) {
        let manager = FileManager.default
        let destination = Recording.audioDirectory.appending(path: name)
        guard !manager.fileExists(atPath: destination.path(percentEncoded: false)) else { return }

        let candidates = [
            legacy,
            URL.documentsDirectory.appending(path: name),
            URL.documentsDirectory.appending(path: "audio").appending(path: name),
        ]
        guard let source = candidates.first(where: {
            manager.fileExists(atPath: $0.path(percentEncoded: false))
        }) else { return }
        try? manager.moveItem(at: source, to: destination)
    }
}
