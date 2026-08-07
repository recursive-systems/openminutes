import Foundation
import Speech

/// The locale transcription runs in.
///
/// Defaults to the device locale, which is what the pipeline used implicitly
/// before this existed — so an upgrading user's behaviour does not change.
/// The stored value is a BCP-47 identifier and is also what lands in the
/// exported file's `language` key, so a folder of markdown stays unambiguous
/// once more than one language is in play.
///
/// `SpeechTranscriber` analyses one locale at a time: a meeting that switches
/// between languages mid-sentence transcribes poorly whichever is chosen, and
/// there is no on-device fix. The UI says so rather than letting people
/// discover it.
enum TranscriptionLanguage {

    static let storageKey = "transcriptionLanguage"

    /// Locales `SpeechTranscriber` can install a model for, sorted by the
    /// name shown to this user. Empty only if the framework reports nothing.
    static func supported() async -> [Locale] {
        let locales = await SpeechTranscriber.supportedLocales
        return locales.sorted { displayName(for: $0) < displayName(for: $1) }
    }

    /// The user's choice, falling back to the device locale. Never returns a
    /// locale the transcriber cannot handle — a stored value that stops being
    /// supported (OS change, removed model) degrades to the device default.
    static func current(in defaults: UserDefaults = .standard) -> Locale {
        guard let identifier = defaults.string(forKey: storageKey) else { return .current }
        return Locale(identifier: identifier)
    }

    static func set(_ locale: Locale?, in defaults: UserDefaults = .standard) {
        guard let locale else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        defaults.set(locale.identifier, forKey: storageKey)
    }

    /// True when the user has not chosen explicitly and is riding the device
    /// locale — worth showing, since it changes if they change iOS settings.
    static func isFollowingDeviceLocale(in defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: storageKey) == nil
    }

    /// Name in the user's own language ("Spanish (Spain)"), not the target
    /// language's — someone picking a language they don't read yet needs it.
    static func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
    }

    /// BCP-47 identifier written to the exported file's `language` key.
    static func tag(for locale: Locale) -> String {
        locale.identifier(.bcp47)
    }
}
