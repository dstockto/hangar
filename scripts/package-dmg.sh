#!/bin/bash
# Builds a distributable DMG. Notarizes when Developer ID plus notary creds exist.
#
# Notarization needs a Developer ID Application cert plus one of:
#   NOTARY_PROFILE=<keychain-profile>   (from: xcrun notarytool store-credentials)
#   NOTARY_APPLE_ID + NOTARY_TEAM_ID + NOTARY_PASSWORD  (app-specific password)
# shellcheck source=scripts/lib/common.sh
source "$(dirname "$0")/lib/common.sh"

# A DMG in dist/ is a build, not a release. Said on every exit path, because the
# step most often skipped is the one after this script.
unpublished_warning() {
    [[ "${RELEASING:-0}" == "1" ]] && return 0
    printf '\033[1;33m\n  This DMG is NOT published. It exists only in dist/.\033[0m\n'
    printf '  Attach it to a GitHub release when you are ready. See RELEASING.md.\n\n'
}

"$REPO_ROOT/scripts/bundle.sh"

IDENTITY="$(find_signing_identity)"

# Resolve notary credentials once; both submissions use them.
NOTARY_ARGS=()
notary_ready() {
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
        return 0
    fi
    if [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
        # Command-line arguments are readable by any process running as this user,
        # so this path briefly exposes the app-specific password.
        warn "NOTARY_PASSWORD is passed as an argument and is visible in the process list."
        warn "Prefer: xcrun notarytool store-credentials, then set NOTARY_PROFILE."
        NOTARY_ARGS=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID"
                     --password "$NOTARY_PASSWORD")
        return 0
    fi
    return 1
}

# Notarize and staple the app itself, before it goes into the image.
#
# Stapling only the DMG is the common shortcut, and it looks fine: Gatekeeper
# accepts the app while the image is mounted because the image carries the ticket.
# But once the user drags the app out, it has no ticket of its own, and Gatekeeper
# falls back to asking Apple online. First launch on a machine that is offline, or
# behind a filtered network, can then fail. Stapling the app removes that.
if [[ -n "$IDENTITY" ]] && notary_ready; then
    ZIP="$DIST_DIR/$APP_NAME-$VERSION-app.zip"
    info "Notarizing the app itself (submission 1 of 2)"
    rm -f "$ZIP"
    # ditto preserves the bundle's symlinks and extended attributes; zip does not
    ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP"
    xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait
    xcrun stapler staple "$APP_BUNDLE"
    rm -f "$ZIP"
    if xcrun stapler validate "$APP_BUNDLE" >/dev/null; then
        info "Ticket stapled to $APP_NAME.app"
    else
        warn "App ticket did not validate; the DMG ticket still applies"
    fi
fi

DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"
STAGE="$DIST_DIR/dmg-stage"

info "Staging DMG contents"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP_BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

info "Creating $DMG"
hdiutil create -volname "$DISPLAY_NAME $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [[ -z "$IDENTITY" ]]; then
    warn "Unsigned DMG: no Developer ID Application cert."
    warn "Users would need: xattr -dr com.apple.quarantine /Applications/$APP_NAME.app"
    info "Built (unsigned): $DMG"
    unpublished_warning
    exit 0
fi

info "Signing DMG with: $IDENTITY"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ ${#NOTARY_ARGS[@]} -eq 0 ]]; then
    warn "Signed but not notarized: keychain profile '$NOTARY_PROFILE' not found."
    warn "Create it with: xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
    warn "  --key <AuthKey.p8> --key-id <KEY_ID> --issuer <ISSUER_ID>"
    info "Built (signed, not notarized): $DMG"
    unpublished_warning
    exit 0
fi

info "Notarizing the DMG (submission 2 of 2)"
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "$DMG"

info "Verifying Gatekeeper acceptance"
spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | sed 's/^/    /'
info "Notarized and stapled: $DMG"
shasum -a 256 "$DMG"
unpublished_warning
