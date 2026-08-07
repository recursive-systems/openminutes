import Foundation

/// The one line a user hands to whatever assistant they already use.
///
/// Deliberately a pointer, not a snapshot. It names the folder and a URL,
/// and the URL carries the format contract, the caveats about speaker
/// labels, and the link to the Agent Skill. When the format gains a key or
/// the skill moves, everyone who ever pasted this gets the new version,
/// because they pasted an address rather than a copy.
///
/// It is also vendor-neutral by construction. There is no integration to
/// build per assistant and nothing to maintain when one of them changes an
/// API: it is instructions for a model, and every model can follow them.
enum SetupPrompt {

    /// Where the format, the caveats, and the skill all live.
    static let referenceURL = "https://openminutes.app/llms.txt"

    /// Built from the destination the user actually picked, so it names
    /// their folder rather than an example. A prompt that says
    /// "iCloud Drive" to someone who chose a folder in their Obsidian vault
    /// is worse than no prompt: they have to work out what to substitute.
    static func text(destination: String?) -> String {
        let place = destination.map { "in \($0)" } ?? "in the folder OpenMinutes exports to"
        return """
        Read \(referenceURL) first. My meeting recordings are \(place). \
        Each one is a folder with a transcript, the audio, or both. \
        Help me search and answer questions across them.
        """
    }
}
