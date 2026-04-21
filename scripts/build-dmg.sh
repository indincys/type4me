#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && /bin/pwd -P)"
APP_NAME="Type4Me"
APP_VERSION="${APP_VERSION:-1.9.2}"
ARCH="${ARCH:-universal}"      # arm64 or universal
DIST_DIR="${DIST_DIR:-$PROJECT_DIR/dist}"
VOLUME_NAME="${VOLUME_NAME:-$APP_NAME}"
DMG_NAME="${DMG_NAME:-${APP_NAME}-v${APP_VERSION}-cloud.dmg}"
DMG_PATH="$DIST_DIR/$DMG_NAME"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/type4me-dmg.XXXXXX")"

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

case "$ARCH" in
    arm64|universal) ;;
    *) echo "ERROR: Unknown ARCH=$ARCH (expected arm64 or universal)"; exit 1 ;;
esac

echo "=== Building cloud-only DMG (${ARCH}) ==="
mkdir -p "$DIST_DIR"

ARCH="$ARCH" APP_VERSION="$APP_VERSION" \
    APP_PATH="$STAGING_DIR/${APP_NAME}.app" bash "$SCRIPT_DIR/package-app.sh"

ln -s /Applications "$STAGING_DIR/Applications"

SIGNED_WITH_DEVID=0
CODESIGN_INFO=$(codesign -dvv "$STAGING_DIR/${APP_NAME}.app" 2>&1 || true)
if echo "$CODESIGN_INFO" | grep -q "Developer ID"; then
    SIGNED_WITH_DEVID=1
    echo "Verified: signed with Developer ID"
fi

rm -f "$DMG_PATH"
echo "Creating DMG at $DMG_PATH..."
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)

NOTARY_PROFILE="${NOTARY_PROFILE:-type4me-notary}"
if [ "$SIGNED_WITH_DEVID" = "1" ]; then
    echo ""
    echo "=== Notarizing DMG ==="
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "$DMG_PATH"
    echo "Notarization complete."
else
    echo "(Skipping notarization: not signed with Developer ID)"
fi

echo ""
echo "=== DMG ready ==="
echo "  Path: $DMG_PATH"
echo "  Size: $DMG_SIZE"
echo "  Variant: cloud"
echo "  Arch: $ARCH"
