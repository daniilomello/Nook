#!/usr/bin/env bash
# Builds Nook for iPhone (the NookiOS target) and installs it on the connected device.
# Free Apple ID: the app expires after 7 days — run this again to renew it.
#
#   ./scripts/ios-install.sh            build + install + launch
#   ./scripts/ios-install.sh --no-launch   build + install only (used by ios-renew.sh)
#   TEAM_ID=ABCDE12345 ./scripts/ios-install.sh   (override the detected team)
#
# Limits of a free Apple ID: Nook cannot be made the default browser (that entitlement needs a
# paid account), and at most 3 sideloaded apps fit on one iPhone.
set -euo pipefail

LAUNCH=1
for arg in "$@"; do
  case "$arg" in
    --no-launch) LAUNCH=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID=com.danilodemellow.browser
DERIVED="$ROOT/build-ios"
LOG="$DERIVED/build.log"

fail() { echo "✗ $*" >&2; exit 1; }

# 1. Xcode (without needing `sudo xcode-select`).
XCODE="${XCODE:-$( (ls -d /Applications/Xcode*.app 2>/dev/null || true) | sort | tail -1)}"
[[ -n "$XCODE" && -d "$XCODE" ]] || fail "Xcode not found. Install it from the App Store, open it once, then rerun."
export DEVELOPER_DIR="$XCODE/Contents/Developer"
echo "→ Using $(xcodebuild -version | head -1) at $XCODE"
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  fail "Xcode needs to finish its first launch. Open Xcode once (accept the license, install the iOS platform), then rerun."
fi

# 2. Development team (personal team for a free Apple ID).
TEAM="${TEAM_ID:-}"
if [[ -z "$TEAM" ]]; then
  TEAM="$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1 || true)"
fi
if [[ -z "$TEAM" ]]; then
  TEAM="$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
    | grep -o 'teamID = [A-Z0-9]*' | head -1 | awk '{print $3}' || true)"
fi
[[ -n "$TEAM" ]] || fail "No Apple developer team found. In Xcode › Settings › Accounts, add your Apple ID, then rerun."
echo "→ Team $TEAM"

# 3. Connected iPhone (physical only; devicectl also lists simulators).
DEVICES_JSON="$(mktemp)"
xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null 2>&1 || true
DEVICE_LINE="$(python3 - "$DEVICES_JSON" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
phones = [d for d in devices
          if d.get("hardwareProperties", {}).get("deviceType") == "iPhone"
          and d.get("hardwareProperties", {}).get("reality", "physical") == "physical"
          and d.get("connectionProperties", {}).get("pairingState") == "paired"]
# Prefer one that is reachable right now.
phones.sort(key=lambda d: d.get("connectionProperties", {}).get("tunnelState") != "connected")
if phones:
    d = phones[0]
    print(d["identifier"], d["hardwareProperties"]["udid"], d.get("deviceProperties", {}).get("name", "iPhone").replace(" ", "_"))
PY
)"
rm -f "$DEVICES_JSON"
DEVICE_ID=""; UDID=""; NAME=""
read -r DEVICE_ID UDID NAME <<< "$DEVICE_LINE" || true
[[ -n "${DEVICE_ID:-}" ]] || fail "No paired iPhone found. Connect it with a cable, unlock it, tap Trust, enable Settings › Privacy & Security › Developer Mode, then rerun."
echo "→ iPhone: ${NAME//_/ } ($UDID)"

# 4. Build (signing is automatic; the device gets registered to your team). The project is
#    committed, so there is nothing to generate. The team comes from here, not from the project
#    file, which still carries upstream's; ios-signing.xcconfig explains what else it changes.
mkdir -p "$DERIVED"
echo "→ Building (Release)… log: $LOG"
if ! xcodebuild \
    -project "$ROOT/Nook.xcodeproj" \
    -scheme NookiOS \
    -configuration Release \
    -destination "id=$UDID" \
    -derivedDataPath "$DERIVED" \
    -xcconfig "$ROOT/scripts/ios-signing.xcconfig" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$TEAM" \
    build >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u | head -20 >&2 || true
  if grep -q "missing Metal Toolchain" "$LOG"; then
    echo "  Run once: xcodebuild -downloadComponent MetalToolchain" >&2
  fi
  fail "Build failed. Full log: $LOG"
fi

APP="$DERIVED/Build/Products/Release-iphoneos/NookiOS.app"
[[ -d "$APP" ]] || fail "Build finished but $APP is missing."

# 5. Install and launch.
echo "→ Installing…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >/dev/null
echo "✓ Installed Nook on ${NAME//_/ }"

# Remember when the installed build's provisioning profile expires (read by ios-renew.sh).
security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null \
  | plutil -extract ExpirationDate raw -o - - > "$DERIVED/installed-expiry" 2>/dev/null || true
[[ -s "$DERIVED/installed-expiry" ]] && echo "  Valid until $(cat "$DERIVED/installed-expiry")"
[[ $LAUNCH -eq 1 ]] || exit 0

if ! xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1; then
  cat <<'MSG'
! Installed, but iOS blocked the launch. On the iPhone, the first time only:
  Settings › General › VPN & Device Management › (your Apple ID) › Trust
  Then open Nook from the Home Screen.
MSG
else
  echo "✓ Launched"
fi
echo "  Free Apple ID: this build expires in 7 days — rerun this script to renew."
