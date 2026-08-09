# Impuls

*English · [Русский](README.ru.md)*

Impuls is a native macOS utility that turns the area around the MacBook notch —
or a compact top-edge tab on other Macs — into a local action search, player,
file shelf, clipboard history, snippets, calendar, translator, and scratchpad.

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

## Impuls Actions

Impuls 1.2 adds one local search across clipboard history, snippets, and notes.
The global shortcut opens Actions directly; Up and Down select a result, Enter
copies it, and the action bar can save it as a snippet, create a note, translate
text, open links or files, and reveal files in Finder. The index is built from
the live local stores and is never uploaded or persisted as another database.

Impuls 1.2.1 adds pinned clipboard entries, content-aware actions for links,
email addresses, phone numbers and JSON, monitoring pause, retention controls,
and per-application exclusions. History remains memory-only by default. Optional
between-launch persistence encrypts the local archive with AES-GCM and stores its
random key in macOS Keychain.

## File tools

Impuls 1.2.2 adds local file actions to the shelf. Images can be converted to
PNG, JPEG, or HEIC, reduced to a selected maximum dimension, combined into a
multi-page PDF, or processed with Apple Vision to recognize text and remove the
background. The shelf also exposes AirDrop, the macOS Share menu, path copying,
and safe renaming. Transformations always create a uniquely named sibling file;
the source is never overwritten or uploaded.

Impuls 1.2.3 extends those actions to multiple selected images, reports batch
progress, adds system Quick Look, and can safely undo the latest generated-file
or rename operation. Generated results are moved to the Trash only while they
remain unchanged; Impuls refuses to touch a file the user has modified.

## Stability and feedback

Impuls 1.2.7 keeps a hover-opened panel visible for the complete lifetime of a
context menu, including nested image tools. Closing the menu restores the normal
hover decision, preventing detached submenus and visual artifacts.

The 1.2.6 stabilization work also keeps compact rows and local search on
bounded text projections, screenshot and note writes no longer occupy the UI
thread, player refreshes are coalesced, artwork is downsampled before display,
and Calendar link discovery has an explicit processing budget. Generated-file
Undo now verifies a SHA-256 content digest before moving a result to the Trash.

A feedback center in the menu and Settings collects a problem report, an
improvement idea, or a general rating. The report is built locally and shown
before it leaves the Mac. Optional diagnostics are limited to the Impuls
version, macOS version, and processor architecture. Clipboard contents, notes,
files, paths, calendar data, logs, and device identifiers are never added.
Impuls uploads nothing itself: after an explicit action it copies the report and
opens the public GitHub form in the system browser.

Repository forms use the same core area, frequency, rating, and version fields
and unstructured blank issues are disabled, keeping voluntary feedback useful
for prioritization without adding analytics to the app.

## Settings and keyboard control

The native Settings window can configure the global shortcut,
hover behaviour, panel size, target display, visible modules, and their order.
When opened from the keyboard, use the left and right arrows to move between
modules and Escape to close the panel. Settings, snippets, and notes can be
exported to and restored from a local JSON backup.

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
swift test -c release
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
