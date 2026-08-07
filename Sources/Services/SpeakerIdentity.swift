import Foundation

/// Speaker identifiers and the labels shown for them.
///
/// IDs are stable and opaque (`s1`, `s2`, …); display names are per-recording
/// text the user can change. Nothing here identifies anyone across recordings
/// except the owner, who enrolled deliberately — see `VoiceEnrollment`.
enum SpeakerIdentity {

    /// The enrolled owner's slot. Diarization seeds this ID so the owner's
    /// turns are recognised rather than landing in an arbitrary cluster.
    static let ownerID = "s1"

    /// Everyone who is not the owner, in only-me mode. One ID covering
    /// several people is deliberate there — the point is not to guess how
    /// many others there were.
    static let othersID = "s2"
    static let othersLabel = "Other"

    /// Default label for a speaker the app cannot name. Numbered from the
    /// ID so two unnamed speakers never collide.
    ///
    /// Non-owner slots start at `s2` because `s1` is reserved for the owner
    /// whether or not anyone enrolled — so the count is offset by one. Naming
    /// straight from the ID instead produced transcripts that opened on
    /// "Speaker 2" and contained no Speaker 1 at all, which reads as a
    /// missing person rather than as a reserved slot nobody claimed.
    static func defaultLabel(for id: String, isOwner: Bool) -> String {
        if isOwner { return "You" }
        let slot = Int(id.dropFirst()) ?? 0
        return "Speaker \(max(1, slot - 1))"
    }

    /// Stable ID for the nth non-owner cluster the diarizer returns.
    static func id(forClusterIndex index: Int) -> String { "s\(index + 2)" }
}

/// The owner's enrolled voiceprint.
///
/// The only biometric template the app ever persists, and only for the person
/// who chose to enrol it, about themselves, on their own device. Other
/// speakers are clustered per-recording and their embeddings are discarded
/// when processing ends: storing those would mean holding biometric
/// identifiers for people who are not users and never consented.
///
/// Never exported. It exists in UserDefaults and nowhere else, and
/// `forget()` removes it completely.
enum VoiceEnrollment {

    private static let embeddingKey = "ownerVoiceEmbedding"
    private static let displayNameKey = "ownerDisplayName"

    static func embedding(in defaults: UserDefaults = .standard) -> [Float]? {
        guard let data = defaults.data(forKey: embeddingKey) else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static var isEnrolled: Bool { embedding() != nil }

    static func enroll(embedding: [Float], in defaults: UserDefaults = .standard) {
        let data = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
        defaults.set(data, forKey: embeddingKey)
    }

    static func forget(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: embeddingKey)
    }

    /// Written into exported files where the UI says "You" — a file saying
    /// "You" is ambiguous to anyone who is not the owner reading it, and the
    /// file is a public contract meant to be read by other tools and people.
    static func displayName(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: displayNameKey)?.trimmingCharacters(in: .whitespaces).nilWhenEmpty
    }

    static func setDisplayName(_ name: String?, in defaults: UserDefaults = .standard) {
        let trimmed = name?.trimmingCharacters(in: .whitespaces).nilWhenEmpty
        guard let trimmed else {
            defaults.removeObject(forKey: displayNameKey)
            return
        }
        defaults.set(trimmed, forKey: displayNameKey)
    }
}

private extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}
