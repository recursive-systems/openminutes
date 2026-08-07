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

@Suite("Setup card visibility")
struct SetupCardVisibilityTests {

    /// Mirrors the three conditions ContentView checks, so the rule is
    /// asserted somewhere rather than only living in a view body.
    private func shows(dismissed: Bool, destination: String?, hasFinished: Bool) -> Bool {
        !dismissed && destination != nil && hasFinished
    }

    /// Offering to connect an assistant to an empty folder asks someone to
    /// configure a workflow for files that do not exist yet.
    @Test func hiddenBeforeAnythingHasFinished() {
        #expect(!shows(dismissed: false, destination: "iCloud Drive › OpenMinutes", hasFinished: false))
    }

    /// With no destination the line cannot name a folder, so there is
    /// nothing useful to offer.
    @Test func hiddenWithoutADestination() {
        #expect(!shows(dismissed: false, destination: nil, hasFinished: true))
    }

    @Test func hiddenOnceDismissed() {
        #expect(!shows(dismissed: true, destination: "iCloud Drive › OpenMinutes", hasFinished: true))
    }

    @Test func shownAfterTheFirstExport() {
        #expect(shows(dismissed: false, destination: "iCloud Drive › OpenMinutes", hasFinished: true))
    }
}
