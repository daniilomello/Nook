#!/usr/bin/env bash
# Builds the fork's macOS app, signs it and (optionally) installs it.
#
#   ./scripts/build.sh             build + sign → build/Build/Products/Release/Nook.app
#   ./scripts/build.sh --install   … then copy to /Applications (quits a running copy first)
#   ./scripts/build.sh --run       … install and open
#
#   SIGN_IDENTITY="-" ./scripts/build.sh   force an ad-hoc signature
#
# Signing uses the "Apple Development" certificate from the keychain when there is one: a stable
# signature keeps macOS from asking again for camera, microphone and keychain access after every
# build. Entitlements are the reduced set (Nook-CI.entitlements); push and system AutoFill need a
# paid developer account.
set -euo pipefail

INSTALL=0; RUN=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --run) INSTALL=1; RUN=1 ;;
    *) echo "Unknown option: $arg (see the header of $0)" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build"
APP="$DERIVED/Build/Products/Release/Nook.app"
LOG="$DERIVED/build.log"
DEST="/Applications/Nook.app"

fail() { echo "✗ $*" >&2; exit 1; }

# Xcode, without needing `sudo xcode-select`.
XCODE="${XCODE:-$( (ls -d /Applications/Xcode*.app 2>/dev/null || true) | sort | tail -1)}"
[[ -n "$XCODE" && -d "$XCODE" ]] || fail "Xcode not found. Install it from the App Store, open it once, then rerun."
export DEVELOPER_DIR="$XCODE/Contents/Developer"
echo "→ Using $(xcodebuild -version | head -1)"

mkdir -p "$DERIVED"
echo "→ Building (Release, arm64)… log: $LOG"
if ! xcodebuild -project "$ROOT/Nook.xcodeproj" -scheme Nook -configuration Release -arch arm64 \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    COMPILER_INDEX_STORE_ENABLE=NO ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
    build >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u | head -20 >&2 || true
  if grep -q "missing Metal Toolchain" "$LOG"; then
    echo "  Run once: xcodebuild -downloadComponent MetalToolchain" >&2
  fi
  fail "Build failed. Full log: $LOG"
fi
[[ -d "$APP" ]] || fail "Build finished but $APP is missing."

# Signature: nested code first and without entitlements, the app last with them.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
[[ -n "$IDENTITY" ]] || IDENTITY="-"
sign() {
  local identity="$1"
  local nested
  while IFS= read -r nested; do
    codesign --force --deep --options runtime --timestamp=none --sign "$identity" "$nested"
  done < <(find "$APP/Contents/Frameworks" -maxdepth 1 -mindepth 1 2>/dev/null)
  codesign --force --options runtime --timestamp=none \
    --entitlements "$ROOT/Nook/Nook-CI.entitlements" --sign "$identity" "$APP"
}
if [[ "$IDENTITY" != "-" ]] && sign "$IDENTITY" 2>"$DERIVED/sign.log"; then
  echo "→ Signed with $IDENTITY"
else
  [[ "$IDENTITY" == "-" ]] || echo "! Could not sign with $IDENTITY (see $DERIVED/sign.log); using an ad-hoc signature."
  sign "-"
  echo "→ Signed ad-hoc"
fi
codesign --verify --deep --strict "$APP" || fail "The signature does not verify."
echo "✓ Built $APP"

[[ $INSTALL -eq 1 ]] || exit 0

# Quit a running copy so the bundle is not replaced under it.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
if pgrep -f "$DEST/Contents/MacOS/Nook" >/dev/null 2>&1; then
  echo "→ Quitting the running copy…"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    pgrep -f "$DEST/Contents/MacOS/Nook" >/dev/null 2>&1 || break
    sleep 0.5
  done
fi
rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "✓ Installed $DEST"

if [[ $RUN -eq 1 ]]; then
  open "$DEST"
  echo "✓ Opened"
fi
