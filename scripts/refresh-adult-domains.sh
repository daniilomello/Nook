#!/bin/bash
# Refresh the bundled snapshot of the adult-content domain list in
# Packages/NookBlocker/Sources/NookBlocker/Resources: adult-domains.bin and adult-domains.json.
# The sources are the ones in AdultDomainSources.swift (OISD NSFW and HaGeZi NSFW, both GPL-3.0);
# every one of them has to download, so the snapshot never ships with a source missing.
# The app keeps itself current after that; this is what a fresh install starts with.
# scripts/refresh-filter-lists.sh runs this.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Packages/NookBlocker/Sources/NookBlocker/Resources"
SOURCES="$ROOT/Packages/NookBlocker/Sources/NookBlocker/SiteBlocking"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

swiftc -O -parse-as-library "$SOURCES/HashedDomainList.swift" "$SOURCES/AdultDomainSources.swift" \
  "$ROOT/scripts/build-adult-domains.swift" -o "$work/build-adult-domains"

files=()
index=0
while read -r _ url; do
  index=$((index + 1))
  file="$work/list-$index.txt"
  curl -sfL --compressed --max-time 180 "$url" -o "$file" || { echo "refresh-adult-domains: $url failed; keeping old copy" >&2; exit 1; }
  if [ "$(wc -c < "$file")" -lt 500000 ]; then
    echo "refresh-adult-domains: $url looks wrong (size $(wc -c < "$file")); keeping old copy" >&2
    exit 1
  fi
  files+=("$file")
done < <("$work/build-adult-domains" --sources)

"$work/build-adult-domains" "$DEST" "${files[@]}"
