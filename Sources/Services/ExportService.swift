import Foundation
import SwiftUI

/// Writes finished recordings as markdown (plus optional audio copy) into a
/// user-chosen folder so any AI/agent can reach them. Access persists via a
/// security-scoped bookmark that is re-resolved on every export; when it
/// goes stale or gets revoked, `folderState` surfaces a re-pick state —
/// never a silent failure (build plan §2).
///
/// Writes go through NSFileCoordinator off the main actor: coordination
/// blocks while iCloud materializes dataless files.
@MainActor
@Observable
final class ExportService {

    enum FolderState: Equatable {
        case notConfigured
        case ready(name: String)
        case needsRepick(lastKnownName: String)
    }

    enum ExportError: Error, LocalizedError {
        case notConfigured
        case folderRevoked

        var errorDescription: String? {
            switch self {
            case .notConfigured: "No export folder chosen yet."
            case .folderRevoked: "The export folder is no longer accessible. Choose it again."
            }
        }
    }

    private static let bookmarkKey = "exportFolderBookmark"
    private static let folderNameKey = "exportFolderName"
    private static let destinationModeKey = "exportDestinationMode"   // "icloud" | "local" | "custom"
    /// User-visible names of the two app-owned destinations.
    static let iCloudFolderDisplayName = "iCloud Drive › OpenMinutes"
    static let localFolderDisplayName = "On My iPhone › OpenMinutes"

    private(set) var folderState: FolderState = .notConfigured
    /// Easy mode is offered only when the app has the iCloud Documents
    /// entitlement AND the user is signed into iCloud Drive. Resolved off
    /// the main actor at launch (the first ubiquity lookup can block).
    private(set) var iCloudAvailable = false

    init() {
        refreshFolderState()
        Task { [weak self] in
            let url = await Task.detached { Self.ubiquityDocumentsURL() }.value
            self?.iCloudAvailable = url != nil
        }
    }

    /// True when the easy-mode container is the active destination.
    var usesICloudContainer: Bool {
        UserDefaults.standard.string(forKey: Self.destinationModeKey) == "icloud"
    }

    /// True when the on-device Documents folder is the active destination.
    var usesLocalFolder: Bool {
        UserDefaults.standard.string(forKey: Self.destinationModeKey) == "local"
    }

    /// Both app-owned destinations are reached without a security scope.
    private var usesAppOwnedFolder: Bool { usesICloudContainer || usesLocalFolder }

    /// A destination exists (a custom folder may still need re-picking).
    var isConfigured: Bool {
        usesAppOwnedFolder || UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil
    }

    /// Live `transcript.md` is written only when there is somewhere to put it
    /// and the user asked to keep transcripts. Audio-only recordings skip it.
    var shouldStreamLiveTranscript: Bool {
        isConfigured && RecordingContentPreference.current.includesTranscript
    }

    private var lastKnownFolderName: String {
        UserDefaults.standard.string(forKey: Self.folderNameKey) ?? "export folder"
    }

    /// Easy mode (PRD C1): claim the app's own iCloud Drive container —
    /// shows up as "iCloud Drive/OpenMinutes" in Files, no picker, no
    /// bookmark, and a predictable home future Mac/MCP companions can find
    /// without configuration. Returns false when iCloud is unavailable.
    @discardableResult
    func useICloudContainer() async -> Bool {
        let url = await Task.detached { () -> URL? in
            guard let documents = Self.ubiquityDocumentsURL() else { return nil }
            try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            return documents
        }.value
        guard url != nil else {
            iCloudAvailable = false
            return false
        }
        UserDefaults.standard.set("icloud", forKey: Self.destinationModeKey)
        folderState = .ready(name: Self.iCloudFolderDisplayName)
        return true
    }

    /// The container's Documents folder ("iCloud Drive/OpenMinutes"); nil
    /// without the iCloud entitlement or a signed-in iCloud Drive account.
    nonisolated private static func ubiquityDocumentsURL() -> URL? {
        FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?
            .appending(path: "Documents")
    }

    /// Always-available destination (PRD C1): the app's own Documents
    /// folder, surfaced in Files as "On My iPhone › OpenMinutes" by
    /// UIFileSharingEnabled. No entitlement, no account, no picker — the
    /// fallback easy mode for anyone not on iCloud.
    func useLocalFolder() {
        UserDefaults.standard.set("local", forKey: Self.destinationModeKey)
        folderState = .ready(name: Self.localFolderDisplayName)
    }

