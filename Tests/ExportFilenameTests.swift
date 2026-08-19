import Foundation
import Testing
@testable import OpenMinutes

@Suite("Export filenames (slug + collision)")
struct ExportFilenameTests {

    private static let chicago = TimeZone(identifier: "America/Chicago")!

    private static func fixedDate() -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 6; components.day = 9
        components.hour = 14; components.minute = 9
        components.timeZone = chicago
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test func slugBasics() {
        #expect(ExportFilename.slug("Standup with platform team") == "standup-with-platform-team")
        #expect(ExportFilename.slug("Recording Jun 9, 2026 at 2:09 PM") == "recording-jun-9-2026-at-2-09-pm")
    }

    @Test func slugFoldsDiacriticsAndCJK() {
        #expect(ExportFilename.slug("Übergabe Café 北京") == "ubergabe-cafe-bei-jing")
    }

    @Test func slugNeverEmpty() {
        #expect(ExportFilename.slug("") == "recording")
        #expect(ExportFilename.slug("!!! ???") == "recording")
    }

    @Test func slugRespectsMaxLengthWithoutTrailingHyphen() {
        let long = ExportFilename.slug(String(repeating: "word ", count: 40), maxLength: 24)
        #expect(long.count <= 24)
        #expect(!long.hasSuffix("-"))
    }

    @Test func filenameMatchesSpecPattern() {
        let base = ExportFilename.base(
            title: "Standup with platform team",
            recorded: Self.fixedDate(),
            timeZone: Self.chicago
        )
        #expect(base == "2026-06-09-1409 standup-with-platform-team")
    }

    @Test func collisionsGetNumericSuffixes() {
        var taken: Set<String> = ["b.md", "b-2.md"]
        #expect(ExportFilename.unique(base: "a", ext: "md") { taken.contains($0) } == "a.md")
        #expect(ExportFilename.unique(base: "b", ext: "md") { taken.contains($0) } == "b-3.md")
        taken.insert("b-3.md")
        #expect(ExportFilename.unique(base: "b", ext: "md") { taken.contains($0) } == "b-4.md")
    }

    // MARK: - Folder plan (re-export)

    private static let currentTitle = "Standup with platform team"
    private static let currentBase = "2026-06-09-1409 standup-with-platform-team"
    /// What the folder was named when the recording exported before its title
    /// was generated.
    private static let placeholder = "2026-06-09-1409 recording-jun-9-2026-at-2-09-pm"

    private static func plan(
        existing: String?, exists: (String) -> Bool
    ) -> ExportFilename.FolderPlan {
        ExportFilename.folderPlan(
            existingFolderName: existing,
            title: currentTitle,
            recorded: fixedDate(),
            timeZone: chicago,
            exists: exists
        )
    }

    @Test func folderPlanCreatesWhenNothingWasExportedYet() {
        let plan = Self.plan(existing: nil) { _ in false }
        #expect(plan == .create(Self.currentBase))
    }

    @Test func folderPlanOverwritesTheFolderThatMatchesTheTitle() {
        let plan = Self.plan(existing: Self.currentBase) { $0 == Self.currentBase }
        #expect(plan == .overwrite(Self.currentBase))
    }

    /// A `-2` the original export minted for a collision still names *this*
    /// title — re-exporting must not walk away from it.
    @Test func folderPlanOverwritesThroughACollisionSuffix() {
        let existing = "\(Self.currentBase)-2"
        let plan = Self.plan(existing: existing) { $0 == existing }
        #expect(plan == .overwrite(existing))
    }

    /// A title generated after the first export leaves the folder named for
    /// the placeholder; the folder moves so what Files shows matches.
    @Test func folderPlanMovesWhenTheTitleChangedSinceTheExport() {
        let plan = Self.plan(existing: Self.placeholder) { $0 == Self.placeholder }
        #expect(plan == .move(from: Self.placeholder, to: Self.currentBase))
    }

    @Test func folderPlanMoveTargetAvoidsAnOccupiedName() {
        let plan = Self.plan(existing: Self.placeholder) {
            $0 == Self.placeholder || $0 == Self.currentBase
        }
        #expect(plan == .move(from: Self.placeholder, to: "\(Self.currentBase)-2"))
    }

    /// The recorded folder was deleted or moved out from under us — there is
    /// nothing to overwrite or rename, so export mints a fresh folder.
    @Test func folderPlanCreatesWhenTheRecordedFolderIsGone() {
        let plan = Self.plan(existing: Self.placeholder) { _ in false }
        #expect(plan == .create(Self.currentBase))
    }
}
