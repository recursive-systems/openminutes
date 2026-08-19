#!/bin/bash
# Reference implementation of INSTALL.md: build OpenMinutes from source and
# install it on a connected iPhone with the user's own (free) Apple ID.
set -euo pipefail

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

say "1/5 Prerequisites"
# awk reads to EOF where `head -1` would SIGPIPE xcodebuild under pipefail.
xcodebuild -version | awk 'NR==1' || die "Xcode not found — install it from the App Store and run it once."
command -v xcodegen >/dev/null || die "xcodegen missing — brew install xcodegen"

say "2/5 Generating project"
xcodegen generate

say "3/5 Resolving signing identity and device"
# TEAM_ID in the environment wins; then a .team-id file; then auto-detection.
# Auto-detection must not guess: a personal team cannot sign the iCloud
# capability, and it looks identical to a paid one in the certificate.
if [ -z "${TEAM_ID:-}" ] && [ -f .team-id ]; then
  TEAM_ID=$(tr -d '[:space:]' < .team-id)
fi
if [ -z "${TEAM_ID:-}" ]; then
  # find-certificate -a emits one PEM block per certificate but openssl reads
  # only the first, so feed each block to openssl separately.
  ALL_TEAMS=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | awk '/BEGIN CERTIFICATE/{cert=""} {cert=cert $0 "\n"} /END CERTIFICATE/{printf "%s", cert | "openssl x509 -noout -subject"; close("openssl x509 -noout -subject"); print ""}' \
    | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | sort -u)
  case $(printf '%s\n' "$ALL_TEAMS" | grep -c .) in
    0) die "No Apple Development certificate. One-time setup: Xcode → Settings → Accounts → add your Apple ID, enable automatic signing once (see INSTALL.md step 3)." ;;
    1) TEAM_ID=$ALL_TEAMS ;;
    *) die "Multiple signing teams found:
$(printf '%s\n' "$ALL_TEAMS" | sed 's/^/  /')
Re-run as: TEAM_ID=<id> $0   (or write the id to a .team-id file at the repo root)
Pick the paid team — a personal team cannot sign this app's iCloud capability." ;;
  esac
fi
# Ask xcodebuild, not xctrace: xctrace lists this Mac first, and its
# hardware UDID is indistinguishable from an iPhone's by format alone.
UDID=$(xcodebuild -project OpenMinutes.xcodeproj -scheme OpenMinutes -showdestinations 2>/dev/null \
  | sed -n 's/.*platform:iOS, arch:[^,]*, id:\([0-9A-F-]*\), name:.*/\1/p' | head -1)
[ -n "$UDID" ] || die "No iPhone detected — connect it by cable, unlock it, and tap 'Trust This Computer'."
echo "team: $TEAM_ID   device: $UDID"

say "4/5 Building (signed)"
xcodebuild -project OpenMinutes.xcodeproj -scheme OpenMinutes \
  -destination "platform=iOS,id=$UDID" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates build | tail -1

say "5/5 Installing"
DERIVED=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/OpenMinutes-* | head -1)
xcrun devicectl device install app --device "$UDID" \
  "$DERIVED/Build/Products/Debug-iphoneos/OpenMinutes.app" >/dev/null
xcrun devicectl device info apps --device "$UDID" | grep -i openminutes

say "Done. On the phone: Settings → General → VPN & Device Management → trust your Apple ID (first install only). Free-team builds expire in 7 days — re-run this script to re-sign; your recordings survive."