    nonisolated private static func localDocumentsURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    func setFolder(_ url: URL) {
        UserDefaults.standard.set("custom", forKey: Self.destinationModeKey)
        guard url.startAccessingSecurityScopedResource() else {
            folderState = .needsRepick(lastKnownName: url.lastPathComponent)
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        // No options: iOS embeds the security scope in default bookmark data
        // (.minimalBookmark would strip it and break access after relaunch).
        guard let bookmark = try? url.bookmarkData() else {
            folderState = .needsRepick(lastKnownName: url.lastPathComponent)
            return
        }
        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        UserDefaults.standard.set(url.lastPathComponent, forKey: Self.folderNameKey)
        folderState = .ready(name: url.lastPathComponent)
    }

    func refreshFolderState() {
        if usesLocalFolder {
            folderState = .ready(name: Self.localFolderDisplayName)
            return
        }
        if usesICloudContainer {
            // Optimistic — demoted asynchronously if iCloud signed out.
            folderState = .ready(name: Self.iCloudFolderDisplayName)
            Task { [weak self] in
                let url = await Task.detached { Self.ubiquityDocumentsURL() }.value
                if url == nil {
                    self?.folderState = .needsRepick(lastKnownName: Self.iCloudFolderDisplayName)
                }
            }
            return
        }
        guard isConfigured else {
            folderState = .notConfigured
            return
        }
        if let url = try? beginFolderAccess() {
            url.stopAccessingSecurityScopedResource()
        }
    }

    nonisolated static let exportedTranscriptName = "transcript.md"
    nonisolated static let exportedAudioName = "audio.m4a"

    private struct LiveSession {
        let id: UUID
        let startedAt: Date
        let title: String
        let folderName: String
        let language: String?
    }

    private var liveSession: LiveSession?
    private var pendingLiveWrite: (lines: [TimedLine], elapsed: TimeInterval)?
    private var liveWriteTask: Task<Void, Never>?

    /// Folder name of the in-progress export, if a live session is open.
    var liveFolderName: String? { liveSession?.folderName }

    /// Creates the recording folder and an empty `transcript.md` marked
    /// `status: recording`. Best effort: a failure here cannot stop capture.
    func beginLiveSession(id: UUID, startedAt: Date) async {
        guard shouldStreamLiveTranscript, liveSession == nil else { return }
        let title = Recording.defaultTitle(for: startedAt)
        let language = TranscriptionLanguage.tag(for: TranscriptionLanguage.current())
        do {
            let (folder, securityScoped) = try await resolveDestination()
            defer { if securityScoped { folder.stopAccessingSecurityScopedResource() } }
            let folderName = try await Task.detached {
                try LiveExportWriter(root: folder).createSession(
                    title: title, recorded: startedAt, language: language)
            }.value
            liveSession = LiveSession(
                id: id, startedAt: startedAt, title: title,
                folderName: folderName, language: language)
        } catch {
            // Live export is disposable, same rule as the on-screen transcript.
        }
    }

    /// Coalesces rapid finalized-line updates into one rewrite a second.
    func scheduleLiveTranscriptWrite(lines: [TimedLine], elapsed: TimeInterval) {
        guard liveSession != nil else { return }
        pendingLiveWrite = (lines, elapsed)
        guard liveWriteTask == nil else { return }
        liveWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.flushLiveWrite()
        }
    }

    /// Last live rewrite (`status: processing`), optional audio copy, then
    /// stamps `exportedFolderName` so the pipeline overwrites this folder
    /// rather than minting a second one. Always sets the folder name when a
    /// session exists, even if the last write fails.
    func finishLiveSession(recording: Recording, lines: [TimedLine]) async {
        liveWriteTask?.cancel()
        liveWriteTask = nil
        pendingLiveWrite = nil
        guard let session = liveSession, session.id == recording.id else { return }
        recording.exportedFolderName = session.folderName

        let includeAudio = RecordingContentPreference.current.includesAudio
        if includeAudio {
            await copyLiveAudio(session: session, from: recording.audioURL)
        }
        await writeLive(
            session: session,
            lines: lines,
            elapsed: recording.duration,
            status: .processing,
            audioFileName: includeAudio ? Self.exportedAudioName : nil
        )
        liveSession = nil
    }

