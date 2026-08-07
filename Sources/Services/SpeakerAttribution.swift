import Foundation

/// A contiguous stretch of audio the diarizer attributed to one speaker.
struct SpeakerTurn: Equatable, Sendable {
    let speakerID: String
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval { max(0, end - start) }
}

/// A transcript line with the span the speech engine reported for it, plus
/// its token timings. Both come from the engine's own alignment — an earlier
/// version derived each line's end from the next line's start, which drifts
/// and takes any highlight built on it out of sync.
struct TimedLine: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    var words: [TimedWord] = []

    var duration: TimeInterval { max(0, end - start) }
}

/// Merges diarization turns onto transcript lines.
///
/// The two systems segment audio independently — `SpeechTranscriber` breaks on
/// speech pauses, the diarizer on speaker changes — so their boundaries never
/// line up exactly. Attribution is therefore by greatest temporal overlap
/// rather than by matching boundaries.
enum SpeakerAttribution {

    /// Attributes each line to the speaker who occupies most of it.
    ///
    /// Returns `nil` for a line no speaker measurably covers rather than
    /// guessing the nearest one: an unlabelled line reads as unknown, while a
    /// wrong label reads as fact, and the wrong label is the worse failure —
    /// especially in a transcript someone quotes from later.
    ///
    /// `minimumOverlapRatio` guards the ambiguous middle: when the winning
    /// speaker covers less of the line than this, the line stays unattributed.
    static func attribute(
        lines: [TimedLine],
        turns: [SpeakerTurn],
        minimumOverlapRatio: Double = 0.2
    ) -> [String?] {
        lines.map { line in
            // Total each speaker's overlap across every turn before comparing
            // any of them. One speaker routinely holds several turns inside a
            // single long line, and those turns are usually *not* adjacent —
            // the common case is one person interrupted and resuming. Judging
            // turn-by-turn against a running leader drops whatever the leader
            // displaced, so an interrupted speaker loses the line they mostly
            // spoke.
            var totals: [String: TimeInterval] = [:]
            for turn in turns {
                let overlap = overlapDuration(line: line, turn: turn)
                guard overlap > 0 else { continue }
                totals[turn.speakerID, default: 0] += overlap
            }
            // Sorted first so an exact tie resolves the same way every run.
            // Ties are vanishingly rare in real timings, but a label that
            // changes between runs on identical audio is a bug report nobody
            // can reproduce.
            var best: (speakerID: String, overlap: TimeInterval)?
            for (speakerID, overlap) in totals.sorted(by: { $0.key < $1.key })
            where overlap > (best?.overlap ?? 0) {
                best = (speakerID, overlap)
            }
            guard let best else { return nil }
            // A zero-length line cannot be covered proportionally; any
            // overlap at all is the best evidence available.
            guard line.duration > 0 else { return best.speakerID }
            return best.overlap / line.duration >= minimumOverlapRatio ? best.speakerID : nil
        }
    }

    private static func overlapDuration(line: TimedLine, turn: SpeakerTurn) -> TimeInterval {
        max(0, min(line.end, turn.end) - max(line.start, turn.start))
    }
}
