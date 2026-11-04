#!/bin/bash
# Points the Homebrew cask (Casks/aayra.rb) at a published GitHub release.
#
# Usage: scripts/update-cask.sh [version]     (default: the version in Resources/Info.plist)
#
# Run it after CI has published the release for that version. It downloads the release zip,
# computes its SHA-256 and writes both into the cask. Then commit and push Casks/aayra.rb.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)}"
url="https://github.com/nullifye/AAYRA-System-Monitor/releases/download/v${version}/AAYRA-${version}.zip"
cask="Casks/aayra.rb"

echo "Downloading $url"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if ! curl -fsSL "$url" -o "$tmp/AAYRA.zip"; then
    echo "error: no release zip for v${version} yet. Push the v${version} tag and let CI publish it first." >&2
    exit 1
fi
sha="$(shasum -a 256 "$tmp/AAYRA.zip" | cut -d' ' -f1)"

sed -i '' -E \
    -e "s/^  version \".*\"/  version \"${version}\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"${sha}\"/" \
    "$cask"

echo "Updated $cask to ${version} (sha256 ${sha})"
echo "Next: git commit -m \"Homebrew cask: AAYRA ${version}\" $cask && git push"
