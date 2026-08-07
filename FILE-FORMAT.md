# The OpenMinutes file format

**Version 1** · This document is the public contract for files OpenMinutes
writes. Any tool may read or emit these files. The format only changes with
a bump of the `openminutes` version key, and never in a way that breaks
readers of older versions silently.

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
title: Standup with platform team
recorded: 2026-06-09T14:09:00-05:00
duration: 1860
device: iPhone17,1
generator: OpenMinutes 1.0 (build 42)
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
| `title` | yes | string | User-visible title. Quoted when it contains YAML-significant characters (e.g. `:`). |
| `recorded` | yes | ISO 8601 datetime | Start of recording, with the device's local UTC offset. |
| `duration` | yes | integer | Recording length in whole seconds. |
| `device` | yes | string | Hardware model identifier (e.g. `iPhone17,1`). |
| `generator` | yes | string | Writing app and version. |
| `language` | no | BCP-47 tag | Language of the `## Transcript` body (e.g. `en-US`, `es-ES`). Present whenever a transcript is and the writer knows the language. Absent on audio-only files, and on transcripts produced before the writer tracked language. |
| `speakers` | no | map | Speaker ID → display name. Present only when speaker labels were produced. The transcript body prefixes each line with the speaker's *display name*, and this map repeats the mapping. That redundancy is deliberate: chunking a file for a language model routinely separates the body from its frontmatter, and a body that only carried IDs would lose its meaning. The map is what tells a reader which ID is the owner (`s1` when a voice is enrolled) and disambiguates two speakers sharing a name. Lines with no confident speaker carry no prefix. |
| `audio` | no | string | Filename of the sibling audio file in the same folder, always `audio.m4a`. Present only when the user keeps audio. |

Readers MUST ignore unknown keys; writers targeting version 1 MUST NOT
require keys beyond these.
