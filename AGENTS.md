# AGENTS.md

Instructions for coding agents working on Impuls. Read this before changing anything.

Impuls is a native macOS utility that turns the area around the MacBook notch into a
local panel: Actions search, music, file shelf, clipboard history, snippets, calendar,
translator and notes. Swift 6 toolchain, SwiftUI on top of AppKit, macOS 15 or newer.
Everything runs on the device.

## Active development: Impuls 1.4.6 — Apple Device Battery Center

Working branch `agent/apple-device-center-1.4.6`, based on `release/1.4.5` and
**not** on `main` — 1.4.5 is not merged yet, and branching from `main` loses it.
Phases 01–04.1 are done; phase 05 (UI, Settings, localization, accessibility) is
next.

Read before editing anything in this area:

- `docs/IMPULS_1_4_6_HANDOFF.md` — state, decisions, what hardware proved
- `docs/IMPULS_1_4_6_CODEMAP.md` — which file does what
- `docs/APPLE_DEVICE_BATTERY_SUPPORT.md` — capability matrix, per data point
- `docs/QA_APPLE_DEVICES_1.4.6.md` — what is verified on hardware and what is not
- `PRIVACY.md`, `SECURITY.md` — the promises the code has to keep

Invariants specific to this work, on top of the hard invariants below:

1. `.power` stays the module's internal identifier — settings, backup and
   migrations depend on it.
2. `PowerMonitor` and the rest of the 1.4.5 power path are not rewritten.
   `LocalMacDeviceProvider` adapts them.
3. No private Apple frameworks. Secure Transport is legacy but public, and it
   lives only in `LockdownTLSChannel.swift`.
4. Raw device identifiers — UDID, serial, Bluetooth address, pairing material —
   never reach the UI, logs, feedback or backups. `AppleDeviceIdentity` is the
   boundary and is deliberately not `Codable`.
5. External device discovery is off until the user turns it on. An update must
   never produce a new prompt or connection by itself.
6. I/O never runs on the main actor. `DeviceBatterySource` is not `@MainActor`
   on purpose, and a test enforces it.
7. Missing data stays missing. Never a fabricated 0%, never a guessed charging
   state, never a category rendered as a number.
8. The iPhone/iPad provider is Beta, behind `IMPULS_MOBILE_DEVICE_BATTERY`, off
   by default.
9. The AirPods `system_profiler` source is best-effort: fixed absolute path,
   fixed arguments, no shell, no user input in the argument list, bounded
   output, timeout.
10. Before the final 1.4.6 pull request, sync with the finished 1.4.5.
    `backup/1.4.5-local-handoff` holds 1.4.5 material that exists nowhere else —
    do not merge it into 1.4.6.

## Commands

```bash
swift test -c release        # the full test suite; run it before every commit
./Scripts/bundle.sh release  # produces build/Impuls.app
./Scripts/dmg.sh             # produces build/Impuls-<version>.dmg
open build/Impuls.app
```

`Scripts/bundle.sh` signs with Developer ID when `IMPULS_DEVELOPER_ID_APPLICATION`
is set and falls back to an ad-hoc signature otherwise.

## Hard invariants

`.github/workflows/build.yml` enforces every item below with a literal `grep`, so
breaking one turns CI red rather than producing a subtly worse app. Read that
workflow before arguing with this list.

1. **Network access has two explicit owners.** `UpdateService.swift` owns the
   opt-in Sparkle channel. `WebMusicPlayer.swift` may open only the official HTTPS
   site selected by the user, and only from the explicit Open Web Player action;
   merely launching Impuls or selecting a source must not construct `WKWebView`.
   `URLSession`, `NSURLSession`, `URLRequest`, `NSURLConnection`, `NWConnection`,
   `NWListener`, `webSocketTask` and `CFStreamCreatePairWithSocketToHost` are banned
   everywhere else. The PR smoke test must still observe zero sockets at launch.
2. **No private media APIs and no injection.** `/usr/bin/perl`, `MediaRemote`,
   `dl_load_file` and `DynaLoader` must not appear anywhere in `Sources` or `Scripts`.
   Native Apple Music metadata comes from its scripting interface and bounded
   player-change notifications, guarded by `AEDeterminePermissionToAutomateTarget`.
   Web metadata comes only from the selected provider page's bounded Media Session
   bridge after the user opens that page.
3. **Sparkle is pinned.** `exact: "2.9.5"` in `Package.swift` and the matching
   revision in `Package.resolved`. Do not add, bump or replace dependencies.
