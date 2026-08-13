# Impuls 1.4.7 — Multi-Display

Working document for the multi-display work that closes issue #34,
"приложение не работает на подключенных экранах". Read this before touching
anything under `Sources/Impuls/Notch`.

Base: `origin/main` at `bc05652`, which is Impuls 1.4.6 released — the Apple
Device Battery Center, its low-battery alerts and `openPower()` are all in the
base and none of it is rewritten here. `Scripts/version` moves to `1.4.7` in
this branch, with `docs/releases/1.4.7.md` beside it.

---

## 1. Why issue #34 happens

Impuls has exactly one panel, on exactly one display, chosen once at launch.

`NotchGeometry.current(preferredDisplayID:)` resolves a single `NSScreen`:

```
preferred (Settings → Display)
  ?? NSScreen.screens.first { $0.safeAreaInsets.top > 0 }   // the notched one
  ?? NSScreen.main
  ?? NSScreen.screens[0]
```

`NotchController.build()` then creates one `NotchPanel`, one `NotchRootView`,
one `NotchViewModel` and one `PointerWatcher` for that screen and nothing else.

Three consequences, all of them what the reporter sees:

1. **On a MacBook with an external monitor the notch display always wins.** The
   second clause of that chain matches the built-in screen before `NSScreen.main`
   is ever consulted, so the panel is on the laptop whatever the user is
   actually working on. On the external display Impuls does not exist: no
   collapsed tab, no hover target, no window.
2. **The global shortcut has no display awareness at all.**
   `toggleFromKeyboard()` opens *the* panel — the one built at launch. Pressing
   ⌥Space while working on a 32" monitor pops the panel open on the laptop
   screen behind it.
3. **The Settings escape hatch is a swap, not a fix.** Choosing a specific
   display moves the single panel there and takes it off the MacBook. There has
   never been a "wherever I am" option; the existing `Automatic` label means
   "the notch display", which is the misleading UX the brief calls out.

Two further defects fall out of the same design and are fixed here:

- `screenParametersChanged()` → `rebuild()` tears down the whole
  `NotchViewModel` on any topology change, which destroys and re-creates
  `ClipboardStore`, `MediaController`, `PowerMonitor`, `DevicePowerCenter`,
  `CalendarStore` and every timer they own. Plugging a monitor in restarts the
  clipboard watcher and the whole 1.4.6 device layer.
- `PointerWatcher` holds one `openRect` / `closeRect` / `warmZone`. Its warm
  band is derived from one screen, so on a two-display setup the sampler is
  cold everywhere except along the top of the chosen display.

## 2. What has to change

| File | Change |
| --- | --- |
| `Notch/NotchGeometry.swift` | Stops resolving an `NSScreen` itself. Built from a `DisplayDescriptor`, clamps the panel to the display it is on. |
| `Notch/PointerWatcher.swift` | One sampler, many zones. Routes by display and reports which display the pointer entered. |
| `Notch/NotchController.swift` | Keeps open/close, keyboard, menu tracking, sleep/wake. Loses panel construction and single-screen geometry; drives the coordinator instead. |
| `Model/NotchViewModel.swift` | Loses `geometry` entirely. Becomes shared state and shared services, nothing per-display. |
| `UI/NotchContentView.swift` | Reads geometry and "is this surface the active one" from a per-display `NotchSurfaceState` instead of the view model. |
| `Settings/SettingsStore.swift` | `PanelSize.automatic`; `selectedDisplayID == nil` now means *all displays*; display list comes from the shared display source. |
| `Settings/SettingsWindow.swift` | Display picker becomes "Display behavior"; panel size gains Automatic. |

New files:

| File | Responsibility |
| --- | --- |
| `Notch/DisplayTopology.swift` | Pure model: `DisplayDescriptor`, `DisplayPreference`, mirror de-duplication, active-display choice, adaptive panel size. No AppKit calls, fully unit-testable from synthetic descriptors. |
| `Notch/ScreenDisplaySource.swift` | The only place that reads `NSScreen` and `CGDisplayMirrorsDisplay` and turns them into descriptors. |
| `Notch/NotchDisplaySurface.swift` | One display's presentation: panel, root view, hosting view, geometry, `isActive`. Owns no service. |
| `Notch/DisplayCoordinator.swift` | Reconciles a fresh topology against the live surfaces, tracks the active display, moves activation. |

## 3. What is left alone

`NotchPanel` (collection behaviour, key handling, ⌘-key dispatch), `NotchShape`,
`NotchRootView` (drag destination, cursor tracking, hit testing), `Theme`, every
`*Pane.swift`, `PanelMenuTrackingState`, `GlobalHotKey`, and the entire
`Services` directory — including all of 1.4.6: `PowerMonitor`,
`DevicePowerCenter`, `LocalMacDeviceProvider`, `MobileDeviceBatteryProvider`,
`SystemProfilerAccessorySource`, `LowBatteryAlertEngine`. The power path is not
touched. `.power` stays the module identifier; `settings.v1` keeps decoding.

