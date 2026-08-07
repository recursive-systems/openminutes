import AVFoundation
import SwiftUI

/// Records a short sample of the owner's voice and stores its voiceprint.
///
/// Deliberately separate from `RecorderService`: enrollment must not touch
/// the recording pipeline, appear in the library, or be exported. The sample
/// is written to a temporary file and deleted as soon as the voiceprint is
/// extracted — the app keeps the 256-number template, never the audio.
struct VoiceEnrollmentView: View {
    @Environment(\.dismiss) private var dismiss
    let diarizer: any Diarizing

    @State private var recorder: AVAudioRecorder?
    @State private var sampleURL: URL?
    @State private var phase: Phase = .ready
    @State private var displayName = VoiceEnrollment.displayName() ?? ""
    @State private var elapsed: TimeInterval = 0
    @State private var ticker: Task<Void, Never>?

    /// The segmentation model works in ten-second windows, so a sample much
    /// shorter than that gives it almost nothing to hold on to.
    private static let minimumSeconds: TimeInterval = 15
    private static let suggestedSeconds: TimeInterval = 25

    /// Something to read, so nobody has to invent small talk while a timer
    /// runs. Deliberately varied in sound rather than meaningful: the model
    /// characterises a voice, and a narrow range of sounds characterises it
    /// narrowly.
    private static let passage = """
        The quick brown fox jumps over the lazy dog while the calm sea washes \
        against the harbour wall. Thirty-five yellow ships were moored there \
        yesterday, and the youngest sailor whistled a cheerful tune as she \
        counted them. Rain threatened, though the evening stayed bright, and \
        somewhere behind the old church a bell rang out across the water.
        """

    private enum Phase: Equatable {
        case ready, recording, processing, done
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("OpenMinutes learns your voice so it can tell your turns apart from other people's. The voiceprint stays on this iPhone, is never exported, and you can delete it at any time.")
                        .font(.callout)
                } header: {
                    ExperimentalLabel(title: "What this does")
                } footer: {
                    Text("Speaker detection is experimental. Even with your voice enrolled it will sometimes attribute a line to the wrong person, so treat the labels as a starting point rather than a record.")
                }

                Section {
                    TextField("Your name", text: $displayName)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Name in exported files")
                } footer: {
                    Text("Transcripts show “You” in the app, but a file saying “You” means nothing to anyone else reading it, or to an agent. This name is written there instead.")
                }

                if phase == .recording || phase == .ready {
                    Section {
                        Text(Self.passage)
                            .font(.callout)
                            .lineSpacing(4)
                    } header: {
                        Text("Read this aloud")
                    } footer: {
                        Text("Or say anything else you like. The words don't matter, only the sound of your voice.")
                    }
                }

                Section {
                    switch phase {
                    case .ready:
                        Button("Start Recording", systemImage: "mic.fill") { start() }
                    case .recording:
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: "waveform")
                                    .foregroundStyle(.red)
                                    .symbolEffect(.variableColor.iterative)
                                Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)))
                                    .font(.title3.monospacedDigit())
                                Spacer()
                                Text(elapsed < Self.minimumSeconds ? "Keep going…" : "Long enough")
                                    .font(.caption)
                                    .foregroundStyle(elapsed < Self.minimumSeconds ? Color.secondary : Color.green)
                            }
                            ProgressView(value: min(elapsed, Self.suggestedSeconds),
                                         total: Self.suggestedSeconds)
                            Button("Stop and Save", systemImage: "stop.fill") {
                                Task { await finish() }
                            }
                            .foregroundStyle(.red)
                            .disabled(elapsed < Self.minimumSeconds)
                        }
                    case .processing:
                        HStack {
                            ProgressView()
                            Text("Learning your voice…").foregroundStyle(.secondary)
                        }
                    case .done:
                        Label("Voice saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed(let reason):
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Button("Try Again") { phase = .ready }
                    }
                } footer: {
                    Text("Talk normally, somewhere similar to where you usually record, not somewhere unusually quiet.")
                }
            }
            .navigationTitle("Recognize My Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        VoiceEnrollment.setDisplayName(displayName)
                        dismiss()
                    }
                }
            }
            .onDisappear { cleanUp() }
        }
    }

    private func start() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "enrollment-\(UUID().uuidString).m4a")
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
            ])
            recorder.record()
            self.recorder = recorder
            sampleURL = url
            phase = .recording
            elapsed = 0
            ticker = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let recorder = self.recorder, recorder.isRecording else { return }
                    elapsed = recorder.currentTime
                }
            }
        } catch {
            phase = .failed("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    private func finish() async {
        ticker?.cancel()
        ticker = nil
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        guard let sampleURL else { return }
        phase = .processing
        do {
            try await diarizer.ensureModelsInstalled { _ in }
            let embedding = try await diarizer.enrollmentEmbedding(fileAt: sampleURL)
            VoiceEnrollment.enroll(embedding: embedding)
            VoiceEnrollment.setDisplayName(displayName)
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
        cleanUp()
    }

    /// The sample never outlives extraction: what is kept is the voiceprint,
    /// not a recording of the user.
    private func cleanUp() {
        ticker?.cancel()
        ticker = nil
        recorder?.stop()
        recorder = nil
        if let sampleURL { try? FileManager.default.removeItem(at: sampleURL) }
        sampleURL = nil
    }
}
