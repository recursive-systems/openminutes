import SwiftUI

/// The transcript arriving while you speak.
///
/// Only the last few lines are shown, settled text receding as it ages and
/// the in-flight guess brightest at the bottom. That ordering is the whole
/// point: attention belongs on the words being spoken now, and older lines
/// are context, not content. Reading the full transcript is what the detail
/// screen is for.
struct LiveTranscriptView: View {
    let finalized: [String]
    let volatile: String

    /// Enough to feel continuous, few enough that the eye stays at the
    /// bottom. More lines turn a follow-along into a wall to read.
    private static let visibleLines = 3

    private var recent: [String] {
        Array(finalized.suffix(Self.visibleLines))
    }

    private var isEmpty: Bool { recent.isEmpty && volatile.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isEmpty {
                Text("Listening…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            } else {
                // Older lines fade rather than disappear, so text leaves the
                // way it arrived instead of popping.
                ForEach(Array(recent.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .opacity(opacity(forRecentIndex: index))
                }
                if !volatile.isEmpty {
                    Text(volatile)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .animation(.easeInOut(duration: 0.2), value: volatile)
        .animation(.easeInOut(duration: 0.25), value: recent)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live transcript")
        .accessibilityValue(volatile.isEmpty ? (recent.last ?? "Listening") : volatile)
    }

    /// Oldest line faintest; the newest settled line nearly full strength.
    private func opacity(forRecentIndex index: Int) -> Double {
        let distanceFromNewest = recent.count - 1 - index
        return max(0.35, 1 - Double(distanceFromNewest) * 0.28)
    }
}
