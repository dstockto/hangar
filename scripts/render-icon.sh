#!/bin/bash
# Re-renders the flattened icon previews from the layer SVGs. Needs Xcode's
# toolchain for `swift`, the same way the test suite does.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
exec swift scripts/render-icon.swift app/Resources/app-icon
