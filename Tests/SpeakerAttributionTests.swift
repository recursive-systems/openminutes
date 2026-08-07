import Foundation
import Testing
@testable import OpenMinutes

@Suite("Speaker attribution")
struct SpeakerAttributionTests {

    private func line(_ start: TimeInterval, _ end: TimeInterval) -> TimedLine {
        TimedLine(start: start, end: end, text: "…")
    }

    private func turn(_ id: String, _ start: TimeInterval, _ end: TimeInterval) -> SpeakerTurn {
        SpeakerTurn(speakerID: id, start: start, end: end)
    }

    @Test func attributesLineToTheSpeakerCoveringMostOfIt() {
        let lines = [line(0, 10), line(10, 20)]
        let turns = [turn("A", 0, 9), turn("B", 9, 21)]

        #expect(SpeakerAttribution.attribute(lines: lines, turns: turns) == ["A", "B"])
    }

    /// Transcriber and diarizer segment independently, so a single spoken
    /// line routinely straddles a speaker change. Majority wins.
    @Test func straddlingLineGoesToTheDominantSpeaker() {
        let lines = [line(0, 10)]
        let turns = [turn("A", 0, 3), turn("B", 3, 10)]

        #expect(SpeakerAttribution.attribute(lines: lines, turns: turns) == ["B"])
    }

    /// One speaker interrupted and resuming still owns the line; their turns
    /// must be summed rather than compared individually.
    @Test func splitTurnsFromOneSpeakerAreSummed() {
        let lines = [line(0, 10)]
        let turns = [turn("A", 0, 4), turn("B", 4, 6), turn("A", 6, 10)]

        #expect(SpeakerAttribution.attribute(lines: lines, turns: turns) == ["A"])
    }

    /// The interruption case, and the one that used to break: B holds the
    /// longest single turn, but A holds the line. Totalling per speaker
    /// before comparing is the whole difference — judging turn-by-turn
    /// against a running leader discards A's opening 3 seconds the moment B
    /// overtakes, and hands the line to the interrupter.
    @Test func interruptedSpeakerKeepsTheLineTheyMostlySpoke() {
        let lines = [line(0, 10)]
        let turns = [turn("A", 0, 3), turn("B", 3, 7), turn("A", 7, 10)]

        #expect(SpeakerAttribution.attribute(lines: lines, turns: turns) == ["A"])
    }

    /// Identical audio must label identically on every run; dictionary order
    /// is not stable, so a tie has to resolve by something that is.
    @Test func exactTieResolvesDeterministically() {
        let lines = [line(0, 10)]
        let turns = [turn("B", 0, 5), turn("A", 5, 10)]

        let repeated = (0..<20).map { _ in
            SpeakerAttribution.attribute(lines: lines, turns: turns)
        }
        #expect(Set(repeated.map { $0.description }).count == 1)
    }

    /// No overlap means no evidence — the line is unlabelled, not guessed at
    /// from whoever spoke nearby.
    @Test func lineWithNoOverlappingTurnIsUnattributed() {
        let lines = [line(30, 40)]
        let turns = [turn("A", 0, 10)]

        #expect(SpeakerAttribution.attribute(lines: lines, turns: turns) == [nil])
    }

    /// A sliver of overlap is not enough to claim a whole line.
    @Test func belowMinimumOverlapStaysUnattributed() {
        let lines = [line(0, 10)]
        let turns = [turn("A", 9.5, 10)]   // 5% of the line

        #expect(SpeakerAttribution.attribute(lines: lines, turns: turns) == [nil])
        #expect(SpeakerAttribution.attribute(lines: lines, turns: turns,
                                             minimumOverlapRatio: 0.01) == ["A"])
    }

    @Test func noTurnsLeavesEverythingUnattributed() {
        let lines = [line(0, 10), line(10, 20)]

        #expect(SpeakerAttribution.attribute(lines: lines, turns: []) == [nil, nil])
    }
}

@Suite("Speaker labels")
struct SpeakerIdentityTests {

    /// The owner's slot is reserved whether or not anyone enrolled, so the
    /// first *other* speaker sits at `s2`. Numbering the label straight from
    /// the ID made every unenrolled transcript open on "Speaker 2" with no
    /// Speaker 1 anywhere — which reads as a speaker the app lost, not as an
    /// empty slot.
    @Test func firstNonOwnerSpeakerIsSpeakerOne() {
        #expect(SpeakerIdentity.defaultLabel(for: SpeakerIdentity.id(forClusterIndex: 0),
                                             isOwner: false) == "Speaker 1")
        #expect(SpeakerIdentity.defaultLabel(for: SpeakerIdentity.id(forClusterIndex: 1),
                                             isOwner: false) == "Speaker 2")
    }

    @Test func ownerIsAlwaysYou() {
        #expect(SpeakerIdentity.defaultLabel(for: SpeakerIdentity.ownerID, isOwner: true) == "You")
    }

    /// Two unnamed speakers must never collide on one label.
    @Test func labelsAreUniquePerCluster() {
        let labels = (0..<6).map {
            SpeakerIdentity.defaultLabel(for: SpeakerIdentity.id(forClusterIndex: $0), isOwner: false)
        }
        #expect(Set(labels).count == labels.count)
    }
}
