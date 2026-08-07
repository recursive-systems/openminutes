import Foundation
import Testing
@testable import OpenMinutes

@Suite("Transcription language selection")
struct TranscriptionLanguageTests {

    private func freshDefaults() -> UserDefaults {
        let suite = "test.transcriptionLanguage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Upgrading users had no setting, and the pipeline used the device
    /// locale — that must stay true until they choose otherwise.
    @Test func defaultsToDeviceLocaleAndSaysSo() {
        let defaults = freshDefaults()
        #expect(TranscriptionLanguage.current(in: defaults) == .current)
        #expect(TranscriptionLanguage.isFollowingDeviceLocale(in: defaults))
    }

    @Test func storesAndClearsAnExplicitChoice() {
        let defaults = freshDefaults()
        let spanish = Locale(identifier: "es_ES")

        TranscriptionLanguage.set(spanish, in: defaults)
        #expect(TranscriptionLanguage.current(in: defaults) == spanish)
        #expect(!TranscriptionLanguage.isFollowingDeviceLocale(in: defaults))

        TranscriptionLanguage.set(nil, in: defaults)
        #expect(TranscriptionLanguage.current(in: defaults) == .current)
        #expect(TranscriptionLanguage.isFollowingDeviceLocale(in: defaults))
    }

    /// The exported `language` key is BCP-47, not Foundation's underscored
    /// identifier — `es-ES`, never `es_ES`.
    @Test func tagIsBCP47() {
        #expect(TranscriptionLanguage.tag(for: Locale(identifier: "es_ES")) == "es-ES")
        #expect(TranscriptionLanguage.tag(for: Locale(identifier: "en_US")) == "en-US")
    }

    /// Deliberately does not assert a non-empty list: `SpeechTranscriber`
    /// reports no supported locales on the simulator (the speech stack is
    /// device-only), so requiring one here would fail every CI run. What it
    /// does guarantee is the ordering contract the picker relies on, and
    /// that an empty list is returned rather than thrown.
    @Test func supportedLocalesAreSortedByDisplayName() async {
        let locales = await TranscriptionLanguage.supported()
        let names = locales.map { TranscriptionLanguage.displayName(for: $0) }
        #expect(names == names.sorted())
    }
}
