import SwiftUI

/// The transcript as a readable conversation rather than a wall of markdown.
///
/// Reads `Recording.transcriptLines` — the same timed lines the exporter
/// renders from — so it can highlight whichever line the audio is currently
/// in, seek by tapping, and group consecutive lines from one speaker under a
/// single name. The markdown string stays the exported artifact; this is the
/// human view of the same data.
struct TranscriptTimelineView: View {
    let lines: [TranscriptLine]
    let speakerNames: [String: String]
    @Bindable var playback: AudioPlaybackController
    /// False when the audio has been discarded — the transcript is still
    /// worth reading, it just cannot be followed along or seeked.
    let canSeek: Bool

    /// Consecutive lines from one speaker read as one turn, the way a
    /// transcript is normally set: the name appears once, not per line.
    private var turns: [Turn] {
        var result: [Turn] = []
        for (index, line) in lines.enumerated() {
            if var last = result.last, last.speakerID == line.speakerID {
                last.lines.append(IndexedLine(index: index, line: line))
                result[result.count - 1] = last
            } else {
                result.append(Turn(speakerID: line.speakerID,
                                   lines: [IndexedLine(index: index, line: line)]))
            }
        }
        return result
    }

    /// The line the playhead is inside, or nil when stopped at the start or
    /// past the end. Index-based so identical text never highlights twice.
    private var activeIndex: Int? {
        guard playback.isPlaying || playback.currentTime > 0 else { return nil }
        return lines.firstIndex { playback.currentTime >= $0.start && playback.currentTime < $0.end }
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 18) {
                ForEach(turns) { turn in
                    VStack(alignment: .leading, spacing: 6) {
                        if let name = turn.speakerID.map({ speakerNames[$0] ?? $0 }) {
                            Text(name)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                        ForEach(turn.lines) { indexed in
                            line(indexed)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: activeIndex) { _, index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func line(_ indexed: IndexedLine) -> some View {
        let isActive = activeIndex == indexed.index
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Self.timestamp(indexed.line.start))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            // Word timings come from the speech engine, so the highlight
            // tracks the audio rather than approximating it. Lines
            // transcribed before those were captured have no words and fall
            // back to plain text — never to a guessed position.
            Group {
                if indexed.line.words.isEmpty {
                    Text(indexed.line.text)
                } else {
                    highlighted(indexed.line)
                }
            }
            .font(.callout)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isActive ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 8))
        .id(indexed.index)
        .contentShape(.rect)
        .onTapGesture {
            guard canSeek else { return }
            playback.seek(to: indexed.line.start)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityHint(canSeek ? "Play from here" : "")
    }

    /// One `Text` built from the words, with the spoken one emphasised.
    /// Concatenating `Text` keeps it a single wrapping paragraph — laying the
    /// words out as separate views would break wrapping and selection.
    private func highlighted(_ line: TranscriptLine) -> Text {
        line.words.reduce(Text("")) { partial, word in
            let spoken = playback.currentTime >= word.start && playback.currentTime < word.end
            return partial + Text(word.text)
                .fontWeight(spoken ? .bold : .regular)
                .foregroundColor(spoken ? .accentColor : .primary)
        }
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    private struct IndexedLine: Identifiable {
        let index: Int
        let line: TranscriptLine
        var id: Int { index }
    }

    private struct Turn: Identifiable {
        let speakerID: String?
        var lines: [IndexedLine]
        var id: Int { lines.first?.index ?? 0 }
    }
}
