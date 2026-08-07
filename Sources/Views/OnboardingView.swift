import AVFAudio
import SwiftUI

/// Four screens, skippable (PRD D3): mic permission with rationale (+
/// speech-model pre-warm so the first transcription doesn't stall), what to
/// keep, where notes are saved, record your first note.
struct OnboardingView: View {
    @Environment(ExportService.self) private var exporter
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage(RecordingContentPreference.storageKey) private var contentPreferenceRaw =
        RecordingContentPreference.current.rawValue
    @State private var page = 0
    @State private var micPermission = AVAudioApplication.shared.recordPermission
    @State private var assetProgress: Progress?
    @State private var showFolderPicker = false

    var body: some View {
        TabView(selection: $page) {
            micPage.tag(0)
            contentPage.tag(1)
            folderPage.tag(2)
            recordPage.tag(3)
        }
        // The dots float over the pages, so once content scrolls they sit on
        // top of it. At accessibility sizes everything scrolls, so drop them.
        .tabViewStyle(.page(indexDisplayMode: dynamicTypeSize.isAccessibilitySize ? .never : .automatic))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .overlay(alignment: .topTrailing) {
            // Same reasoning as "Decide later" below: never leave the app
            // with nowhere to write.
            Button("Skip") {
                if !exporter.isConfigured { exporter.useLocalFolder() }
                onboardingComplete = true
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            if let progress = assetProgress, !progress.isFinished {
                VStack(spacing: 4) {
                    Text("Downloading on-device speech model…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(progress)
                        .progressViewStyle(.linear)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 48)
            }
        }
        .fileImporter(isPresented: $showFolderPicker,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                exporter.setFolder(url)
                withAnimation { page = 3 }
            }
        }
    }

    /// Onboarding has to survive accessibility text sizes. At those sizes the
    /// content no longer fits, so it scrolls rather than truncating; minHeight
    /// keeps it centred while it still fits. The padding clears the Skip button
    /// and the page dots, which are overlays and contribute no layout here.
    private func pageShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let body = VStack(spacing: 24) { content() }
        return GeometryReader { proxy in
            ScrollView {
                body
                .padding(.top, 56)
                .padding(.bottom, 76)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }

    private var micPage: some View {
        pageShell {
            RecordMark(size: 72)
            Text("OpenMinutes")
                .font(.largeTitle.bold())
            Text("Record meetings and voice notes. Transcription happens entirely on this iPhone. Nothing is ever uploaded.")
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            switch micPermission {
            case .granted:
                Button("Continue") { withAnimation { page = 1 } }
                    .buttonStyle(.borderedProminent)
            case .denied:
                VStack(spacing: 8) {
                    Text("Microphone access is off.")
                        .font(.callout)
                        .foregroundStyle(.red)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            default:
                Button("Allow Microphone Access") {
                    Task {
                        let granted = await AVAudioApplication.requestRecordPermission()
                        micPermission = AVAudioApplication.shared.recordPermission
                        if granted {
                            prewarmSpeechAssets()
                            withAnimation { page = 1 }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var contentPage: some View {
        pageShell {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Choose what to keep")
                .font(.title.bold())
            Text("You can change this later in Settings. Transcript-only removes the raw audio after processing.")
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 12) {
                ForEach(RecordingContentPreference.allCases) { preference in
                    Button {
                        contentPreferenceRaw = preference.rawValue
                        withAnimation { page = 2 }
                    } label: {
                        HStack(spacing: 12) {
                            if !dynamicTypeSize.isAccessibilitySize {
                                Image(systemName: iconName(for: preference))
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                    .frame(width: 28)
                                    .accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                RowHeading(title: preference.title,
                                           recommended: preference.isRecommended)
                                Text(preference.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if contentPreferenceRaw == preference.rawValue {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        contentPreferenceRaw == preference.rawValue ? [.isSelected] : []
                    )
                }
            }
            .padding(.horizontal, 24)

        }
    }

    /// Destinations are named by where the files land, not by the mechanism
    /// that puts them there — a first-run user should never meet a bare
    /// folder picker. Choosing is free; the Pro gate lives at export time
    /// (PRD C5), so onboarding never opens with a paywall.
    private var folderPage: some View {
        pageShell {
            Image(systemName: "folder")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Where should notes go?")
                .font(.title.bold())
            Text("Each finished recording is saved as a markdown file you can open, search, and back up.")
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 12) {
                if exporter.iCloudAvailable {
                    destinationRow(
                        icon: "icloud",
                        title: "iCloud Drive",
                        detail: "Syncs to your Mac and other devices.",
                        recommended: true
                    ) {
                        Task {
                            if await exporter.useICloudContainer() {
                                withAnimation { page = 3 }
                            }
                        }
                    }
                }

                destinationRow(
                    icon: "iphone",
                    title: "On My iPhone",
                    detail: "Stays on this device. Open them in the Files app.",
                    recommended: !exporter.iCloudAvailable
                ) {
                    exporter.useLocalFolder()
                    withAnimation { page = 3 }
                }

                destinationRow(
                    icon: "folder.badge.plus",
                    title: "Choose a folder…",
                    detail: "Dropbox, an Obsidian vault, anywhere in Files.",
                    recommended: false
                ) {
                    showFolderPicker = true
                }
            }
            .padding(.horizontal, 24)

            // Not a no-op: skipping used to leave the app with no destination
            // at all, so recordings existed only inside the app container and
            // deleting the app lost everything. On My iPhone needs no account
            // or permission, so "later" can mean "change it later" instead of
            // "no durable copy exists".
            Button("Decide later") {
                if !exporter.isConfigured { exporter.useLocalFolder() }
                withAnimation { page = 3 }
            }
            .font(.subheadline)
        }
    }

    private func destinationRow(
        icon: String,
        title: String,
        detail: String,
        recommended: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    RowHeading(title: title, recommended: recommended)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            // .plain, not .bordered: bordered tints every label inside it,
            // which flattens the title/detail contrast to red-on-red.
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var recordPage: some View {
        pageShell {
            RecordMark(size: 72)
            Text("You're set")
                .font(.title.bold())
            Text(recordPageDescription)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Start Using OpenMinutes") { onboardingComplete = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private func prewarmSpeechAssets() {
        Task {
            try? await TranscriptionAssets.ensureInstalled { progress in
                assetProgress = progress
            }
            assetProgress = nil
        }
    }

    private func iconName(for preference: RecordingContentPreference) -> String {
        switch preference {
        case .transcriptsOnly: "doc.text"
        case .audioOnly: "waveform"
        case .audioAndTranscripts: "doc.on.doc"
        }
    }

    private var selectedContentPreference: RecordingContentPreference {
        RecordingContentPreference(rawValue: contentPreferenceRaw) ?? .defaultValue
    }

    private var recordPageDescription: String {
        switch selectedContentPreference {
        case .audioOnly:
            "Tap Record to capture your first note. OpenMinutes will keep the raw audio without generating a transcript."
        case .transcriptsOnly:
            "Tap Record to capture your first note. The transcript appears moments after you stop, then the raw audio is removed."
        case .audioAndTranscripts:
            "Tap Record to capture your first note. The transcript appears moments after you stop, and the raw audio stays available."
        }
    }
}

/// Shared by the content and destination screens so the suggested option
/// looks identical in both.
private struct RecommendedBadge: View {
    var body: some View {
        Text("Recommended")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.12), in: .capsule)
    }
}

/// Title plus optional badge. Falls back to a stacked layout when the two
/// cannot sit side by side — in an HStack at accessibility sizes both get
/// truncated to nothing ("Aud…" next to "Reco…").
private struct RowHeading: View {
    let title: String
    let recommended: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { label; badge }
            VStack(alignment: .leading, spacing: 4) { label; badge }
        }
    }

    private var label: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var badge: some View {
        if recommended { RecommendedBadge() }
    }
}
