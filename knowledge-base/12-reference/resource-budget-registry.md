---
title: Input & Resource Budget Registry
type: reference
status: active
documentation_version: 1.4
app_version: 1.4.15
last_reviewed: 2026-08-24
tags: [impuls, performance, limits, budgets, security, ai]
---

# Input & Resource Budget Registry

This document centralizes the limits that keep Impuls responsive and resistant to accidental or hostile oversized input. Exact constants remain in code; this registry is the review surface that explains which budgets are architectural rather than incidental.

## Content and storage budgets

| Area | Budget | Current value | Owner / source |
| --- | --- | ---: | --- |
| Actions | query length | 256 chars | `ImpulsActionsStore.maximumQueryCharacters` |
| Actions | searchable material per result | 16,384 chars | `ImpulsActionsStore.maximumSearchCharacters` |
| Actions | matched results | 30 | final result prefix |
| Actions | empty-query landing rows | 10 | 4 clipboard + 3 snippets + 3 notes |
| Clipboard | text payload | 512 KiB UTF-8 | `ClipboardStore.maximumTextBytes` |
| Clipboard | image payload | 64 MiB | `ClipboardStore.maximumImageBytes` |
| Clipboard | in-memory history | 100 items | `ClipboardStore.limit` |
| Clipboard persistence | encrypted archive | 64 MiB | `ClipboardHistoryPersistence.maximumArchiveBytes` |
| Notes | file | 10 MiB | `NoteStore.maximumFileBytes` |
| Notes | items | 5,000 | `NoteStore.maximumItems` |
| Snippets | file | 10 MiB | `SnippetStore.maximumFileBytes` |
| Snippets | items | 5,000 | `SnippetStore.maximumItems` |
| Snippets | query | 256 chars | `SnippetStore.maximumQueryCharacters` |
| Snippets | searchable text per field | 16,384 chars | `SnippetStore.maximumSearchCharacters` |
| Backup | encoded/import file | 10 MiB | `ImpulsBackupDocument.maximumEncodedBytes` |
| Backup | notes / snippets | 5,000 each | backup decoder guard |
| Calendar | fetched meetings | 250 | `CalendarStore.maximumMeetings` |
| Calendar | fetch horizon | 7 days | `CalendarStore.horizon` |
| Calendar | meeting-link text scan | 32,768 chars | `MeetingLink.maximumScannedCharacters` |
| Calendar | displayed event title | 240 chars | bounded title conversion |
| Translate | input | 20,000 chars | `Translator.maximumInputCharacters` |
| Apple Music | artwork bytes | 16 MiB | `PlayerBridge.maximumArtworkBytes` |
| Apple Music | normalized artwork target | 512 px | `PlayerBridge.artworkPixelSize` |
| Screenshot vault | concurrent pending saves | 2 | `ScreenshotVault.maximumPendingSaves` |
| Telemetry | response body | 1 KiB | `VersionTelemetryService.maximumResponseBytes` |
| Telemetry | version string | 32 chars | `VersionTelemetryService.validVersion` |
| Shelf | cards | 60 | `ShelfStore.limit`; restore completion clamps before icon/thumbnail fan-out |
| Shelf | inline pasteboard payload | 64 MiB | `ShelfStore.maximumInlinePasteboardBytes` |
| File tools | decoded image | 64,000,000 px | `FileToolsService.maximumDecodedImagePixels`; pixel bound, not file-byte bound |
| File tools | digest read | 512 MiB | `GeneratedFileRecord` streaming SHA-256 cap |
| File tools / vault | collision-suffix attempts | 1,000 | `uniqueOutputURL`, `ScreenshotVault`; then UUID fallback |
| Accessories | `system_profiler` stdout | 1 MiB | `SystemProfilerAccessorySource.maximumOutputBytes`; truncation is error |
| Accessories | `system_profiler` stderr | 8 KiB | `SystemProfilerAccessorySource.maximumErrorBytes` |
| Accessories | `system_profiler` deadline | 5 s | terminate, then `SIGKILL` after grace |
| Device transport | usbmuxd/lockdown frame | 512 KiB | `MobileDeviceTransport.maximumPayloadBytes` |
| Device transport | socket read/write deadline | 5 s | `SO_RCVTIMEO` / `SO_SNDTIMEO` |
| Device transport | TLS handshake | 10 s, 256 iterations | `LockdownTLSChannel` |
| Device transport | public key compared | 8 KiB | `LockdownPairRecord.maximumPublicKeyBytes` |
| Settings | remembered Apple devices | 100 | `SettingsStore.maximumRememberedAppleDevices` |
| Device log | message | 200 chars | `DevicePowerLog.maximumMessageCharacters`; off unless `IMPULS_DEVICE_LOG=1` |
| Web music | reported string fields | 512 / 2,048 chars | `WebMusicState.decode` |
| Web music | artwork transferred from page | 6 MiB base64 → 16 MiB decoded | `WebMusicPlayer`, then `PlayerBridge.maximumArtworkBytes` |
| Web music | page diagnostic line | 512 chars | forwarded to `NSLog`; page-controlled text |
| Feedback | summary / details / prefilled URL | 120 / 4,000 / 7,000 chars | `FeedbackService`; over-long body is copied instead of prefilled |

