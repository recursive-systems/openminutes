import Foundation
import FoundationModels

/// On-device summarization via Apple's Foundation Models framework.
/// Free, unlimited, offline — the reason this app can be pay-once.
///
/// Long transcripts (PRD B3) are handled by map-reduce: split at sentence
/// boundaries near `chunkThreshold` chars, summarize each chunk, then
/// summarize-the-summaries (recursively, so 2h recordings never hit a hard
/// length failure). The ~3B on-device model's context window is the reason
/// for the threshold; each request gets a fresh session so context never
/// accumulates across chunks.
///
/// WWDC26's LanguageModel protocol lets this same call route to Claude or
/// Gemini with the user's own key later (BYO-AI) — keep the abstraction thin.
struct SummaryService {

    static let chunkThreshold = 8_000

    enum SummaryError: Error, LocalizedError {
        case modelUnavailable(String)
        var errorDescription: String? {
            if case .modelUnavailable(let reason) = self { return reason }
            return nil
        }
    }

    private static let finalInstructions = """
        You summarize meeting and voice-note transcripts. Respond in markdown with:
        a 2-3 sentence summary, key decisions (if any), and action items with
        owners when identifiable. Be concise. If it's a short personal note,
        a one-paragraph summary is enough.
        """

    private static let chunkInstructions = """
        You summarize one part of a longer meeting transcript. Capture the key
        points, any decisions made, and any action items with owners, as short
        markdown bullets. Be concise; do not add introductions or conclusions —
        your output will be merged with summaries of the other parts.
        """

    private static let mergeInstructions = """
        You are given partial summaries of consecutive parts of one long meeting.
        Merge them into shorter combined notes: key points, decisions, action
        items with owners. Markdown bullets only, no introductions.
        """

    private static let titleInstructions = """
        You write short titles for meeting and voice-note transcripts. Respond
        with only a concise title, 2-6 words, no markdown, no quotes, no ending
        punctuation. Capture the specific subject, not the word "Recording".
        """

    func summarize(transcript: String) async throws -> String {
        try checkAvailability()

        if transcript.count <= Self.chunkThreshold {
            return try await respond(to: "Summarize this transcript:\n\n\(transcript)",
                                     instructions: Self.finalInstructions)
        }

        // Map: summarize each chunk independently.
        let chunks = Self.chunk(transcript, target: Self.chunkThreshold)
        var partials: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let partial = try await respond(
                to: "Part \(index + 1) of \(chunks.count):\n\n\(chunk)",
                instructions: Self.chunkInstructions
            )
            partials.append(partial)
        }

        // Reduce: merge partials, re-chunking while they still exceed the
        // window (a 2h meeting produces more partial text than one pass fits).
        var combined = partials.joined(separator: "\n\n")
        var rounds = 0
        while combined.count > Self.chunkThreshold && rounds < 3 {
            var merged: [String] = []
            for piece in Self.chunk(combined, target: Self.chunkThreshold) {
                merged.append(try await respond(to: piece, instructions: Self.mergeInstructions))
            }
            combined = merged.joined(separator: "\n\n")
            rounds += 1
        }

        return try await respond(
            to: "Combined notes from a long meeting:\n\n\(combined)",
            instructions: Self.finalInstructions
        )
    }

    func title(transcript: String, summary: String?) async throws -> String {
        try checkAvailability()

        let source: String
        if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = "Summary:\n\n\(summary)"
        } else {
            source = "Transcript:\n\n\(Self.chunk(transcript, target: Self.chunkThreshold).first ?? transcript)"
        }

        let rawTitle = try await respond(
            to: "Create a title for this recording:\n\n\(source)",
            instructions: Self.titleInstructions
        )
        return Self.cleanTitle(rawTitle)
    }

    private func checkAvailability() throws {
        let model = SystemLanguageModel.default
        if case .unavailable(let reason) = model.availability {
            throw SummaryError.modelUnavailable(Self.userCopy(for: reason))
        }
    }

    /// Distinct copy per unavailability reason (build plan §2: availability
    /// is not binary — never generically fail).
    static func userCopy(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            "This iPhone doesn't support Apple Intelligence, so summaries aren't available. Transcripts and export still work."
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence in Settings to get summaries."
        case .modelNotReady:
            "The on-device model is still downloading. Retry once it's ready, usually a few minutes on Wi-Fi."
        @unknown default:
            "On-device summaries are unavailable right now. Transcripts and export still work."
        }
    }

    private func respond(to prompt: String, instructions: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: prompt).content
    }

    /// Splits `text` into pieces of at most `target` characters, cutting at the
    /// last line break in range, else the last sentence terminator, else hard.
    static func chunk(_ text: String, target: Int) -> [String] {
        guard text.count > target else { return [text] }
        var chunks: [String] = []
        var remaining = Substring(text)
        while remaining.count > target {
            let window = remaining.prefix(target)
            let cut: Substring.Index
            if let newline = window.lastIndex(of: "\n"), newline > window.startIndex {
                cut = window.index(after: newline)
            } else if let sentenceEnd = window.lastIndex(where: { ".!?".contains($0) }) {
                cut = window.index(after: sentenceEnd)
            } else {
                cut = window.endIndex
            }
            chunks.append(String(remaining[..<cut]))
            remaining = remaining[cut...]
        }
        chunks.append(String(remaining))
        return chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func cleanTitle(_ title: String, maxLength: Int = 48) -> String {
        var cleaned = title
            .components(separatedBy: .newlines)
            .first ?? title
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasPrefix("title:") {
            cleaned = String(cleaned.dropFirst(6))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*_# "))
        cleaned = cleaned.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".:;,- "))

        guard !cleaned.isEmpty else { return "" }
        guard cleaned.count > maxLength else { return cleaned }

        let limit = cleaned.index(cleaned.startIndex, offsetBy: maxLength)
        let prefix = cleaned[..<limit]
        if let lastSpace = prefix.lastIndex(of: " ") {
            cleaned = String(prefix[..<lastSpace])
        } else {
            cleaned = String(prefix)
        }
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".:;,- "))
    }
}
