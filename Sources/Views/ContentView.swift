import AVFAudio
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ExportService.self) private var exporter
    @Environment(AudioImportService.self) private var audioImporter
    @Environment(ProcessingCoordinator.self) private var processor
    @Environment(RecorderService.self) private var recorder
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("consentNoticeDismissed") private var consentDismissed = false
    @AppStorage("setupPromptDismissed") private var setupPromptDismissed = false
    @State private var showFolderPicker = false
    @State private var showAudioPicker = false
    @State private var importError: String?
    /// Why a record link from another app did not start a recording.
    @State private var linkError: String?
    @State private var linkStarter = RecordLinkStarter()
    @State private var micPermission = AVAudioApplication.shared.recordPermission
    @State private var searchText = ""

    /// The setup card needs all three: a finished recording so there is a real
    /// file to point at, a configured destination so the line can name it, and
    /// no prior dismissal.
    private var setupDestination: String? {
        guard !setupPromptDismissed,
              case .ready(let name) = exporter.folderState,
              recordings.contains(where: { $0.status == .done })
        else { return nil }
        return name
    }

    /// Filtered in memory rather than through a @Query predicate: the corpus
    /// is one person's recordings, and searching transcript text needs a
    /// case-insensitive contains that reads far worse as a #Predicate.
    /// Every list operation must go through this — indexing `recordings`
    /// while a search is active deletes the wrong row.
    private var visibleRecordings: [Recording] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recordings }
        return recordings.filter { recording in
            [recording.title, recording.transcript, recording.summary]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if micPermission == .denied {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Microphone access is off", systemImage: "mic.slash")
                                .foregroundStyle(.red)
                            Text("OpenMinutes can't record without it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .font(.callout)
                        }
                    }
                }
                if let destination = setupDestination {
                    SetupPromptCard(destination: destination) {
                        setupPromptDismissed = true
                    }
                }
                if !consentDismissed {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Recording laws vary by region. Make sure you have consent where required.",
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            consentDismissed = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss consent notice")
                    }
                }
                if processor.persistenceFailed {
                    Label("Couldn't save progress. Your device may be out of storage.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                switch exporter.folderState {
                case .notConfigured:
                    ExportDestinationMenu {
                        showFolderPicker = true
                    } label: {
                        Text("Choose where your notes are saved")
                    }
                    .foregroundStyle(.orange)
                case .needsRepick(let name):
                    ExportDestinationMenu {
                        showFolderPicker = true
                    } label: {
                        Label("“\(name)” is no longer accessible. Choose again",
                              systemImage: "exclamationmark.triangle")
                    }
                    .foregroundStyle(.red)
                case .ready:
                    EmptyView()
                }
                if !searchText.isEmpty, visibleRecordings.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
                ForEach(visibleRecordings) { recording in
                    NavigationLink(value: recording) {
                        RecordingRow(recording: recording)
                    }
                }
                .onDelete { offsets in
                    for offset in offsets {
                        let recording = visibleRecordings[offset]
                        processor.cancelProcessing(for: recording)
                        try? FileManager.default.removeItem(at: recording.audioURL)
                        context.delete(recording)
                    }
                    try? context.save()
                }
            }
            .navigationTitle("OpenMinutes")
            // iOS 26 defaults search to a bottom bar on iPhone, which here
            // stacked underneath the record controls: two bars competing for
            // the same edge, and the record button — the reason people open
            // the app — shrank to make room. In the navigation bar drawer it
            // sits under the title and scrolls away with the list, so it
            // costs nothing until pulled down.
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "Search titles and transcripts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if audioImporter.isImporting {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Importing audio")
                    } else {
                        Button {
                            showAudioPicker = true
                        } label: {
                            Label("Import Audio", systemImage: "square.and.arrow.down")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationDestination(for: Recording.self) { DetailView(recording: $0) }
            .safeAreaInset(edge: .bottom) {
                RecordControls(recorder: recorder) { finished in
                    context.insert(finished)
                    try? context.save()
                    processor.enqueue(finished)
                }
            }
            .fileImporter(isPresented: $showFolderPicker,
                          allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    exporter.setFolder(url)
                    processor.exportPendingRecordings()
                }
            }
            .fileImporter(isPresented: $showAudioPicker,
                          allowedContentTypes: [.mpeg4Audio]) { result in
                switch result {
                case .success(let url):
                    importAudio(from: url)
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
            .alert("Couldn't Import Audio", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
            .fullScreenCover(isPresented: Binding(
                get: { !onboardingComplete },
                set: { if !$0 { onboardingComplete = true } }
            )) {
                OnboardingView()
            }
            // Shown from here only when no recording is running; while one
            // is, the session cover is on top and presents it instead.
            .alert("Couldn't Start Recording", isPresented: linkErrorShown(whileRecording: false)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(linkError ?? "")
            }
            .fullScreenCover(isPresented: Binding(
                get: { recorder.state != .idle },
                set: { _ in }
            )) {
                RecordingSessionView(recorder: recorder) { finished in
                    context.insert(finished)
                    try? context.save()
                    processor.enqueue(finished)
                }
                .interactiveDismissDisabled()
                .alert("Couldn't Start Recording", isPresented: linkErrorShown(whileRecording: true)) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(linkError ?? "")
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // Refresh after returning from Settings → Privacy.
                if phase == .active {
                    micPermission = AVAudioApplication.shared.recordPermission
                }
            }
            .onOpenURL { url in
                switch OpenMinutesURLRoute(url: url) {
                case .importAudio(let fileURL):
                    importAudio(from: fileURL)
                case .startRecording(let request):
                    // The Lock Screen widget (accessory widgets can't run
                    // intents directly; they open the app to record), and
                    // other apps passing a title and ref.
                    startRecording(from: request)
                case .rejectedRecordRequest(let problem):
                    linkError = problem.message
                case .unsupported:
                    break
                }
            }
        }
    }

    private func linkErrorShown(whileRecording: Bool) -> Binding<Bool> {
        Binding(
            get: { linkError != nil && (recorder.state != .idle) == whileRecording },
            set: { if !$0 { linkError = nil } }
        )
    }

    private func startRecording(from request: RecordRequest) {
        Task {
            linkError = await linkStarter.handle(
                request,
                isIdle: { recorder.state == .idle },
                prepare: {
                    if AVAudioApplication.shared.recordPermission == .undetermined {
                        _ = await AVAudioApplication.requestRecordPermission()
                    }
                },
                start: { try recorder.start($0) }
            ) ?? linkError
        }
    }

    private func importAudio(from url: URL) {
        Task {
            do {
                let recording = try await audioImporter.importRecording(from: url)
                context.insert(recording)
                do {
                    try context.save()
                } catch {
                    context.delete(recording)
                    try? FileManager.default.removeItem(at: recording.audioURL)
                    throw error
                }
                processor.enqueue(recording)
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

struct RecordingRow: View {
    @Environment(ProcessingCoordinator.self) private var processor
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let recording: Recording

    /// Title and status share a line only while there is room for both; at
    /// accessibility sizes they stack instead of truncating each other.
    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
    }

    var body: some View {
        layout {
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                // One Text, not three in an HStack: this wraps, that clipped.
                Text("\(RecordingRowDateFormatter.text(for: recording.createdAt)) · \(Duration.seconds(recording.duration).formatted(.time(pattern: .minuteSecond)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            statusView
                .font(.caption)
        }
    }

    /// A spinner while work is happening, nothing when it is finished, and
    /// the reason when it failed.
    ///
    /// Naming each stage told people about the app's internals rather than
    /// their recording — and a finished row needs no badge, because being in
    /// the list already says it is there. Only failure earns words, since a
    /// silent failure is the one outcome the user cannot act on.
    ///
    /// The stage is still announced to VoiceOver: a bare spinner is the one
    /// case where sighted users get information from motion that a screen
    /// reader would otherwise lose.
    @ViewBuilder
    private var statusView: some View {
        switch recording.status {
        case .pending, .transcribing, .summarizing, .exporting:
            ProgressView()
                .accessibilityLabel(Self.stageDescription(for: recording.status))
        case .downloadingAssets:
            // Determinate here on purpose: a first-run model download runs for
            // minutes, and a spinner that long reads as stuck.
            if let progress = processor.assetDownloadProgress {
                ProgressView(progress)
                    .progressViewStyle(.circular)
                    .accessibilityLabel("Downloading speech model")
            } else {
                ProgressView().accessibilityLabel("Downloading speech model")
            }
        case .failed:
            Label(recording.failureReason ?? "Failed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .done:
            EmptyView()
        }
    }

    private static func stageDescription(for status: ProcessingStatus) -> String {
        switch status {
        case .pending: "Queued"
        case .transcribing: "Transcribing"
        case .summarizing: "Summarizing"
        case .exporting: "Exporting"
        default: "Processing"
        }
    }
}

enum RecordingRowDateFormatter {
    static func text(
        for date: Date,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return normalize(format(date, dateStyle: .none, timeStyle: .short, calendar: calendar, locale: locale))
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }

        return normalize(format(date, dateStyle: .long, timeStyle: .none, calendar: calendar, locale: locale))
    }

    private static func format(
        _ date: Date,
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: date)
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
    }
}

/// Record / pause / resume / stop — the control Shortcuts can't give you.
struct RecordControls: View {
    @Bindable var recorder: RecorderService
    var onFinish: (Recording) -> Void
    @State private var startError: String?

    var body: some View {
        HStack(spacing: 24) {
            switch recorder.state {
            case .idle:
                // The brand mark IS the record button (no label — it's the
                // app icon's ring-and-disc, which everyone reads as REC).
                Button {
                    startRecording()
                } label: {
                    // Glass sized exactly to the mark, not padded around it:
                    // it frosts whatever scrolls underneath so list text is
                    // not sharply legible through the ring's gap, without
                    // adding a visible container around the button.
                    RecordMark(size: 72)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record")

            case .recording, .paused:
                VStack(spacing: 2) {
                    Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                        .font(.title3.monospacedDigit())
                        .accessibilityLabel("Elapsed time")
                    if recorder.isInterrupted {
                        Text("Paused by interruption")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                Button {
                    recorder.state == .recording ? recorder.pause() : recorder.resume()
                } label: {
                    Image(systemName: recorder.state == .recording ? "pause.circle.fill" : "play.circle.fill")
                        .font(.largeTitle)
                }
                .accessibilityLabel(recorder.state == .recording ? "Pause recording" : "Resume recording")

                Button {
                    if let finished = recorder.stop() { onFinish(finished) }
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(Color.recordRed)
                }
                .accessibilityLabel("Stop recording")
            }
        }
        // No bar and no backdrop: the mark is its own button, and anything
        // drawn behind it just reads as a block taking the bottom of the
        // screen. `.safeAreaInset` still reserves the height, so the list
        // stops above it rather than scrolling underneath — which is what
        // makes a backdrop unnecessary in the first place.
        .padding(.top, 8)
        .padding(.bottom, 4)
        .animation(.snappy, value: recorder.state)
        .alert("Couldn't Start Recording", isPresented: Binding(
            get: { startError != nil },
            set: { if !$0 { startError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(startError ?? "")
        }
    }

    private func startRecording() {
        Task {
            // First in-app record tap without onboarding: prompt explicitly.
            if AVAudioApplication.shared.recordPermission == .undetermined {
                _ = await AVAudioApplication.requestRecordPermission()
            }
            do {
                try recorder.start()
            } catch {
                // Surfaces mic denial and disk-full class failures (PRD edge states).
                startError = error.localizedDescription
            }
        }
    }
}
