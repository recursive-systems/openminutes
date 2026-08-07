import Foundation

/// Whether the pipeline attributes transcript lines to speakers, and how
/// finely.
///
/// Off by default. The stage costs a second ML pass over the audio and needs
/// ~13MB of models, so it stays opt-in — and a transcript without speaker
/// labels is exactly what the app produced before this existed.
enum SpeakerPreferences {
    static let enabledKey = "speakerLabelsEnabled"
    static let modeKey = "speakerLabelMode"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// How many people the labels distinguish.
    enum Mode: String, CaseIterable, Identifiable {
        /// Every distinct voice gets its own label.
        case everyone
        /// Only the enrolled owner is named; everyone else collapses into a
        /// single "Other".
        case onlyMe

        var id: String { rawValue }

        var title: String {
            switch self {
            case .everyone: "Everyone"
            case .onlyMe: "Only me"
            }
        }

        /// Only-me mode is strictly more reliable, and worth saying so: the
        /// owner's boundary is the one anchored to an enrolled voiceprint,
        /// while telling other people apart from each other is where
        /// clustering makes most of its mistakes. Collapsing them hides
        /// errors that only-me mode never has to make.
        var detail: String {
            switch self {
            case .everyone:
                "Names you and numbers everyone else. More detail, and more mistakes: telling other people apart is the least reliable part."
            case .onlyMe:
                "Marks your turns and labels everyone else “Other”. Less detail, but noticeably more reliable, because only your voice has to be recognised."
            }
        }
    }

    static var mode: Mode {
        get {
            UserDefaults.standard.string(forKey: modeKey).flatMap(Mode.init(rawValue:)) ?? .everyone
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }
}
