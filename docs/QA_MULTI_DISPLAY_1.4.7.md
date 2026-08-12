# QA — Impuls 1.4.7 Multi-Display

What the automated suite cannot reach. `swift test -c release` covers the
topology model, the geometry and the settings migration from synthetic
descriptors; everything below needs real displays, a real pointer and a real
keyboard.

Status of every item at the time of writing: **not run**. Nothing here has been
verified on hardware — the implementation is complete and the automated suite is
green, and that is a different claim. Fill the Result column in as you go.

Legend: ✅ pass · ❌ fail · — not applicable to this hardware.

## Before starting

- [ ] `swift test -c release` — 331 tests, 0 failures
- [ ] `./Scripts/bundle.sh release`, then `open build/Impuls.app`
- [ ] Settings → General → Display Behavior is **All Displays**
- [ ] Settings → General → Panel Size is **Automatic**
- [ ] Activity Monitor open on the Impuls process, for the idle-CPU checks

---

## 1. MacBook only

| # | Step | Expected | Result |
| --- | --- | --- | --- |
| 1.1 | Move the pointer into the notch | Panel opens, flush with the camera housing | |
| 1.2 | Move the pointer away | Panel folds back into the cutout, no seam | |
| 1.3 | Press the global shortcut | Panel opens on Actions with the caret in the field | |
| 1.4 | ← / → , Esc | Modules change, Esc closes | |
| 1.5 | Compare the collapsed tab with 1.4.6 | Identical — the physical notch geometry is unchanged | |

## 2. MacBook + one external monitor

| # | Step | Expected | Result |
| --- | --- | --- | --- |
| 2.1 | Look at the top centre of the external monitor | A small black anchor is there, roughly 120 × 12 pt | |
| 2.2 | Click the menu bar left and right of the anchor | The menu bar responds normally; the anchor swallows nothing beside itself | |
| 2.3 | Hover the anchor on the external monitor | Panel opens **there**, with the same tab and the same data as on the MacBook | |
| 2.4 | Hover the notch on the MacBook | Panel opens there, and the external panel is folded | |
| 2.5 | With the panel open on the MacBook, hover the external anchor | Exactly one expanded panel at any moment; never two | |
| 2.6 | Put the pointer on the external monitor, press the shortcut | Panel opens on the external monitor — this is issue #34 | |
| 2.7 | Put the pointer on the MacBook, press the shortcut | Panel opens on the MacBook | |
| 2.8 | Sweep the pointer across the boundary along the top edge | No flicker, no panel handed back and forth | |
| 2.9 | Arrange the monitor left of the MacBook, repeat 2.3–2.7 | Identical behaviour with a negative display origin | |
| 2.10 | Arrange the monitor above, then below, repeat 2.3–2.7 | Identical behaviour | |
| 2.11 | Set the external monitor as the main display in System Settings | Impuls still works on both; the shortcut still follows the pointer | |

## 3. Keyboard ownership

| # | Step | Expected | Result |
| --- | --- | --- | --- |
| 3.1 | Open Translate on the MacBook, type a few words | Text appears, caret blinks | |
| 3.2 | Without closing it, summon Impuls on the external monitor | The MacBook panel folds and stops being key; typing goes to the new panel only | |
| 3.3 | Check the text | Still there — moving display does not throw away what was typed | |
| 3.4 | ⌘A, ⌘C, ⌘X, ⌘V, ⌘Z in the field on the external monitor | All work | |
| 3.5 | Esc | Closes the active panel | |
| 3.6 | ← / → on each display | Moves through modules on the active display only | |
| 3.7 | Click into another app | Panel drops the keyboard, keeps the text, folds | |
| 3.8 | Notes and Snippets on the external monitor | Focus lands in the editor on arrival | |

## 4. Drag and drop

| # | Step | Expected | Result |
| --- | --- | --- | --- |
| 4.1 | Drag a file onto the MacBook notch | Shelf opens there and accepts the drop | |
| 4.2 | Drag a file onto the external anchor | Shelf opens **on the external monitor** and accepts the drop | |
| 4.3 | Start a drag on one display, finish it on the other | One drop target at a time; the file lands once | |
| 4.4 | Check the shelf afterwards | Both files present, one shelf, no duplicates | |
| 4.5 | Drag a file out of the shelf on the external monitor | Drag source works as on the MacBook | |

## 5. Sidecar

| # | Step | Expected | Result |
| --- | --- | --- | --- |
| 5.1 | Connect an iPad as an **extended** display | An anchor appears on the iPad within a second, no restart | |
| 5.2 | Hover the anchor on the iPad | Panel opens on the iPad | |
| 5.3 | Move the pointer to the iPad, press the shortcut | Panel opens on the iPad | |
| 5.4 | Use Clipboard and Notes there | Same data as on the Mac — one set of stores | |
| 5.5 | Disconnect Sidecar with Impuls **closed** | Anchor disappears, everything else untouched | |
| 5.6 | Disconnect Sidecar with Impuls **open on the iPad** | Panel folds, no dangling window, no crash; Impuls still works on the Mac | |
| 5.7 | Reconnect Sidecar | Anchor comes back, hover and shortcut work again | |
| 5.8 | Repeat 5.1–5.7 over Wi-Fi and over cable | No difference — Impuls does not know which it is | |

