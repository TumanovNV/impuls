#!/bin/bash
# Builds Impuls.app without Xcode and signs it with Developer ID when configured.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Impuls.app"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version" 2>/dev/null || echo 1.0.0)"
ENTITLEMENTS="$ROOT/Resources/Impuls.entitlements"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/Impuls"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Impuls"

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
    <key>NSAppleEventsUsageDescription</key>
    <string>Impuls читает название текущего трека и управляет воспроизведением в Apple Music и Spotify.</string>
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

if [ -n "${IMPULS_DEVELOPER_ID_APPLICATION:-}" ]; then
    echo "==> Developer ID signing"
    codesign --force --deep --strict --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$IMPULS_DEVELOPER_ID_APPLICATION" "$APP"
else
    echo "==> ad-hoc signing (Developer ID is not configured)"
    codesign --force --deep --strict --options runtime \
        --entitlements "$ENTITLEMENTS" --sign - "$APP"
fi

codesign --verify --deep --strict "$APP"
echo "==> done: $APP"