    /// Force-quit leaves `status: recording` on disk. Call on launch when
    /// nothing is capturing so agents stop waiting on a meeting that is over.
    func markAbandonedLiveTranscripts() async {
        guard isConfigured, liveSession == nil else { return }
        do {
            let (folder, securityScoped) = try await resolveDestination()
            defer { if securityScoped { folder.stopAccessingSecurityScopedResource() } }
            _ = try await Task.detached {
                try LiveExportWriter(root: folder).markAbandonedLiveTranscripts()
            }.value
        } catch {}
    }

    /// Writes the recording's folder; returns the primary exported URL.
    /// Re-exports overwrite the previous folder rather than minting `-2`
    /// copies; fresh exports get a collision-safe name.
    @discardableResult
    func export(_ recording: Recording) async throws -> URL {
        let (folder, securityScoped) = try await resolveDestination()
        defer { if securityScoped { folder.stopAccessingSecurityScopedResource() } }

        let preference = RecordingContentPreference.current

        // One folder per recording, so its transcript and audio stay together
        // rather than interleaving with every other recording's files. A
        // folder that holds only audio, only a transcript, or both is a
        // truthful picture of what was kept.
        let folderName: String
        let plan = ExportFilename.folderPlan(
            existingFolderName: recording.exportedFolderName,
            title: recording.title,
            recorded: recording.createdAt
        ) { candidate in
            FileManager.default.fileExists(
                atPath: folder.appending(path: candidate).path(percentEncoded: false))
        }
        switch plan {
        case .overwrite(let name), .create(let name):
            folderName = name
        case .move(let previous, let renamed):
            // The title changed since the last export (a late-generated title
            // or a manual rename): carry the folder to the new name so what
            // the user sees in Files matches the title. A failed move keeps
            // the old name rather than minting a duplicate folder.
            let source = folder.appending(path: previous, directoryHint: .isDirectory)
            let destination = folder.appending(path: renamed, directoryHint: .isDirectory)
            do {
                try await Task.detached {
                    try Self.coordinatedMove(from: source, to: destination)
                }.value
                folderName = renamed
            } catch {
                folderName = previous
            }
        }
        let recordingFolder = folder.appending(path: folderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true)

        // Fixed names inside the folder: the folder already carries the
        // title, and predictable paths let an agent glob `*/transcript.md`
        // across a whole library.
        if preference.includesAudio {
            let source = recording.audioURL
            let destination = recordingFolder.appending(path: Self.exportedAudioName)
            try await Task.detached {
                try Self.coordinatedCopy(from: source, to: destination)
            }.value
        }

        guard preference.includesTranscript else {
            return recordingFolder.appending(path: Self.exportedAudioName)
        }

        let document = MarkdownDocument(
            title: recording.title,
            recorded: recording.createdAt,
            duration: recording.duration,
            transcript: recording.transcript,
            summary: recording.summary,
            audioFileName: preference.includesAudio ? Self.exportedAudioName : nil,
            device: MarkdownDocument.currentDevice(),
            generator: MarkdownDocument.currentGenerator(),
            language: recording.transcriptLanguage,
            speakers: recording.speakerNames
        )

        let data = Data(document.rendered().utf8)
        let markdownURL = recordingFolder.appending(path: Self.exportedTranscriptName)
        try await Self.writeWithRetry(data, to: markdownURL)

        return markdownURL
    }

    // MARK: - Destination

    /// Resolves the active export root and begins security-scoped access when
    /// the destination is a user-picked folder. Caller must stop access on
    /// the URL when `securityScoped` is true.
    private func resolveDestination() async throws -> (folder: URL, securityScoped: Bool) {
        if usesLocalFolder {
            guard let url = Self.localDocumentsURL() else {
                folderState = .needsRepick(lastKnownName: Self.localFolderDisplayName)
                throw ExportError.folderRevoked
            }
            folderState = .ready(name: Self.localFolderDisplayName)
            return (url, false)
        }
        if usesICloudContainer {
            // No security scope: the container is the app's own. Resolution
            // happens off-main (the ubiquity lookup can block).
            guard let url = await Task.detached(operation: { () -> URL? in
                guard let documents = Self.ubiquityDocumentsURL() else { return nil }
                try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
                return documents
            }).value else {
                folderState = .needsRepick(lastKnownName: Self.iCloudFolderDisplayName)
                throw ExportError.folderRevoked
            }
            folderState = .ready(name: Self.iCloudFolderDisplayName)
            return (url, false)
        }
        return (try beginFolderAccess(), true)
    }

