---
paths:
  - "Sources/Impuls/UI/**"
  - "Sources/Impuls/Notch/**"
  - "Sources/Impuls/Model/**"
---

# Panel UI

Read `Sources/Impuls/UI/Theme.swift` first. Sizes, radii, colours and animation
curves are defined there; a value invented at the call site is how the panel stops
looking like part of macOS.

## Colours are semantic, never literal

`Theme` wraps AppKit's semantic colours — `labelColor`, `secondaryLabelColor`,
`tertiaryLabelColor`, `quaternaryLabelColor`, `separatorColor`,
`windowBackgroundColor`. The expanded panel adopts the user's appearance, so light
mode has to work without a second code path.

CI rejects `darkAqua`, `Color.white` and `foregroundStyle(.white)` anywhere in these
directories. The collapsed tab is the single exception: it is filled with
`Color.black` on purpose, so it disappears into the physical cutout.

## Geometry

- Expanded panel: `620 × 208` pt by default, from `NotchGeometry.expandedSize`;
  Settings offers three presets.
- `NotchShape` draws concave shoulders, so the frame is `topRadius` wider than the
  body on each side. Radii: 12 pt top and 22 pt bottom when open, 6 and 9 when closed.
- Displays without a cutout get a 96 × 10 pt tab with a 120 × 16 pt hover target.
- The header leaves a gap the width of the notch in the centre. Nothing interactive
  goes in that row — menu-bar utilities watch for clicks there with a global monitor.

## The rail

`NotchViewModel.leftRailTabs` takes the first half of the enabled modules and
`rightRailTabs` the rest, the left rail keeping the extra one when the count is
odd. Nine modules therefore split 5/4, not 6/3.

Icons are SF Symbols from `Tab.symbol`, 12 pt inside a button 30 pt wide with a
`Theme.Radius.small` corner. The height is **not** a constant:
`NotchContentView.railButtonHeight` fits it to the panel, measuring both rails
against the longer of the two so the two sides always agree, reserving
`Theme.Space.xs` at each end and clamping to `Theme.Size.railButtonMin` /
`railButtonMax`. Do not put a fixed height back — a fixed 24 pt is what pushed
the sixth icon out of the standard preset.

Hover switches tabs only after a 150 ms dwell, so a pointer crossing on its way
elsewhere does not change the module.

## Panes

One `*Pane.swift` per module. A pane observes its own store directly rather than
reading through the view model, because the view model deliberately does not forward
keystroke-driven stores — a redraw per letter rebuilds the text field and drops focus.

Typical metrics: search rows 26 pt tall at 11 pt type, result rows 26 pt (32 with a
subtitle), footer command buttons 22 pt at 9.5 pt, corner radius 7 pt for rows and
6 pt for buttons. Match the neighbouring pane instead of picking new numbers.

## Selection and hover

Hover is a visual affordance. In `ActionsPane.swift` selection must not follow the
pointer — CI fails on `if $0 { select() }`. Keep `.onHover { hovering = $0 }`,
`.onTapGesture(perform: select)` and the double-tap gesture as they are.

## Focus

Panes with a text field own the keyboard through `wantsKeyboard`. Request focus from
`onAppear` of the view that actually holds the field: a focus request aimed at a view
not yet in the hierarchy is dropped, and the row appears with no caret. Never remount
an editor per selection (`.id(selected)`) — SwiftUI's focus cleanup races every way
of re-requesting it.
