#!/bin/sh
# One-time setup: keep the pinned XCFramework inside the repository, outside Git.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
framework="$root/Vendor/GhosttyKit/BinaryTarget/GhosttyKit.xcframework"
[ -f "$framework/Info.plist" ] && exit 0
url='https://github.com/egoist-labs/libghostty-spm/releases/download/storage.1.3.6/GhosttyKit.xcframework.zip'
checksum='f60e46d2829e892c23cc6ee6e1eb0dccddcb0ba77727c830b69a6b0d1d9a9821'
directory=$(dirname "$framework")
mkdir -p "$directory"
archive="$directory/.GhosttyKit.zip.download"
# Preserve partial downloads across interruptions; the SHA-256 guards the result.
curl --fail --silent --show-error --location --retry 3 --continue-at - --output "$archive" "$url"
echo "$checksum  $archive" | shasum -a 256 -c -
tmp=$(mktemp -d "$directory/.extract.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
ditto -x -k "$archive" "$tmp"
[ -f "$tmp/GhosttyKit.xcframework/Info.plist" ] || { echo 'Invalid GhosttyKit archive' >&2; exit 1; }
mv "$tmp/GhosttyKit.xcframework" "$framework"
rm -f "$archive"
echo "GhosttyKit available at $framework"
