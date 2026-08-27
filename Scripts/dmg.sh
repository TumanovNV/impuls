#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Impuls.app"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version" 2>/dev/null || echo 1.0.0)"
DMG="$ROOT/build/Impuls-$VERSION.dmg"

# Packaging and building are separate concerns, and conflating them broke
# artifact identity: the release workflow built the app, then this script built
# it again, so the ZIP Sparkle ships came from a different binary than the one
# the workflow had just verified. Once a bundle is notarized and stapled, a
# rebuild silently discards the ticket. `--no-build` is how the release workflow
# packages the one app that went through Apple; the default still builds so the
# local `./Scripts/dmg.sh` habit keeps working.
BUILD_APP=1
for ARGUMENT in "$@"; do
    case "$ARGUMENT" in
        --no-build) BUILD_APP=0 ;;
        *)
            echo "usage: ${BASH_SOURCE[0]##*/} [--no-build]" >&2
            exit 2
            ;;
    esac
done

if [ "$BUILD_APP" -eq 1 ]; then
    "$ROOT/Scripts/bundle.sh" release
elif [ ! -d "$APP" ]; then
    # Refuse to package nothing. A missing bundle here means the caller skipped
    # the build step, and an empty or stale image is worse than a failed job.
    echo "--no-build requires an existing $APP" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# ditto rather than cp -R: this now stages a Developer ID signed and stapled
# bundle, and ditto is the tool Apple documents for copying one without losing
# extended attributes or breaking the signature seal. bundle.sh already uses it
# for Sparkle.framework for the same reason.
ditto "$APP" "$STAGE/Impuls.app"
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
