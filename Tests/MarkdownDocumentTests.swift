import Foundation
import Testing
@testable import OpenMinutes

@Suite("Markdown file format (public contract)")
struct MarkdownDocumentTests {

    private static let chicago = TimeZone(identifier: "America/Chicago")!

    /// 2026-06-09 14:09:00 in America/Chicago (CDT, UTC-5).
    private static func fixedDate() -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 6; components.day = 9
        components.hour = 14; components.minute = 9; components.second = 0
        components.timeZone = chicago
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test func rendersSpecExampleExactly() {
        let doc = MarkdownDocument(
            title: "Standup with platform team",
            recorded: Self.fixedDate(),
            duration: 1860,
            transcript: "[00:00:00] Good morning everyone.",
            summary: "- Shipped the build.",
            audioFileName: nil,
            device: "iPhone17,1",
            generator: "OpenMinutes 1.0 (build 42)",
            language: "en-US",
            speakers: ["s1": "Bradley Golden", "s2": "Speaker 2"],
            timeZone: Self.chicago
        )
        let expected = """
        ---
        openminutes: 1
        spec: https://github.com/recursive-systems/openminutes/blob/main/FILE-FORMAT.md
        title: Standup with platform team
        recorded: 2026-06-09T14:09:00-05:00
        duration: 1860
        device: iPhone17,1
        generator: OpenMinutes 1.0 (build 42)
        language: en-US
        speakers:
          s1: Bradley Golden
          s2: Speaker 2
        ---

        ## Summary

        - Shipped the build.

        ## Transcript

        [00:00:00] Good morning everyone.

        """
        #expect(doc.rendered() == expected)
    }

    /// `language` describes the transcript, so it must not appear on an
    /// audio-only file where there is no transcript to describe.
    @Test func languageKeyOmittedWithoutTranscript() {
        let doc = MarkdownDocument(
            title: "Note", recorded: Self.fixedDate(), duration: 60,
            transcript: nil, summary: nil, audioFileName: "note.m4a",
            device: "iPhone17,1", generator: "OpenMinutes 1.0 (build 42)",
            language: "en-US", timeZone: Self.chicago
        )
        #expect(!doc.rendered().contains("language:"))
    }

    /// Recordings made before language selection existed carry no tag; the
    /// key is simply absent rather than written empty.
    @Test func languageKeyOmittedWhenUnknown() {
        let doc = MarkdownDocument(
            title: "Note", recorded: Self.fixedDate(), duration: 60,
            transcript: "[00:00:00] Hi.", summary: nil, audioFileName: nil,
            device: "iPhone17,1", generator: "OpenMinutes 1.0 (build 42)",
            language: nil, timeZone: Self.chicago
        )
        #expect(!doc.rendered().contains("language:"))
    }

    /// Speaker names describe the transcript, so they must not appear on an
    /// audio-only file — same rule as `language`.
    @Test func speakersOmittedWithoutTranscript() {
        let doc = MarkdownDocument(
            title: "Note", recorded: Self.fixedDate(), duration: 60,
            transcript: nil, summary: nil, audioFileName: "note.m4a",
            device: "iPhone17,1", generator: "OpenMinutes 1.0 (build 42)",
            language: "en-US", speakers: ["s1": "Bradley"], timeZone: Self.chicago
        )
        #expect(!doc.rendered().contains("speakers:"))
    }

    @Test func audioKeyAppearsOnlyWhenSet() {
        var doc = MarkdownDocument(
            title: "Note", recorded: Self.fixedDate(), duration: 60,
            transcript: "[00:00:00] Hi.", summary: nil, audioFileName: nil,
            device: "iPhone17,1", generator: "OpenMinutes 1.0 (build 42)",
            timeZone: Self.chicago
        )
        #expect(!doc.rendered().contains("audio:"))

        doc.audioFileName = "2026-06-09-1409 note.m4a"
        #expect(doc.rendered().contains("audio: 2026-06-09-1409 note.m4a"))
    }

    @Test func summarySectionOmittedWhenNil() {
        let doc = MarkdownDocument(
            title: "Note", recorded: Self.fixedDate(), duration: 60,
            transcript: "[00:00:00] Hi.", summary: nil, audioFileName: nil,
            device: "x", generator: "y", timeZone: Self.chicago
        )
        let output = doc.rendered()
        #expect(!output.contains("## Summary"))
        #expect(output.contains("## Transcript"))
    }

    @Test func durationIsBareRoundedInteger() {
        let doc = MarkdownDocument(
            title: "Note", recorded: Self.fixedDate(), duration: 1860.6,
            transcript: nil, summary: nil, audioFileName: nil,
            device: "x", generator: "y", timeZone: Self.chicago
        )
        #expect(doc.rendered().contains("duration: 1861\n"))
        #expect(!doc.rendered().contains("1861s"))
    }

    @Test func titleWithColonGetsQuoted() {
        #expect(MarkdownDocument.yamlValue("Sync: roadmap") == "\"Sync: roadmap\"")
        #expect(MarkdownDocument.yamlValue("Plain title") == "Plain title")
        #expect(MarkdownDocument.yamlValue("Quote \"this\"") == "\"Quote \\\"this\\\"\"")
        #expect(MarkdownDocument.yamlValue("") == "\"\"")
    }

    @Test func recordedUsesLocalUTCOffset() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let stamp = MarkdownDocument.iso8601(Self.fixedDate(), timeZone: tokyo)
        // 14:09 CDT == 04:09 next day JST
        #expect(stamp == "2026-06-10T04:09:00+09:00")
    }
}
