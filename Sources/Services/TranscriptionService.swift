import AVFoundation
import Foundation
import Speech

/// On-device transcription via SpeechAnalyzer/SpeechTranscriber (iOS 26+).
/// No network, no API key, benchmarks faster than Whisper Large V3 Turbo.
///
/// NOTE: SpeechAnalyzer API surface is new (WWDC25, revised WWDC26) — if a
/// signature drifts in the current SDK, Xcode's fix-its + the WWDC25 session
/// "Bring advanced speech-to-text to your app" (session 277) are the reference.
struct TranscriptionService {

    /// One token (usually a word) with the range the engine reports for it.
    struct Token {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    struct Segment {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        /// Empty only when the engine reported no time ranges at all.
        let tokens: [Token]
    }

    /// Transcribes an audio file, returning timestamped segments.
    func transcribe(fileAt url: URL, locale: Locale = .current) async throws -> [Segment] {
        // Asset installation (with progress UI) is the coordinator's job via
        // TranscriptionAssets.ensureInstalled — by the time we run, the
        // language model is on disk.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: url)

        // Collect results concurrently while feeding the file through the analyzer.
        async let collected: [Segment] = {
            var segments: [Segment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                // Per-run audioTimeRange is the engine's own alignment. Never
                // infer a token's timing from its neighbours: guessed
                // boundaries drift, and the highlight drifts with them.
                var tokens: [Token] = []
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let piece = String(result.text[run.range].characters)
                    guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    tokens.append(Token(text: piece,
                                        start: range.start.seconds,
                                        end: range.end.seconds))
                }
                let start = tokens.first?.start ?? result.range.start.seconds
                let end = tokens.last?.end ?? result.range.end.seconds
                segments.append(Segment(start: start, end: end, text: text, tokens: tokens))
            }
            return segments
        }()

        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        return try await collected
    }

    /// Renders segments as "[HH:MM:SS] text" lines (same format as the Mac pipeline).
    func markdown(from segments: [Segment]) -> String {
        segments.map { seg in
            let t = Int(seg.start)
            let stamp = String(format: "[%02d:%02d:%02d]", t / 3600, (t % 3600) / 60, t % 60)
            return "\(stamp) \(seg.text.trimmingCharacters(in: .whitespaces))"
        }.joined(separator: "\n")
    }
}

private extension CMTime {
    var seconds: TimeInterval { CMTimeGetSeconds(self) }
}
