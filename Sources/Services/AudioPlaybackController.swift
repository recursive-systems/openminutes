import AVFoundation
import Foundation
import Observation

/// Plays back a recording's saved audio file.
///
/// View-scoped rather than an `AppServices` singleton: playback belongs to
/// the detail screen that started it and must stop when that screen closes.
///
/// No `AVAudioPlayerDelegate`: its callbacks arrive off the main actor and
/// the type is not `Sendable`, so completion is observed from the same tick
/// that already drives the scrubber. One mechanism instead of two.
@MainActor
@Observable
final class AudioPlaybackController {

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// The row still renders when true, explaining itself rather than
    /// silently doing nothing on tap (build plan §2: never fail quietly).
    private(set) var loadFailed = false

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    /// Safe to call repeatedly; only the first load for a given URL builds a
    /// player. Returns quietly when the file is gone — a transcript-only
    /// recording has had its audio discarded on purpose.
    func load(url: URL) {
        guard player == nil, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            ticker?.cancel()
            ticker = nil
            return
        }
        // The recorder leaves the session on `.record` and deactivated;
        // playback needs its own category or it routes to the receiver.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            loadFailed = true
            return
        }
        // Restart from the top once finished, rather than no-oping on tap.
        if player.currentTime >= player.duration { player.currentTime = 0 }
        player.play()
        isPlaying = true
        startTicking()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, time), player.duration)
        player.currentTime = clamped
        currentTime = clamped
    }

    /// Call when the view disappears: playback must not outlive the screen.
    func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// 40ms, not 100: word highlighting reads this, and a short word can be
    /// under 150ms — at a coarser tick it would be skipped entirely.
    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, let player = self.player, self.isPlaying else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {   // reached the end
                    self.isPlaying = false
                    self.currentTime = player.duration
                    try? AVAudioSession.sharedInstance().setActive(false)
                    return
                }
            }
        }
    }
}