## 4. The architecture chosen

**One shared application, many presentation surfaces, one expanded panel.**

```
AppDelegate
└── NotchController                     shared, one instance
    ├── NotchViewModel                  shared services + shared panel state
    │   └── ClipboardStore, MediaController, ShelfStore, CalendarStore,
    │       Translator, SnippetStore, NoteStore, PowerMonitor,
    │       DevicePowerCenter, ImpulsActionsStore, FileToolsCoordinator
    ├── PointerWatcher                  ONE sampler, N zones
    └── DisplayCoordinator
        ├── NotchDisplaySurface(A)      panel + root view + geometry + isActive
        ├── NotchDisplaySurface(B)
        └── NotchDisplaySurface(C)
```

A surface is deliberately cheap: an `NSPanel`, an `NSView`, an `NSHostingView`
and a `NotchSurfaceState` with two published properties. It holds no store, no
timer and no monitor. Exactly one surface has `isActive == true`; the shared
`vm.isOpen` only expands *that* one, because `NotchContentView` reads
`surface.isActive && vm.isOpen`. Two expanded panels are therefore not a bug
that has to be avoided by discipline — they are not representable.

Each display keeps its own surface rather than one panel being moved between
displays, because a borderless non-activating panel that changes screens also
changes backing scale and space membership mid-flight, and because the collapsed
anchor has to be present on every allowed display at once for hover to have
anything to hit. Activation is a state flip, not a window rebuild, so switching
displays does not remount the SwiftUI hierarchy and does not lose the tab,
the typed text or the selection.

## 5. How duplicate services are avoided

`NotchViewModel` no longer takes a `NotchGeometry`; it is constructed once in
`NotchController.install()` and never rebuilt. There is no code path left that
constructs a second one — `rebuild()` is gone, replaced by
`DisplayCoordinator.reconcile(geometries:)`, which only adds, updates and
removes surfaces.

The single `PointerWatcher` keeps one timer for the whole app. Adding a third
monitor adds a `PointerZone` (four rects) to an array, not a 60 Hz timer.

A test asserts the invariant structurally rather than by inspection: the view
model is not constructible from a display and the coordinator has no reference
to it.

## 6. Sidecar

Nothing Sidecar-specific exists in the code, on purpose. An iPad in Extended
Desktop mode is an `NSScreen` with a display ID, a frame, a backing scale and
no safe-area inset — that is all `ScreenDisplaySource` asks for, and it is all
that matters. Impuls neither knows nor cares whether the display is wired,
wireless or an iPad.

Disconnecting Sidecar arrives as
`NSApplication.didChangeScreenParametersNotification`, the same as unplugging
HDMI. Reconciliation removes the surface, tears its panel down
(`acceptsKeyboard = false`, `orderOut`, `contentView = nil`), drops its pointer
zone, and — if it was the active display — closes the panel and moves activation
to the pointer's display, then `NSScreen.main`, then the primary display.
Reconnecting adds a surface back. No restart, no dangling window, no orphaned
timer: the only timer belongs to the controller and it never belonged to a
display.

## 7. Mirroring

`ScreenDisplaySource` reads `CGDisplayMirrorsDisplay(id)` — public
CoreGraphics, no private API. A display whose mirror source is another display
in the same set is a secondary mirror and is dropped from the topology, so a
mirror set contributes exactly one surface. As a second guard, two descriptors
with an identical frame collapse to one (macOS never lays two extended displays
on the same rectangle), which also covers software-mirroring reports where the
mirror source is not populated. Extended Desktop is unaffected: different
frames, different displays, one surface each.

## 8. Adaptive panel size

`PanelSize.automatic` is a fourth case beside the three presets, not a scaling
factor. Scaling the SwiftUI hierarchy by pixel count would break every metric in
`Theme.swift`; picking a proven preset does not.

Everything is decided in **logical points**. Retina and backing scale are never
read for layout.

The small threshold is 1400 pt, not 1280. A 1280 × 800 panel is the smallest
display a Mac has shipped with and 1366 pt is the cheapest external anybody
plugs in; classifying either as "not small" and giving it the middle preset
contradicted the rule the function exists to express — Standard would have
taken 45% of a 1366 pt width against Compact's 41%. 1400 leaves every Retina
MacBook (1440 through 1728) exactly where it was.

```
usable width = display.frame.width
  < 1400 pt → Compact    (560 × 208)   -- 1024, 1180 Sidecar, 1280, 1366
  < 1800 pt → Standard   (620 × 208)   -- every built-in MacBook lands here
  ≥ 1800 pt → Large      (700 × 232)
```

The chosen preset is then **clamped to the display it will actually appear on**,
in `NotchGeometry`, for the manual presets too. Two rules:

**Content fits; decoration may overhang.** The window is the panel plus 40 pt of
shoulder slack each side and 44 pt below. That slack is transparent — no text,
no control, no hit target — so it is not part of what has to be on screen. An
earlier draft measured against `display.frame` minus the padding and shrank the
panel on displays that could have shown all of it, to keep a shadow nobody would
have missed.

