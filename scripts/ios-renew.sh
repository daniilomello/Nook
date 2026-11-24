#!/usr/bin/env bash
# Keeps Nook signed on the iPhone (free Apple ID profiles expire after 7 days).
# Reinstalls only when the installed build expires within RENEW_DAYS (default 3),
# so it is cheap to run often. The iPhone must be reachable: cable, or the same
# Wi-Fi with "Connect via network" enabled in Xcode › Devices (unlocked helps).
#
#   ./scripts/ios-renew.sh                  renew if due
#   ./scripts/ios-renew.sh --force          renew now
#   ./scripts/ios-renew.sh --status         show when the installed build expires
#   ./scripts/ios-renew.sh --install-agent  check automatically (login + every 4 h)
#   ./scripts/ios-renew.sh --remove-agent   stop the automatic check
#
# Log: ~/Library/Logs/NookRenew.log
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/build-ios/installed-expiry"
BUNDLE_ID=com.danilodemellow.browser
LABEL=com.danilodemellow.browser.renew
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/NookRenew.log"
RENEW_DAYS="${RENEW_DAYS:-3}"

notify() { osascript -e "display notification \"$1\" with title \"Nook\"" >/dev/null 2>&1 || true; }

# Seconds until the installed build expires (negative = expired, empty = unknown).
seconds_left() {
  [[ -s "$STATE" ]] || return 0
  local expiry
  expiry="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$(cat "$STATE")" +%s 2>/dev/null)" || return 0
  echo $(( expiry - $(date +%s) ))
}

describe() {
  local left="$1"
  if [[ -z "$left" ]]; then echo "unknown (no successful install recorded)"
  elif (( left <= 0 )); then echo "expired ($(cat "$STATE"))"
  else echo "$(cat "$STATE") — $(( left / 86400 ))d $(( left % 86400 / 3600 ))h left"
  fi
}

case "${1:-}" in
  --status)
    echo "Installed build expires: $(describe "$(seconds_left)")"
    if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
      echo "Automatic renewal: on (log: $LOG)"
    else
      echo "Automatic renewal: off (enable with --install-agent)"
    fi
    exit 0 ;;

  --install-agent)
    mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
    cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$ROOT/scripts/ios-renew.sh</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>14400</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PL
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "✓ Automatic renewal on: checks at login and every 4 h, renews $RENEW_DAYS days before expiry."
    echo "  Log: $LOG"
    exit 0 ;;

  --remove-agent)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "✓ Automatic renewal off."
    exit 0 ;;

  --force|"") ;;
  *) echo "Unknown option: $1 (see the header of $0)" >&2; exit 2 ;;
esac

LEFT="$(seconds_left)"
echo "[$(date '+%Y-%m-%d %H:%M')] Installed build expires: $(describe "$LEFT")"
if [[ "${1:-}" != "--force" && -n "$LEFT" ]] && (( LEFT > RENEW_DAYS * 86400 )); then
  echo "  Not due yet."
  exit 0
fi

echo "  Renewing…"
# Xcode reuses a cached profile while it is still valid; drop ours so it fetches a fresh 7-day one.
# Only the iOS profile: the Mac app shares this bundle id.
for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision; do
  [[ -f "$f" ]] || continue
  if security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null \
      | grep -q "^iOS .*$BUNDLE_ID$"; then
    rm -f "$f"
  fi
done
if "$ROOT/scripts/ios-install.sh" --no-launch; then
  notify "Renewed — valid until $(cat "$STATE" 2>/dev/null | cut -c1-10)."
  exit 0
fi

echo "  ✗ Renewal failed (iPhone unreachable?). Will retry on the next check."
LEFT="$(seconds_left)"
if [[ -n "$LEFT" ]] && (( LEFT < 86400 )); then
  notify "Expires in under a day and renewal failed. Connect the iPhone (cable or same Wi-Fi, unlocked)."
fi
exit 1
