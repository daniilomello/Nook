#!/bin/bash
# Refresh the bundled snapshot of the adult-content domain list (OISD NSFW, GPL-3.0) in
# Packages/NookBlocker/Sources/NookBlocker/Resources: adult-domains.bin and adult-domains.json.
# The app keeps itself current after that; this is what a fresh install starts with.
# Keep the URL in sync with AdultDomainList.source. scripts/refresh-filter-lists.sh runs this.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Packages/NookBlocker/Sources/NookBlocker/Resources"
URL="https://nsfw.oisd.nl/domainswild2"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -sfL --compressed --max-time 180 "$URL" -o "$work/list.txt"
if [ "$(wc -c < "$work/list.txt")" -lt 1000000 ]; then
  echo "refresh-adult-domains: download looks wrong (size $(wc -c < "$work/list.txt")); keeping old copy" >&2
  exit 1
fi
swiftc -O -parse-as-library "$ROOT/Packages/NookBlocker/Sources/NookBlocker/SiteBlocking/HashedDomainList.swift" \
  "$ROOT/scripts/build-adult-domains.swift" -o "$work/build-adult-domains"
"$work/build-adult-domains" "$work/list.txt" "$URL" "$DEST"
