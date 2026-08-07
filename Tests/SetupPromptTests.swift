import Foundation
import Testing
@testable import OpenMinutes

@Suite("Setup prompt")
struct SetupPromptTests {

    /// The line has to name the folder the user actually picked. Saying
    /// "iCloud Drive" to someone who chose a folder in their Obsidian vault
    /// is worse than saying nothing: they have to work out the substitution.
    @Test func namesTheChosenDestination() {
        let text = SetupPrompt.text(destination: "Obsidian › Meetings")
        #expect(text.contains("in Obsidian › Meetings"))
    }

    /// Before a destination exists the line still has to make sense.
    @Test func staysReadableWithNoDestination() {
        let text = SetupPrompt.text(destination: nil)
        #expect(text.contains("the folder OpenMinutes exports to"))
        #expect(!text.contains("in nil"))
    }

    /// A pointer, not a snapshot: the whole point is that the reference can
    /// change without every user re-pasting.
    @Test func carriesTheReferenceURL() {
        #expect(SetupPrompt.text(destination: "anywhere").contains(SetupPrompt.referenceURL))
    }

    /// The rule in AGENTS.md covers every string that renders, and this one
    /// renders inside somebody else's assistant.
    @Test func containsNoEmDash() {
        #expect(!SetupPrompt.text(destination: "iCloud Drive › OpenMinutes").contains("\u{2014}"))
    }

    /// Short enough to paste on a phone without it becoming a wall.
    @Test func staysShort() {
        #expect(SetupPrompt.text(destination: "iCloud Drive › OpenMinutes").count < 260)
    }
}