## 6. Mirroring

| # | Step | Expected | Result |
| --- | --- | --- | --- |
| 6.1 | Turn on display mirroring | Exactly one Impuls anchor, not two stacked | |
| 6.2 | Open the panel while mirrored | One panel, no doubled shape, no shadow-on-shadow | |
| 6.3 | Settings → Display Behavior | The mirror set is listed once | |
| 6.4 | Switch back to Extended Desktop | Both displays get their own anchor again | |

## 7. Panel size

| # | Step | Expected | Result |
| --- | --- | --- | --- |
| 7.1 | Automatic on a MacBook | Standard — the size it has always been | |
| 7.2 | Automatic on a 27" monitor at default scaling | Large | |
| 7.3 | Automatic on a display scaled below 1280 pt wide | Compact | |
| 7.4 | Automatic with the MacBook and a large monitor at once | Each display shows its own size; moving between them re-sizes | |
| 7.5 | Force Large, then move to the smallest display available | Panel is clamped to that display, never clipped by its edge | |
| 7.6 | Set a very low logical resolution (System Settings → Displays → Larger Text) | Panel still whole and on screen | |
| 7.7 | Compact / Standard / Large chosen manually | Respected on every display, still clamped to fit | |

## 8. Hot-plug and topology

| # | Step | Expected | Result |
| --- | --- | --- | --- |
| 8.1 | Plug a monitor in while Impuls is closed | Anchor appears; no restart needed | |
| 8.2 | Plug one in while the panel is **open** | The open panel stays where it is and keeps its tab and text | |
| 8.3 | Unplug the monitor the panel is open on | Panel folds and Impuls remains usable on the display that is left | |
| 8.4 | Type in Notes, then plug and unplug twice | The note is intact; the shelf, clipboard and translation text too | |
| 8.5 | Rearrange displays in System Settings while running | Anchors follow their displays | |
| 8.6 | Change the main display while running | No restart; behaviour follows the new arrangement | |

## 9. Spaces and full screen

| # | Step | Expected | Result |
| --- | --- | --- | --- |
| 9.1 | MacBook on Space 1, external on Space 2 | Impuls appears on the right display for the right Space | |
| 9.2 | Switch Spaces with the panel open | Panel folds, nothing is lost | |
| 9.3 | Full-screen app on the external display | Anchor still reachable, panel opens above it | |
| 9.4 | Mission Control | Impuls does not appear as a cyclable window | |

## 10. Sleep and wake

| # | Step | Expected | Result |
| --- | --- | --- | --- |
| 10.1 | Let the displays sleep, wake them | Panel folded, hover works again | |
| 10.2 | Sleep the Mac, unplug the monitor, wake | No phantom anchor for the display that is gone | |
| 10.3 | Sleep the Mac, plug a monitor in, wake | The new display has an anchor | |
| 10.4 | Sleep with Sidecar connected, wake with it gone | No dangling window, no stuck pointer state | |

## 11. Performance

| # | Step | Expected | Result |
| --- | --- | --- | --- |
| 11.1 | Idle CPU with one display | Same as 1.4.6 | |
| 11.2 | Idle CPU with three displays | Effectively unchanged — one pointer sampler, not three | |
| 11.3 | `sample Impuls` while idle with three displays | One timer thread driving the pointer; no per-display timers | |
| 11.4 | Copy something with three displays connected | One clipboard entry, not three | |
| 11.5 | Watch the battery reading with three displays | One reading, updating on one schedule | |
| 11.6 | Connect and disconnect a display twenty times | Memory returns to its baseline; no growth per cycle | |

## 12. Regression — everything that already worked

Run each module once on the MacBook and once on an external display.

| # | Module | Expected | Result |
| --- | --- | --- | --- |
| 12.1 | Actions | Search, ↑ ↓, Enter, footer commands | |
| 12.2 | Music | Artwork, transport, scrubber, source name | |
| 12.3 | Shelf | Files, drag out, tools | |
| 12.4 | Clipboard | History, pin, delete | |
| 12.5 | Snippets | Add, edit, delete | |
| 12.6 | Calendar | Next event, countdown, meeting link | |
| 12.7 | Translate | Typing, language pickers, result | |
| 12.8 | Notes | Create, edit, autosave, sweep on leave | |
| 12.9 | **Power / Battery (1.4.6)** | Mac reading, external devices when enabled, low-battery alert opens the Power pane on the display the pointer is on | |
| 12.10 | Settings | Every pane, export and import | |
| 12.11 | Feedback | Opens a prefilled GitHub issue | |
| 12.12 | Updater | Check for updates still opt-in and working | |
| 12.13 | Context menus | Right-click in a list holds the panel open until the menu closes | |
| 12.14 | Menu-bar utilities (Ice and similar) | Clicking the header strip still reaches them | |
| 12.15 | VoiceOver | Rail, rows and fields announced as in 1.4.6, on both displays | |
