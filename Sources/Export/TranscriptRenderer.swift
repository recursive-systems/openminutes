import Foundation

/// Renders timed transcript lines into the `## Transcript` body.
///
/// Display names go in the body, and the frontmatter `speakers` map repeats
/// the ID→name mapping. The redundancy is deliberate: these files are fed to
/// language models, and chunking for RAG routinely separates a body from its
/// frontmatter. A chunk reading "s1: …" has lost its meaning, so the body has
/// to stand alone. The map still says which ID is the owner and disambiguates
/// two speakers who share a display name.
enum TranscriptRenderer {

    static func markdown(
        lines: [TimedLine],
        speakerIDs: [String?] = [],
        names: [String: String] = [:]
    ) -> String {
        lines.enumerated().map { index, line in
            let id = index < speakerIDs.count ? speakerIDs[index] : nil
            let speaker = id.map { names[$0] ?? $0 }
            let text = line.text.trimmingCharacters(in: .whitespaces)
            // An unattributed line keeps the plain shape rather than gaining
            // an "unknown" label — absence of a speaker reads as unknown by
            // itself, and inventing a placeholder would imply a real speaker.
            guard let speaker else { return "\(timestamp(line.start)) \(text)" }
            return "\(timestamp(line.start)) \(speaker): \(text)"
        }.joined(separator: "\n")
    }

    /// Re-renders from stored lines — used after a speaker is renamed, so the
    /// transcript updates without transcribing again.
    static func markdown(lines: [TranscriptLine], names: [String: String]) -> String {
        markdown(
            lines: lines.map { TimedLine(start: $0.start, end: $0.end, text: $0.text) },
            speakerIDs: lines.map(\.speakerID),
            names: names
        )
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "[%02d:%02d:%02d]", total / 3600, (total % 3600) / 60, total % 60)
    }
}
