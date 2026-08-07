import SwiftUI
import UIKit

/// Offers the setup line once the user has a real file to point at.
///
/// Shown as a card rather than a sheet because the timing is unreliable: a
/// long meeting takes a while to transcribe and the phone is usually back in
/// a pocket by the time it finishes. A sheet fired on completion either
/// interrupts something or is missed entirely. A card is simply there when
/// they next look, ten seconds later or two days later.
///
/// It never appears before the first successful export. Offering to connect
/// an assistant to an empty folder asks someone to configure a workflow for
/// files that do not exist yet.
struct SetupPromptCard: View {
    let destination: String
    let onDismiss: () -> Void

    @State private var copied = false

    private var prompt: String { SetupPrompt.text(destination: destination) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Your recordings are in \(destination)", systemImage: "sparkles")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }

            Text("Point your AI at them and it can answer questions across all of them.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = prompt
                    // Copying is not finishing. Someone may copy on the phone
                    // and still want Share later to reach the Mac, so the card
                    // stays until it is dismissed on purpose.
                    withAnimation(.snappy) { copied = true }
                } label: {
                    Label(copied ? "Copied" : "Copy setup instructions",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)

                ShareLink(item: prompt) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}
