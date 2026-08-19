# Impuls

*English · [Русский](README.ru.md)*

[![Release](https://img.shields.io/github/v/release/TumanovNV/impuls?label=release&color=5b8cff)](https://github.com/TumanovNV/impuls/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/TumanovNV/impuls/total?label=downloads&color=5b8cff)](https://github.com/TumanovNV/impuls/releases)
[![macOS](https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white)](https://tumanovnv.github.io/impuls/)
[![Swift](https://img.shields.io/badge/Swift-6-f05138?logo=swift&logoColor=white)](Package.swift)
[![License](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)](LICENSE)

**[Website](https://tumanovnv.github.io/impuls/) · [Download](https://github.com/TumanovNV/impuls/releases/latest) · [Privacy](PRIVACY.md) · [Security](SECURITY.md)**

Impuls is a native macOS utility that turns the area around the MacBook notch —
or a compact top-edge tab on other Macs — into a local action search, player,
file shelf, clipboard history, snippets, calendar, translator, and scratchpad.

Impuls 1.4 adds a built-in **Battery** module. It shows charge, power state,
estimated running or charging time, and the electrical and battery indicators
that macOS actually makes available. On Macs without an internal battery, the
same module becomes **Power**. The available values vary by Mac model and macOS
version; unavailable hardware data is shown as unavailable rather than guessed.

> Public releases are currently ad-hoc signed and are not notarized by Apple,
> so the first installation still needs manual Gatekeeper approval. Beginning
> with 1.2.9, later releases install from inside Impuls through a signed update
> channel; Developer ID will remove the first-install warning when available.

## Privacy by design

- no advertising, account, remote configuration, or device fingerprinting;
- no network connection unless the user explicitly allows update checks,
  opens a selected web music service, or separately opts in to minimal version
  statistics;
- version statistics contain only a random installation pseudonym and app
  version (plus a correctly observed previous version), at most once per hour;
- update checks contact only the Impuls GitHub Releases endpoint;
- an update is downloaded and installed only after the user acts;
- clipboard content, notes, snippets, files, and calendar data never leave the Mac;
- concealed password-manager pasteboard entries are excluded from history;
- no private MediaRemote framework, `/usr/bin/perl`, or process injection; the
  updater uses only Sparkle's documented, signed helper components.

See [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md) for the precise model.

## Impuls Actions

Impuls 1.2 adds one local search across clipboard history, snippets, and notes.
The global shortcut opens Actions directly; Up and Down select a result, Enter
copies it, and the action bar can save it as a snippet, create a note, translate
text, open links or files, and reveal files in Finder. The index is built from
the live local stores and is never uploaded or persisted as another database.

With the pointer, a single click selects a result without running it and a
double-click copies it. Hover only highlights the row, so crossing other results
on the way to the action bar no longer replaces the explicit selection.

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

Impuls 1.2.9 adds authenticated in-app updates through Sparkle 2.9.5. The app
checks a fixed HTTPS feed only after consent, verifies the signed feed and the
Ed25519 signature of the update before extraction, replaces the application,
relaunches it, and leaves no installer in Downloads. Automatic installation and
anonymous system profiling remain disabled.

Impuls 1.2.8 separates pointer hover, selection, and activation in Actions. The
command bar now remains attached to the explicitly selected result while the
pointer travels across the list; a click selects and a double-click copies.

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
for prioritization without adding feedback analytics to the app. The separate
1.4.10 version statistic remains off until the user opts in.

## Settings and keyboard control

The native sidebar-and-detail Settings window can configure the global shortcut,
hover behaviour, panel size, target display, visible modules, and their order.
When opened from the keyboard, use the left and right arrows to move between
modules and Escape to close the panel. Settings, snippets, and notes can be
exported to and restored from a local JSON backup.

Impuls 1.4.11 adds a versioned first-run tour and a configurable **Menu Bar**
workspace. A fresh installation can choose a preset, a compact status item, one
or two live widgets, Smart priorities, and zero to four quick actions. Existing
installations receive only a concise What’s New note; the full tour remains
available from Settings → Menu Bar. The Menu Bar reads existing local battery and
player state only. It never starts a provider, makes a network request, or
invents missing device data.

## Battery and power

On a MacBook, the Battery module uses public IOPowerSources data for charge,
charging state, estimated time to empty or full charge, current, voltage,
temperature when published, and adapter rating. Battery-side power and adapter
rating are deliberately separate: a 70 W adapter is not claimed to be charging
the battery at 70 W. Cycle count is read locally through a small public IORegistry
fallback when the Mac publishes it. No power data is stored or sent anywhere.

MagSafe and USB-C are shown only when a reliable source provides that fact. The
public adapter API describes the adapter but not the active charging port, so a
connection otherwise remains unknown. On Mac mini, Mac Studio, iMac, and Mac Pro
the module displays the available system power source without inventing a wall-
power wattage.

## Music support

The Music pane now makes the source explicit. The native Apple Music adapter
uses its scripting interface and player-change events, with Automation as its
only music permission. Yandex Music is the first web choice, alongside VK Music
and YouTube Music. Their official sites open in a separate system
WebKit window only after the user presses **Open Web Player**; the notch then
shows the page's bounded Media Session metadata and sends transport or seek
actions back to that page. Selecting a source alone never starts a request.

Spotify is deliberately not on that list: its web player decrypts through
Widevine, which WebKit does not implement, so an embedded tab can sign in but
never play.

Impuls does not use unofficial catalogue APIs, copy audio, bypass a subscription
or DRM, or claim access to the private system-wide Now Playing database.

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
“Do Not Check” causes no update request. The decision can be changed from the
menu. Version 1.2.9 is the one-time transition install. Starting with 1.2.10,
“Check for Updates…” downloads a signed ZIP to temporary system storage,
verifies it before extraction, replaces Impuls, relaunches the app, and cleans
the temporary files. Developer ID and notarization are still required to remove
Gatekeeper approval from the first installation on a Mac.

## Licensing and origin

Impuls is derived from `akalikbergenov/cyclop`. Original MIT-licensed portions
retain their notice in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). New
Impuls work is distributed under GPL-3.0-or-later. The code license does not
grant rights to the Impuls name or branding; see [TRADEMARKS.md](TRADEMARKS.md).
