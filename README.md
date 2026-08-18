# OpenMinutes

**Record meetings on your iPhone. Transcripts and summaries land in your own folder, readable by any assistant you already use. 100% on-device. Free, and nothing is locked. No account, no server, no subscription.**

OpenMinutes uses Apple's on-device SpeechTranscriber and Foundation Models, so processing never leaves your phone. Every recording becomes its own folder in a place you choose (iCloud Drive, an Obsidian vault, any file provider that supports folder access), holding the transcript as markdown with YAML frontmatter, the audio as a plain `.m4a`, or both. Your call, in Settings. Which means your AI tools can already read it, and the audio is still yours to keep. No new cloud: files sync through whatever your phone already syncs.

Record directly in OpenMinutes, or share an M4A recording from Notes or Files into the app. Imported audio enters the same on-device transcript, summary, title, and export pipeline as an in-app recording.

## Status

🚧 Pre-release. Buildable from source today: see
[INSTALL.md](INSTALL.md) to put it on your own iPhone.

## Why there is no cloud service

Because two things you already own are enough.

Your iPhone transcribes and summarizes on-device. No server is doing that
work, and none needs to. And whatever assistant you already use reads a
folder of transcripts better than any feature bolted on here could.

So OpenMinutes does not try to be either one. There is no chat window, no
ask-your-meetings screen, no assistant of its own. Each would be a worse
copy of something already open on your Mac. It records, transcribes, writes
the file, and puts it where you asked. That is the entire job, and staying
that small is exactly what lets it work with everything else.

Every other AI recorder is a subscription cloud service holding your audio,
or a local app holding your transcripts hostage. This is the third thing:
built for you and your agents, and deliberately not in the way.

## Build

Requires Xcode 26+, iOS 26+ device with Apple Intelligence for the full pipeline.

```bash
brew install xcodegen
xcodegen generate
open OpenMinutes.xcodeproj   # set your signing team, run on device
```

## Use your notes with an assistant

Transcripts are plain markdown in a folder you control, so anything that
reads files can read it. [`skills/openminutes`](skills/README.md) is an
[Agent Skill](https://agentskills.io) that teaches an assistant the format
and how to answer questions across many meetings at once: "what did I agree
to in the last two weeks?" The app itself still makes no network calls; the
skill runs in your assistant, on your files, when you ask it to.

## Docs

- [**Vision**](VISION.md): what this project is for, and what will not be merged
- [**File format**](FILE-FORMAT.md): the public contract; any tool can read or emit OpenMinutes files
- [Agent & contributor instructions](AGENTS.md): constraints, architecture, and the platform edges worth knowing before changing anything
- [Installing from source](INSTALL.md)
- [Agent Skill](skills/README.md): read your recordings with the assistant you already use
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md): how to report anything that could move a recording off the device

## License

Source: MIT (see LICENSE). The OpenMinutes name and logo are trademarks of Recursive Systems LLC. Forks must use a different name and branding.
