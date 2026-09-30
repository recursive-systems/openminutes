# The OpenMinutes file format

**Version 1** · This document is the public contract for files OpenMinutes
writes. Any tool may read or emit these files. New optional keys can be added
without changing the `openminutes` version key; anything that could break an
existing reader bumps it. See [Versioning](#versioning) and the
[changelog](#changelog).

A JSON Schema for the frontmatter lives next to this document:
[`FILE-FORMAT.schema.json`](FILE-FORMAT.schema.json).

## The layout

One folder per recording, named `YYYY-MM-DD-HHmm <title-slug>`, holding only
what was kept:

```
2026-06-09-1409 standup-with-platform-team/
  transcript.md      # present when a transcript was produced
  audio.m4a          # present when the user keeps audio
```

A folder may hold either file or both. Names inside are fixed, because the folder
already carries the title, so a reader can glob `*/transcript.md` across a
library without parsing anything. Collisions get `-2`, `-3` suffixes on the
folder.

## The file

`transcript.md` is one UTF-8 markdown file:

```markdown
---
openminutes: 1
spec: https://github.com/recursive-systems/openminutes/blob/main/FILE-FORMAT.md
id: 7c3a5b1e-2f4d-4e8a-9b6c-0d1e2f3a4b5c
title: Standup with platform team
recorded: 2026-06-09T14:09:00-05:00
duration: 1860
device: iPhone17,1
generator: OpenMinutes 1.0 (build 42)
ref: abc123
language: en-US
speakers:
  s1: Bradley Golden
  s2: Alex
audio: audio.m4a
---

## Summary
…model output…

## Transcript
[00:00:00] Bradley Golden: …
[00:00:12] Alex: …
```

## Frontmatter keys

| Key | Required | Type | Meaning |
|---|---|---|---|
| `openminutes` | yes | integer | Format version. This document describes version `1`. |
| `spec` | no | URL | This document. Lets a reader (including an AI agent that has never seen the format) fetch the contract. OpenMinutes always writes it; other writers should too. |
| `id` | no | string | A stable identifier for the recording, minted once by the writer and never changed, even when the title changes or the file is written again. Opaque to readers: compare it, do not parse it. OpenMinutes writes its internal recording UUID in lowercase. Added 2026-09-30. |
| `title` | yes | string | User-visible title. Quoted when it contains YAML-significant characters (e.g. `:`). |
| `recorded` | yes | ISO 8601 datetime | Start of recording, with the device's local UTC offset. |
| `duration` | yes | integer | Recording length in whole seconds. |
| `device` | yes | string | Hardware model identifier (e.g. `iPhone17,1`). |
| `generator` | yes | string | Writing app and version. |
| `ref` | no | string | An opaque value supplied by whoever asked for the recording (for example the `ref` parameter of `openminutes://record`), written back exactly as received. At most 200 Unicode code points, no control characters. The writer never interprets it; it means something only to the tool that supplied it. Absent when nobody supplied one. Added 2026-09-30. |
| `language` | no | BCP-47 tag | Language of the `## Transcript` body (e.g. `en-US`, `es-ES`). Present whenever a transcript is and the writer knows the language. Absent on audio-only files, and on transcripts produced before the writer tracked language. |
| `speakers` | no | map | Speaker ID → display name. Present only when speaker labels were produced. The transcript body prefixes each line with the speaker's *display name*, and this map repeats the mapping. That redundancy is deliberate: chunking a file for a language model routinely separates the body from its frontmatter, and a body that only carried IDs would lose its meaning. The map is what tells a reader which ID is the owner (`s1` when a voice is enrolled) and disambiguates two speakers sharing a name. Lines with no confident speaker carry no prefix. |
| `audio` | no | string | Filename of the sibling audio file in the same folder, always `audio.m4a`. Present only when the user keeps audio. |

Readers MUST ignore unknown keys; writers targeting version 1 MUST NOT
require keys beyond these.

Every value above is a YAML string unless its type says otherwise. Writers
quote a string that a YAML parser would otherwise read as something else
(`ref: "123"`, not `ref: 123`), and inside double quotes they escape any
character YAML cannot hold literally, such as `\uFFFF` or a line separator.
Parse the frontmatter with a YAML 1.2 core
schema loader so `recorded` stays a string; YAML 1.1 loaders turn it into a
timestamp.

### Files without an `id`

Files written before `id` existed, and files from writers that do not mint
one, have no stable identifier. A reader that needs one can derive it from
the app name in `generator` (without its version, which changes with every
update), the instant in `recorded`, and `duration`. None of those change when
a recording is renamed or exported again.

Use the instant, not the text. `recorded` is written with the device's UTC
offset at the time of export, so the same recording exported again after the
phone changed time zone reads `2026-06-09T14:09:00-05:00` one time and
`2026-06-09T21:09:00+02:00` the next. Convert it to UTC (for example
`2026-06-09T19:09:00Z`) before deriving anything from it.

If a later export of the same recording adds
`id`, keep the derived value as an alias so the two are recognised as one
recording, not two.

## Versioning

- `openminutes` is the major version, an integer. It changes only for a
  breaking change: removing or renaming a key, changing a key's type or
  meaning, making an optional key required, or changing the folder layout.
- Adding an optional key is not a breaking change, because readers already
  ignore keys they do not know. It keeps the version and gets a line in the
  [changelog](#changelog) with the date it was added.
- A reader that meets a higher `openminutes` value than it knows reads the
  keys it understands and tells the user the file is in a newer format. It
  does not fail silently, and it does not guess at keys it does not know.
- The `spec` URL does not change. Files already in people's folders point at
  it.

## Changelog

| Date | Version | Change |
|---|---|---|
| 2026-09-30 | 1 | Added the optional `id` and `ref` keys. Wrote down the versioning policy and published the JSON Schema. |
| 2026-08-07 | 1 | First published version. |
