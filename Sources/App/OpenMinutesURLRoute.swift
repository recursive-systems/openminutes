import Foundation

enum OpenMinutesURLRoute: Equatable {
    case importAudio(URL)
    case startRecording
    case unsupported

    init(url: URL) {
        if url.isFileURL {
            self = .importAudio(url)
        } else if url.scheme == "openminutes", url.host == "record" {
            self = .startRecording
        } else {
            self = .unsupported
        }
    }
}
