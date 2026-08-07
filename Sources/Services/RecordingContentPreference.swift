import Foundation

/// Case order is the presentation order everywhere (`allCases` drives both
/// onboarding and Settings): the recommended, least-surprising option first,
/// then the two lossy ones.
enum RecordingContentPreference: String, CaseIterable, Identifiable {
    case audioAndTranscripts
    case audioOnly
    case transcriptsOnly

    static let storageKey = "recordingContentPreference"
    static let legacyAudioExportKey = "exportAudioEnabled"
    /// Keeping both is the safe default — the other two discard something
    /// permanently, and a first-run user cannot yet know which they want.
    /// Only affects fresh installs; `current(in:)` reads a stored choice first.
    static let defaultValue: Self = .audioAndTranscripts

    var id: String { rawValue }

    /// Surfaced as a badge in onboarding; keeps the suggested option and the
    /// preselected option from disagreeing.
    var isRecommended: Bool { self == .defaultValue }

    var title: String {
        switch self {
        case .transcriptsOnly: "Transcripts only"
        case .audioOnly: "Raw audio only"
        case .audioAndTranscripts: "Audio and transcripts"
        }
    }

    var detail: String {
        switch self {
        case .transcriptsOnly:
            "Create searchable transcripts and remove the raw audio after processing."
        case .audioOnly:
            "Keep and export the original recording without generating a transcript."
        case .audioAndTranscripts:
            "Keep the original recording and create a transcript for each note."
        }
    }

    var includesAudio: Bool {
        switch self {
        case .transcriptsOnly: false
        case .audioOnly, .audioAndTranscripts: true
        }
    }

    var includesTranscript: Bool {
        switch self {
        case .audioOnly: false
        case .transcriptsOnly, .audioAndTranscripts: true
        }
    }

    static var current: Self {
        get { current(in: .standard) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }

    static func current(in defaults: UserDefaults) -> Self {
        if let rawValue = defaults.string(forKey: storageKey),
           let preference = Self(rawValue: rawValue) {
            return preference
        }

        // Preserve the old boolean export preference for existing installs.
        if defaults.bool(forKey: legacyAudioExportKey) {
            return .audioAndTranscripts
        }

        return defaultValue
    }
}
