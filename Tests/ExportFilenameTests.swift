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
}
