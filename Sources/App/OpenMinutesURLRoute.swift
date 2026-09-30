import Foundation

/// What another app asked for when it opened `openminutes://record`.
///
/// Both values are optional, and a bare `openminutes://record` (the Lock
/// Screen widget) carries neither.
struct RecordRequest: Equatable, Sendable {
    /// Becomes the recording's title, and skips title generation.
    var title: String?
    /// Opaque to OpenMinutes: stored on the recording and written back
    /// unchanged as the exported file's `ref` key.
    var ref: String?

    /// Limits count Unicode scalars, the same unit JSON Schema's `maxLength`
    /// counts, so the app and FILE-FORMAT.schema.json agree on what fits.
    static let maxTitleLength = 200
    static let maxRefLength = 200

    var isEmpty: Bool { title == nil && ref == nil }
}

enum OpenMinutesURLRoute: Equatable {
    case importAudio(URL)
    case startRecording(RecordRequest)
    /// A record link whose parameters cannot be honoured. Starting anyway
    /// would drop or alter what the caller sent without telling anyone, so
    /// the app says why instead of recording.
    case rejectedRecordRequest(Problem)
    case unsupported

    enum Problem: Equatable {
        case tooLong(parameter: Parameter, length: Int, limit: Int)
        case controlCharacters(parameter: Parameter)

        enum Parameter: String, Equatable {
            case title, ref
        }

        /// Shown to the person holding the phone. Names no product and no
        /// person: the caller is only ever "the app that opened OpenMinutes".
        var message: String {
            switch self {
            case .tooLong(let parameter, let length, let limit):
                "The app that opened OpenMinutes sent a \(parameter.displayName) of \(length) characters. "
                    + "The limit is \(limit), so nothing was recorded. Try again from that app."
            case .controlCharacters(let parameter):
                "The app that opened OpenMinutes sent a \(parameter.displayName) with characters "
                    + "that can't be saved in a file, so nothing was recorded. Try again from that app."
            }
        }
    }

    init(url: URL) {
        if url.isFileURL {
            self = .importAudio(url)
        } else if url.scheme == "openminutes", url.host == "record" {
            self = Self.recordRoute(url)
        } else {
            self = .unsupported
        }
    }

    /// Parameters other than `title` and `ref` are ignored, so a caller can
    /// add its own without the link ever needing a version. An empty value
    /// counts as absent. When a parameter repeats, the first one wins.
    /// `+` is a literal plus (RFC 3986), not a space: callers percent-encode.
    private static func recordRoute(_ url: URL) -> OpenMinutesURLRoute {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func first(_ name: Problem.Parameter) -> String? {
            guard let value = items.first(where: { $0.name == name.rawValue })?.value,
                  !value.isEmpty
            else { return nil }
            return value
        }

        var request = RecordRequest()
        for (parameter, limit) in [(Problem.Parameter.title, RecordRequest.maxTitleLength),
                                   (.ref, RecordRequest.maxRefLength)] {
            guard let value = first(parameter) else { continue }
            let length = value.unicodeScalars.count
            if length > limit {
                return .rejectedRecordRequest(.tooLong(parameter: parameter, length: length, limit: limit))
            }
            // Newlines, tabs and other control characters have no faithful
            // plain form in a one-line YAML value, and `ref` must come back
            // byte for byte.
            if value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                return .rejectedRecordRequest(.controlCharacters(parameter: parameter))
            }
            switch parameter {
            case .title:
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                request.title = trimmed.isEmpty ? nil : trimmed
            case .ref:
                request.ref = value
            }
        }
        return .startRecording(request)
    }
}

private extension OpenMinutesURLRoute.Problem.Parameter {
    var displayName: String {
        switch self {
        case .title: "title"
        case .ref: "reference"
        }
    }
}

/// Starts recordings for record links, one at a time.
///
/// Asking for microphone permission suspends, and a second link can arrive
/// in that window. Without a reservation both would see an idle recorder and
/// both would start, and the second start replaces the first capture's file
/// and engine with nothing left pointing at the first. The reservation is
/// held from the first check until `start` returns, and the recorder's state
/// is checked again after the suspension, because the user may have tapped
/// record meanwhile.
@MainActor
final class RecordLinkStarter {
    static let busyMessage = "A recording is already running, so the link from the other app was not used. "
        + "Stop this recording, then try again from that app."

    private(set) var isStarting = false

    /// Returns what to tell the user, or nil when there is nothing to say.
    /// A bare link (the widget) that finds a recording running says nothing:
    /// it only reopens the app. A link carrying a title or ref says why it
    /// was not used, since the caller is waiting for a file.
    func handle(
        _ request: RecordRequest,
        isIdle: () -> Bool,
        prepare: () async -> Void,
        start: (RecordRequest) throws -> Void
    ) async -> String? {
        let busy = request.isEmpty ? nil : Self.busyMessage
        guard !isStarting, isIdle() else { return busy }
        isStarting = true
        defer { isStarting = false }
        await prepare()
        guard isIdle() else { return busy }
        do {
            try start(request)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
