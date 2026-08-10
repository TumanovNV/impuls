#!/bin/bash
# Builds Impuls.app without Xcode, embeds Sparkle, and signs the bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Impuls.app"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version" 2>/dev/null || echo 1.0.0)"
ENTITLEMENTS="$ROOT/Resources/Impuls.entitlements"
ADHOC_ENTITLEMENTS="$ROOT/Resources/Impuls.AdHoc.entitlements"
SPARKLE_PUBLIC_KEY="/fAb0WKLYV8FTT+VkvGKgtIXfsiVG74NlJ+to0BusDg="
SPARKLE_FEED_URL="https://github.com/TumanovNV/impuls/releases/latest/download/appcast.xml"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/Impuls"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Impuls"

SPARKLE_FRAMEWORK="$(find "$ROOT/.build/artifacts" -type d \
    -path '*/Sparkle.xcframework/macos-*/Sparkle.framework' -print -quit)"
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    echo "Sparkle.framework was not resolved by Swift Package Manager" >&2
    exit 1
fi
echo "==> Sparkle 2 framework"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"

echo "==> application and menu-bar icons"
swift "$ROOT/Scripts/make-icon.swift" \
    "$APP/Contents/Resources/AppIcon.icns" \
    "$APP/Contents/Resources/ImpulsStatusTemplate.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Impuls</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>ru</string></array>
    <key>CFBundleDisplayName</key><string>Impuls</string>
    <key>CFBundleIdentifier</key><string>io.tumanov.impuls</string>
    <key>CFBundleExecutable</key><string>Impuls</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>SUFeedURL</key><string>$SPARKLE_FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><false/>
    <key>SUAutomaticallyUpdate</key><false/>
    <key>SUAllowsAutomaticUpdates</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
    <key>SUEnableSystemProfiling</key><false/>
    <key>SUVerifyUpdateBeforeExtraction</key><true/>
    <key>SURequireSignedFeed</key><true/>
    <key>SUSignedFeedFailureExpirationInterval</key><integer>0</integer>
    <key>SUShowReleaseNotes</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Impuls читает название текущего трека и управляет воспроизведением в приложении Apple Music.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Impuls показывает ближайшие встречи и кнопку подключения к ним.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Impuls показывает ближайшие встречи и кнопку подключения к ним.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 TumanovNV. Portions © 2026 akalikbergenov.</string>
</dict>
</plist>
PLIST

echo "==> localizations"
for lproj in "$ROOT"/Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$APP/Contents/Resources/"
done
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/ThirdPartyNotices.md"

if [ -n "${IMPULS_DEVELOPER_ID_APPLICATION:-}" ]; then
    echo "==> Developer ID signing"
    # Library Validation requires the embedded dynamic framework to carry the
    # application's identity. Sign the framework first, then seal the app.
    codesign --force --strict --options runtime --timestamp \
        --sign "$IMPULS_DEVELOPER_ID_APPLICATION" \
        "$APP/Contents/Frameworks/Sparkle.framework"
    codesign --force --strict --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$IMPULS_DEVELOPER_ID_APPLICATION" "$APP"
else
    echo "==> ad-hoc signing (Developer ID is not configured)"
    # The upstream Sparkle framework keeps its own valid signature. An ad-hoc
    # host has no Team ID, so Library Validation is disabled only for this
    # transitional build. The production Developer ID path does not use this
    # entitlement.
    codesign --force --strict --options runtime \
        --entitlements "$ADHOC_ENTITLEMENTS" --sign - "$APP"
fi

codesign --verify --deep --strict "$APP"
echo "==> done: $APP"
