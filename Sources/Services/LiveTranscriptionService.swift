import AVFoundation
import Foundation
import OSLog
import Speech

/// Transcribes while recording, for the on-screen follow-along.
///
/// Entirely separate from the pipeline that produces the saved transcript:
/// this one is disposable. The recording is still transcribed properly from
/// the file afterwards, so nothing here can cost the user their transcript —
/// if live transcription fails, stalls, or is switched off, the on-screen
/// text and the in-progress export file are what go missing, never the
/// recording.
///
/// `volatileResults` gives the in-flight guess that firms up as more audio
/// arrives, which is what makes the display track speech rather than lurch
/// forward a sentence at a time.
@MainActor
@Observable
final class LiveTranscriptionService {

    /// Settled lines, oldest first. Only the tail is shown on screen; the
    /// live export writes the whole list.
    private(set) var finalized: [TimedLine] = []
    /// The current in-flight guess, replaced as it firms up.
    private(set) var volatile: String = ""
    private(set) var isRunning = false

    /// Fired on the main actor after a line settles. Live export uses this
    /// to debounce a rewrite; the UI observes `finalized` directly.
    var onFinalizedChange: (@MainActor () -> Void)?

    /// Elapsed recording time, used when a live result has no audio range.
    var elapsedProvider: @MainActor () -> TimeInterval = { 0 }

    private let log = Logger(subsystem: "dev.recursivesystems.openminutes", category: "live")
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    /// Best effort by design: a failure here leaves `isRunning` false and the
    /// UI simply shows no live text.
    func start(locale: Locale) async {
        guard !isRunning else { return }
        finalized = []
        volatile = ""

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            log.info("No compatible live audio format; skipping live transcription")
            return
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        self.transcriber = transcriber

        guard let recorderFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: RecorderService.sampleRate,
            channels: 1, interleaved: false
        ) else { return }
        feedBox.value = BufferFeed(target: analyzerFormat, source: recorderFormat,
                                   continuation: continuation)

        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber])
        self.analyzer = analyzer

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if result.isFinal {
                        let start = Self.startTime(of: result) ?? self.elapsedProvider()
                        let end = Self.endTime(of: result) ?? start
                        self.finalized.append(TimedLine(start: start, end: end, text: text))
                        self.volatile = ""
                        self.onFinalizedChange?()
                    } else {
                        self.volatile = text
                    }
                }
            } catch {
                self?.log.error("Live transcription ended: \(error.localizedDescription, privacy: .public)")
            }
        }
        isRunning = true
    }

    /// Called from the audio thread. Must not block or hop actors.
    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        feedBox.value?.send(buffer)
    }

    func stop() async {
        isRunning = false
        continuation?.finish()
        continuation = nil
        feedBox.value = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        transcriber = nil
        resultsTask?.cancel()
        resultsTask = nil
        volatile = ""
    }

    /// The audio thread reads this without touching the main actor.
    private let feedBox = FeedBox()

    /// Per-run audioTimeRange is the engine's own alignment. Same rule as the
    /// file transcriber: never infer a token's timing from its neighbours.
    private static func startTime(of result: SpeechTranscriber.Result) -> TimeInterval? {
        for run in result.text.runs {
            if let range = run.audioTimeRange { return range.start.seconds }
        }
        return result.range.start.seconds
    }

    private static func endTime(of result: SpeechTranscriber.Result) -> TimeInterval? {
        var last: TimeInterval?
        for run in result.text.runs {
            if let range = run.audioTimeRange { last = range.end.seconds }
        }
        return last ?? result.range.end.seconds
    }
}

/// Holds the feed so the nonisolated audio path can reach it without hopping
/// to the main actor.
private final class FeedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: BufferFeed?

    var value: BufferFeed? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}

/// Converts recorder buffers into the analyzer's format and yields them.
/// `@unchecked Sendable` for the same reason as the recorder's sink: only the
/// audio thread uses it, and AVFoundation delivers taps serially.
private final class BufferFeed: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation

    init?(target: AVAudioFormat, source: AVAudioFormat,
          continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.target = target
        self.continuation = continuation
        // Identical formats need no converter; the common case on a
        // speech-tuned 16 kHz recording.
        self.converter = target.isEqual(source) ? nil : AVAudioConverter(from: source, to: target)
        if !target.isEqual(source), converter == nil { return nil }
    }

    func send(_ buffer: AVAudioPCMBuffer) {
        guard let converter else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

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
        continuation.yield(AnalyzerInput(buffer: converted))
    }
}
