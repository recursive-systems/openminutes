import Foundation
import Testing
@testable import OpenMinutes

@Suite("Transcript chunker")
struct ChunkerTests {

    /// ~2h of "[HH:MM:SS] line" transcript, ~166k chars.
    private static func syntheticTranscript() -> String {
        (0..<1800).map { i in
            let t = i * 4
            return String(format: "[%02d:%02d:%02d] ", t / 3600, (t % 3600) / 60, t % 60)
                + "Discussion point number \(i), covering roadmap items and follow-ups for the team."
        }.joined(separator: "\n")
    }

    @Test func twoHourTranscriptChunksWithinTarget() {
        let transcript = Self.syntheticTranscript()
        let chunks = SummaryService.chunk(transcript, target: SummaryService.chunkThreshold)

        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= SummaryService.chunkThreshold })
        // Cuts land on line boundaries: every chunk starts with a timestamp.
        #expect(chunks.allSatisfy { $0.hasPrefix("[") })
        // No content lost beyond boundary whitespace.
        let rejoined = chunks.joined(separator: "\n")
        #expect(rejoined.count >= transcript.count - chunks.count * 2)
    }

    @Test func shortTextPassesThrough() {
        #expect(SummaryService.chunk("hello", target: 8_000) == ["hello"])
    }

    @Test func separatorFreeTextHardCuts() {
        let sizes = SummaryService.chunk(String(repeating: "a", count: 20_000), target: 8_000)
            .map(\.count)
        #expect(sizes == [8_000, 8_000, 4_000])
    }

    @Test func sentenceBoundaryFallbackWhenNoNewlines() {
        let text = (0..<100).map { "Sentence \($0) has no newline at all." }
            .joined(separator: " ")
        let chunks = SummaryService.chunk(text, target: 800)
        #expect(chunks.allSatisfy { $0.count <= 800 })
        #expect(chunks.allSatisfy { $0.hasSuffix(".") })
    }

    @Test func whitespaceOnlyYieldsNothing() {
        #expect(SummaryService.chunk(String(repeating: " ", count: 20_000), target: 8_000).isEmpty)
    }
}
