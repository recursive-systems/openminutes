# Security Policy

## Reporting a vulnerability

Use GitHub's **[private vulnerability reporting](https://github.com/recursive-systems/openminutes/security/advisories/new)**
so the details stay private until there is a fix. If that is unavailable,
email <security@openminutes.app>.

Please do not open a public issue for a security problem.

This is a small project with one maintainer. Expect an acknowledgement within
a few days rather than a few hours, and say so in your report if you have a
disclosure deadline in mind. There is no bug bounty.

## What matters most here

OpenMinutes makes one promise above all others: **recording content never
leaves the device.** Anything that breaks it is the most serious class of bug
in this project, more serious than a crash. Reports in this category get
priority:

- Any path by which audio, transcripts, or summaries leave the device
- Any network call originating from app code
- Recording content written somewhere the user did not choose, or left
  readable by other apps
- Anything that causes a recording to be captured without the user starting
  it, or to continue after they stopped it
- The enrolled voiceprint, the only biometric template the app stores,
  leaving the device or being exported with a recording

Also in scope, at ordinary severity: security-scoped bookmark handling that
grants broader folder access than the user picked, and anything that lets
another app read the internal store.

## What is not a vulnerability

- **Files the user chose to sync.** Once a recording is exported to iCloud
  Drive or another provider, it lives under that account and that provider's
  policy. The app writes it where the user asked and does not upload it
  anywhere itself.
- **Handing a transcript to an assistant.** That is the user's own tool and
  their own account. See [`skills/README.md`](skills/README.md).
- **Speaker labels being wrong.** Diarization is experimental and labelled as
  such in the app. Incorrect attribution is a quality bug. Report it as a
  normal issue.
- **`NSURLSession` symbols in the built binary.** These come from a
  dependency's model downloader that this app never reaches, because the
  models ship in the bundle. App source contains no networking and CI enforces
  that. A demonstration that the path *is* reachable at runtime would be a
  genuine finding.

## Verifying the claims yourself

You do not have to take any of this on faith:

```sh
# app source contains no networking (this is also a CI gate)
grep -rnE "URLSession|NWConnection|CFNetwork|import Network" Sources Shared Widgets

# what the binary links
otool -L path/to/OpenMinutes.app/OpenMinutes
```

The strongest check is a proxy capture. Run a full record → transcribe →
export cycle on a device behind mitmproxy or Charles and watch for traffic.
If you find any, that is a report worth making.

## Supported versions

The latest released version only. This is a free app with no long-term support
branches; fixes ship in a new release rather than as backports.
