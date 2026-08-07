import SwiftUI

struct RecordingSessionView: View {
    @Bindable var recorder: RecorderService
    @Environment(LiveTranscriptionService.self) private var live
    var onFinish: (Recording) -> Void
    /// Persisted: the screen reopens on whichever view was last used.
    @AppStorage(LivePreferences.showsTranscriptKey) private var showsTranscript = false

    /// The elapsed timer is the screen's primary content, so it tracks the
    /// user's text size rather than sitting at a fixed 58pt.
    @ScaledMetric(relativeTo: .largeTitle) private var timerFontSize: CGFloat = 58

    private var isPaused: Bool { recorder.state == .paused }

    var body: some View {
        ZStack {
            RecordingSessionBackground(level: recorder.audioLevel)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 72)

                VStack(spacing: 18) {
                    // Scales with Dynamic Type instead of staying pinned at
                    // 58pt, but capped by minimumScaleFactor so a long
                    // elapsed time at accessibility sizes shrinks rather
                    // than wrapping or clipping.
                    Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                        .font(.system(size: timerFontSize, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .contentTransition(.numericText())
                        .accessibilityLabel("Elapsed time")

                    // A capture failure gets its own words. "Paused by
                    // interruption" describes something the system will often
                    // undo by itself; a dead engine needs the user to act.
                    if let failure = recorder.captureFailure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    } else if recorder.isInterrupted {
                        Text("Paused by interruption")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    // One or the other, never both: two things competing for
                    // the same glance means neither gets read.
                    Group {
                        if showsTranscript {
                            LiveTranscriptView(finalized: live.finalized, volatile: live.volatile)
                                .padding(.horizontal, 16)
                        } else {
                            LiveWaveform(levels: recorder.recentAudioLevels, isPaused: isPaused)
                                .frame(height: 220)
                                .padding(.horizontal, 10)
                                .accessibilityLabel(isPaused ? "Recording paused" : "Live recording waveform")
                        }
                    }
                    .frame(minHeight: 220)
                    .transition(.opacity)

                    modeToggle
                }
                .animation(.snappy, value: showsTranscript)
                .frame(maxWidth: .infinity)

                Spacer(minLength: 28)

                controls
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            }
            .foregroundStyle(.primary)
        }
        // Transcribing only runs while its view is on screen, so choosing the
        // waveform costs nothing. Switching mid-recording starts from that
        // moment — earlier speech is in the saved transcript regardless.
        .task(id: showsTranscript) {
            if showsTranscript {
                await live.start(locale: TranscriptionLanguage.current())
            } else {
                await live.stop()
            }
        }
        .onDisappear {
            Task { await live.stop() }
        }
    }

    private var modeToggle: some View {
        Button {
            showsTranscript.toggle()
        } label: {
            Label(showsTranscript ? "Show levels" : "Show transcript",
                  systemImage: showsTranscript ? "waveform" : "text.alignleft")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsTranscript
                            ? "Show audio levels instead of the transcript"
                            : "Show the transcript instead of audio levels")
    }

    private var controls: some View {
        HStack(spacing: 48) {
            Button {
                withAnimation(controlAnimation) {
                    isPaused ? recorder.resume() : recorder.pause()
                }
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 86, height: 86)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")

            if isPaused {
                Button {
                    if let finished = recorder.stop() {
                        onFinish(finished)
                    }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Color.recordRed)
                        .frame(width: 86, height: 86)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Finish recording")
                .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(controlAnimation, value: isPaused)
    }

    private var controlAnimation: Animation {
        .spring(response: 0.42, dampingFraction: 0.78)
    }
}

private struct LiveWaveform: View {
    let levels: [Double]
    let isPaused: Bool

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let samples = levels.isEmpty ? [0.04] : levels
                let spacing: CGFloat = 4
                let barWidth = max(3, (size.width - spacing * CGFloat(samples.count - 1)) / CGFloat(samples.count))
                let centerY = size.height / 2
                let maxHeight = size.height * 0.86
                let minimumHeight = size.height * 0.08

                for (index, sample) in samples.enumerated() {
                    let x = CGFloat(index) * (barWidth + spacing)
                    let emphasis = Double(index + 1) / Double(samples.count)
                    let shaped = max(0.04, min(1, sample)) * (0.72 + 0.28 * emphasis)
                    let height = max(minimumHeight, CGFloat(shaped) * maxHeight)
                    let rect = CGRect(
                        x: x,
                        y: centerY - height / 2,
                        width: barWidth,
                        height: height
                    )
                    let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                    let opacity = isPaused ? 0.35 : 0.38 + 0.62 * emphasis
                    context.fill(path, with: .color(Color.recordRed.opacity(opacity)))
                }
            }
            .overlay(alignment: .center) {
                Capsule()
                    .fill(.primary.opacity(isPaused ? 0.08 : 0.14))
                    .frame(width: proxy.size.width, height: 1)
            }
        }
    }
}

private struct RecordingSessionBackground: View {
    let level: Double

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(uiColor: .systemBackground),
                    Color.recordRed.opacity(0.08 + 0.10 * level),
                    Color(uiColor: .secondarySystemBackground)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

#Preview {
    let recorder = RecorderService()
    RecordingSessionView(recorder: recorder) { _ in }
        .environment(LiveTranscriptionService())
}
