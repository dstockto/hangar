#!/bin/bash
# Re-renders the wordmark @2x fallbacks from the lockup SVGs, and refreshes the
# brand kit's manifest so a changed asset is visible rather than silent.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift scripts/render-wordmark.swift design/brand/wordmark
cd design/brand/wordmark
shasum -a 256 hangar-wordmark-dark.svg hangar-wordmark-light.svg \
    hangar-wordmark-mono-black.svg hangar-wordmark-mono-white.svg \
    hangar-wordmark-dark@2x.png hangar-wordmark-light@2x.png \
    hangar-wordmark-mono-black@2x.png hangar-wordmark-mono-white@2x.png \
    README.md > MANIFEST.sha256
echo "  MANIFEST.sha256 refreshed"
