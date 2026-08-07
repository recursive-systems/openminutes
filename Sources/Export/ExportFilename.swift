import Foundation

/// Builds spec filenames: `YYYY-MM-DD-HHmm <title-slug>.md`, sortable and
/// collision-safe (PRD C3).
enum ExportFilename {

    static func base(title: String, recorded: Date, timeZone: TimeZone = .current) -> String {
        "\(timestamp(for: recorded, timeZone: timeZone)) \(slug(title))"
    }

    static func timestamp(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: date)
    }

    /// Lowercase ASCII-folded hyphenated slug ("Übergabe Café 北京" →
    /// "ubergabe-cafe-bei-jing"); never empty.
    static func slug(_ title: String, maxLength: Int = 60) -> String {
        let ascii = title.applyingTransform(
            StringTransform("Any-Latin; Latin-ASCII; Lower"), reverse: false
        ) ?? title.lowercased()

        var out = ""
        var pendingHyphen = false
        for char in ascii {
            if char.isASCII, char.isLetter || char.isNumber {
                if pendingHyphen, !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.append(char)
            } else {
                pendingHyphen = true
            }
        }

        var trimmed = String(out.prefix(maxLength))
        while trimmed.hasSuffix("-") { trimmed = String(trimmed.dropLast()) }
        return trimmed.isEmpty ? "recording" : trimmed
    }

    /// First name not rejected by `exists`: `base.ext`, `base-2.ext`, `base-3.ext`…
    static func unique(base: String, ext: String, exists: (String) -> Bool) -> String {
        var candidate = "\(base).\(ext)"
        var n = 2
        while exists(candidate) {
            candidate = "\(base)-\(n).\(ext)"
            n += 1
        }
        return candidate
    }

    /// Same rule without an extension, for the per-recording folder.
    static func uniqueDirectory(base: String, exists: (String) -> Bool) -> String {
        var candidate = base
        var n = 2
        while exists(candidate) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }
}
