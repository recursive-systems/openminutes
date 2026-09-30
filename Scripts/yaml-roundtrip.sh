#!/bin/bash
# Round-trips awkward strings through the real frontmatter writer and a real
# YAML parser. The app's unit tests cannot load a YAML library, so this runs
# on the Mac: it compiles Sources/Export/MarkdownDocument.swift (Foundation
# only) with a small driver, renders a document per string, and parses each
# with Ruby's Psych (libyaml), which ships with macOS. Every value must come
# back as the same string, and every file must parse.
#
#   Scripts/yaml-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/main.swift" <<'SWIFT'
import Foundation

let values: [String] = [
    "Coffee", "abc", "7c3a5b1e-2f4d-4e8a-9b6c-0d1e2f3a4b5c",
    "123", "-7", "0x1F", "0o17", "1e3", "3.14", ".5", ".inf", ".NaN",
    "true", "No", "yes", "off", "y", "~", "null", "2026-06-09", "=", "<<",
    "a: b", "a:b", "x #y", "#x", "- x", "-x", "? x", "?x", ",x", "[x]", "{x}", "|x", ">x",
    "*x", "&x", "!x", "%x", "@x", "`x", "'single'", "\"double\"", "back\\slash",
    " lead", "trail ", "tab\there", "line\nbreak", "cr\rhere", "crlf\r\nhere",
    "\u{0}nul", "bell\u{7}", "del\u{7F}", "c1\u{80}\u{9F}", "nel\u{85}here",
    "ls\u{2028}ps\u{2029}", "\u{FEFF}bom", "non\u{FFFE}\u{FFFF}char",
    "nbsp\u{A0}here", "Élise & co", "e\u{301}", "emoji \u{1F600}", "\u{10FFFF}",
    "\u{E000}private", "…", "a---b", "---",
]

struct Case: Encodable {
    let expected: String
    let document: String
}

let cases = values.map { value in
    Case(expected: value, document: MarkdownDocument(
        id: value, title: value, recorded: Date(timeIntervalSince1970: 1_780_000_000),
        duration: 60, transcript: "[00:00:00] Hi.", summary: nil, audioFileName: nil,
        device: "iPhone17,1", generator: "OpenMinutes 1.0 (build 1)",
        speakers: ["s1": value], ref: value,
        timeZone: TimeZone(identifier: "America/Chicago")!
    ).rendered())
}
FileHandle.standardOutput.write(try! JSONEncoder().encode(cases))
SWIFT

xcrun swiftc -O -o "$work/render" Sources/Export/MarkdownDocument.swift "$work/main.swift"
"$work/render" > "$work/cases.json"

/usr/bin/ruby -ryaml -rjson -e '
  load = YAML.respond_to?(:unsafe_load) ? YAML.method(:unsafe_load) : YAML.method(:load)
  cases = JSON.parse(File.read(ARGV[0]))
  failures = 0
  cases.each do |c|
    expected = c["expected"]
    front = c["document"].split("---\n", 3)[1]
    begin
      doc = load.call(front)
      got = { "id" => doc["id"], "title" => doc["title"], "ref" => doc["ref"],
              "speakers.s1" => doc.dig("speakers", "s1") }
      got.each do |key, value|
        next if value.is_a?(String) && value == expected
        failures += 1
        puts "FAIL #{key}: wrote #{expected.inspect}, read back #{value.inspect}"
      end
    rescue => e
      failures += 1
      puts "FAIL parse of #{expected.inspect}: #{e.class}: #{e.message.lines.first}"
    end
  end
  puts "#{cases.size} values, 4 keys each, #{failures} failures"
  exit(failures.zero? ? 0 : 1)
' "$work/cases.json"
