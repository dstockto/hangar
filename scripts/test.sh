#!/bin/bash
# Runs the offline test suite. No network, no AWS account, no real ~/.aws files.
#
# XCTest lives inside Xcode, and xcode-select usually points at the Command Line
# Tools, which is all `swift build` needs. Point DEVELOPER_DIR at Xcode for the
# duration of the run rather than making the whole machine switch.
# shellcheck source=scripts/lib/common.sh
source "$(dirname "$0")/lib/common.sh"

if [[ -z "${DEVELOPER_DIR:-}" ]] && [[ ! -d "$(xcode-select -p)/Library/Frameworks/XCTest.framework" ]]; then
    if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    else
        die "XCTest not found. Install Xcode, or set DEVELOPER_DIR to a toolchain that has it."
    fi
fi

# Its own scratch path. `swift build` runs under the Command Line Tools and this
# runs under Xcode, and two toolchains sharing one .build leave modules the other
# cannot read: "module compiled with Swift X cannot be imported by Swift Y".
info "Testing $APP_NAME $VERSION"
exec swift test --package-path "$APP_DIR" --scratch-path "$APP_DIR/.build-test" "$@"
