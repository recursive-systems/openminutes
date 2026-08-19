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

    static let exportedTranscriptName = "transcript.md"
    static let exportedAudioName = "audio.m4a"

    /// Writes the recording's folder; returns the primary exported URL.
    /// Re-exports overwrite the previous folder rather than minting `-2`
    /// copies; fresh exports get a collision-safe name.
    @discardableResult
    func export(_ recording: Recording) async throws -> URL {
        let folder: URL
        let securityScoped: Bool
        if usesLocalFolder {
            guard let url = Self.localDocumentsURL() else {
                folderState = .needsRepick(lastKnownName: Self.localFolderDisplayName)
                throw ExportError.folderRevoked
            }
            folderState = .ready(name: Self.localFolderDisplayName)
            folder = url
            securityScoped = false
        } else if usesICloudContainer {
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
            folder = url
            securityScoped = false
        } else {
            folder = try beginFolderAccess()
            securityScoped = true
        }
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
                if FileManager.default.fileExists(atPath: actualURL.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: actualURL)
                }
                try FileManager.default.copyItem(at: source, to: actualURL)
            } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }
}
