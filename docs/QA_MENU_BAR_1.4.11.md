# Impuls 1.4.11 — Manual acceptance

Automated tests cover the resolver, persistence, backups, localisation and
telemetry consent policy. The visual and assistive-technology checks below
need a person on a Mac; no test result is a substitute for them.

## Fresh installation

1. Launch with an empty `UserDefaults` suite / fresh macOS account.
2. Confirm the seven screens appear in order: Welcome, real features, Menu
   Bar preset and sample preview, Quick Actions, permissions explanation,
   voluntary version statistics, then the personalization summary.
3. On the statistics screen, confirm both choices have equal visual weight;
   **Not now** leaves the Settings choice unknown. Do not use a production
   collector to test this unreleased build.
4. Choose zero, one and four actions in turn; check add/remove and up/down
   ordering. Skip the tour and close it at different screens; the panel must
   remain usable and the full tour must not return automatically.

## Upgrade and persistence

1. Start from a 1.4.10 settings snapshot. Confirm only the concise What's New
   window appears once, never the full tour.
2. With version statistics allowed or denied beforehand, confirm What's New
   does not offer it again. With an unknown choice, confirm the offer appears
   once and **Not now** does not create a launch-time loop.
3. Open **Settings → Menu Bar → Show Impuls Tour** and confirm it intentionally
   reopens the complete tour.
4. Restart after choosing a preset, status mode, widgets and action order;
   export/import Settings and verify generic choices return. A selected device
   is intentionally local to this Mac and must not transfer in the backup.

## Menu Bar and Settings

1. Check Minimal, Batteries, Music, Work and Smart presets, then make one
   manual change and confirm the configuration says Custom.
2. Exercise each status mode with a Mac battery, selected device, lowest
   battery, player and no available data. Missing/stale selected devices must
   fall back to current Mac data, then the Impuls logo — never an invented 0%.
3. Check Primary and Secondary Widgets, including None and Quick Actions.
   The same resolved content must not be presented twice.
4. With a real current player, check track/artist display and transport
   controls. With no player, no player controls should appear.
5. Confirm the fixed footer is exactly Open Panel, Settings, Check for Updates,
   Send Feedback and Quit. Persistent preferences and screenshot maintenance
   must not be permanent footer/menu rows; screenshot folder actions are
   optional Quick Actions.
6. Compare the live sample preview (MacBook 72%, AirPods 58%, Magic Mouse 14%,
   sample player) in light and dark appearance. It must not change real state,
   start a provider, start playback or make a request.

## Accessibility and sizing

1. At a 1440-pixel MacBook width and a smaller settings window, check that RU
   and EN text wraps without clipping.
2. Navigate onboarding, Settings and the NSMenu using the keyboard. With
   VoiceOver, verify controls have meaningful names and low battery is conveyed
   by text/icon as well as any colour.
3. Turn on Reduce Motion and repeat screen changes. There must be no required
   motion or lost focus.

## Performance and privacy observation

1. Open/close the status menu at least 50 times while idle; watch Activity
   Monitor for persistent CPU/memory growth.
2. With external-device discovery disabled and telemetry consent unknown,
   launch the app and confirm no new device scan or telemetry request occurs.
3. Enable only already-supported external-device discovery if testing hardware.
   Unsupported or stale accessories must remain absent rather than guessed.
