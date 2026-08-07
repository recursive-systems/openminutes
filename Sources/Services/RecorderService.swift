import AVFoundation
import Foundation

/// Audio capture with real pause/resume (the thing Shortcuts can't do)
/// and background recording (UIBackgroundModes: audio).
///
/// Hardened per PRD A4: phone-call interruptions auto-pause and, when the
/// system allows, auto-resume; route changes (AirPods disconnect) never stop
/// the recording — capture falls back to the built-in mic.
///
/// Built on `AVAudioEngine` rather than `AVAudioRecorder` because live
/// transcription needs the sample buffers, and `AVAudioRecorder` only ever
/// hands back a finished file. Two things cannot own the microphone, so the
/// engine writes the file itself and forwards the same buffers to
/// `bufferHandler`. Crash safety is unchanged in kind: buffers are written as
/// they arrive, so a force-quit loses only what has not yet been flushed.
@MainActor
@Observable
final class RecorderService {
    enum State { case idle, recording, paused }

    /// Lifecycle events for the Live Activity (wired by AppServices so the
    /// recorder stays AVFoundation-pure). `resumed` carries an adjusted
    /// start date (now - elapsed) so interval timers survive pauses.
    enum ActivityEvent {
        case started(Date)
        case paused(adjustedStart: Date)
        case resumed(adjustedStart: Date)
        case stopped
    }

    var activityHandler: ((ActivityEvent) -> Void)?

    /// Receives every captured buffer, already converted to the recording
    /// format. Set by whoever wants live transcription; nil costs nothing.
    /// Called off the main actor — the tap runs on a realtime audio thread,
    /// and blocking it drops audio.
    nonisolated(unsafe) var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    enum RecorderError: Error, LocalizedError {
        case microphoneDenied
        case engineUnavailable

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                "Microphone access is off. Enable it in Settings → Privacy & Security → Microphone."
            case .engineUnavailable:
                "The microphone couldn't be started. Try again."
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var audioLevel: Double = 0
    private(set) var recentAudioLevels: [Double] = Array(repeating: 0.04, count: 72)
    /// True while paused because of a system interruption (call, Siri, alarm)
    /// rather than a user tap — lets the UI say why recording stopped.
    private(set) var isInterrupted = false
    /// Set when capture stopped for a reason the user has to know about, and
    /// nil whenever capture is healthy. Recording that has died must never
    /// look like recording that is running: the elapsed timer reads from the
    /// frame counter, so a dead engine shows a frozen clock — which looks far
    /// more like a UI glitch than like lost audio, and the user keeps talking.
    private(set) var captureFailure: String?

    /// Speech-optimized and small; also what the speech models want.
    static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var timer: Timer?
    private var currentID = UUID()
    private var startedAt = Date()
    private var url: URL?
    private var observers: [NSObjectProtocol] = []
    private var isTapInstalled = false

    /// Written from the audio thread, read on the main actor. A plain counter
    /// of frames actually committed to the file, so elapsed time reflects
    /// what was recorded rather than wall-clock.
    private let recordedFrames = FrameCounter()

    init() {
        observeAudioSession()
    }

    isolated deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func start() throws {
        guard AVAudioApplication.shared.recordPermission != .denied else {
            throw RecorderError.microphoneDenied
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        currentID = UUID()
        startedAt = Date()
        isInterrupted = false
        recordedFrames.reset()

        let url = Recording.audioDirectory.appending(path: "\(currentID.uuidString).m4a")
        self.url = url

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        self.file = file

        // The write target is the file's own processingFormat, never one we
        // construct: `write(from:)` raises an Objective-C exception — which
        // Swift cannot catch, so it is an instant crash — if the buffer
        // format differs from it by even a channel layout.
        let recordingFormat = file.processingFormat

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.engineUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
            throw RecorderError.engineUnavailable
        }
        self.converter = converter

        installTap(inputFormat: inputFormat, recordingFormat: recordingFormat)
        engine.prepare()
        try engine.start()

        state = .recording
        captureFailure = nil
        startTimer()
        activityHandler?(.started(startedAt))
    }

    func pause() {
        engine.pause()
        state = .paused
        audioLevel = 0
        isInterrupted = false
        captureFailure = nil
        timer?.invalidate()
        activityHandler?(.paused(adjustedStart: Date().addingTimeInterval(-elapsed)))
    }

    func resume() {
        // The session may have been deactivated by an interruption.
        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            try engine.start()   // appends to the same file; frame count continues
        } catch {
            // Announcing .recording on a dead engine is the worst outcome
            // available here: the screen says recording, the file never grows.
            reportCaptureFailure()
            return
        }
        captureFailure = nil
        state = .recording
        isInterrupted = false
        startTimer()
        activityHandler?(.resumed(adjustedStart: Date().addingTimeInterval(-elapsed)))
    }

