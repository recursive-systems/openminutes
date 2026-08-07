import SwiftUI

/// Brand colors, matching the app icon and openminutes.app.
extension Color {
    /// Record red — the single accent everywhere (#d6361c).
    static let recordRed = Color(red: 0.839, green: 0.212, blue: 0.110)
}

/// The record mark from the app icon: a hairline ring around a solid red
/// disc. Proportions match Sources/AppIcon.icon. The ring uses `.primary`
/// so it stays visible in dark mode (the icon's ink on paper becomes
/// light-on-dark in the app).
struct RecordMark: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.primary, lineWidth: size * 0.044)
            Circle()
                .fill(Color.recordRed)
                .frame(width: size * 0.78, height: size * 0.78)
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    HStack(spacing: 24) {
        RecordMark(size: 32)
        RecordMark(size: 64)
        RecordMark(size: 96)
    }
    .padding()
}
