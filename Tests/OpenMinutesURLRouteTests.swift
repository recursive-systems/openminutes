import Foundation
import Testing
@testable import OpenMinutes

@Suite("Open URL routing")
struct OpenMinutesURLRouteTests {
    private func route(_ string: String) throws -> OpenMinutesURLRoute {
        OpenMinutesURLRoute(url: try #require(URL(string: string)))
    }

    @Test func fileURLRoutesToAudioImport() throws {
        let url = URL(filePath: "/tmp/Call Recording.m4a")
        #expect(OpenMinutesURLRoute(url: url) == .importAudio(url))
    }

    @Test func widgetDeepLinkStillRoutesToRecording() throws {
        #expect(try route("openminutes://record") == .startRecording(RecordRequest()))
    }

    @Test func unrelatedURLIsIgnored() throws {
        #expect(try route("https://example.com/recording.m4a") == .unsupported)
    }

    @Test func titleAndRefAreCarriedThrough() throws {
        #expect(try route("openminutes://record?title=Coffee&ref=abc")
            == .startRecording(RecordRequest(title: "Coffee", ref: "abc")))
    }

    @Test func eitherParameterWorksAlone() throws {
        #expect(try route("openminutes://record?title=Coffee")
            == .startRecording(RecordRequest(title: "Coffee")))
        #expect(try route("openminutes://record?ref=abc")
            == .startRecording(RecordRequest(ref: "abc")))
    }

    /// Callers percent-encode; `+` is a literal plus, as RFC 3986 has it, so
    /// a ref containing one comes back exactly as sent.
    @Test func valuesArePercentDecodedAndPlusIsLiteral() throws {
        #expect(try route("openminutes://record?title=Coffee%20with%20%C3%89lise%20%26%20co&ref=a%2Bb+c%3D%3F")
            == .startRecording(RecordRequest(title: "Coffee with Élise & co", ref: "a+b+c=?")))
    }

    /// The link never needs a version: whatever else a caller adds is ignored.
    @Test func unknownParametersAreIgnored() throws {
        #expect(try route("openminutes://record?title=Coffee&source=calendar&v=2&ref=abc")
            == .startRecording(RecordRequest(title: "Coffee", ref: "abc")))
    }

    @Test func emptyValuesCountAsAbsent() throws {
        #expect(try route("openminutes://record?title=&ref=") == .startRecording(RecordRequest()))
        #expect(try route("openminutes://record?title=%20%20") == .startRecording(RecordRequest()))
    }

    /// The ref is opaque, so it is kept byte for byte, spaces included. The
    /// title is display text, so surrounding spaces are trimmed.
    @Test func refIsNeverTrimmedButTitleIs() throws {
        #expect(try route("openminutes://record?title=%20Coffee%20&ref=%20abc%20")
            == .startRecording(RecordRequest(title: "Coffee", ref: " abc ")))
    }

    @Test func firstOfARepeatedParameterWins() throws {
        #expect(try route("openminutes://record?ref=first&ref=second")
            == .startRecording(RecordRequest(ref: "first")))
    }

    @Test func valuesAtTheLimitAreAccepted() throws {
        let title = String(repeating: "t", count: RecordRequest.maxTitleLength)
        let ref = String(repeating: "r", count: RecordRequest.maxRefLength)
        #expect(try route("openminutes://record?title=\(title)&ref=\(ref)")
            == .startRecording(RecordRequest(title: title, ref: ref)))
    }

    /// Over-long values are refused with a reason, never cut to fit: a
    /// truncated ref would file the recording under something the caller
    /// never sent.
    @Test func overLongRefIsRejectedNotTruncated() throws {
        let ref = String(repeating: "r", count: RecordRequest.maxRefLength + 1)
        #expect(try route("openminutes://record?title=Coffee&ref=\(ref)")
            == .rejectedRecordRequest(.tooLong(parameter: .ref, length: 201, limit: 200)))
    }

    @Test func overLongTitleIsRejectedNotTruncated() throws {
        let title = String(repeating: "t", count: RecordRequest.maxTitleLength + 1)
        #expect(try route("openminutes://record?title=\(title)")
            == .rejectedRecordRequest(.tooLong(parameter: .title, length: 201, limit: 200)))
    }

    /// Length is counted in Unicode scalars, the unit JSON Schema's
    /// `maxLength` uses, so the app and the published schema agree.
    @Test func lengthCountsUnicodeScalars() throws {
        // "é" as e + combining acute is one Character but two scalars.
        let decomposed = String(repeating: "e\u{301}", count: 100)
        let encoded = try #require(decomposed.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "e")))
        #expect(try route("openminutes://record?ref=\(encoded)")
            == .startRecording(RecordRequest(ref: decomposed)))
        #expect(try route("openminutes://record?ref=\(encoded)x")
            == .rejectedRecordRequest(.tooLong(parameter: .ref, length: 201, limit: 200)))
    }

    @Test func controlCharactersAreRejected() throws {
        #expect(try route("openminutes://record?ref=a%0Ab")
            == .rejectedRecordRequest(.controlCharacters(parameter: .ref)))
        #expect(try route("openminutes://record?title=a%09b")
            == .rejectedRecordRequest(.controlCharacters(parameter: .title)))
    }

    /// What the user reads says what happened and what to do, and names
    /// neither the calling product nor anything the ref might stand for.
    @Test func rejectionMessageIsPlain() {
        let message = OpenMinutesURLRoute.Problem
            .tooLong(parameter: .ref, length: 250, limit: 200).message
        #expect(message.contains("reference of 250 characters"))
        #expect(message.contains("nothing was recorded"))
        #expect(!message.contains("\u{2014}"))
    }
}