    /// Turns a capture stall into an honest pause the user can act on.
    ///
    /// Every path that can leave the engine stopped mid-recording routes
    /// through here, so there is one place where "capture died" becomes
    /// visible state rather than a silently paused engine under a running UI.
    private func reportCaptureFailure() {
        engine.pause()
        state = .paused
        isInterrupted = true
        captureFailure = RecorderError.engineUnavailable.errorDescription
        audioLevel = 0
        timer?.invalidate()
        activityHandler?(.paused(adjustedStart: Date().addingTimeInterval(-elapsed)))
    }

    /// Stops and returns the finished Recording (untranscribed).
    func stop() -> Recording? {
        guard let url else { return nil }
        let duration = Double(recordedFrames.value) / Self.sampleRate

        teardownEngine()
        // Releasing the file closes it, flushing the encoder's tail.
        file = nil
        converter = nil
        timer?.invalidate()
        state = .idle
        elapsed = 0
        audioLevel = 0
        recentAudioLevels = Array(repeating: 0.04, count: 72)
        isInterrupted = false
        try? AVAudioSession.sharedInstance().setActive(false)
        activityHandler?(.stopped)
        self.url = nil

        return Recording(
            id: currentID,
            title: Recording.defaultTitle(for: startedAt),
            audioFileName: url.lastPathComponent,
            createdAt: startedAt,
            duration: duration
        )
    }

    // MARK: - Capture

    /// `recordingFormat` must be the file's `processingFormat` — see `start()`.
    private func installTap(inputFormat: AVAudioFormat, recordingFormat: AVAudioFormat) {
        removeTap()
        guard let file, let converter else { return }
        let sink = CaptureSink(file: file, converter: converter, recordingFormat: recordingFormat,
                               counter: recordedFrames, levels: LevelBox(), handler: bufferHandler)
        self.sink = sink

        // `@Sendable` is load-bearing, not decoration. A closure written
        // inside a @MainActor method inherits that isolation, and AVFoundation
        // calls this one on a realtime audio thread — which trips Swift's
        // executor check and traps before a single buffer is written. Marking
        // it @Sendable detaches it, which in turn forces everything it touches
        // into CaptureSink.
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            @Sendable buffer, _ in
            sink.process(buffer)
        }
        isTapInstalled = true
    }

    private func removeTap() {
        guard isTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        isTapInstalled = false
    }

    private func teardownEngine() {
        removeTap()
        sink = nil
        engine.stop()
        engine.reset()
    }

    private var sink: CaptureSink?

    // MARK: - Audio session notifications (PRD A4)

    private func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { note in
            // Extract Sendable scalars before hopping isolation domains.
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { [weak self] in
                self?.handleInterruption(typeValue: typeValue, optionsValue: optionsValue)
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { note in
            let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { [weak self] in
                self?.handleRouteChange(reasonValue: reasonValue)
            }
        })
    }

    private func handleInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard let typeValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // The system already stopped the engine; mirror it so the UI is
            // honest and the user never silently loses audio.
            guard state == .recording else { return }
            engine.pause()
            timer?.invalidate()
            state = .paused
            audioLevel = 0
            isInterrupted = true
            activityHandler?(.paused(adjustedStart: Date().addingTimeInterval(-elapsed)))

        case .ended:
            guard state == .paused, isInterrupted else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
            if options.contains(.shouldResume) {
                resume()
            }
            // Otherwise stay paused; the UI shows the interrupted-pause state
            // and the user resumes manually.

        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonValue: UInt?) {
        guard let reasonValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        // AirPods disconnect (or any input vanishing) must not end the
        // recording: the engine's input format changes with the route, so the
        // tap is rebuilt against the new one and capture continues from
        // whatever input remains.
        guard reason == .oldDeviceUnavailable || reason == .newDeviceAvailable,
              state == .recording else { return }
        rebuildTapForCurrentRoute()
    }

    private func rebuildTapForCurrentRoute() {
        guard let file else { return }
        let recordingFormat = file.processingFormat
        engine.pause()
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
            // The engine is already paused by the line above, so returning
            // here used to leave a stopped engine under a `.recording` state
            // — the AirPods-disconnect case, and silent.
            reportCaptureFailure()
            return
        }
        self.converter = converter
        installTap(inputFormat: inputFormat, recordingFormat: recordingFormat)
        do { try engine.start() } catch { reportCaptureFailure() }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            // The timer fires on the main run loop; tell the compiler so.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = Double(self.recordedFrames.value) / Self.sampleRate
                self.audioLevel = self.sink?.level ?? 0.04
                self.recentAudioLevels.append(self.audioLevel)
                if self.recentAudioLevels.count > 72 {
                    self.recentAudioLevels.removeFirst(self.recentAudioLevels.count - 72)
                }
            }
        }
    }
}

