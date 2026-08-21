---
title: Behavioral QA Matrix
type: qa-reference
status: active
documentation_version: 1.3
app_version: 1.4.12
last_reviewed: 2026-08-19
tags: [impuls, qa, scenarios, hardware, permissions, release]
---

# Behavioral QA Matrix

The rows below describe the contract to verify. They deliberately separate **verification mode** from **pass/fail evidence** so documentation cannot accidentally claim a release passed hardware QA merely because a scenario exists.

## Display, pointer and lifecycle

| ID | Scenario | Mode | Expected contract |
| --- | --- | --- | --- |
| DISP-01 | MacBook built-in display only | mixed | one surface, correct notch geometry, no duplicate service graph |
| DISP-02 | Mac mini / display without physical notch | manual-hardware | top-edge anchor behaves correctly without assuming a MacBook notch |
| DISP-03 | MacBook + one external monitor | mixed | exactly one active surface; shared state follows presentation handoff |
| DISP-04 | Two external displays | manual-hardware | pointer routing selects only the target display and does not create per-display polling |
| DISP-05 | Hot-plug / unplug external display | mixed | stale surface and pointer bookkeeping are removed without orphan windows |
| DISP-06 | Move pointer directly between display anchors | automated | dwell/handover uses the incoming display and preserves one active panel |
| DISP-07 | Pointer parked in menu bar/top band | automated | sampler cools to idle cadence after rest threshold |
| DISP-08 | Open from keyboard while pointer is elsewhere | automated | panel is not immediately closed by stale pointer authority |
| DISP-09 | Context menu / drag leaves visual panel bounds | automated | lifecycle hold prevents premature close, then releases cleanly |
| DISP-10 | Sleep → wake with external display changes | manual-hardware | topology/surface state is rebuilt without duplicate monitors or frozen keyboard ownership |

## Permissions and TCC

| ID | Scenario | Mode | Expected contract |
| --- | --- | --- | --- |
| PERM-01 | Fresh install, launch only | manual-macos | no sensitive permission prompt appears merely because Impuls launched |
| PERM-02 | Calendar never opened | manual-macos | no Calendar prompt |
| PERM-03 | Calendar explicit access action | mixed | prompt occurs only from user action; granted state populates events |
| PERM-04 | Calendar denied | mixed | useful denied state; app remains functional; no prompt loop |
| PERM-05 | Apple Music automation not determined | manual-macos | read path does not silently prompt; explicit resolve action may prompt |
| PERM-06 | Apple Music automation denied | mixed | explanatory access state and System Settings route; no crash/retry storm |
| PERM-07 | External Apple devices disabled | mixed | no usbmuxd topology socket/read is started |
| PERM-08 | Notifications not granted for low-battery alert | manual-macos | feature explains/handles permission state without blocking Power module |

## Power and connected devices

| ID | Scenario | Mode | Expected contract |
| --- | --- | --- | --- |
| PWR-01 | MacBook on battery | mixed | local battery, charging state and estimates are truthful; missing fields stay missing |
| PWR-02 | MacBook charging via MagSafe | manual-hardware | source/power details use available system data; no fabricated connector label |
| PWR-03 | MacBook charging via USB-C | manual-hardware | source/power details remain truthful and responsive |
| PWR-04 | Desktop Mac with no internal battery | mixed | unavailable-desktop state, never fake `0%` |
| PWR-05 | Supported Apple accessory appears/disappears | manual-hardware | list updates from event/read path without duplicate rows |
| PWR-06 | AirPods component topology changes | manual-hardware | bounded active polling observes public-source lag without busy polling |
| PWR-07 | Trusted unlocked iPhone over USB | manual-hardware | battery snapshot arrives off-main; UI remains responsive |
| PWR-08 | iPhone locked / temporarily unavailable | manual-hardware | temporary failure/backoff, no UI freeze and no invented percentage |
| PWR-09 | iPhone unplugged during read | manual-hardware | task/session unwinds; backoff/topology state recovers |
| PWR-10 | macOS Wi-Fi sync topology transition | manual-hardware | topology change does not require 1 s battery polling and does not leak raw identity |
| PWR-11 | Repeated provider failures | automated | scheduler doubles cadence up to 600 s cap and resets after success |

## Local data, migration and bounds

| ID | Scenario | Mode | Expected contract |
| --- | --- | --- | --- |
| DATA-01 | Existing pre-new-field settings snapshot | automated | tolerant decode/default preserves old install |
| DATA-02 | Backup schema 1 import | automated | accepted and decoded compatibly |
| DATA-03 | Future backup schema | automated | rejected explicitly, current data not replaced |
| DATA-04 | Backup larger than 10 MiB | automated | bounded read rejects before unbounded decode |
| DATA-05 | Notes/snippets > 5000 in import | automated | rejected by item-count budget |
| DATA-06 | Corrupt notes/snippets JSON | mixed | no crash; invalid external state is not half-published |
| DATA-07 | Snippets file replaced while being read | automated | signature retry avoids mixed/stale snapshot |
| DATA-08 | Clipboard persistence enabled → relaunch | automated | encrypted archive restores valid bounded history |
| DATA-09 | Clipboard persistence disabled | automated | archive and device-only encryption key are deleted |
| DATA-10 | Concealed/internal clipboard item | automated | item is not captured |
| DATA-11 | Oversized clipboard text/image | automated | payload rejected within documented bounds |

