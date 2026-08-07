import Foundation

/// Renders the OpenMinutes markdown file format — the versioned public
/// contract from the PRD. Any change to the output shape requires bumping
/// the `openminutes:` version key and the published spec.
struct MarkdownDocument {
    /// Stays at 1 until a build ships. The version protects readers that
    /// already exist, and there are none yet — so the format changes in place
    /// rather than accreting migrations nobody has to make. Bump strictly
    /// once it is in users' hands.
    static let formatVersion = 1
    /// Dereferenceable contract pointer: a reader (human or AI agent) that has
    /// never seen the format can fetch this URL and learn the full spec.
    static let specURL = "https://github.com/recursive-systems/openminutes/blob/main/FILE-FORMAT.md"

    var title: String
    var recorded: Date
    var duration: TimeInterval
    var transcript: String?
    var summary: String?
    /// Set only when the user has enabled audio export.
    var audioFileName: String?
    var device: String
    var generator: String
    /// BCP-47 tag of the transcript's language. Nil when there is no
    /// transcript, or for recordings made before language selection existed.
    var language: String?
    /// Speaker ID → display name. The transcript body references IDs, so a
    /// reader resolves names here instead of parsing prose, and a rename
    /// touches one line rather than every entry.
    var speakers: [String: String] = [:]
    var timeZone: TimeZone = .current

    func rendered() -> String {
        var lines = [
            "---",
            "openminutes: \(Self.formatVersion)",
            "spec: \(Self.specURL)",
            "title: \(Self.yamlValue(title))",
            "recorded: \(Self.iso8601(recorded, timeZone: timeZone))",
            "duration: \(Int(duration.rounded()))",
            "device: \(device)",
            "generator: \(generator)",
        ]
        if let language, transcript != nil {
            lines.append("language: \(language)")
        }
        if !speakers.isEmpty, transcript != nil {
            lines.append("speakers:")
            for id in speakers.keys.sorted() {
                lines.append("  \(id): \(Self.yamlValue(speakers[id] ?? id))")
            }
        }
        if let audioFileName {
            lines.append("audio: \(Self.yamlValue(audioFileName))")
        }
        lines.append("---")

        var output = lines.joined(separator: "\n") + "\n"
        if let summary {
            output += "\n## Summary\n\n\(summary)\n"
        }
        if let transcript {
            output += "\n## Transcript\n\n\(transcript)\n"
        }
        return output
    }

    /// ISO 8601 with the local UTC offset (spec: `2026-06-09T14:09:00-05:00`).
    static func iso8601(_ date: Date, timeZone: TimeZone) -> String {
        Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: timeZone)
            .format(date)
    }

    /// Quotes a YAML scalar only when needed (colons, hashes, quotes, etc.).
    static func yamlValue(_ string: String) -> String {
        let needsQuoting = string.isEmpty
            || string.contains(":") || string.contains("#")
            || string.contains("\"") || string.contains("'")
            || string.contains("\\") || string.contains("\n")
            || string.hasPrefix(" ") || string.hasSuffix(" ")
            || "-[{&*!|>%@`".contains(string.first ?? " ")
        guard needsQuoting else { return string }
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    /// Hardware identifier, e.g. "iPhone17,1" ("arm64" on simulator).
    static func currentDevice() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: systemInfo.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// "OpenMinutes 1.0 (build 42)" from the bundle's version keys.
    static func currentGenerator(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "OpenMinutes \(version) (build \(build))"
    }
}
