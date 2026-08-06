# Impuls

*English · [Русский](README.ru.md)*

Impuls is a native macOS utility that turns the area around the MacBook notch —
or a compact top-edge tab on other Macs — into a player, file shelf, clipboard
history, snippets, calendar, translator, and scratchpad.

> Public releases are currently ad-hoc signed and are not notarized by Apple.
> macOS therefore requires manual Gatekeeper approval. Trusted automatic
> installation remains disabled until Developer ID signing and notarization are configured.

## Privacy by design

- no analytics, telemetry, advertising, or device fingerprinting;
- no network connection unless the user explicitly allows update checks;
- update checks contact only the Impuls GitHub Releases endpoint;
- an update is never downloaded before the user acts;
- clipboard content, notes, snippets, files, and calendar data never leave the Mac;
- concealed password-manager pasteboard entries are excluded from history;
- no private MediaRemote framework, `/usr/bin/perl`, dynamic-library injection,
  or hidden helper process.

See [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md) for the precise model.

## Music support

Apple Music and Spotify provide metadata, seeking, artwork where available, and
transport controls through their public scripting interfaces. Other players and
browser tabs may receive standard media-key controls when macOS grants the
required Accessibility permission. Apple does not provide a public API that
exposes full metadata for every system Now Playing source.

## Requirements

- macOS 15 or newer;
- Swift 6 toolchain for source builds.

Macs without a physical notch use a 96 × 10 pt tab with a 120 × 16 pt hover
target. MacBook notch geometry is detected from the display safe area.

## Build

```bash
./Scripts/bundle.sh release
open build/Impuls.app
```

The script uses Developer ID when `IMPULS_DEVELOPER_ID_APPLICATION` is configured;
otherwise it produces an ad-hoc signed development build. An ad-hoc build needs
manual Gatekeeper approval on another Mac.

## Update policy

At first launch, Impuls asks whether it may check GitHub Releases. Choosing
“Stay Offline” causes no update request. The decision can be changed from the
menu. Until Developer ID and notarization are available, the safe update action
opens the release page for a manual install; in-app unattended installation is
intentionally disabled.

## Licensing and origin

Impuls is derived from `akalikbergenov/cyclop`. Original MIT-licensed portions
retain their notice in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). New
Impuls work is distributed under GPL-3.0-or-later. The code license does not
grant rights to the Impuls name or branding; see [TRADEMARKS.md](TRADEMARKS.md).
