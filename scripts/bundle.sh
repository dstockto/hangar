#!/bin/bash
# Builds the Swift binary, assembles dist/Hangar.app, and signs it.
# Signs with Developer ID plus hardened runtime when the cert is present, so the
# result is ready to notarize. Falls back to ad-hoc for local use.
# shellcheck source=scripts/lib/common.sh
source "$(dirname "$0")/lib/common.sh"

CONFIG="${CONFIG:-release}"

info "Building $APP_NAME $VERSION ($CONFIG)"
swift build --package-path "$APP_DIR" -c "$CONFIG"
BINARY="$APP_DIR/.build/$CONFIG/$APP_NAME"
[[ -f "$BINARY" ]] || die "binary not found at $BINARY"

# Named colours and template images come from the compiled catalog, so this is a
# hard requirement rather than an optional nicety.
ACTOOL="$(find_actool)"
[[ -n "$ACTOOL" ]] || die "actool not found. Install Xcode; the asset catalog cannot be compiled without it."

info "Compiling asset catalog"
mkdir -p "$DIST_DIR/assets"
"$ACTOOL" --compile "$DIST_DIR/assets" --platform macosx \
    --minimum-deployment-target "$DEPLOY_TARGET" \
    --output-format human-readable-text "$CATALOG" >/dev/null

# TEMPORARY: the production icon is layered artwork that only Icon Composer can
# assemble; see ICON_COMPOSER_MANUAL_STEP.md. Until Hangar.icon exists this renders
# the flattened review preview so the bundle is not iconless.
if [[ -f "$ICON_SRC/Hangar.icon" ]]; then
    info "Hangar.icon present; Icon Composer output takes precedence"
    warn "Compiling a layered .icon needs Xcode's icon toolchain; wire it in here."
else
    info "Building a temporary icon from the review preview"
    ICONSET="$DIST_DIR/AppIcon.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    while read -r size name; do
        sips -z "$size" "$size" "$ICON_SRC/preview-default-1024.png" \
            --out "$ICONSET/$name.png" >/dev/null 2>&1
    done <<'SIZES'
16 icon_16x16
32 icon_16x16@2x
32 icon_32x32
64 icon_32x32@2x
128 icon_128x128
256 icon_128x128@2x
256 icon_256x256
512 icon_256x256@2x
512 icon_512x512
1024 icon_512x512@2x
SIZES
    iconutil -c icns "$ICONSET" -o "$DIST_DIR/AppIcon.icns"
    rm -rf "$ICONSET"
fi

info "Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
cp "$DIST_DIR/assets/Assets.car" "$APP_BUNDLE/Contents/Resources/Assets.car"
[[ -f "$DIST_DIR/AppIcon.icns" ]] && cp "$DIST_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"

IDENTITY="$(find_signing_identity)"
if [[ -n "$IDENTITY" ]]; then
    info "Signing with: $IDENTITY"
    # Hardened runtime and a secure timestamp are both required for notarization.
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP_BUNDLE"
else
    warn "No Developer ID Application cert: signing ad-hoc."
    warn "An ad-hoc bundle runs locally but cannot be notarized, and downloads stay quarantined."
    codesign --force --entitlements "$ENTITLEMENTS" \
        --sign - --timestamp=none "$APP_BUNDLE"
fi

codesign --verify --strict --verbose=1 "$APP_BUNDLE" 2>&1 | sed 's/^/    /'
info "Built $APP_BUNDLE"
