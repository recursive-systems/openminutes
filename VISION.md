# OpenMinutes Vision

OpenMinutes records a meeting on an iPhone, transcribes and summarizes it
on-device, and writes the result into a folder the person already owns:
the audio, the transcript, or both, whichever they chose to keep.

Project overview: [`README.md`](README.md)
Working instructions: [`AGENTS.md`](AGENTS.md)
File contract: [`FILE-FORMAT.md`](FILE-FORMAT.md)

## Core idea

Meeting recorders split into two camps. Cloud notetakers are capable but take
custody of your audio, charge monthly for capability that has no marginal cost,
and hold the transcript inside their product. Local transcribers keep the audio
private and then trap the result in an app database nobody else can read.

Both fail the same way: the recording is the valuable thing, and neither leaves
you holding it. Not the audio, not the text.

OpenMinutes takes the third position. Your phone is already capable of the
whole pipeline, since Apple ships the speech and language models, so no
server needs to exist. And whatever assistant you already use reads a folder of
transcripts better than any feature bolted on here ever would. Between those
two facts there is very little left for this app to do, and doing
exactly that little is the point.

The product is what lands in the folder. The app is the part that produces it
and gets out of the way.

## Principles

### 1. Recording content never leaves the device

Not for processing, not for diagnostics, not for support, not for any future
monetization. This is the one commitment that cannot be traded, because it is
what makes the app usable by people who cannot use cloud transcription at all:
privilege, HIPAA, NDA, source protection. For them the alternative is a legal
pad, not a competitor.

Everything else in this document is a preference. This is not.

### 2. The files are the interface

Every recording exports as its own folder holding what the user chose to keep:
the transcript as markdown with a documented, versioned frontmatter contract,
the audio as a plain `.m4a`, or both. Audio and transcripts are separate
choices because they serve different needs. A transcript is what you search
and feed to a tool, the audio is the record you may need to go back to, and
neither is a substitute for the other.

No database, no proprietary container, no export button that produces something
lesser than what the app holds.

The test: if OpenMinutes is deleted tomorrow, the recordings are still there
and still openable by everything else. If a change would make that less true,
it does not belong.

### 3. Stay small on purpose

There is no chat window, no ask-your-meetings screen, no assistant of its own.
Each would be a worse copy of something the user already has open. Restraint
here is not a gap to be filled later. It is what lets the app compose with
tools that outclass anything shipped in a recorder.

Prefer removing a feature to gating one, and prefer files the user can hand to
another tool over features that keep them in this one.

### 4. Never fail silently

Recording is unrepeatable. A meeting that did not capture cannot be re-run, so
every failure the user could act on must be visible while they can still act:
a dead engine, a revoked export folder, an unavailable model. A frozen timer
over a stopped engine is worse than a crash, because the user keeps talking.

Prefer an honest error to a plausible-looking success.

### 5. Free, and honest about why

The app is MIT-licensed and buildable from source, so selling capability would
mean selling what the user already has. Support is a tip jar that unlocks
nothing. Nothing is gated, and no feature is held back to create a reason to
pay.

## Boundaries

**The app** owns capture, on-device transcription and summarization, and
writing the recording out. It should stay the smallest thing that does those
well.

**The transcript format** is a public contract, versioned independently of the
app. Other tools may read or write it. Changes are additive where possible and
never silent. Audio is written as an unmodified `.m4a`, with no container of ours and
nothing to reverse-engineer.

**Agents and assistants** own everything downstream: search, synthesis,
cross-meeting questions, workflows. OpenMinutes ships an Agent Skill so they
can read the format, and otherwise stays out of their way.

## What will not be merged

- Anything that uploads recording content, for any reason.
- Network calls in app source. The current answer is zero, and CI enforces it.
- Analytics or crash SDKs of any kind.
- Paywalls, trials, entitlement checks, or features held back to create a
  reason to pay.
- An in-app assistant, chat interface, or search-your-meetings feature that
  duplicates what the user's own tools already do better.
- A proprietary store, sync service, or account system.
- Silent failure paths: swallowed errors, states that look like success, UI
  that keeps running over a stopped pipeline.
- Format changes that break existing readers without a version bump.
- Features that only work if the user stays inside this app.

## Contribution guardrail

Use this as a fit check before building. If a change makes capture more
reliable, makes what lands in the folder more useful to tools that are not this
app, removes a way to fail silently, or deletes something the user did not need, it
likely belongs.

If a change adds a capability the user's existing assistant already has, keeps
data inside the app, or trades any part of principle 1, it does not, no matter
how useful it is on its own. Open an issue and argue the case before writing
the code.