    private func flushLiveWrite() async {
        liveWriteTask = nil
        guard let session = liveSession, let pending = pendingLiveWrite else { return }
        pendingLiveWrite = nil
        await writeLive(
            session: session,
            lines: pending.lines,
            elapsed: pending.elapsed,
            status: .recording,
            audioFileName: nil
        )
        if pendingLiveWrite != nil, liveWriteTask == nil {
            liveWriteTask = Task { [weak self] in
                await self?.flushLiveWrite()
            }
        }
    }

    private func writeLive(
        session: LiveSession,
        lines: [TimedLine],
        elapsed: TimeInterval,
        status: LiveTranscriptStatus,
        audioFileName: String?
    ) async {
        let document = MarkdownDocument(
            title: session.title,
            recorded: session.startedAt,
            duration: elapsed,
            transcript: TranscriptRenderer.markdown(lines: lines),
            summary: nil,
            audioFileName: audioFileName,
            device: MarkdownDocument.currentDevice(),
            generator: MarkdownDocument.currentGenerator(),
            language: session.language,
            status: status
        )
        let data = Data(document.rendered().utf8)
        do {
            let (folder, securityScoped) = try await resolveDestination()
            defer { if securityScoped { folder.stopAccessingSecurityScopedResource() } }
            let url = folder.appending(path: session.folderName)
                .appending(path: Self.exportedTranscriptName)
            try await Self.writeWithRetry(data, to: url)
        } catch {
            // Best effort. The next finalized line, or finishLiveSession, retries.
        }
    }

    private func copyLiveAudio(session: LiveSession, from source: URL) async {
        do {
            let (folder, securityScoped) = try await resolveDestination()
            defer { if securityScoped { folder.stopAccessingSecurityScopedResource() } }
            let destination = folder.appending(path: session.folderName)
                .appending(path: Self.exportedAudioName)
            try await Task.detached {
                try Self.coordinatedCopy(from: source, to: destination)
            }.value
        } catch {}
    }

    // MARK: - Bookmark resolution

    /// Resolves the bookmark and begins security-scoped access; the caller
    /// must call `stopAccessingSecurityScopedResource()` on the result.
    /// Updates `folderState` as a side effect — resolution failure is how
    /// we discover revocation.
    private func beginFolderAccess() throws -> URL {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            folderState = .notConfigured
            throw ExportError.notConfigured
        }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
        } catch {
            folderState = .needsRepick(lastKnownName: lastKnownFolderName)
            throw ExportError.folderRevoked
        }
        guard url.startAccessingSecurityScopedResource() else {
            folderState = .needsRepick(lastKnownName: lastKnownFolderName)
            throw ExportError.folderRevoked
        }
        if stale, let fresh = try? url.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
        }
        folderState = .ready(name: url.lastPathComponent)
        return url
    }

    // MARK: - Coordinated IO (off the main actor)

    /// One retry on transient file-coordination failures (PRD reliability).
    private static func writeWithRetry(_ data: Data, to url: URL) async throws {
        do {
            try await Task.detached { try coordinatedWrite(data, to: url) }.value
        } catch {
            try await Task.sleep(for: .milliseconds(500))
            try await Task.detached { try coordinatedWrite(data, to: url) }.value
        }
    }

    nonisolated private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError
        ) { actualURL in
            do { try data.write(to: actualURL, options: .atomic) } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    nonisolated private static func coordinatedMove(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var moveError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: source, options: .forMoving,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { actualSource, actualDestination in
            do {
                try FileManager.default.moveItem(at: actualSource, to: actualDestination)
            } catch { moveError = error }
        }
        if let coordinationError { throw coordinationError }
        if let moveError { throw moveError }
    }

    nonisolated private static func coordinatedCopy(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: destination, options: .forReplacing, error: &coordinationError
        ) { actualURL in
            do {
                try LiveExportWriter.replaceFile(copying: source, to: actualURL)
            } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }
}
