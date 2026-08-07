import SwiftUI

struct SettingsView: View {
    @Environment(ExportService.self) private var exporter
    @Environment(ProcessingCoordinator.self) private var processor
    @Environment(TipJar.self) private var tipJar
    @AppStorage(RecordingContentPreference.storageKey) private var contentPreferenceRaw =
        RecordingContentPreference.current.rawValue
    @AppStorage(SummaryPreferences.enabledKey) private var summariesEnabled = false
    @State private var showFolderPicker = false
    @State private var storageBytes: Int64 = 0
    @State private var showDeleteAudioConfirm = false
    @State private var supportedLanguages: [Locale] = []
    /// nil means "follow the device language", which is what the pipeline did
    /// before this setting existed.
    @State private var selectedLanguage: String?
    @AppStorage(SpeakerPreferences.enabledKey) private var speakerLabelsEnabled = false
    @State private var showEnrollment = false
    @State private var showForgetVoiceConfirm = false
    @State private var isEnrolled = VoiceEnrollment.isEnrolled
    @AppStorage(SpeakerPreferences.modeKey) private var speakerModeRaw =
        SpeakerPreferences.Mode.everyone.rawValue

    private var speakerMode: SpeakerPreferences.Mode {
        SpeakerPreferences.Mode(rawValue: speakerModeRaw) ?? .everyone
    }

    private var selectedContentPreference: RecordingContentPreference {
        RecordingContentPreference(rawValue: contentPreferenceRaw) ?? .defaultValue
    }

