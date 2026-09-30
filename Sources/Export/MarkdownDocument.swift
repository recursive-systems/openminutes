import Foundation

/// Renders the OpenMinutes markdown file format — the versioned public
/// contract in FILE-FORMAT.md. A new optional key is additive and keeps the
/// version (it goes in the spec's changelog and FILE-FORMAT.schema.json);
/// anything that could break an existing reader bumps `openminutes:`.
struct MarkdownDocument {
    /// Stays at 1 until a build ships. The version protects readers that
    /// already exist, and there are none yet — so the format changes in place
    /// rather than accreting migrations nobody has to make. Bump strictly
    /// once it is in users' hands.
    static let formatVersion = 1
    /// Dereferenceable contract pointer: a reader (human or AI agent) that has
    /// never seen the format can fetch this URL and learn the full spec.
    static let specURL = "https://github.com/recursive-systems/openminutes/blob/main/FILE-FORMAT.md"

    /// Stable identifier minted once per recording (OpenMinutes writes the
    /// Recording's UUID). Optional in the format, so other writers and older
    /// files may lack it.
    var id: String?
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
    /// Opaque caller string from `openminutes://record?ref=`, written back
    /// unchanged.
    var ref: String?
    var timeZone: TimeZone = .current

    func rendered() -> String {
        var lines = [
            "---",
            "openminutes: \(Self.formatVersion)",
            "spec: \(Self.specURL)",
        ]
        if let id {
            lines.append("id: \(Self.yamlValue(id))")
        }
        lines += [
            "title: \(Self.yamlValue(title))",
            "recorded: \(Self.iso8601(recorded, timeZone: timeZone))",
            "duration: \(Int(duration.rounded()))",
            "device: \(device)",
            "generator: \(generator)",
        ]
        if let ref {
            lines.append("ref: \(Self.yamlValue(ref))")
        }
        if let language, transcript != nil {
            lines.append("language: \(language)")
        }
        if !speakers.isEmpty, transcript != nil {
            lines.append("speakers:")
            for speakerID in speakers.keys.sorted() {
                lines.append("  \(speakerID): \(Self.yamlValue(speakers[speakerID] ?? speakerID))")
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
    /// Inside quotes, anything YAML cannot hold literally is escaped, so a
    /// `ref` of any Unicode string comes back from a parser unchanged.
    static func yamlValue(_ string: String) -> String {
        let needsQuoting = string.isEmpty
            || string.contains(":") || string.contains("#")
            || string.contains("\"") || string.contains("'")
            || string.contains("\\")
            || string.hasPrefix(" ") || string.hasSuffix(" ")
            || "-[]{},?&*!|>%@`".contains(string.first ?? " ")
            || string.unicodeScalars.contains(where: needsEscape)
            || resolvesToNonString(string)
        guard needsQuoting else { return string }
        var escaped = ""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            case "\r": escaped += "\\r"
            case _ where needsEscape(scalar):
                escaped += scalar.value <= 0xFFFF
                    ? "\\u" + hex(scalar.value, width: 4)
                    : "\\U" + hex(scalar.value, width: 8)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }

    /// Characters that cannot appear literally in a one-line YAML value:
    /// everything outside YAML 1.2's printable set (C0 and C1 controls, DEL,
    /// U+FFFE, U+FFFF), line breaks including YAML 1.1's NEL, U+2028 and
    /// U+2029, and the byte order mark, which YAML excludes from content.
    static func needsEscape(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x20...0x7E: false
        case 0x85, 0x2028, 0x2029, 0xFEFF: true
        case 0xA0...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: false
        default: true
        }
    }

    private static func hex(_ value: UInt32, width: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    /// True when a YAML parser would read the unquoted value as something
    /// other than a string: a `ref` of `123` must come back as the string
    /// "123", and a speaker called "No" must not become `false`. Covers the
    /// YAML 1.2 core schema and the YAML 1.1 forms common parsers (PyYAML,
    /// js-yaml's default schema) still apply.
    static func resolvesToNonString(_ string: String) -> Bool {
        let patterns = [
            // null and booleans, including YAML 1.1's yes/no/on/off
            "~|null|y|yes|n|no|true|false|on|off|=|<<",
            // integers: decimal, binary, octal, hex
            "[-+]?(0b[01_]+|0o?[0-7_]+|0x[0-9a-f_]+|[0-9][0-9_]*)",
            // floats, with or without a dot or exponent
            "[-+]?(\\.[0-9][0-9_]*|[0-9][0-9_]*(\\.[0-9_]*)?)(e[-+]?[0-9]+)?",
            "[-+]?\\.(inf|nan)",
            // YAML 1.1 date
            "[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}",
        ]
        return patterns.contains { pattern in
            guard let regex = try? Regex(pattern).ignoresCase() else { return false }
            return string.wholeMatch(of: regex) != nil
        }
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
