import AVFoundation
import FluidAudio
import Foundation
import OSLog

/// Production diarization: FluidAudio's offline "community" pipeline
/// (pyannote speaker-diarization-community-1) through Core ML.
///
/// The offline pipeline clusters better than the legacy one but has no
/// concept of a known speaker, so owner recognition is done here: it returns
/// an embedding per cluster, and the enrolled voiceprint is matched against
/// those by cosine distance. That keeps the better clustering *and* the
/// ability to say which turns are the owner's.
///
/// Models are bundled rather than fetched at runtime — the library's loader
/// would pull from HuggingFace, which would be this app's first third-party
/// network call. They are staged into the cache directory it expects on
/// first use, so it finds them locally and never reaches the network.
///
/// The models are CC-BY-4.0 (pyannote, converted by FluidInference) — see the
/// acknowledgements screen, which the licence requires.
/// Runs queued work one item at a time.
///
/// Needed because the diarizer is shared: `ProcessingCoordinator` uses it for
/// recordings and `VoiceEnrollmentView` uses it for enrolment, and nothing
/// otherwise stops a background recording being processed while someone
/// enrols. The pipeline serialises its own work; it does not serialise
/// against enrolment.
private actor SerialGate {
    private var tail: Task<Void, Never> = Task {}

    func run<T: Sendable>(_ work: @Sendable @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let work = Task<T, Error> {
            await previous.value
            return try await work()
        }
        // The tail must not carry the error, or one failure would stop the
        // queue; it exists only to order the next caller behind this one.
        tail = Task { _ = try? await work.value }
        return try await work.value
    }
}

/// Holds the library's manager off the main actor.
///
/// `@unchecked Sendable` is a real claim, not a silencer. The manager is a
/// plain class wrapping Core ML models the library treats as read-only after
/// initialization, and every entry point here funnels through `gate`, so
/// calls queue instead of overlapping. Remove the gate and the claim stops
/// being true.
private final class DiarizationEngine: @unchecked Sendable {
    private var manager: OfflineDiarizerManager?
    private let gate = SerialGate()

    func prepare(directory: URL) async throws {
        try await gate.run { [self] in
            guard manager == nil else { return }
            let manager = OfflineDiarizerManager(config: .default)
            try await manager.prepareModels(directory: directory)
            self.manager = manager
        }
    }

    func process(_ url: URL) async throws -> DiarizationResult {
        try await gate.run { [self] in
            guard let manager else { throw SpeakerDiarizer.DiarizationError.notReady }
            return try await manager.process(url)
        }
    }
}

@MainActor
final class SpeakerDiarizer: Diarizing {

    /// Maximum cosine distance from the enrolled voiceprint for a cluster to
    /// be considered the owner. Matches the library's own clustering
    /// threshold; untuned against real recordings, and the first constant to
    /// revisit if the owner is missed or over-claimed.
    static let ownerMatchThreshold: Float = 0.65

    private let log = Logger(subsystem: "dev.recursivesystems.openminutes", category: "diarization")
    private let engine = DiarizationEngine()
    /// Mirrors the engine's state so the protocol can answer synchronously.
    private(set) var isReady = false

    func ensureModelsInstalled(onProgress: (Progress) -> Void) async throws {
        guard !isReady else { return }
        onProgress(Progress(totalUnitCount: -1))
        try await engine.prepare(directory: try Self.stageBundledModels())
        isReady = true
    }

    func diarize(fileAt url: URL, enrolledOwner: [Float]?) async throws -> [SpeakerTurn] {
        let result = try await engine.process(url)
        let ownerCluster = enrolledOwner.flatMap {
            Self.closestCluster(to: $0, in: result.speakerDatabase ?? [:])
        }
        if enrolledOwner != nil, ownerCluster == nil {
            log.info("Enrolled voice matched no cluster; every speaker will be numbered")
        }
        return result.segments.map {
            SpeakerTurn(
                // Rewrite the owner's cluster to the reserved ID so the
                // coordinator can name it without knowing about clustering.
                speakerID: $0.speakerId == ownerCluster ? SpeakerIdentity.ownerID : $0.speakerId,
                start: TimeInterval($0.startTimeSeconds),
                end: TimeInterval($0.endTimeSeconds)
            )
        }
    }

