import Foundation

/// One transcript line as stored: its span, its text, and who said it.
///
/// Persisted alongside the rendered `transcript` so a speaker rename can
/// re-render without re-transcribing. Rendering stays a pure function of
/// these plus the recording's speaker names.
struct TranscriptLine: Codable, Equatable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    /// Nil when no speaker confidently covered this line.
    var speakerID: String?
    /// Token timings straight from the speech engine, used to follow the
    /// audio word by word. Empty for recordings transcribed before these
    /// were captured — the line still has its own range.
    var words: [TimedWord] = []
}

/// One token with the range the speech engine reported for it. Never
/// interpolated: an inferred boundary drifts out of sync with the audio.
struct TimedWord: Codable, Equatable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}