**Never below the smallest designed layout.** The floor is Compact, and that is
not a round number: at the 32 pt camera housing of a notched MacBook, Compact's
208 pt is exactly `RailMetrics.comfortablePanelHeight` — the height at which the
fullest rail, five icons of nine modules split 5/4, still gets its designed
28 pt buttons.

The first draft floored at 320 × 120 on the theory that a clipped panel beats
one hanging off the screen. That was wrong twice over. 120 pt clips the rail on
every Mac, and the floor is not somewhere ordinary hardware goes — every mode
the suite checks, from 640 × 480 up, holds Compact without clamping. No promise
is made about virtual, remote or future displays beyond the behaviour itself:
below Compact the layout stops shrinking, the panel is centred, and the shadow
rather than the content is what leaves the screen.
`NotchGeometryTests` now asserts the whole chain — that Compact is exactly the
rail's comfortable height, that a taller header shrinks the rail towards
`railButtonMin` rather than clipping it (and keeps fitting up to a 72 pt
header), and that the floor is unreachable at 640 × 480, 800 × 600, 1024 × 768
and 1280 × 800. The arithmetic lives in `RailMetrics`, shared with
`NotchContentView`, so the minimum is derived from the layout rather than
asserted about it.

`windowFrame` is finally clamped horizontally into the display frame when the
window fits, and centred when it does not, so a panel wider than its display
overhangs evenly instead of hanging off one side.

Nothing assumes `minX == 0`, `minY == 0`, equal heights, equal scaling, or that
the built-in display is on the left. Every rect is computed from that display's
own frame.

## 9. The synthetic anchor, reviewed rather than assumed

120 × 12 pt, with a 140 × 18 pt hover target. Kept after review, for reasons
that should be written down rather than rediscovered:

- **It is not a click target first.** The panel opens on hover, and the hover
  rect sits against the top edge of the display. Throwing the pointer at the
  top of a screen is a gesture that cannot overshoot — the pointer stops at the
  edge — so the only dimension the user has to aim in is horizontal, where
  there are 140 pt. Height buys much less here than it would for a control in
  the middle of a window, and every point of height is taken from the user's
  menu bar.
- **12 pt against a ~24 pt menu bar** leaves the menu bar readable either side
  and never covers a menu title: the top centre of an external display is empty
  on macOS, with app menus to the left and status items to the right.
- **120 pt is deliberately not 180 pt.** A physical notch is ~180 pt wide, and
  matching it would be drawing a fake MacBook cutout on a monitor that has
  none. Against the 560–700 pt panel it expands into, 120 pt reads as a tab
  belonging to something larger rather than as a lid.
- **It scales by staying still.** Points, not pixels, so the anchor is the same
  physical size on a Retina 27" and a non-Retina 24". On a 1180 pt Sidecar iPad
  it is proportionally larger, which is right — the iPad is closer to the user.
- **The silhouette is the brand.** `NotchShape` draws the same concave
  shoulders at 6/9 pt collapsed as at 12/22 pt open, so the anchor is a small
  Impuls rather than a black rectangle, and the open animation is the same
  radius morph on every display.

What review could not settle without hardware: whether 12 pt *feels* thin in
the hand, and whether the anchor is discoverable on a large monitor by someone
who has never seen Impuls. Both are in `QA_MULTI_DISPLAY_1.4.7.md` (2.1, 2.2).

**Accessibility.** The anchor carries no VoiceOver label — neither does the
physical notch, so this is not a regression, but on an external display the
anchor is the primary affordance where previously there was nothing at all.
The accessible route is the global shortcut, which opens on the display under
the pointer and falls back to the display macOS reports as active — the right
answer for someone navigating by keyboard. The expanded panel's accessibility
is untouched from 1.4.6 and is identical on every display.

## 10. How it is tested without hardware

Three seams, all with live defaults:

- `DisplayDescriptor` — the display model is a value, so any arrangement is
  three lines in a test. `ScreenDisplaySource` is the only code that reads
  `NSScreen` or CoreGraphics.
- `NotchSurfacing` — the controller and coordinator talk to a protocol, not to
  an `NSPanel`. The suite substitutes a surface with no window in it and can
  then drive a drop on the second monitor or a press on the third.
- `NotchEnvironment` — the display list, the pointer position, the main display
  and the surface factory are injected. `NotchEnvironment.live` is the real
  thing and `AppDelegate` passes it.

`SettingsStore` gained a `displaySource` for the same reason, and its `defaults`
became internal so `ShelfStore` writes where the settings write. That last one
is not cosmetic: while writing these tests a drop test persisted a card into the
real shelf and a notes test wrote into the developer's own `notes.json`. A test
must not be able to reach a user's data, and now the shelf cannot.

---

## Manual QA checklist

See `QA_MULTI_DISPLAY_1.4.7.md`.