## Cadence and wake-up budgets

| Work | Current cadence / cap | Notes |
| --- | --- | --- |
| Pointer sampling | warm 60 Hz / idle 8 Hz | one sampler for all displays; stationary pointer cools after 3 s |
| Clipboard `changeCount` | 0.5 s, tolerance 0.2 s | payload is not materialized unless counter moves |
| Playback position | 0.25 s, tolerance 0.05 s | visible + playing only |
| Native Apple Music state | 1 s, tolerance 0.15 s | visible Apple Music pane only |
| Calendar countdown | 30 s, tolerance 5 s | visible pane only |
| Local Mac power | 2 s, tolerance 0.5 s | visible Power pane only |
| Apple accessory provider | 10 s active / 600 s idle | IOKit events may trigger immediate reads |
| Mobile device provider | 60 s active / 900 s idle | topology events are separate from battery polling |
| Device failure backoff | max 600 s | exponential, reset after success |
| Translation debounce | 320 ms | pending task cancels on new input |
| Notes save debounce | 800 ms | disk work on utility queue |
| Snippets save | no debounce | utility queue on each deliberate change; synchronous shutdown flush |
| Clipboard archive save | 750 ms | encryption/disk work on utility queue |
| Clipboard image conversion | one in flight | serial queue; stale pasteboard generation result discarded |
| Actions corpus fold | once per source change | not per keystroke |
| Menu bar rebuild | once per shown-state change | gated on fingerprint excluding playback position |
| Web music bridge push | 1 s, DOM observer debounced 400 ms | stopped by `WebMusicPlayer.teardown()` |
| Device topology reconnect | 1 s doubling to 60 s | unbounded attempts, bounded interval |
| Low-battery background override | 60 s low / 300 s otherwise | only while alerts enabled |
| Rail hover dwell | 150 ms | hover is affordance, not selection |
| Version telemetry attempt | max one attempt per `(app version, 1 h)` | timestamp/version recorded before request; different version gets immediate attempt; 10 s timeout |
| Version telemetry proposal | every 1 h, tolerance 15 min | scheduler proposes only; service throttle remains authoritative |
| Sparkle scheduled check | 86,400 s | only after user enables automatic checks |
| Project-support prompt appearances | max 2 for lifetime of local state | hard ceiling; second decline/close is `dismissedForever`; GitHub/feedback choice ends automatic prompting |
| Project-support prompt earliest appearance | 30 calendar days **and** 10 active days **and** 20 meaningful uses | all three thresholds must hold; clock starts at first counted deliberate use |
| Project-support prompt snooze | 60 days **and** at least one meaningful use after prompt | elapsed time alone does not reopen the question |
| Meaningful-use coalescing window | 60 s | anchored to last counted use; prevents click bursts from becoming separate episodes |
| Project-support prompt minimum uptime | 120 s | prompt is never part of launch experience |
| Project-support prompt quiet delay | one `+8 s` one-shot per eligible quiet transition | never a timer; cancelled when work resumes or app terminates |
| Self-relaunch PID wait | max 100 probes × 0.1 s (≈10 s) | `AppRelaunchService.pollLimit` / `pollInterval`; timeout exits without launching a second instance |
| Self-relaunch teardown settle | 0.2 s once old PID disappears | one-shot helper margin before `open` of exact current bundle; not repeated and not a background agent |

## Relaunch budget rationale

The relaunch helper is an application-lifecycle safety mechanism, not a service cadence to tune for responsiveness. Its upper bound prevents a failed termination from creating an unbounded helper process. The timeout is deliberately **fail-closed**: after approximately ten seconds the helper exits without opening anything, because a missed relaunch is safer than two Impuls instances writing the same local stores or contending for the global hotkey.

Changing `pollLimit`, `pollInterval`, the `0.2 s` settle delay or the fail-closed timeout behavior requires review of [Localization](../04-development/localization.md), [Background Work & Concurrency Registry](background-concurrency-registry.md), `AppRelaunchServiceTests` and this registry in the same change set.

## Budget change rules

A higher limit is not automatically an improvement. Before raising a budget, answer:

1. What user scenario requires it?
2. What is the worst-case allocation / CPU / disk / UI cost?
3. Can the operation become streaming, lazy, paginated or chunked instead?
4. Is the input attacker-controlled, user-controlled or local trusted state?
5. Does the new value require a migration or change backup/privacy behavior?
6. What automated or manual test protects the new boundary?

Prefer **streaming, lazy evaluation, bounded previews and backpressure** before making a limit unbounded.

## Relationship to security

These limits are both performance and security controls. A file-size cap, bounded Web/telemetry response, bounded image decode, capped search surface and bounded process/helper lifetime prevent a convenience utility from allocating arbitrary resources or leaving unintended background work behind.

See also [Threat Model](../06-security/threat-model.md), [Data Classification](../06-security/data-classification.md), [Background Work & Concurrency Registry](background-concurrency-registry.md) and [Schema & Migration Registry](schema-migration-registry.md).
