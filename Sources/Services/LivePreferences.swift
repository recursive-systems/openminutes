import Foundation

/// Which view the recording screen shows: audio levels or the live
/// transcript. They are alternatives, not companions — two things competing
/// for the same glance means neither is read.
///
/// Levels for a fresh install. They answer the only question that matters
/// mid-recording — is this thing hearing me — instantly and at a glance,
/// where text has to be read. Without an export destination, transcribing
/// also runs a second speech model only while it is shown, so levels are
/// the cheaper default too. When the live file is being written, the model
/// runs for the whole session regardless of this toggle.
///
/// The switch on the recording screen writes straight here, so the app simply
/// stays where it was left. There is no separate setting: a preference the
/// user can set in the place they notice wanting it does not need a second
/// home in a list.
enum LivePreferences {
    static let showsTranscriptKey = "liveShowsTranscript"

    static var showsTranscript: Bool {
        get { UserDefaults.standard.bool(forKey: showsTranscriptKey) }
        set { UserDefaults.standard.set(newValue, forKey: showsTranscriptKey) }
    }
}
