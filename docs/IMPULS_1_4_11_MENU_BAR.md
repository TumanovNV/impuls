# Impuls 1.4.11 — Onboarding and Menu Bar workspace

## Boundaries

The Menu Bar is a presentation client, not a service owner. It subscribes to
existing `PowerMonitor`, `DevicePowerCenter`, and `MediaController` publishers;
it creates no timer, hardware provider, WebKit view, permission request, or
network request. The three established network owners stay unchanged.

`MenuBarWorkspaceConfiguration` is the exportable part of Settings. Its chosen
device key is intentionally not present: local device keys are HMAC-derived from
this Mac's Keychain secret, and a backup cannot identify the same device on a
different Mac. The local selection accepts only a bounded lower-case hex key and
falls back to Mac battery, then the Impuls logo when absent or stale.

`AppFeatureCatalog` is the single list used by the onboarding cards and
available quick actions. It contains only destinations and maintenance actions
that already exist in Impuls. `MenuBarWidgetRegistry` supplies compact widget
content from an immutable state snapshot, so a future module can register a
widget without adding module-specific control flow to the AppKit controller.
The current registry includes battery, selected-device, lowest-battery, player
and automatic providers, plus explicit None and Quick Actions presentation
choices.

## Resolver policy

`MenuBarWorkspaceResolver` receives already sanitised display labels, optional
percentages, honest charging states and selected-player metadata. It never sees
raw device identifiers. The Smart resolver checks the configured priority order:

1. a real percentage at or below the user-selected low-battery threshold;
2. an actively playing selected player;
3. a current charging or charged battery;
4. neutral current content, then the logo.

The selected-device mode uses the same safe fallback. External devices must be
visible, connected and fresh. A missing percentage is no value, not `0%`.

## Onboarding lifecycle

A fresh installation without a Settings snapshot receives the seven-step tour.
An existing installation never receives the tour because it updated; it gets at
most one concise What’s New note per application version. The full tour is
available manually from Settings → Menu Bar.

The telemetry page makes no request. Allowing version statistics writes the
existing explicit-consent state; Not now preserves `.unknown` and records only
that the offer was shown. A local acceptance build without a configured endpoint
keeps the control unavailable and cannot send a heartbeat.

For an upgrade, What's New shows the same optional offer only once when the
existing consent is `.unknown`; it never asks an already allowed or denied user
again. The version-statistics payload is unchanged: it does not include the
Menu Bar configuration, a battery/device/player value, a quick action, or an
onboarding choice.
