import Foundation

/// Writes the in-progress `transcript.md` into a recording folder, and
/// overwrites that same file as the body grows.
///
/// The contract is one path per recording. Creates and atomic replaces only.
/// Never deletes `transcript.md` first, and never mints a second transcript
/// next to it. Coordination (iCloud, security scope) is the caller's job:
/// this type talks to a directory it can already write.
struct LiveExportWriter: Sendable {
    let root: URL

    /// Collision-safe folder for a new live session, with an empty
    /// `transcript.md` already in it so a reader can glob the file the
    /// moment recording starts.
    func createSession(
        title: String,
        recorded: Date,
        timeZone: TimeZone = .current,
        language: String? = nil
    ) throws -> String {
        let plan = ExportFilename.folderPlan(
            existingFolderName: nil,
            title: title,
            recorded: recorded,
            timeZone: timeZone
        ) { candidate in
            FileManager.default.fileExists(
                atPath: root.appending(path: candidate).path(percentEncoded: false))
        }
        let folderName: String
        switch plan {
        case .create(let name), .overwrite(let name):
            folderName = name
        case .move(_, let name):
            folderName = name
        }
        let folder = root.appending(path: folderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(
            folderName: folderName,
            title: title,
            recorded: recorded,
            duration: 0,
            lines: [],
            status: .recording,
            language: language,
            audioFileName: nil,
            timeZone: timeZone
        )
        return folderName
    }

    /// Atomically replaces `transcript.md` in `folderName`. The file already
    /// exists after `createSession`; this is a rename-over, not a delete.
    func write(
        folderName: String,
        title: String,
        recorded: Date,
        duration: TimeInterval,
        lines: [TimedLine],
        status: LiveTranscriptStatus,
        language: String?,
        audioFileName: String?,
        timeZone: TimeZone = .current,
        device: String = MarkdownDocument.currentDevice(),
        generator: String = MarkdownDocument.currentGenerator()
    ) throws {
        let document = MarkdownDocument(
            title: title,
            recorded: recorded,
            duration: duration,
            transcript: TranscriptRenderer.markdown(lines: lines),
            summary: nil,
            audioFileName: audioFileName,
            device: device,
            generator: generator,
            language: language,
            status: status,
            timeZone: timeZone
        )
        let url = transcriptURL(folderName: folderName)
        try Data(document.rendered().utf8).write(to: url, options: .atomic)
    }

    /// Copies `source` onto `audio.m4a` without removing the destination
    /// first. A reader that already opened the live folder never sees the
    /// audio file vanish.
    func replaceAudio(folderName: String, from source: URL) throws {
        let destination = root.appending(path: folderName)
            .appending(path: ExportService.exportedAudioName)
        try Self.replaceFile(copying: source, to: destination)
    }

    /// Rewrite any `status: recording` file in `root` to `interrupted`.
    /// Call on launch when nothing is currently recording, so a force-quit
    /// does not leave agents waiting on a meeting that is not happening.
    @discardableResult
    func markAbandonedLiveTranscripts() throws -> Int {
        let folders = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var count = 0
        for folder in folders {
            let isDirectory = (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            let url = folder.appending(path: ExportService.exportedTranscriptName)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let updated = MarkdownDocument.replacingStatus(
                    in: text, from: .recording, to: .interrupted)
            else { continue }
            try Data(updated.utf8).write(to: url, options: .atomic)
            count += 1
        }
        return count
    }

    func transcriptURL(folderName: String) -> URL {
        root.appending(path: folderName)
            .appending(path: ExportService.exportedTranscriptName)
    }

    /// Copy to a sibling temp, then swap. If the destination does not exist
    /// yet, the temp is moved into place. Either way the destination is never
    /// deleted before the new bytes are on disk.
    static func replaceFile(copying source: URL, to destination: URL) throws {
        let temp = destination
            .deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try FileManager.default.copyItem(at: source, to: temp)
            if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}
