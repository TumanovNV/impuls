#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Impuls.app"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version" 2>/dev/null || echo 1.0.0)"
DMG="$ROOT/build/Impuls-$VERSION.dmg"

"$ROOT/Scripts/bundle.sh" release

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Impuls.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Impuls $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -quiet "$DMG"
hdiutil verify "$DMG"

INSIDE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
test "$INSIDE" = "$VERSION"

if ! spctl -a "$APP" >/dev/null 2>&1; then
    cat <<'NOTE'

WARNING: this build is ad-hoc signed and not notarized. Gatekeeper will require
manual approval on another Mac. Public automatic installation must remain off
until a Developer ID certificate and Apple notarization are configured.
NOTE
fi

echo "==> done: $DMG"
