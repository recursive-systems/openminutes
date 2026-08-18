import AVFAudio
import Foundation
import Testing
@testable import OpenMinutes

@MainActor
@Suite("Audio import")
struct AudioImportServiceTests {
    @Test func validM4ABecomesANormalPendingRecording() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let sourceURL = harness.sourceDirectory.appending(path: "Call Recording.m4a")
        try Self.writeM4A(to: sourceURL, duration: 0.2)

        let importedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let recording = try await harness.importer.importRecording(
            from: sourceURL,
            importedAt: importedAt
        )

        #expect(recording.status == .pending)
        #expect(recording.createdAt == importedAt)
        #expect(recording.title == Recording.defaultTitle(for: importedAt))
        #expect(recording.titleNeedsGeneration)
        #expect(recording.transcript == nil)
        #expect(recording.summary == nil)
        #expect(recording.audioFileName.hasSuffix(".m4a"))
        let copiedURL = harness.destinationDirectory.appending(path: recording.audioFileName)
        #expect(FileManager.default.fileExists(atPath: copiedURL.path(percentEncoded: false)))
        #expect(abs(recording.duration - 0.2) < 0.02)
        #expect(harness.importer.isImporting == false)
    }

    @Test func importedCopySurvivesSourceDeletion() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let sourceURL = harness.sourceDirectory.appending(path: "Saved Call.m4a")
        try Self.writeM4A(to: sourceURL, duration: 0.1)

        let recording = try await harness.importer.importRecording(from: sourceURL)
        try FileManager.default.removeItem(at: sourceURL)
        let copiedURL = harness.destinationDirectory.appending(path: recording.audioFileName)

        #expect(FileManager.default.fileExists(atPath: copiedURL.path(percentEncoded: false)))
        let copiedAudio = try AVAudioFile(forReading: copiedURL)
        #expect(copiedAudio.length > 0)
    }

    @Test func corruptAudioIsRejectedWithoutLeavingAnOrphan() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let sourceURL = harness.sourceDirectory.appending(path: "Broken.m4a")
        try Data("not audio".utf8).write(to: sourceURL)

        await #expect(throws: AudioImportService.ImportError.self) {
            _ = try await harness.importer.importRecording(from: sourceURL)
        }

        let destinationFiles = try FileManager.default.contentsOfDirectory(
            at: harness.destinationDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(destinationFiles.isEmpty)
        #expect(harness.importer.isImporting == false)
    }

    @Test func nonM4AFileIsRejectedBeforeCopying() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let sourceURL = harness.sourceDirectory.appending(path: "Call Recording.mp3")
        try Data("audio".utf8).write(to: sourceURL)

        await #expect(throws: AudioImportService.ImportError.self) {
            _ = try await harness.importer.importRecording(from: sourceURL)
        }

        let destinationFiles = try FileManager.default.contentsOfDirectory(
            at: harness.destinationDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(destinationFiles.isEmpty)
    }

    private static func writeM4A(to url: URL, duration: TimeInterval) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let frameCount = AVAudioFrameCount(16_000 * duration)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        try file.write(from: buffer)
    }

    private struct Harness {
        let root: URL
        let sourceDirectory: URL
        let destinationDirectory: URL
        let importer: AudioImportService

        @MainActor
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "audio-import-test-\(UUID().uuidString)", directoryHint: .isDirectory)
            sourceDirectory = root.appending(path: "source", directoryHint: .isDirectory)
            destinationDirectory = root.appending(path: "destination", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            importer = AudioImportService(audioDirectory: destinationDirectory)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
