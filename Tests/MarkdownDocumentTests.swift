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
            id: "7c3a5b1e-2f4d-4e8a-9b6c-0d1e2f3a4b5c",
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
            ref: "abc123",
            timeZone: Self.chicago
        )
        let expected = """
        ---
        openminutes: 1
        spec: https://github.com/recursive-systems/openminutes/blob/main/FILE-FORMAT.md
        id: 7c3a5b1e-2f4d-4e8a-9b6c-0d1e2f3a4b5c
        title: Standup with platform team
        recorded: 2026-06-09T14:09:00-05:00
        duration: 1860
        device: iPhone17,1
        generator: OpenMinutes 1.0 (build 42)
        ref: abc123
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

    /// Both keys are optional in the format: a writer that has neither (an
    /// older build, another app) produces a file without them, not empty ones.
    @Test func idAndRefOmittedWhenAbsent() {
        let doc = MarkdownDocument(
            title: "Note", recorded: Self.fixedDate(), duration: 60,
            transcript: "[00:00:00] Hi.", summary: nil, audioFileName: nil,
            device: "x", generator: "y", timeZone: Self.chicago
        )
        #expect(!doc.rendered().contains("\nid:"))
        #expect(!doc.rendered().contains("\nref:"))
    }

    /// `ref` is described by what the caller sent, so it is written even on
    /// an audio-only file, unlike the keys that describe the transcript.
    @Test func refWrittenOnAudioOnlyFiles() {
        let doc = MarkdownDocument(
            title: "Note", recorded: Self.fixedDate(), duration: 60,
            transcript: nil, summary: nil, audioFileName: "audio.m4a",
            device: "x", generator: "y", ref: "abc", timeZone: Self.chicago
        )
        #expect(doc.rendered().contains("\nref: abc\n"))
    }

    @Test func documentForARecordingCarriesItsIdTitleAndRef() throws {
        let id = try #require(UUID(uuidString: "7C3A5B1E-2F4D-4E8A-9B6C-0D1E2F3A4B5C"))
        let recording = Recording(
            id: id, title: "Coffee", audioFileName: "coffee.m4a",
            createdAt: Self.fixedDate(), duration: 60, transcript: "[00:00:00] Hi.",
            titleNeedsGeneration: false, transcriptLanguage: "en-US", ref: "abc"
        )
        let doc = MarkdownDocument(recording: recording, audioFileName: nil, device: "x", generator: "y")
        #expect(doc.id == "7c3a5b1e-2f4d-4e8a-9b6c-0d1e2f3a4b5c")
        #expect(doc.title == "Coffee")
        #expect(doc.ref == "abc")
        #expect(doc.language == "en-US")
        let rendered = doc.rendered()
        #expect(rendered.contains("\nid: 7c3a5b1e-2f4d-4e8a-9b6c-0d1e2f3a4b5c\n"))
        #expect(rendered.contains("\ntitle: Coffee\n"))
        #expect(rendered.contains("\nref: abc\n"))
    }

    /// The ref must come back from a YAML parser as the same string, so any
    /// value a parser would read as a number, boolean, null or date is quoted.
    @Test func valuesAParserWouldRetypeAreQuoted() {
        for value in ["123", "-7", "0x1F", "0o17", "1e3", "3.14", ".5", ".inf", "-.Inf", ".NaN",
                      "true", "False", "yes", "No", "on", "OFF", "y", "~", "null", "NULL",
                      "2026-06-09", "=", "<<", "?", ",x", "]"] {
            #expect(MarkdownDocument.yamlValue(value) == "\"\(value)\"", "\(value)")
        }
        for value in ["abc", "Coffee", "7c3a5b1e-2f4d-4e8a-9b6c-0d1e2f3a4b5c", "1.2.3",
                      "2026-06-09 standup", "Nobody", "123abc", "iPhone17,1"] {
            #expect(MarkdownDocument.yamlValue(value) == value, "\(value)")
        }
    }

    @Test func tabsAndCarriageReturnsAreEscapedInsideQuotes() {
        #expect(MarkdownDocument.yamlValue("a\tb") == "\"a\\tb\"")
        #expect(MarkdownDocument.yamlValue("a\rb") == "\"a\\rb\"")
    }

    /// FILE-FORMAT.schema.json is published for other writers and checkers,
    /// so it must describe every key this writer emits, and require exactly
    /// the keys the spec calls required. Read from the source tree, which the
    /// simulator can see.
    @Test func schemaDescribesEveryKeyTheWriterEmits() throws {
        let schemaURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "FILE-FORMAT.schema.json")
        let data = try Data(contentsOf: schemaURL)
        let schema = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let required = try #require(schema["required"] as? [String])

        let doc = MarkdownDocument(
            id: "7c3a5b1e-2f4d-4e8a-9b6c-0d1e2f3a4b5c",
            title: "Everything", recorded: Self.fixedDate(), duration: 60,
            transcript: "[00:00:00] Hi.", summary: "Sum.", audioFileName: "audio.m4a",
            device: "x", generator: "y", language: "en-US", speakers: ["s1": "A"],
            ref: "abc", timeZone: Self.chicago
        )
        let frontmatter = doc.rendered()
            .components(separatedBy: "---\n")[1]
            .split(separator: "\n")
        let emitted = Set(frontmatter
            .filter { !$0.hasPrefix(" ") }
            .compactMap { $0.split(separator: ":", maxSplits: 1).first.map(String.init) })

        #expect(emitted == Set(properties.keys))
        #expect(Set(required) == ["openminutes", "title", "recorded", "duration", "device", "generator"])
        let version = try #require(properties["openminutes"] as? [String: Any])
        #expect(version["const"] as? Int == MarkdownDocument.formatVersion)
        let ref = try #require(properties["ref"] as? [String: Any])
        #expect(ref["maxLength"] as? Int == RecordRequest.maxRefLength)
    }
}
