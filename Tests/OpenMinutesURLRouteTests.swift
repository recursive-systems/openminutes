import Foundation
import Testing
@testable import OpenMinutes

@Suite("Open URL routing")
struct OpenMinutesURLRouteTests {
    @Test func fileURLRoutesToAudioImport() throws {
        let url = URL(filePath: "/tmp/Call Recording.m4a")
        #expect(OpenMinutesURLRoute(url: url) == .importAudio(url))
    }

    @Test func widgetDeepLinkStillRoutesToRecording() throws {
        let url = try #require(URL(string: "openminutes://record"))
        #expect(OpenMinutesURLRoute(url: url) == .startRecording)
    }

    @Test func unrelatedURLIsIgnored() throws {
        let url = try #require(URL(string: "https://example.com/recording.m4a"))
        #expect(OpenMinutesURLRoute(url: url) == .unsupported)
    }
}
