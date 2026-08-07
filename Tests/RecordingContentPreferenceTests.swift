import Foundation
import Testing
@testable import OpenMinutes

@Suite("Recording content preference")
struct RecordingContentPreferenceTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "test.recordingContentPreference.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Fresh installs keep both: the other two options discard something
    /// permanently, and the onboarding badge marks this as recommended.
    @Test func defaultsToAudioAndTranscripts() {
        #expect(RecordingContentPreference.current(in: freshDefaults()) == .audioAndTranscripts)
        #expect(RecordingContentPreference.defaultValue.isRecommended)
    }

    @Test func legacyAudioExportBooleanMapsToAudioAndTranscripts() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: RecordingContentPreference.legacyAudioExportKey)

        #expect(RecordingContentPreference.current(in: defaults) == .audioAndTranscripts)
    }

    @Test func explicitPreferenceWinsOverLegacyBoolean() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: RecordingContentPreference.legacyAudioExportKey)
        defaults.set(RecordingContentPreference.audioOnly.rawValue,
                     forKey: RecordingContentPreference.storageKey)

        #expect(RecordingContentPreference.current(in: defaults) == .audioOnly)
    }
}
