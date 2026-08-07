---
name: openminutes
description: Read, search, and answer questions across OpenMinutes meeting recordings, which are markdown transcripts with YAML frontmatter, one folder per recording. Use when the user asks about their meetings, standups, calls, voice notes, or minutes; when they mention OpenMinutes; when they ask what was decided, what they agreed to, or what their action items are; or when a folder contains dated subfolders holding transcript.md files.
license: MIT
metadata:
  author: recursive-systems
  version: "1"
  spec: https://github.com/recursive-systems/openminutes/blob/main/FILE-FORMAT.md
---

# OpenMinutes recordings

OpenMinutes records meetings on an iPhone and writes each one to the user's
own folder as markdown. The files are the product: plain, portable, and not
tied to the app. Your job is to read them and answer questions about what
was said.

## Finding the recordings

One folder per recording, named `YYYY-MM-DD-HHmm <title-slug>`:

```
2026-06-09-1409 standup-with-the-platform-team/
  transcript.md      # present when a transcript was produced
  audio.m4a          # present when the user kept audio
```

A folder may hold either file or both. Glob `*/transcript.md` from the
library root to reach every transcript in one pass.

If you do not know where the library is, check these first, then ask. Use the
real paths, not the Finder display names the user will say out loud.

- macOS, iCloud destination:
  `~/Library/Mobile Documents/iCloud~dev~recursivesystems~openminutes/Documents`
  Finder shows this as "iCloud Drive > OpenMinutes", so that is how the user
  will describe it. The recordings are inside `Documents/`, not at the
  container root.
- Any folder the user picked, often inside an Obsidian vault. Ask for the
  path rather than guessing.
- "On My iPhone > OpenMinutes" is on the phone only. It does not sync to a
  computer, so there is nothing to read there. If that is the destination,
  the user has to move the files or switch to iCloud Drive.

The folder name carries the date and title, so you can narrow by date range
without opening a single file. Do that before reading, on large libraries.

## Reading a transcript

`transcript.md` is UTF-8 markdown with YAML frontmatter:

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
...model output, when the user had summaries enabled...

## Transcript
[00:00:00] Bradley Golden: ...
[00:00:12] Alex: ...
```

| Key | Meaning |
|---|---|
| `openminutes` | Format version. This skill describes version `1`. |
| `spec` | URL of the full format contract. Fetch it if you hit something here does not explain. |
| `title` | User-visible title. May be user-written or model-generated. |
| `recorded` | ISO 8601 start time with the device's local UTC offset. Use this, not the file's mtime. |
| `duration` | Length in whole seconds. |
| `language` | BCP-47 tag of the transcript body. Absent on audio-only recordings and on older transcripts. |
| `speakers` | Speaker ID to display name. Present only when speaker labels ran. |
| `audio` | Filename of the sibling audio file. Present only when audio was kept. |

Two sections follow: `## Summary` (optional, absent when the user turned
summaries off or the device could not run them) and `## Transcript`.

Each transcript line is `[HH:MM:SS] text`, with `Speaker Name: ` between the
timestamp and the text when a speaker was identified. Timestamps are offsets
from the start of the recording, not clock times. Add them to `recorded` to
get a wall-clock moment.

## What to be careful about

**Unlabelled lines are unknown, not unimportant.** A line with no speaker
prefix means no speaker confidently covered it. Do not guess who spoke it,
and do not attribute it to whoever spoke last.

**Speaker labels are experimental and sometimes wrong.** The app says so
in its own UI. People get merged, split, or swapped, especially when voices
overlap. Treat a name as a strong hint, not a fact. When the answer turns on
who said something, say which line you drew it from so the user can check.

**Files may be present but not downloaded.** iCloud evicts file contents
under Optimize Mac Storage. The placeholders list normally, with plausible
names and sizes, and then every read fails with `Resource deadlock avoided`
or `EPERM`. It looks like a permissions problem and it is not. Check with
`du -sh` on the library: 0 means nothing is materialized. Fix it with
`brctl download <path>`, or ask the user to select all in Finder and choose
Download Now. Do not report the library as empty, corrupt, or inaccessible
without checking this first.

**A missing `## Summary` is not a missing meeting.** Read the transcript.

**The summary has no timestamps.** It is model output about the recording,
not a quote from it. Cite it by recording title alone, and say it came from
the summary. If the user needs the moment it refers to, find the supporting
line in `## Transcript` and cite that instead. The summary is a claim about
the meeting, the transcript is the evidence.

**Trust the frontmatter over the folder name.** The folder name is generated
from `title` and `recorded` at export, but folders can be renamed or moved
afterwards and the file cannot. When they disagree, `title` and `recorded`
are authoritative. Use the folder name for cheap date filtering, then
confirm from the frontmatter of anything you actually cite.

**Absent frontmatter keys are normal.** `language`, `speakers`, and `audio`
are all optional. Ignore keys you do not recognise, since later format versions
may add them.

## Answering questions

Most single-recording questions are answered by reading one file. The value
here is in the questions that span recordings, which no recording app can
answer because the files are in one folder the user owns:

- "What did I agree to in the last two weeks?": glob by date prefix, read
  each `## Summary`, fall back to the transcript where a summary is absent
- "Every time we discussed the migration": grep across `*/transcript.md`,
  then quote with the recording title and timestamp
- "What has come up repeatedly this month?": read summaries first; they are
  short, and the transcripts are the expensive fallback

When you cite something, give the recording title and the timestamp. The
user can open that recording and jump straight to it.

Read only what you need. A busy library is hundreds of files and most
questions touch a handful of them.
