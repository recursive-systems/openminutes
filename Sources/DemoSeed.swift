#if DEBUG
import AVFoundation
import Foundation
import SwiftData

/// Populates the store with staged recordings for App Store screenshots.
///
/// Debug-only and opt-in: it runs when the app is launched with
/// `-seedDemoData`, which nothing but a capture script passes. Screenshots
/// of an empty app tell a prospective user nothing, and the alternative —
/// recording real meetings on a simulator that has no microphone — is not
/// available.
///
/// The content is invented. Nothing here is a real meeting, and no real
/// person's voice, name, or words appear in a store listing.
enum DemoSeed {

    static var isRequested: Bool {
        CommandLine.arguments.contains("-seedDemoData")
    }

    @MainActor
    static func populate(_ context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        guard existing.isEmpty else { return }

        for sample in samples {
            // Real audio on disk, because the default setting keeps it. Seeding
            // transcripts alone made the detail screen say "Audio was removed
            // after transcription" — a truthful render of a state most people
            // will never be in, and a misleading one to put in a store listing.
            let audioName = "demo-\(UUID().uuidString).m4a"
            writeDemoAudio(named: audioName, seconds: sample.duration)
            let recording = Recording(
                title: sample.title,
                audioFileName: audioName,
                createdAt: sample.recordedAt,
                duration: sample.duration,
                transcript: sample.transcript,
                summary: sample.summary,
                exportedFolderName: sample.folder,
                titleNeedsGeneration: false,
                transcriptLanguage: "en-US",
                speakerNames: sample.speakers,
                transcriptLines: sample.lines,
                status: .done
            )
            context.insert(recording)
        }
        try? context.save()
    }

    /// Quiet, gently varying tone for the recording's full stated length.
    ///
    /// Not silence: the player draws from the samples, and a flat line looks
    /// like a broken file. And not a short clip either — a six-second file
    /// under a row that says 31:00 is its own small lie, visible across two
    /// screenshots in the same set.
    private static func writeDemoAudio(named name: String, seconds: Double) {
        let url = Recording.audioDirectory.appending(path: name)
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        let rate = 16_000.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
        ]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings),
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))
        else { return }
        buffer.frameLength = AVAudioFrameCount(rate)
        guard let channel = buffer.floatChannelData?[0] else { return }
        var phase = 0.0
        for second in 0..<Int(seconds) {
            let envelope = 0.05 + 0.04 * sin(Double(second) * 1.1)
            for frame in 0..<Int(rate) {
                channel[frame] = Float(sin(phase) * envelope)
                phase += 2 * Double.pi * 180 / rate
            }
            try? file.write(from: buffer)
        }
    }

    private struct Sample {
        let title: String
        let recordedAt: Date
        let duration: TimeInterval
        let transcript: String
        let summary: String
        let folder: String
        let speakers: [String: String]
        let lines: [TranscriptLine]
    }

    /// Fixed offsets from a fixed date, so a rerun produces the same
    /// screenshots. `Date.now` would make every capture differ.
    private static let base = Date(timeIntervalSince1970: 1_780_000_000)

    private static var samples: [Sample] {
        [
            Sample(
                title: "Standup with the platform team",
                recordedAt: base,
                duration: 1_860,
                transcript: """
                [00:00:00] Let's keep this short. Where are we on the migration?
                [00:00:11] Staging is done. Production is waiting on the backfill.
                [00:00:24] The backfill finishes tonight if nothing else lands on it.
                [00:00:38] Then let's freeze it. Anything else blocking?
                """,
                summary: """
                - Staging migration is complete; production is blocked on the backfill.
                - Backfill completes tonight assuming no competing writes.

                **Decisions**
                - Freeze other work on the backfill until it finishes.

                **Action items**
                - Confirm the backfill landed before the morning standup.
                """,
                folder: "2026-06-09-1409 standup-with-the-platform-team",
                // No speaker labels in the seeded data. The feature is marked
                // experimental in the app, and a store screenshot is a promise
                // — showing it front and centre would sell the least reliable
                // thing here as if it were the product.
                speakers: [:],
                lines: [
                    TranscriptLine(start: 0, end: 10, text: "Let's keep this short. Where are we on the migration?", speakerID: nil),
                    TranscriptLine(start: 11, end: 23, text: "Staging is done. Production is waiting on the backfill.", speakerID: nil),
                    TranscriptLine(start: 24, end: 37, text: "The backfill finishes tonight if nothing else lands on it.", speakerID: nil),
                    TranscriptLine(start: 38, end: 48, text: "Then let's freeze it. Anything else blocking?", speakerID: nil),
                ]
            ),
            Sample(
                title: "Client call: scope for Q3",
                recordedAt: base.addingTimeInterval(-86_400),
                duration: 2_745,
                transcript: "[00:00:00] Walking through the Q3 scope and what moves to Q4.",
                summary: """
                - Q3 scope confirmed at three workstreams; reporting moves to Q4.
                - Budget unchanged.

                **Action items**
                - Send the revised statement of work by Thursday.
                """,
                folder: "2026-06-08-1030 client-call-scope-for-q3",
                speakers: [:],
                lines: [TranscriptLine(start: 0, end: 12, text: "Walking through the Q3 scope and what moves to Q4.", speakerID: nil)]
            ),
            Sample(
                title: "Voice note: architecture idea",
                recordedAt: base.addingTimeInterval(-172_800),
                duration: 214,
                transcript: "[00:00:00] Idea: move the export step behind a queue so a revoked folder never loses work.",
                summary: "- Proposal: queue the export step so a revoked folder cannot lose work.",
                folder: "2026-06-07-0812 voice-note-architecture-idea",
                speakers: [:],
                lines: [TranscriptLine(start: 0, end: 9, text: "Idea: move the export step behind a queue so a revoked folder never loses work.", speakerID: nil)]
            ),
            Sample(
                title: "1:1 quarter planning",
                recordedAt: base.addingTimeInterval(-259_200),
                duration: 1_502,
                transcript: "[00:00:00] Priorities for the quarter and what to drop.",
                summary: "- Agreed the top two priorities; deprioritised the reporting rewrite.",
                folder: "2026-06-06-1500 1-1-quarter-planning",
                speakers: [:],
                lines: [TranscriptLine(start: 0, end: 8, text: "Priorities for the quarter and what to drop.", speakerID: nil)]
            ),
        ]
    }
}
#endif
