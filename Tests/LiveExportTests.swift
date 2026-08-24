import Foundation
import Testing
@testable import OpenMinutes

@Suite("Live export writer")
struct LiveExportWriterTests {

    private func makeWriter() throws -> (LiveExportWriter, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "live-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (LiveExportWriter(root: root), root)
    }

    @Test func createThenOverwriteLeavesExactlyOneTranscript() throws {
        let (writer, root) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorded = Date()
        let folderName = try writer.createSession(title: "Recording", recorded: recorded)
        let url = writer.transcriptURL(folderName: folderName)
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        let first = try String(contentsOf: url, encoding: .utf8)
        #expect(first.contains("status: recording"))
        #expect(first.contains("## Transcript"))

        try writer.write(
            folderName: folderName, title: "Recording", recorded: recorded,
            duration: 12,
            lines: [TimedLine(start: 4, end: 10, text: "Let's take the migration this week.")],
            status: .recording, language: "en-US", audioFileName: nil
        )
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        let second = try String(contentsOf: url, encoding: .utf8)
        #expect(second.contains("[00:00:04] Let's take the migration this week."))
        #expect(second.contains("status: recording"))
        #expect(!second.contains("## Summary"))

        try writer.write(
            folderName: folderName, title: "Recording", recorded: recorded,
            duration: 90,
            lines: [TimedLine(start: 4, end: 10, text: "Let's take the migration this week.")],
            status: .processing, language: "en-US", audioFileName: "audio.m4a"
        )
        let third = try String(contentsOf: url, encoding: .utf8)
        #expect(third.contains("status: processing"))
        #expect(third.contains("audio: audio.m4a"))

        let contents = try FileManager.default.contentsOfDirectory(
            atPath: root.appending(path: folderName).path(percentEncoded: false))
        #expect(contents.filter { $0.hasSuffix(".md") } == [ExportService.exportedTranscriptName])
        let folders = try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
        #expect(folders == [folderName])
    }

    @Test func markAbandonedRewritesRecordingStatusOnly() throws {
        let (writer, root) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorded = Date()
        let liveName = try writer.createSession(title: "Live", recorded: recorded)
        try writer.write(
            folderName: liveName, title: "Live", recorded: recorded, duration: 20,
            lines: [TimedLine(start: 0, end: 4, text: "The status: recording of this meeting is live.")],
            status: .recording, language: nil, audioFileName: nil
        )

        let processingName = try writer.createSession(title: "Processing", recorded: recorded)
        try writer.write(
            folderName: processingName, title: "Processing", recorded: recorded, duration: 20,
            lines: [TimedLine(start: 0, end: 1, text: "Hi.")],
            status: .processing, language: nil, audioFileName: nil
        )

        let finishedFolder = root.appending(path: "finished", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: finishedFolder, withIntermediateDirectories: true)
        let finished = MarkdownDocument(
            title: "Finished", recorded: recorded, duration: 20,
            transcript: "[00:00:00] Done.", summary: "- Done.",
            audioFileName: nil, device: "x", generator: "y"
        )
        try Data(finished.rendered().utf8).write(
            to: finishedFolder.appending(path: ExportService.exportedTranscriptName),
            options: .atomic)

        #expect(try writer.markAbandonedLiveTranscripts() == 1)

        let live = try String(
            contentsOf: writer.transcriptURL(folderName: liveName), encoding: .utf8)
        #expect(live.contains("status: interrupted\n"))
        #expect(live.contains("The status: recording of this meeting is live."))
        #expect(!live.contains("status: recording\n"))

        let processing = try String(
            contentsOf: writer.transcriptURL(folderName: processingName), encoding: .utf8)
        #expect(processing.contains("status: processing\n"))

        let done = try String(
            contentsOf: finishedFolder.appending(path: ExportService.exportedTranscriptName),
            encoding: .utf8)
        #expect(!done.contains("status:"))
    }

    @Test func replaceAudioNeverDeletesFirst() throws {
        let (writer, root) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorded = Date()
        let folderName = try writer.createSession(title: "Recording", recorded: recorded)

        let source1 = root.appending(path: "src1.m4a")
        let source2 = root.appending(path: "src2.m4a")
        try Data("one".utf8).write(to: source1)
        try Data("two".utf8).write(to: source2)

        try writer.replaceAudio(folderName: folderName, from: source1)
        let audio = root.appending(path: folderName).appending(path: ExportService.exportedAudioName)
        #expect(try String(contentsOf: audio, encoding: .utf8) == "one")
        #expect(FileManager.default.fileExists(
            atPath: writer.transcriptURL(folderName: folderName).path(percentEncoded: false)))

        try writer.replaceAudio(folderName: folderName, from: source2)
        #expect(try String(contentsOf: audio, encoding: .utf8) == "two")
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: root.appending(path: folderName).path(percentEncoded: false))
        #expect(contents.contains(ExportService.exportedAudioName))
        #expect(contents.contains(ExportService.exportedTranscriptName))
        #expect(contents.filter { $0.hasPrefix(".audio") || $0.hasSuffix(".tmp") }.isEmpty)
    }
}
