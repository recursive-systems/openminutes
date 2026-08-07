import AVFoundation
import Foundation
import Testing
@testable import OpenMinutes

/// Exercises the real capture path — engine, converter, and file writes.
///
/// Worth having as a test rather than only a manual check: `AVAudioFile.write`
/// raises an Objective-C exception on a format mismatch, which Swift cannot
/// catch, so the failure mode is an instant crash on tapping record. That is
/// exactly the class of bug a compile-and-launch check misses.
@MainActor
@Suite("Recorder capture", .serialized)
struct RecorderServiceTests {

    private func recordBriefly() async throws -> Recording? {
        let recorder = RecorderService()
        try recorder.start()
        #expect(recorder.state == .recording)
        try await Task.sleep(for: .milliseconds(700))
        return recorder.stop()
    }

    @Test func startsAndStopsWritingAReadableFile() async throws {
        let recording = try await recordBriefly()
        let finished = try #require(recording)
        defer { try? FileManager.default.removeItem(at: finished.audioURL) }

        #expect(FileManager.default.fileExists(atPath: finished.audioURL.path(percentEncoded: false)))
        #expect(finished.duration > 0)

        // Readable by AVFoundation means the container and encoder tail were
        // written properly, not just that bytes landed on disk.
        let file = try AVAudioFile(forReading: finished.audioURL)
        #expect(file.length > 0)
        #expect(file.fileFormat.sampleRate == RecorderService.sampleRate)
        #expect(file.fileFormat.channelCount == 1)
    }

    /// Pause must not end the recording or reset what was captured.
    @Test func pauseAndResumeKeepsOneFile() async throws {
        let recorder = RecorderService()
        try recorder.start()
        try await Task.sleep(for: .milliseconds(300))
        recorder.pause()
        #expect(recorder.state == .paused)
        let atPause = recorder.elapsed

        recorder.resume()
        #expect(recorder.state == .recording)
        try await Task.sleep(for: .milliseconds(300))

        let finished = try #require(recorder.stop())
        defer { try? FileManager.default.removeItem(at: finished.audioURL) }
        #expect(recorder.state == .idle)
        #expect(finished.duration >= atPause)
    }

    /// The buffer hand-off live transcription depends on: every captured
    /// buffer arrives in the file's own format.
    @Test func forwardsBuffersInTheRecordingFormat() async throws {
        let recorder = RecorderService()
        let seen = BufferSpy()
        recorder.bufferHandler = { seen.record($0) }

        try recorder.start()
        try await Task.sleep(for: .milliseconds(700))
        let finished = recorder.stop()
        if let finished { try? FileManager.default.removeItem(at: finished.audioURL) }

        #expect(seen.count > 0)
        #expect(seen.sampleRates.allSatisfy { $0 == RecorderService.sampleRate })
        #expect(seen.channelCounts.allSatisfy { $0 == 1 })
    }
}

/// Collects what the audio thread hands over. Locked because the tap runs off
/// the main actor.
private final class BufferSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var rates: [Double] = []
    private var channels: [AVAudioChannelCount] = []

    func record(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        rates.append(buffer.format.sampleRate)
        channels.append(buffer.format.channelCount)
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return rates.count }
    var sampleRates: [Double] { lock.lock(); defer { lock.unlock() }; return rates }
    var channelCounts: [AVAudioChannelCount] { lock.lock(); defer { lock.unlock() }; return channels }
}