/// Holds `prepare` (the microphone permission prompt) open until released,
/// so a test can deliver a second link inside that window.
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class FakeLinkRecorder {
    var idle = true
    var started: [RecordRequest] = []

    func start(_ request: RecordRequest) {
        started.append(request)
        idle = false
    }
}

@MainActor
private func yield(until condition: () -> Bool) async -> Bool {
    for _ in 0..<10_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@MainActor
@Suite("Record link starts")
struct RecordLinkStarterTests {
    @Test func startsWithTheRequest() async {
        let starter = RecordLinkStarter()
        var started: [RecordRequest] = []
        let message = await starter.handle(
            RecordRequest(title: "Coffee", ref: "abc"),
            isIdle: { true }, prepare: {}, start: { started.append($0) })
        #expect(message == nil)
        #expect(started == [RecordRequest(title: "Coffee", ref: "abc")])
        #expect(!starter.isStarting)
    }

    /// Two links while the permission prompt is up: only the first starts,
    /// and the second says why instead of starting over the first capture.
    @Test func overlappingLinksStartOnlyOnce() async throws {
        let starter = RecordLinkStarter()
        let gate = Gate()
        let recorder = FakeLinkRecorder()

        let first = Task {
            await starter.handle(RecordRequest(ref: "first"), isIdle: { recorder.idle },
                                 prepare: { await gate.wait() }, start: { recorder.start($0) })
        }
        #expect(await yield { gate.isWaiting })
        #expect(starter.isStarting)

        let second = await starter.handle(RecordRequest(ref: "second"), isIdle: { recorder.idle },
                                          prepare: {}, start: { recorder.start($0) })
        #expect(second == RecordLinkStarter.busyMessage)
        // The widget's bare link during the same window is quietly ignored.
        let bare = await starter.handle(RecordRequest(), isIdle: { recorder.idle },
                                        prepare: {}, start: { recorder.start($0) })
        #expect(bare == nil)
        #expect(recorder.started.isEmpty)

        gate.open()
        #expect(await first.value == nil)
        #expect(recorder.started == [RecordRequest(ref: "first")])
        #expect(!starter.isStarting)
    }

    /// The user can tap record while the prompt is up. The recorder's state
    /// is read again after the suspension, not trusted from before it.
    @Test func recordingStartedDuringPermissionPromptWins() async {
        let starter = RecordLinkStarter()
        var idle = true
        var started: [RecordRequest] = []
        let message = await starter.handle(
            RecordRequest(ref: "abc"), isIdle: { idle },
            prepare: { idle = false }, start: { started.append($0) })
        #expect(message == RecordLinkStarter.busyMessage)
        #expect(started.isEmpty)
        #expect(!starter.isStarting)
    }

    @Test func startFailureIsReportedAndReleasesTheReservation() async {
        let starter = RecordLinkStarter()
        let failed = await starter.handle(
            RecordRequest(), isIdle: { true }, prepare: {},
            start: { _ in throw RecorderService.RecorderError.microphoneDenied })
        #expect(failed == RecorderService.RecorderError.microphoneDenied.errorDescription)
        #expect(!starter.isStarting)

        var started = 0
        _ = await starter.handle(RecordRequest(), isIdle: { true }, prepare: {}, start: { _ in started += 1 })
        #expect(started == 1)
    }
}