    var body: some View {
        Form {
            Section {
                switch exporter.folderState {
                case .notConfigured:
                    LabeledContent("Folder", value: "Not set")
                case .ready(let name):
                    LabeledContent("Folder", value: name)
                case .needsRepick(let name):
                    Label("“\(name)” is no longer accessible",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                ExportDestinationMenu {
                    showFolderPicker = true
                } label: {
                    Text(exporter.isConfigured ? "Change Destination" : "Choose Destination")
                }
            } header: {
                Text("Export")
            } footer: {
                Text("Finished recordings are written here as markdown, within about five seconds of processing.")
            }

            Section {
                ForEach(RecordingContentPreference.allCases) { preference in
                    Button {
                        contentPreferenceRaw = preference.rawValue
                    } label: {
                        HStack {
                            Text(preference.title)
                            Spacer()
                            if selectedContentPreference == preference {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Recording Content")
            } footer: {
                Text(selectedContentPreference.detail)
            }

            Section {
                Picker("Language", selection: $selectedLanguage) {
                    Text("Device language (\(TranscriptionLanguage.displayName(for: .current)))")
                        .tag(nil as String?)
                    ForEach(supportedLanguages, id: \.identifier) { locale in
                        Text(TranscriptionLanguage.displayName(for: locale))
                            .tag(locale.identifier as String?)
                    }
                }
                .disabled(supportedLanguages.isEmpty)
            } header: {
                Text("Transcription")
            } footer: {
                Text("Speech models download once per language. Transcription uses one language at a time, so a conversation that switches between languages mid-sentence won't transcribe well in any of them.")
            }

            Section {
                Toggle(isOn: $speakerLabelsEnabled) {
                    ExperimentalLabel(title: "Label speakers")
                }
                .disabled(!selectedContentPreference.includesTranscript)
                if speakerLabelsEnabled, selectedContentPreference.includesTranscript {
                    Picker("Label", selection: $speakerModeRaw) {
                        ForEach(SpeakerPreferences.Mode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    if speakerMode == .onlyMe, !isEnrolled {
                        Label("Enrol your voice below. Without it there is nothing to tell apart, and no labels are written.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button(isEnrolled ? "Re-record My Voice" : "Recognize My Voice") {
                        showEnrollment = true
                    }
                    if isEnrolled {
                        Button("Forget My Voice", role: .destructive) {
                            showForgetVoiceConfirm = true
                        }
                    }
                }
            } header: {
                Text("Speakers")
            } footer: {
                Text(speakerFooter)
            }

            Section {
                Toggle("Generate summaries", isOn: $summariesEnabled)
                    .disabled(!selectedContentPreference.includesTranscript)
            } header: {
                Text("Summaries")
            } footer: {
                Text(selectedContentPreference.includesTranscript
                     ? "Off by default. When enabled, OpenMinutes tries to generate summaries on Apple Intelligence devices after transcription. Titles are generated automatically when available."
                     : "Summaries require transcripts. Switch recording content to include transcripts to enable them.")
            }

            Section {
                LabeledContent("Audio recordings") {
                    Text(storageBytes, format: .byteCount(style: .file))
                }
                Button("Delete All Audio, Keep Transcripts", role: .destructive) {
                    showDeleteAudioConfirm = true
                }
                .disabled(storageBytes == 0)
            } header: {
                Text("Storage")
            } footer: {
                Text("Transcripts and summaries are kept. Recordings without a transcript are never touched: their audio is the only copy.")
            }

            if tipJar.isAvailable {
                Section {
                    ForEach(tipJar.products, id: \.id) { product in
                        Button {
                            Task { await tipJar.tip(product) }
                        } label: {
                            LabeledContent(product.displayName, value: product.displayPrice)
                        }
                        .disabled(tipJar.isPurchasing)
                    }
                    if let error = tipJar.purchaseError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Support Development")
                } footer: {
                    Text(tipJar.hasTipped
                         ? "Thank you, it genuinely helps. OpenMinutes is free and open source; tips unlock nothing, because there is nothing locked."
                         : "OpenMinutes is free and open source. Tips are optional and unlock nothing: every feature is already yours.")
                }
            }

            Section {
                LabeledContent("Version", value: Self.versionString)
                NavigationLink("Acknowledgements") { AcknowledgementsView() }
            } header: {
                Text("About")
            } footer: {
                Text("Recording laws vary by region. Make sure you have consent where required. OpenMinutes makes no network calls: transcription and optional summaries run entirely on this device.")
            }
        }
        .navigationTitle("Settings")
        .task {
            await tipJar.loadProducts()
            storageBytes = Self.audioStorageBytes()
            selectedLanguage = TranscriptionLanguage.isFollowingDeviceLocale()
                ? nil : TranscriptionLanguage.current().identifier
            supportedLanguages = await TranscriptionLanguage.supported()
        }
        .onChange(of: selectedLanguage) { _, identifier in
            TranscriptionLanguage.set(identifier.map(Locale.init(identifier:)))
        }
        .sheet(isPresented: $showEnrollment, onDismiss: { isEnrolled = VoiceEnrollment.isEnrolled }) {
            VoiceEnrollmentView(diarizer: AppServices.shared.diarizer)
        }
        .confirmationDialog("Forget your voice?",
                            isPresented: $showForgetVoiceConfirm,
                            titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                VoiceEnrollment.forget()
                isEnrolled = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The voiceprint is deleted from this iPhone. Existing transcripts keep the speaker names they already have.")
        }
        .confirmationDialog("Delete all audio files?",
                            isPresented: $showDeleteAudioConfirm,
                            titleVisibility: .visible) {
            Button("Delete Audio", role: .destructive) {
                processor.deleteAllAudioKeepingTranscripts()
                storageBytes = Self.audioStorageBytes()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. Transcripts and summaries stay; audio-only recordings are left alone.")
        }
        .fileImporter(isPresented: $showFolderPicker,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                exporter.setFolder(url)
                processor.exportPendingRecordings()
            }
        }
    }

    private var speakerFooter: String {
        guard selectedContentPreference.includesTranscript else {
            return "Speaker labels need transcripts. Switch recording content to include transcripts to enable them."
        }
        let caveat = "Experimental: labels are guessed from the audio and will sometimes be wrong: people get merged, split, or swapped, especially when voices overlap. Check them before relying on who said what, and correct any that are wrong in the recording."
        if !speakerLabelsEnabled {
            return "Marks who spoke each line. Adds a second processing pass over the audio, so it is off by default.\n\n\(caveat)"
        }
        let identity = speakerMode == .onlyMe
            ? SpeakerPreferences.Mode.onlyMe.detail
            : isEnrolled
            ? "Your turns are marked “You”; everyone else is numbered. Only your voiceprint is stored, and only on this iPhone. Other speakers are grouped within a single recording and forgotten afterwards."
            : "Without your voice enrolled, every speaker is just numbered. Enrolling lets OpenMinutes tell which turns are yours."
        return "\(SpeakerPreferences.Mode.everyone.detail)\n\n\(identity)\n\n\(caveat)"
    }

    private static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private static func audioStorageBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Recording.audioDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.reduce(into: Int64(0)) { total, url in
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
