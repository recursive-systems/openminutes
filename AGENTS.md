# AGENTS.md

Instructions for agents and contributors working on OpenMinutes. Read
[`VISION.md`](VISION.md) first for what belongs here and what does not.

OpenMinutes is a free iPhone app (iOS 26+, Swift 6, SwiftUI) that records
meetings, transcribes on-device with SpeechTranscriber, summarizes with
Foundation Models, and exports each recording as its own folder holding the
transcript, the audio, or both, per the user's setting, into a location they
choose.

[`FILE-FORMAT.md`](FILE-FORMAT.md) is the public contract for the files the app
writes. Once a build has shipped, never change the format without bumping the
`openminutes:` key.

## Hard constraints, never to be violated

1. **Recording content never leaves the device.** Audio, transcripts, and
   summaries are captured, processed, and stored on-device only. Nothing
   uploads them, ever, for any diagnostics or support rationale. This is what
   makes the app usable by people who cannot use cloud transcription at all:
   privilege, HIPAA, NDA, source protection. For them the alternative is a
   legal pad, not a competitor.
2. **Zero network calls at all.** Stronger than constraint 1 strictly requires,
   and held deliberately: it costs nothing, and an App Privacy "Data Not
   Collected" label is far cheaper to keep than to regain. CI fails the build if
   a networking symbol appears in `Sources`, `Shared`, or `Widgets`.
3. **Everything on-device.** No API keys, no remote inference.
4. **Swift 6 strict concurrency must stay clean.** Services are
   `@MainActor @Observable`.
5. **XcodeGen-based build.** Edit `project.yml`, never the `.xcodeproj`, which
   is generated and gitignored. Regenerate with `xcodegen generate`.
6. **Nothing is ever gated.** No paywall, no trial, no entitlement check. The
   tip jar is consumable purchases that unlock nothing.
7. **No analytics or crash SDKs, ever** (Firebase, Amplitude, PostHog,
   Sentry, …). They phone home continuously and their payloads are
   unauditable, so they put constraint 1 at risk, not just constraint 2. Xcode
   Organizer and App Store Connect already provide crash reports and install
   numbers with no SDK and no effect on the privacy label.

## Build and test

```sh
xcodegen generate                 # after editing project.yml

xcodebuild -project OpenMinutes.xcodeproj -scheme OpenMinutes \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

xcodebuild -project OpenMinutes.xcodeproj -scheme OpenMinutes \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

A simulator build only proves compilation. The microphone, SpeechTranscriber
assets, Foundation Models, and diarization all need a real device. See
[`INSTALL.md`](INSTALL.md).

## Commit style

Plain imperative, sentence case, no prefixes. Write the subject as the change
itself: `Fix the recorder crashing on record`, not `fix: recorder crash` and not
`feat(recorder): ...`. Conventional Commits are not used here.

The body explains *why*, in prose, when the reason is not obvious from the
diff. Say what was wrong and what it cost, not what lines moved.

Never add AI attribution: no `Co-Authored-By` for an assistant, no "generated
with" trailers. The author of a commit is the person responsible for it.

## Writing style

**Do not use em dashes in anything a reader outside the codebase sees.** That
means every markdown file in the repo, and every string that renders in the
app. Use a period, a comma, a colon, or parentheses, whichever the sentence
actually needs.

Code comments are exempt. They are written for whoever is already in the file,
the audience is not being persuaded of anything, and churning them adds diff
noise for no reader benefit.

Two reasons for the rule, and the second is the durable one:

1. Large language models overused em dashes badly enough that readers now
   treat them as a signal that text was machine-written. That signal is
   unreliable as detection, but it is real as a first impression, and this
   project asks people to trust claims about what the software does.
2. An em dash is usually a sentence avoiding a decision. "It failed, and the
   user kept talking" and "It failed. The user kept talking." both say more
   than the version with a dash, because each commits to whether those are one
   thought or two.

En dashes are fine in number ranges. Hyphens in compound words are fine. This
rule is about the em dash only.

Everything else: plain words, no filler. Say the thing once. Comments explain
constraints the code cannot express, never what the next line already says.

## Layout

```
Sources/Models/      SwiftData @Model types
Sources/Services/    the pipeline, one @MainActor @Observable class per stage
Sources/Views/       SwiftUI
Sources/Export/      markdown rendering
Shared/              App Intents, compiled into both app and widget
Widgets/             Live Activity + control widget
Models/              bundled Core ML diarization models (~21MB)
skills/              Agent Skill for reading exported recordings
```

`RecorderService` is `AVAudioEngine` with a tap on the input node. The engine
writes the file itself and forwards the same buffers to `bufferHandler`,
because live transcription needs the samples and `AVAudioRecorder` only hands
back a finished file. `TranscriptionService` keeps each token's
`audioTimeRange`, which is what lets playback follow the transcript word by
word without heuristics. `ProcessingCoordinator` runs transcribe → summarize →
export and re-enqueues anything a previous launch left unfinished.

## Platform edges

Each of these cost real debugging time. Preserve the behaviour if you touch the
surrounding code.

**Audio taps run on a realtime thread.** A closure written inside a
`@MainActor` method inherits that isolation, and AVFoundation calls the tap off
the main actor, which trips Swift's executor check and traps before a single
buffer is written. The tap closure must be `@Sendable` with its state boxed.

**`AVAudioFile.write(from:)` raises an Objective-C exception** (uncatchable
from Swift, so an instant crash) if the buffer format differs from the file's
`processingFormat` by even a channel layout. Always write to
`file.processingFormat`, never a format you constructed.

**Pausing the engine before a guard that can return** leaves a stopped engine
under a `.recording` state: the UI keeps counting and nothing reaches the file.
Every path that can stop capture mid-recording must surface `captureFailure`.

**SwiftData reads the iCloud entitlement as consent to sync.** The entitlement
exists only so export can write into the app's iCloud Drive container, but
`ModelContainer` enables CloudKit unless told otherwise, and `Recording` has
non-optional attributes and a unique `id`, which CloudKit forbids, so the app
hard-crashes at launch. `cloudKitDatabase: .none` is load-bearing.

**Security-scoped bookmarks go stale.** Re-resolve on every export; when stale
or revoked, surface a re-pick state rather than failing silently.

**iCloud folders hold dataless files.** Use `NSFileCoordinator` for writes, off
the main actor, because coordination blocks while the file materializes.

**Foundation Models has several distinct unavailable reasons** (device, region,
model still downloading). Each needs its own message; never fail generically.

**App Intents cold start.** Intent handlers must stay dependency-free, because
recording has to start before the full SwiftUI graph loads.

**Bundled Core ML models are staged to a cache directory** and stamped with the
build that wrote them. Model filenames are stable across versions, so without
the stamp an app update keeps serving old weights, or pairs new PLDA parameters
with old embeddings and degrades quietly.

**Internal audio lives in Application Support, not Documents.**
`UIFileSharingEnabled` exposes Documents in the Files app, and internal storage
uses opaque UUID filenames, so showing users those invites them to move or delete
files the database still points at. Documents is for their exports.

## Tests

The suite runs against fakes for each pipeline stage. Keep the fakes honest
about lifecycle: `FakeDiarizer` starts un-installed like the real one, because
a fake that hardcodes readiness hides exactly the bug where production code
depends on some other path having initialized it.