## Actions and translation

| ID | Scenario | Mode | Expected contract |
| --- | --- | --- | --- |
| ACT-01 | Empty Actions query | automated | builds only the bounded 10-row landing set |
| ACT-02 | Query over large local stores | automated | query/search/result budgets remain enforced |
| ACT-03 | Pointer hover over Actions result | automated | hover is visual only; explicit selection is not replaced |
| TR-01 | Continuous typing | mixed | 320 ms debounce cancels intermediate translation requests |
| TR-02 | >20,000 character input | automated | input is clipped to documented maximum |
| TR-03 | Missing language pack | manual-macos | actionable failure/download route; no hanging session loop |
| TR-04 | RU↔EN and another supported pair | manual-macos | direction/pair normalization matches framework availability |

## Music and web player

| ID | Scenario | Mode | Expected contract |
| --- | --- | --- | --- |
| MUS-01 | Apple Music not running | mixed | clear empty state; no private media APIs |
| MUS-02 | Apple Music playing while pane active | mixed | 1 s metadata refresh + 0.25 s presentation ticker; no refresh overlap storm |
| MUS-03 | Apple Music pane folded | automated | fast native refresh/ticker stop |
| MUS-04 | Select web source without opening | automated | no `WKWebView` construction and no request |
| MUS-05 | Explicitly open each allowed web source | manual-service | only selected official HTTPS provider loads |
| MUS-06 | Web provider navigation failure | manual-service | bounded visible error and retry; no silent host expansion |
| MUS-07 | Artwork oversized / malformed | automated | bounded validation prevents unbounded decode |

## Appearance and accessibility

| ID | Scenario | Mode | Expected contract |
| --- | --- | --- | --- |
| UI-01 | Light appearance | manual-macos | semantic panel colors remain legible; intentional physical-notch black exception only |
| UI-02 | Dark appearance | manual-macos | same hierarchy/contrast without hard-coded white assumptions |
| UI-03 | Change appearance while app runs | manual-macos | surfaces update without restart |
| UI-04 | Reduce Motion enabled | mixed | transitions use reduced-motion contract rather than full animation |
| UI-05 | Keyboard handoff between displays/text modules | mixed | keyboard ownership follows active surface without stealing focus from another app |
| UI-06 | Menu Bar battery status in light/dark on Retina display | manual-macos | native battery glyph, percentage and charging bolt remain legible, aligned and semantically coloured in both appearances at Retina scale |
| UI-07 | Interface language chosen in Settings, confirmed restart | manual-macos | confirming the restart prompt quits and reopens Impuls by itself — no manual relaunch, no logout, no reboot — and the returning UI is in the chosen language with no pending-restart message. The old instance is fully gone before the new one starts: exactly one Impuls runs at any moment, the global shortcut works after the restart, and notes, clipboard history and shelf survive. The new process comes from the same bundle URL that was running. Impuls's own usage-description string is read from the chosen localization; returning to System Default restores macOS language selection, and a per-app language set from macOS itself survives a launch untouched. Cancelling keeps the language and leaves the restart offered. System-supplied permission-dialog chrome staying in the macOS language is not an Impuls defect; a missing or wrong-locale usage description is |

## Release and update

| ID | Scenario | Mode | Expected contract |
| --- | --- | --- | --- |
| REL-01 | Fresh ad-hoc build launch | manual-macos | bundle launches and explains any distribution limitation honestly |
| REL-02 | Signed appcast artifact | automated | Sparkle feed signature and verify-before-extraction contract remain enabled |
| REL-03 | Update checks disabled | automated | launch produces no unsolicited update request |
| REL-04 | User enables automatic checks | mixed | Sparkle uses 86,400 s scheduled interval and user-controlled policy |
| REL-05 | Upgrade preserving local data | manual-macos | settings/notes/snippets and optional encrypted history behave per migration contracts |
| REL-06 | Reinstall/update TCC behavior | manual-macos | permission behavior is recorded as platform/distribution reality, not assumed from unit tests |

## Evidence routes

Automated behavior lives primarily under [`Tests/ImpulsTests`](../../Tests/ImpulsTests) and [`Tests/PythonTests`](../../Tests/PythonTests).

Hardware/TCC/service/mixed rows are accounted for per version in [Release QA Evidence](release-evidence/README.md). The matrix remains the canonical contract inventory; do not add `passed` state here or infer certification merely because a scenario exists.

Starting with 1.4.12, the release evidence validator derives the complete manual/mixed ID set from this table. Adding or changing a non-automated row therefore creates a machine-checked evidence obligation for the current release candidate.
