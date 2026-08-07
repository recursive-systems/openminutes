import SwiftUI

private let approximateMobileCharactersPerLine = 45

struct DetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(ProcessingCoordinator.self) private var processor
    @Environment(ExportService.self) private var exporter
    @State private var showRename = false
    @State private var renamingSpeakerID: String?
    @State private var draftSpeakerName = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draftTitle = ""
    @State private var playback = AudioPlaybackController()
    /// The transport control scales with the user's text size; a 40pt tap
    /// target that never grows is the usual accessibility complaint here.
    @ScaledMetric(relativeTo: .title) private var playButtonSize: CGFloat = 40
    @State private var summaryExpanded = false
    @State private var transcriptExpanded = false
    let recording: Recording

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if recording.status == .failed {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(recording.failureReason ?? "Processing failed",
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                            Button("Retry") { processor.retry(recording) }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                audioSection
                speakerSection
                if let summary = recording.summary {
                    GroupBox("Summary") {
                        ExpandableTextBlock(
                            text: summary,
                            collapsedLineLimit: 10,
                            expanded: $summaryExpanded,
                            expandTitle: "Show full summary",
                            collapseTitle: "Collapse summary"
                        ) {
                            Text(.init(summary))   // render markdown
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else if let reason = recording.summarySkippedReason {
                    GroupBox("Summary") {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(reason, systemImage: "info.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Try Again") { processor.retry(recording) }
                                .font(.callout)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !recording.transcriptLines.isEmpty {
                    GroupBox("Transcript") {
                        TranscriptTimelineView(
                            lines: recording.transcriptLines,
                            speakerNames: recording.speakerNames,
                            playback: playback,
                            canSeek: audioFileExists
                        )
                    }
                } else if let transcript = recording.transcript {
                    // Recordings made before lines were stored structurally
                    // keep the rendered markdown; there is nothing to follow
                    // along with, but the text is not lost.
                    GroupBox("Transcript") {
                        ExpandableTextBlock(
                            text: transcript,
                            collapsedLineLimit: 18,
                            expanded: $transcriptExpanded,
                            expandTitle: "Show full transcript",
                            collapseTitle: "Collapse transcript"
                        ) {
                            Text(transcript)
                                .font(.callout.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                } else if recording.status == .done {
                    ContentUnavailableView("Audio-only recording",
                                           systemImage: "waveform",
                                           description: Text("This recording was saved without a transcript."))
                } else if recording.status != .failed {
                    ContentUnavailableView("Not transcribed yet",
                                           systemImage: "waveform",
                                           description: Text("Processing happens automatically after recording."))
                }
                if recording.exportPending {
                    Label("Export pending. The export folder needs to be chosen again",
                          systemImage: "exclamationmark.icloud")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let exported = recording.exportedFolderName {
                    Label("Exported: \(exported)", systemImage: "checkmark.icloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle(recording.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let transcript = recording.transcript {
                ShareLink(item: transcript)
            }
            Menu {
                Button("Rename", systemImage: "pencil") {
                    draftTitle = recording.title
                    showRename = true
                }
                if audioFileExists {
                    ShareLink(item: recording.audioURL) {
                        Label("Share Audio", systemImage: "waveform")
                    }
                }
                if audioFileExists, recording.transcript != nil {
                    Button("Delete Audio, Keep Transcript", systemImage: "waveform.slash", role: .destructive) {
                        playback.stop()
                        processor.deleteAudioKeepingTranscript(for: recording)
                    }
                }
                if recording.transcript != nil || audioFileExists {
                    // Retroactive export after a destination change (PRD C5);
                    // overwrites this recording's previous export in place.
                    Button("Re-export", systemImage: "square.and.arrow.up.on.square") {
                        if exporter.isConfigured { processor.retry(recording) }
                    }
                    .disabled(!exporter.isConfigured)
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
        .alert("Rename Speaker",
               isPresented: Binding(get: { renamingSpeakerID != nil },
                                    set: { if !$0 { renamingSpeakerID = nil } })) {
            TextField("Name", text: $draftSpeakerName)
            Button("Save") {
                if let id = renamingSpeakerID {
                    processor.renameSpeaker(id, to: draftSpeakerName, in: recording)
                }
                renamingSpeakerID = nil
            }
            Button("Cancel", role: .cancel) { renamingSpeakerID = nil }
        } message: {
            Text("Updates the transcript and its exported file. Applies to this recording only.")
        }
        .alert("Rename Recording", isPresented: $showRename) {
            TextField("Title", text: $draftTitle)
            Button("Save") {
                let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    recording.title = trimmed
                    recording.titleNeedsGeneration = false
                    try? context.save()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The new title is used for the next export's filename.")
        }
    }

    /// Speaker labels for this recording, renameable in place. Renaming
    /// annotates this file only: no voiceprint exists for anyone but the
    /// enrolled owner, so the same person in another recording starts again
    /// as a number.
    @ViewBuilder
    private var speakerSection: some View {
        if !recording.speakerNames.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(recording.speakerNames.keys.sorted(), id: \.self) { id in
                        Button {
                            renamingSpeakerID = id
                            draftSpeakerName = recording.speakerNames[id] ?? ""
                        } label: {
                            HStack(spacing: 8) {
                                if !dynamicTypeSize.isAccessibilitySize {
                                    Image(systemName: id == SpeakerIdentity.ownerID
                                          ? "person.crop.circle.fill" : "person.crop.circle")
                                        .foregroundStyle(.tint)
                                        .accessibilityHidden(true)
                                }
                                Text(recording.speakerNames[id] ?? id)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Image(systemName: "pencil")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Rename this speaker for this recording")
                    }
                    Text("Detected automatically and sometimes wrong. Tap to correct. Names apply to this recording only.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                ExperimentalLabel(title: "Speakers")
            }
        }
    }

    /// Whether this recording still has audio, and if not, why — a
    /// transcript-only recording discarded it on purpose, which is worth
    /// saying rather than leaving the screen silently player-less.
    @ViewBuilder
    private var audioSection: some View {
        if audioFileExists {
            GroupBox("Audio") {
                VStack(spacing: 8) {
                    if playback.loadFailed {
                        Label("This recording's audio can't be played.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 14) {
                        Button {
                            playback.togglePlayback()
                        } label: {
                            Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: playButtonSize))
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                        .disabled(playback.loadFailed)
                        .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                        VStack(spacing: 2) {
                            Slider(
                                value: Binding(
                                    get: { playback.currentTime },
                                    set: { playback.seek(to: $0) }
                                ),
                                in: 0...max(playback.duration, 0.01)
                            )
                            .disabled(playback.loadFailed)
                            .accessibilityLabel("Playback position")

                            HStack {
                                Text(Self.timeLabel(playback.currentTime))
                                Spacer(minLength: 8)
                                Text(Self.timeLabel(playback.duration))
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        }
                    }
                }
            }
            .onAppear { playback.load(url: recording.audioURL) }
            .onDisappear { playback.stop() }
        } else if recording.transcript != nil {
            Label("Audio was removed after transcription.", systemImage: "waveform.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func timeLabel(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds)).formatted(.time(pattern: .minuteSecond))
    }

    private var audioFileExists: Bool {
        FileManager.default.fileExists(atPath: recording.audioURL.path(percentEncoded: false))
    }
}

private struct ExpandableTextBlock<Content: View>: View {
    let text: String
    let collapsedLineLimit: Int
    @Binding var expanded: Bool
    let expandTitle: String
    let collapseTitle: String
    @ViewBuilder var content: () -> Content

    private var needsCollapse: Bool {
        text.count > collapsedLineLimit * approximateMobileCharactersPerLine
            || text.filter(\.isNewline).count >= collapsedLineLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
                .lineLimit(needsCollapse && !expanded ? collapsedLineLimit : nil)

            if needsCollapse {
                Button {
                    withAnimation(.snappy) {
                        expanded.toggle()
                    }
                } label: {
                    Label(expanded ? collapseTitle : expandTitle,
                          systemImage: expanded ? "chevron.up" : "chevron.down")
                }
                .font(.callout.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel(expanded ? collapseTitle : expandTitle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
