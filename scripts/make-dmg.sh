#!/bin/bash
# Packs Clickr.app into a disk image with an Applications shortcut to drag it onto.
#
#   scripts/make-dmg.sh path/to/Clickr.app Clickr-1.0.0-arm64.dmg
set -euo pipefail

app="$1"
output="$2"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

ditto "$app" "$staging/Clickr.app"
ln -s /Applications "$staging/Applications"
rm -f "$output"

# hdiutil now and then fails with "Resource busy" on CI machines, so give it a few tries.
for attempt in 1 2 3 4 5; do
  if hdiutil create -volname Clickr -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$output" > /dev/null; then
    exit 0
  fi
  echo "hdiutil create failed (attempt $attempt), retrying" >&2
  sleep $((attempt * 3))
done
exit 1
