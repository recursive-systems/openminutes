# Contributing to OpenMinutes

The repo is small on purpose. Two documents carry everything you need:

- [`VISION.md`](VISION.md): what belongs here and what will not be merged.
  Read it before proposing a feature; it will save you writing code that gets
  turned down for reasons that have nothing to do with its quality.
- [`AGENTS.md`](AGENTS.md): hard constraints, build and test commands,
  architecture, and the platform edges that have already cost someone a day.

## Before you open a PR

- **Check the fit.** The guardrail at the end of `VISION.md` is the test. A
  good change that does not fit is still a decline, so argue it in an issue
  first rather than in a diff.
- **Green CI is the bar**: build, tests, and the network guard.
- **Match the code style.** Comments explain constraints the code cannot,
  and nothing else. No comment that restates the line below it.
- **Extend the test seams.** The pipeline is testable in the simulator through
  protocol seams with fake transcriber, summarizer, diarizer, and exporter
  services. Extend those rather than adding device-only paths.

## Commits

Plain imperative, sentence case, no prefixes:

```
Fix the recorder crashing on record
Move internal audio out of Documents
Show a spinner while processing, nothing when done
```

Not `fix:`, not `feat(scope):`. Conventional Commits are not used here.

The body explains why, in prose, when the reason is not obvious from the diff.
Say what was wrong and what it cost, not which lines moved.

Do not add AI attribution: no `Co-Authored-By` for an assistant, no
"generated with" trailers. The author of a commit is the person responsible
for it, whatever tools they used.

## Reporting a security issue

Do not open a public issue. See [`SECURITY.md`](SECURITY.md); anything that
could move a recording off the device belongs there rather than in the tracker.

## Reporting bugs

A recording that failed to capture is the worst thing this app can do to
someone, and the hardest bug to reproduce. If you hit one, include the device
model, iOS version, whether the screen was locked, and whether anything
interrupted the recording: a call, an alarm, headphones connecting or
disconnecting.

## License

MIT for code. The OpenMinutes name and logo are trademarks of Recursive
Systems LLC. Forks should ship under their own name.