    /// The dominant speaker's voiceprint from a sample of the owner alone.
    ///
    /// Enrolment asks for one voice, but a stray second one should not
    /// silently become the owner's identity, so the speaker with the most
    /// speech wins rather than the first one heard.
    func enrollmentEmbedding(fileAt url: URL) async throws -> [Float] {
        let result = try await engine.process(url)
        var totals: [String: TimeInterval] = [:]
        for segment in result.segments {
            totals[segment.speakerId, default: 0] +=
                TimeInterval(segment.endTimeSeconds - segment.startTimeSeconds)
        }
        guard let dominant = totals.max(by: { $0.value < $1.value })?.key,
              let embedding = result.speakerDatabase?[dominant], !embedding.isEmpty else {
            throw DiarizationError.noSpeechFound
        }
        log.info("Enrolled voice from \(totals[dominant] ?? 0, privacy: .public)s of speech")
        return embedding
    }

    /// Nearest cluster within `ownerMatchThreshold`, or nil when none is
    /// close enough — a wrong owner is worse than an unrecognised one.
    private static func closestCluster(
        to enrolled: [Float], in database: [String: [Float]]
    ) -> String? {
        var best: (id: String, distance: Float)?
        for (id, embedding) in database {
            guard let distance = cosineDistance(enrolled, embedding) else { continue }
            if best == nil || distance < best!.distance { best = (id, distance) }
        }
        guard let best, best.distance < ownerMatchThreshold else { return nil }
        return best.id
    }

    /// Nil when the vectors cannot be compared (mismatched size, or either
    /// one is degenerate) rather than returning a misleading distance.
    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return nil }
        return 1 - (dot / (normA.squareRoot() * normB.squareRoot()))
    }

    /// Copies the bundled models into the directory the loader looks in, so
    /// it finds them there instead of downloading. Idempotent.
    ///
    /// Staged copies are stamped with the build that wrote them and thrown
    /// away when a different build runs. Skipping files that already exist is
    /// the right check for a re-launch and the wrong one for an app update:
    /// the model files keep their names across versions, so an update would
    /// silently keep serving the old weights — or, worse, pair new PLDA
    /// parameters with old embeddings and degrade quietly instead of failing.
    private static func stageBundledModels() throws -> URL {
        let destination = URL.cachesDirectory.appending(path: "DiarizationModels", directoryHint: .isDirectory)
        let manager = FileManager.default
        let stamp = destination.appending(path: ".staged-build")
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "unknown"

        if (try? String(contentsOf: stamp, encoding: .utf8)) != build {
            try? manager.removeItem(at: destination)
        }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)

        let required = ["Segmentation.mlmodelc", "FBank.mlmodelc",
                        "Embedding.mlmodelc", "PldaRho.mlmodelc", "plda-parameters.json"]
        for name in required {
            let target = destination.appending(path: name)
            guard !manager.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            guard let source = Bundle.main.url(forResource: stem, withExtension: ext) else {
                throw DiarizationError.modelsMissing
            }
            try manager.copyItem(at: source, to: target)
        }
        // Written last, so an interrupted staging leaves no stamp and the
        // next launch re-stages rather than trusting a half-copied set.
        try? Data(build.utf8).write(to: stamp)
        return destination
    }

    enum DiarizationError: Error, LocalizedError {
        case modelsMissing
        case notReady
        case noSpeechFound

        var errorDescription: String? {
            switch self {
            case .modelsMissing: "Speaker models couldn't be loaded."
            case .notReady: "Speaker models aren't ready yet."
            case .noSpeechFound: "We couldn't hear enough speech. Try again somewhere quieter."
            }
        }
    }
}