4. **The panel follows the system appearance.** `darkAqua`, `Color.white` and
   `foregroundStyle(.white)` are banned in `Sources/Impuls/UI` and
   `Sources/Impuls/Notch`. Colours come from `Theme.swift`, which wraps semantic
   AppKit colours. The collapsed tab is the one deliberate exception: it stays black
   so it merges with the physical cutout.
5. **Actions selection never follows the pointer.** Hover is a visual affordance
   only; `if $0 { select() }` in `ActionsPane.swift` is explicitly rejected by CI.
6. **Localization is complete.** Every `localized("…")` key must exist in both
   `Resources/en.lproj/Localizable.strings` and `Resources/ru.lproj/Localizable.strings`.
   Keys are the English text itself, so a missing translation degrades to English
   instead of showing an identifier.
7. **Version and release notes travel together.** `Scripts/version` holds
   `VERSION=x.y.z`, and `docs/releases/x.y.z.md` must exist and be non-empty.
8. **`docs/index.html` keeps three literal strings** that CI greps for:
   `const RELEASE_API = 'https://api.github.com/repos/TumanovNV/impuls/releases/latest';`,
   `function releaseHash(asset,body)` and `data-conversion="feedback"`.
9. **Feedback collects nothing.** `FeedbackService.swift` may not reference
   `URLSession`, `URLRequest`, `IOKit`, `IOPlatformSerialNumber`, `hostName` or
   `machineIdentifier`. It opens a prefilled GitHub issue in the browser.
10. **Sparkle is opt-in and verified.** Automatic checks and automatic installation
    both default to `false`; system profiling is always `false`. A user may enable
    automatic installation only after opting into update checks in Settings. Signed
    feed and verify-before-extraction are always `true`.
11. **Bounded reads everywhere.** Files and pasteboard payloads go through
    `BoundedFileReader`, `BoundedData` and `BoundedText`. Search input is capped at
    16 KiB, calendar scanning at 32 KiB, artwork at 16 MiB.

## Layout

| Path | What lives there |
| --- | --- |
| `Sources/Impuls/App` | `AppDelegate`, launcher glue, `localized()` |
| `Sources/Impuls/Model` | `NotchViewModel` — tabs, stores, panel state |
| `Sources/Impuls/Notch` | window, geometry, shape, pointer tracking |
| `Sources/Impuls/Services` | one store or service per file, no UI |
| `Sources/Impuls/Settings` | native settings and feedback windows |
| `Sources/Impuls/UI` | one `*Pane.swift` per module, plus `Theme.swift` |
| `Sources/ImpulsLauncher` | three-line executable target |
| `Tests/ImpulsTests` | one test file per service |
| `Resources` | `*.lproj` string tables, entitlements |
| `Scripts` | `bundle.sh`, `dmg.sh`, `version`, `make-icon.swift` |
| `docs` | the public website, release notes, security audits |

## Conventions

- **Comments are in English** and explain *why*, not *what*. The existing comments
  are unusually detailed about trade-offs — match that, and say what was tried and
  rejected when the reason is not obvious from the code.
- **UI numbers come from the code, not from taste.** Sizes and radii live in
  `Theme.swift` and the panes; the expanded panel is `620 × 208` pt by default
  (`NotchGeometry.expandedSize`), corner radii are 12 pt on top and 22 pt at the
  bottom when open.
- **The rail has two sides.** Enabled modules are split evenly between them, the
  left rail taking the extra one when the count is odd, so nine modules go 5/4
  (`NotchViewModel.leftRailTabs` / `rightRailTabs`). Icon height is fitted to the
  panel by `NotchContentView.railButtonHeight`, not fixed.
- **Stores never import SwiftUI**; panes never touch the filesystem directly.
- **One responsibility per file.** A new module means a new `*Pane.swift`, a new
  store, a `Tab` case, and string-table entries in both languages.

## Release flow

1. Bump `VERSION` in `Scripts/version`.
2. Write `docs/releases/<version>.md` with a Russian section, then `---`, then a
   short English summary. Follow the existing files.
3. Open a pull request and let `build.yml` pass.
4. Merging to `main` runs `release.yml`: it tags `v<version>`, builds, signs the
   appcast with the Sparkle key from repository secrets, and creates the release
   with the DMG, ZIP, both checksums and `appcast.xml`.

Never create tags or releases by hand, and never commit signing keys.

## Website

`docs/` is served by GitHub Pages. `docs/index.html` is a single self-contained file:
no build step, no external CSS or JS. Version, download link and SHA-256 are fetched
from the GitHub Releases API at runtime, so **do not hardcode a version** — the one
in the markup is only a fallback for when the API is unreachable.

See `.claude/rules/website.md` for the CSS pitfalls that have already bitten once.
