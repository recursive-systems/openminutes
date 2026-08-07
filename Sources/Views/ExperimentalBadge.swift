import SwiftUI

/// Marks a feature whose output can be wrong.
///
/// Used wherever speaker labels are turned on or read. Diarization is
/// accurate most of the time and confidently wrong the rest, and a label that
/// looks authoritative is worse than one the reader knows to check — so the
/// caveat appears at the moment of opting in *and* at the moment of reading,
/// not only in a settings footer nobody revisits.
struct ExperimentalBadge: View {
    var body: some View {
        Text("Experimental")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.15), in: .capsule)
            .accessibilityLabel("Experimental feature")
    }
}

/// A label with the badge beside it, stacking when they no longer fit.
/// An HStack squeezes both to nothing at accessibility text sizes — the same
/// failure the onboarding rows had.
struct ExperimentalLabel: View {
    let title: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { Text(title); ExperimentalBadge() }
            VStack(alignment: .leading, spacing: 4) { Text(title); ExperimentalBadge() }
        }
    }
}
