# Impuls

*English · [Русский](README.ru.md)*

[![Release](https://img.shields.io/github/v/release/TumanovNV/impuls?label=release&color=5b8cff)](https://github.com/TumanovNV/impuls/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/TumanovNV/impuls/total?label=downloads&color=5b8cff)](https://github.com/TumanovNV/impuls/releases)
[![macOS](https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white)](https://tumanovnv.github.io/impuls/)
[![Swift](https://img.shields.io/badge/Swift-6-f05138?logo=swift&logoColor=white)](Package.swift)
[![License](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)](LICENSE)

**[Website](https://tumanovnv.github.io/impuls/) · [Download](https://github.com/TumanovNV/impuls/releases/latest) · [Privacy](https://tumanovnv.github.io/impuls/privacy/) · [Security](SECURITY.md)**

Impuls is a native macOS utility that turns the area around the MacBook notch —
or a compact top-edge tab on other Macs — into a local action search, player,
file shelf, clipboard history, snippets, calendar, translator, notes, and
battery/power workspace.

The current product ships **seven interface languages**: English, Russian,
German, French, Spanish, Simplified Chinese, and Japanese. The public marketing
site and privacy notices have matching static language versions. The application
follows macOS by default; **Settings → General → Interface Language** can select
one explicitly and Impuls safely relaunches itself to apply the change.

Impuls 1.4 adds a built-in **Battery / Power** module. It shows charge, power
state, estimated running or charging time, and the electrical and battery
indicators that macOS actually makes available. On Macs without an internal
battery, the same module becomes **Power**. The available values vary by Mac
model and macOS version; unavailable hardware data is shown as unavailable
rather than guessed.

> Public releases are currently ad-hoc signed and are not notarized by Apple,
> so the first installation still needs manual Gatekeeper approval. Later
> releases install from inside Impuls through a signed Sparkle update channel;
> Developer ID will remove the first-install warning when available.

## Privacy by design

- no advertising, account, remote configuration, or device fingerprinting;
- no network connection unless the user explicitly allows update checks,
  opens a selected web music service, or separately opts in to minimal version
  statistics;
- version statistics contain only a random installation pseudonym and app
  version (plus a correctly observed previous version), at most one attempt per
  hour for the same app version;
- update checks contact only the fixed Impuls GitHub Releases feed;
- an update is downloaded and installed only after the user acts;
- clipboard content, notes, snippets, files, calendar data, and project-support
  eligibility never leave the Mac through Impuls telemetry;
- concealed password-manager pasteboard entries are excluded from history;
- no private MediaRemote framework, `/usr/bin/perl`, or process injection; the
  updater uses only Sparkle's documented, signed helper components.

See [PRIVACY.md](PRIVACY.md), the localized [privacy policy](https://tumanovnv.github.io/impuls/privacy/), and [SECURITY.md](SECURITY.md) for the precise model.

## Seven languages

The macOS application currently carries these complete localization tables:

- English (`en`)
- Русский (`ru`)
- Deutsch (`de`)
- Français (`fr`)
- Español (`es`)
- 简体中文 (`zh-Hans`)
- 日本語 (`ja`)

Every shipped application localization contains both `Localizable.strings` and
localized `InfoPlist.strings`. CI requires the same user-facing key set in every
application table and verifies the bundle declaration. Language selection is
local; Impuls downloads no language pack and sends no language preference as
telemetry.

The website has separate static routes for the same current language set, and
its legal/privacy pages are a third independent localization contract. Their
sets happen to match today but are not inferred from one another. Engineering
details live in `knowledge-base/04-development/localization.md`.

## Impuls Actions

Impuls 1.2 adds one local search across clipboard history, snippets, and notes.
The global shortcut opens Actions directly; Up and Down select a result, Enter
copies it, and the action bar can save it as a snippet, create a note, translate
text, open links or files, and reveal files in Finder. The index is built from
the live local stores and is never uploaded or persisted as another database.

With the pointer, a single click selects a result without running it and a
double-click copies it. Hover only highlights the row, so crossing other results
on the way to the action bar no longer replaces the explicit selection.

Snippets can also hold a **local file pin** — drop a file on the Snippets tab and
the row copies, opens, or reveals that file. Impuls stores the readable path and
an optional local bookmark so a rename or a move can be followed; it never reads
or stores the file's contents, and the bookmark is left out of a portable backup.

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

## Stability, feedback, and project support

Impuls uses authenticated in-app updates through Sparkle 2.9.5. The app checks a
fixed HTTPS feed only after consent, verifies the signed feed and the Ed25519
signature of the update before extraction, replaces the application, relaunches
it, and leaves no installer in Downloads. Automatic installation and anonymous
system profiling remain disabled by default.

Actions keeps pointer hover, explicit selection, and activation separate. The
command bar remains attached to the explicitly selected result while the pointer
travels across the list; a click selects and a double-click copies. Context-menu
lifecycle and bounded local processing are covered by the current test/CI
contracts rather than inferred from an old release note.

A feedback center in the menu and Settings collects a problem report, an
improvement idea, or a general rating. The report is built locally and shown
before it leaves the Mac. Optional diagnostics are limited to the Impuls
version, macOS version, and processor architecture. Clipboard contents, notes,
files, paths, calendar data, logs, and device identifiers are never added.
Impuls uploads nothing itself: after an explicit action it copies the report and
opens the public GitHub form in the system browser.

After sustained deliberate use, Impuls may also offer **Support the Project**:
a GitHub project link or the same Feedback window. Eligibility is computed only
on the Mac, is never telemetry, and automatic presentation is capped at two
appearances for the lifetime of that local state. Impuls does not query GitHub
to check whether a star was actually given.

Repository forms use the same core area, frequency, rating, and version fields
and unstructured blank issues are disabled, keeping voluntary feedback useful
for prioritization without adding feedback analytics to the app. The separate
minimal version statistic remains off until the user opts in.

## Settings and keyboard control

The native sidebar-and-detail Settings window can configure the global shortcut,
hover behaviour, panel size, target display, visible modules, their order, Menu
Bar workspace, privacy choices, Apple-device visibility, and interface language.
When opened from the keyboard, use the left and right arrows to move between
modules and Escape to close the panel. Settings, snippets, and notes can be
exported to and restored from a local JSON backup; machine-local language,
device identity/order, and project-support state are not turned into portable
cross-Mac identity.

Impuls 1.4.11 introduced a versioned first-run tour and a configurable **Menu
Bar** workspace. A fresh installation can choose a preset, a compact status
item, one or two live widgets, Smart priorities, and zero to four quick actions.
Existing installations receive a concise version-aware What’s New note; the
full tour remains available from Settings. The Menu Bar reads existing local
battery and player state only. It never starts a provider, makes a network
request, or invents missing device data.

## Battery and power

On a MacBook, the Battery module uses public IOPowerSources data for charge,
charging state, estimated time to empty or full charge, current, voltage,
temperature when published, and adapter rating. Battery-side power and adapter
rating are deliberately separate: a 70 W adapter is not claimed to be charging
the battery at 70 W. Cycle count is read locally through a small public
IORegistry fallback when the Mac publishes it. No power data is stored or sent
anywhere.

MagSafe and USB-C are shown only when a reliable source provides that fact. The
public adapter API describes the adapter but not the active charging port, so a
connection otherwise remains unknown. On Mac mini, Mac Studio, iMac, and Mac Pro
the module displays the available system power source without inventing a wall-
power wattage.

**Stay Awake** is an explicit mode in the same module: while it is on, the Mac
does not fall into user-idle sleep, and a separate option can additionally hold
the display awake. It is local only — it changes no Energy Saver setting, is
never restored across a launch, and adds no network or telemetry path.

When the user separately turns on Apple devices, Impuls can also show the battery
of connected Apple accessories and of an iPhone or iPad this Mac already trusts.
That iPhone/iPad status is stable in normal use, but its device-sync transport is
an undocumented Apple protocol boundary rather than a public API, so no particular
model or iOS version is guaranteed. Unavailable values stay unavailable.

## Music support

The Music pane makes the source explicit. The native Apple Music adapter uses
its scripting interface and player-change events, with Automation as its only
music permission. Yandex Music, VK Music, and YouTube Music can open their
official sites in a separate system WebKit window only after the user presses
**Open Web Player**; the notch then shows bounded page metadata and sends
transport or seek actions back to that page. Selecting a source alone never
starts a request.

Spotify is supported the same native way as Apple Music: Impuls talks to the
installed Spotify macOS app through the Scripting Dictionary that app ships, over
the public Apple Events path, and macOS grants that Automation per application —
so Apple Music and Spotify are allowed independently and nothing is requested for
an application that is not installed.

What remains unsupported is Spotify **web** embedding: its web player decrypts
through Widevine, which WebKit does not implement, so an embedded tab can sign in
but never play. That limit applies to the web player alone, not to Spotify.

Impuls does not use unofficial catalogue APIs, copy audio, bypass a subscription
or DRM, or claim access to the private system-wide Now Playing database.

## Requirements

- macOS 15 or newer;
- Swift 6 toolchain for source builds.

Macs without a physical notch use a compact top-edge tab; MacBook notch geometry
is detected from the display safe area. Exact geometry belongs to the current
theme/geometry implementation and tests rather than this public overview.

## Build

```bash
swift test -c release
./Scripts/bundle.sh release
open build/Impuls.app
```

The script uses Developer ID when `IMPULS_DEVELOPER_ID_APPLICATION` is configured;
otherwise it produces an ad-hoc signed build. An ad-hoc build needs manual
Gatekeeper approval on another Mac.

## Update policy

At first launch, Impuls asks whether it may check GitHub Releases. Choosing not
to check causes no update request. The decision can be changed later. When the
user requests/allows an update, Sparkle uses temporary system storage, verifies
the signed feed and archive before extraction, replaces Impuls, relaunches the
app, and cleans temporary files. Developer ID and notarization are still
required to remove Gatekeeper approval from the first installation on a Mac.

## Licensing and origin

Impuls is derived from `akalikbergenov/cyclop`. Original MIT-licensed portions
retain their notice in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). New
Impuls work is distributed under GPL-3.0-or-later. The code license does not
grant rights to the Impuls name or branding; see [TRADEMARKS.md](TRADEMARKS.md).
