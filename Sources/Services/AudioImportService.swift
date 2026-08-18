import AVFAudio
import Foundation

/// Copies an externally supplied M4A into app-owned storage and turns it into
/// the same pending Recording produced by RecorderService. The source may be a
/// short-lived security-scoped URL from Files or another app, so the copy must
/// finish before this method returns.
@MainActor
@Observable
final class AudioImportService {
    enum ImportError: Error, LocalizedError {
        case unsupportedFormat
        case unreadableFile
        case emptyRecording

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                "OpenMinutes can currently import M4A audio recordings."
            case .unreadableFile:
                "OpenMinutes couldn't read this audio recording."
            case .emptyRecording:
                "This audio recording is empty."
            }
        }
    }

    private(set) var activeImportCount = 0
    var isImporting: Bool { activeImportCount > 0 }

    private let audioDirectory: URL

    init(audioDirectory: URL = Recording.audioDirectory) {
        self.audioDirectory = audioDirectory
    }

    func importRecording(from sourceURL: URL, importedAt: Date = .now) async throws -> Recording {
        guard sourceURL.isFileURL,
              sourceURL.pathExtension.caseInsensitiveCompare("m4a") == .orderedSame else {
            throw ImportError.unsupportedFormat
        }

        activeImportCount += 1
        defer { activeImportCount -= 1 }

        let id = UUID()
        let destinationURL = audioDirectory.appending(path: "\(id.uuidString).m4a")
        let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { sourceURL.stopAccessingSecurityScopedResource() }
        }

        do {
            let duration = try await Task.detached {
                try Self.copyAndInspect(from: sourceURL, to: destinationURL)
            }.value

            return Recording(
                id: id,
                title: Recording.defaultTitle(for: importedAt),
                audioFileName: destinationURL.lastPathComponent,
                createdAt: importedAt,
                duration: duration
            )
        } catch let error as ImportError {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw ImportError.unreadableFile
        }
    }

    nonisolated private static func copyAndInspect(from sourceURL: URL, to destinationURL: URL) throws -> TimeInterval {
        var coordinationError: NSError?
        var operationResult: Result<TimeInterval, Error>?

        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: sourceURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            operationResult = Result {
                try FileManager.default.copyItem(at: coordinatedURL, to: destinationURL)
                let audioFile = try AVAudioFile(forReading: destinationURL)
                let sampleRate = audioFile.processingFormat.sampleRate
                guard audioFile.length > 0, sampleRate > 0 else {
                    throw ImportError.emptyRecording
                }
                let duration = TimeInterval(audioFile.length) / sampleRate
                guard duration.isFinite, duration > 0 else {
                    throw ImportError.emptyRecording
                }
                return duration
            }
        }

        if let coordinationError { throw coordinationError }
        guard let operationResult else { throw ImportError.unreadableFile }
        return try operationResult.get()
    }
}