/// Frame count shared between the audio thread and the main actor.
/// A lock rather than an actor: the audio thread cannot await, and this is a
/// single integer.
private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: AVAudioFramePosition = 0

    var value: AVAudioFramePosition {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    func add(_ count: AVAudioFrameCount) {
        lock.lock(); defer { lock.unlock() }
        frames += AVAudioFramePosition(count)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        frames = 0
    }
}

/// Latest audio level, written on the audio thread and sampled by the UI
/// timer. Only the most recent value matters, so it is overwritten rather
/// than queued.
private final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Double = 0.04

    func record(_ level: Double) {
        lock.lock(); defer { lock.unlock() }
        latest = level
    }

    func take() -> Double {
        lock.lock(); defer { lock.unlock() }
        return latest
    }
}

/// Everything the audio thread touches, in one place.
///
/// `@unchecked Sendable` because `AVAudioFile` and `AVAudioConverter` are not
/// `Sendable`, but nothing outside the tap ever reaches them and AVFoundation
/// delivers taps serially. Boxing them here is what lets the tap closure be
/// `@Sendable` and so escape main-actor isolation.
private final class CaptureSink: @unchecked Sendable {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let recordingFormat: AVAudioFormat
    private let counter: FrameCounter
    private let levels: LevelBox
    private let handler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    init(file: AVAudioFile, converter: AVAudioConverter, recordingFormat: AVAudioFormat,
         counter: FrameCounter, levels: LevelBox,
         handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        self.file = file
        self.converter = converter
        self.recordingFormat = recordingFormat
        self.counter = counter
        self.levels = levels
        self.handler = handler
    }

    var level: Double { levels.take() }

    func process(_ buffer: AVAudioPCMBuffer) {
        let ratio = recordingFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: recordingFormat, frameCapacity: capacity)
        else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0 else { return }
        // Belt and braces: a format drift here is a crash, not a throw.
        guard converted.format.isEqual(file.processingFormat) else { return }

        try? file.write(from: converted)
        counter.add(converted.frameLength)
        levels.record(Self.peakLevel(of: converted))
        handler?(converted)
    }

    /// Matches the curve the old metering produced, so the waveform is
    /// unchanged: -60dB floor, gently compressed.
    private static func peakLevel(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0.04 }
        var peak: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(channel[index]))
        }
        let decibels = peak > 0 ? 20 * log10(peak) : -60
        let floor: Float = -60
        let clamped = min(max(decibels, floor), 0)
        let linear = 1 - Double(clamped / floor)
        return max(0.04, pow(linear, 0.7))
    }
}
