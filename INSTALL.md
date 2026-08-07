# Installing OpenMinutes on an iPhone from source

This document is written for AI agents (and patient humans) installing
OpenMinutes from source onto the user's own iPhone with a **free Apple ID**.
This is sanctioned by Apple: personal-team sideloading is what free
developer accounts are for. Nothing in the app is gated, so a source build
is the store build.

Follow the steps in order. Each step has a command and a check; if a check
fails, fix that step before moving on. `Scripts/install-device.sh` encodes
the same steps as a reference implementation. Running it instead of
stepping through manually is equally supported.

**Tell the user up front:**
- They need a Mac with Xcode 26+ and their iPhone connected by cable.
- Free-team builds expire after **7 days**. Re-run this runbook to
  re-sign (a paid Apple Developer account extends that to a year).
- Free teams allow max 3 sideloaded apps per device.
- The one-tap "Use iCloud Drive" export option requires an entitlement
  free teams can't sign, so source builds use a custom export folder
  instead. Everything else works.

## 1. Prerequisites

```sh
xcodebuild -version        # need Xcode 26 or later
brew install xcodegen      # project generator (skip if installed)
```

Check: `xcodebuild -version` prints `Xcode 26.x`. If Xcode is missing,
the user must install it from the App Store and run it once to accept
the license (`sudo xcodebuild -license accept`).

## 2. Clone and generate

```sh
git clone https://github.com/recursive-systems/openminutes.git
cd openminutes
xcodegen generate
```

Check: `OpenMinutes.xcodeproj` exists.

## 3. Find the signing identity and device

```sh
# Team ID = the OU field of the Apple Development certificate:
security find-identity -v -p codesigning
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
# -> subject= ... OU=<TEAM_ID> ...

# Connected iPhone identifier:
xcrun xctrace list devices   # phone appears as "Name (iOS x.y) (UDID)"
```

Check: you have a 10-character `TEAM_ID` and a device `UDID`.

If there is **no** Apple Development certificate: the user must (once)
open Xcode → Settings → Accounts → add their Apple ID, then
Xcode → any project → Signing & Capabilities → check "Automatically
manage signing" with their Personal Team selected, which mints the free
certificate. There is no CLI for the initial Apple ID sign-in.

## 4. Build, signed for the device

```sh
xcodebuild -project OpenMinutes.xcodeproj -scheme OpenMinutes \
  -destination "platform=iOS,id=<UDID>" \
  DEVELOPMENT_TEAM=<TEAM_ID> CODE_SIGN_STYLE=Automatic \
  build
```

A source build is the store build. Nothing in the app is gated, so there
is no unlock flag and no tier to pass on the command line.

Check: output ends `** BUILD SUCCEEDED **`. Common failures:
- `No Account for Team` → the TEAM_ID is wrong (you probably used the
  parenthetical from the certificate *name*, which is the cert ID. Use
  the `OU=` value).
- `No profiles for…` → first build for this bundle id; add
  `-allowProvisioningUpdates` (requires the Apple ID signed into Xcode).
- Device not listed → unlock the phone, tap "Trust This Computer".

## 5. Install

```sh
APP="$HOME/Library/Developer/Xcode/DerivedData/$(ls ~/Library/Developer/Xcode/DerivedData | grep '^OpenMinutes-')/Build/Products/Debug-iphoneos/OpenMinutes.app"
xcrun devicectl device install app --device <UDID> "$APP"
xcrun devicectl device info apps --device <UDID> | grep -i openminutes
```

Check: the grep shows `OpenMinutes  dev.recursivesystems.openminutes`.

First launch only: the phone may show "Untrusted Developer". The user
opens Settings → General → VPN & Device Management → trusts their own
Apple ID. That's iOS confirming the user trusts *themselves*; it's the
standard flow for every personal-team app.

## 6. Verify

Launch the app on the phone. Record a short note; the transcript appears in under a minute, and a
summary on Apple Intelligence devices (iPhone 15 Pro+).

## Re-signing after expiry (every 7 days on a free team)

Repeat steps 4–5. Recordings and settings survive: reinstalling over
an existing install preserves app data.
