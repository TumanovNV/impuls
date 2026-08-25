---
title: Input & Resource Budget Registry
type: reference
status: active
documentation_version: 1.8
app_version: 1.4.16
last_reviewed: 2026-08-25
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
| Backup | encoded/import file | 10 MiB | `ImpulsBackupDocument.maximumEncodedBytes`. **1.4.16:** unchanged as a number, but its scope is now stated: a byte budget bounds how *much* is read, never how *long* a read waits, and it is consulted only after a read returns. `BoundedFileReader` therefore also refuses anything that is not a regular file, so a FIFO, device or socket cannot wait on a peer that never arrives. Slow *regular* files remain bounded only by the filesystem — see the `BackupService` row in the background/concurrency registry |
| Backup | notes / snippets | 5,000 each | backup decoder guard |
| Calendar | fetched meetings | 250 | `CalendarStore.maximumMeetings` |
| Calendar | fetch horizon | 7 days | `CalendarStore.horizon` |
| Calendar | meeting-link text scan | 32,768 chars | `MeetingLink.maximumScannedCharacters` |
| Calendar | displayed event title | 240 chars | bounded title conversion |
| Translate | input | 20,000 chars | `Translator.maximumInputCharacters`; reviewed for 1.4.16 (#99) language-pack reliability audit — unchanged, no new size/count/cadence/timeout budget introduced (readiness re-scans stay lifecycle-driven, not a new interval) |
| Apple Music | artwork bytes | 16 MiB | `PlayerBridge.maximumArtworkBytes` |
| Apple Music | normalized artwork target | 512 px | `PlayerBridge.artworkPixelSize` |
| Screenshot vault | concurrent pending saves | 2 | `ScreenshotVault.maximumPendingSaves` |
| Telemetry | response body | 1 KiB | `VersionTelemetryService.maximumResponseBytes` |
| Telemetry | version string | 32 chars | `VersionTelemetryService.validVersion` |
| Shelf | cards | 60 | `ShelfStore.limit` — enforced on `add` **and** on the restore's completion, before any icon or thumbnail work. The persisted `shelf.urls` list may exceed it *while a restore is running*: the unrestored tail has not been checked for existence yet, and clamping before knowing which entries still exist would drop live cards to keep dead ones. The completion clamps and writes back, and `load()` clamps too, so the overshoot heals and cannot accumulate |
| Shelf | inline pasteboard payload | 64 MiB | `ShelfStore.maximumInlinePasteboardBytes` |
| File tools | decoded image | 64,000,000 px | `FileToolsService.maximumDecodedImagePixels` — a pixel bound; the file itself is read through ImageIO and is not byte-bounded |
| File tools | digest read | 512 MiB | `GeneratedFileRecord` streaming SHA-256 cap |
| File tools / vault | collision-suffix attempts | 1,000 | `uniqueOutputURL`, `ScreenshotVault`; falls back to a UUID |
| Accessories | `system_profiler` stdout | 1 MiB | `SystemProfilerAccessorySource.maximumOutputBytes`; truncation is an error, never a partial parse |
| Accessories | `system_profiler` stderr | 8 KiB | `SystemProfilerAccessorySource.maximumErrorBytes` |
| Accessories | `system_profiler` deadline | 5 s | terminate, then `SIGKILL` after a grace period |
| Device transport | usbmuxd/lockdown frame | 512 KiB | `MobileDeviceTransport.maximumPayloadBytes`; the plist parser only ever sees a bounded buffer |
| Device transport | socket read/write deadline | 5 s | `SO_RCVTIMEO` / `SO_SNDTIMEO` |
| Device transport | TLS handshake | 10 s, 256 iterations | `LockdownTLSChannel` |
| Device transport | public key compared | 8 KiB | `LockdownPairRecord.maximumPublicKeyBytes` |
| Settings | remembered Apple devices | 100 | `SettingsStore.maximumRememberedAppleDevices` |
| Device log | message | 200 chars | `DevicePowerLog.maximumMessageCharacters`; off unless `IMPULS_DEVICE_LOG=1` |
| Web music | reported string fields | 512 / 2,048 chars | `WebMusicState.decode` |
| Web music | artwork transferred from the page | 6 MiB base64 → 16 MiB decoded | `WebMusicPlayer`, then `PlayerBridge.maximumArtworkBytes` |
| Web music | page diagnostic line | 512 chars | forwarded to `NSLog`; page-controlled text |
| Web music | capability flags (`canNext`/`canPrevious`/`canPlayPause`/`canSeek`) | fixed 4 booleans, `?? false` when absent | `WebMusicState.decode`; reviewed for 1.4.16 — no new size/count budget, an unproven capability defaults to unavailable rather than needing a bound |
| Feedback | summary / details / prefilled URL | 120 / 4,000 / 7,000 chars | `FeedbackService`; an over-long body is copied instead of prefilled |

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
| Snippets save | no debounce | written from a utility queue on each deliberate change; flushed synchronously at shutdown |
| Clipboard archive save | 750 ms | encryption/disk work on utility queue |
| Clipboard image conversion | one in flight | serial queue; a result whose pasteboard generation moved on is discarded. Representations are read in stages so the 64 MiB image budget is not paid twice for one copy |
| Actions corpus fold | once per source change | not per keystroke; invalidated by clipboard/snippets/notes announcements |
| Menu bar rebuild | once per shown-state change | gated on a fingerprint that excludes playback position |
| Web music bridge push | 1 s, DOM observer debounced 400 ms | runs in the page; stopped by `WebMusicPlayer.teardown()` |
| Device topology reconnect | 1 s doubling to 60 s | unbounded in attempts by design, bounded in interval |
| Low-battery background override | 60 s low / 300 s otherwise | only while alerts are enabled |
| Rail hover dwell | 150 ms | hover is an affordance, not a selection |
| Version telemetry attempt | max one attempt per `(app version, 1 h)` | both the timestamp and the attempted app version are recorded before request, including failures; a different app version is not throttled by an older version's cooldown; 10 s request/resource timeout |
| Version telemetry proposal | `VersionTelemetryScheduler` fires every 1 h, tolerance 15 min (`interval / 4`) | proposes an attempt only; `VersionTelemetryService`'s cap above still applies, so this never raises the effective send rate |
| Sparkle scheduled check | 86,400 s | only after user enables automatic checks |
| Project-support prompt appearances | max 2 for the lifetime of the local state | `maximumAutomaticPrompts`. Hard ceiling, not a rate: a second decline or a second close is `dismissedForever` and no automatic prompt is ever shown again. Opening GitHub or choosing feedback ends it immediately, so two is the worst case and one is the common one |
| Project-support prompt earliest appearance | 30 calendar days **and** 10 active days **and** 20 meaningful uses since the first deliberate use | all three at once. Any single threshold alone describes an install somebody forgot. The clock starts at the first counted use, never at a reconstructed install date |
| Project-support prompt snooze | 60 days **and** at least one meaningful use after the prompt | `snoozeDays`. Elapsed time alone does not reopen the question — an app nobody opens has not earned a second ask |
| Meaningful-use coalescing window | 60 s | `meaningfulUseWindow`. Anchored to the last counted use, not slid forward by further clicks, so "20 uses" means twenty separate times somebody reached for Impuls rather than twenty clicks in one afternoon |
| Project-support prompt quiet delay | one `+8 s` one-shot per quiet transition | never a timer; scheduled only when eligibility already holds, cancelled when work resumes or the app terminates. Minimum uptime before any prompt is 120 s |
| Self-relaunch PID wait | max `100 × 0.1 s` ≈ `10 s` | `AppRelaunchService.pollLimit` / `pollInterval`; timeout is fail-closed and exits without opening a second instance |
| Self-relaunch teardown settle | `0.2 s` once the old PID disappears | one-shot helper margin before opening the exact current bundle; no daemon, Login Item or persistent timer |

Reviewed for 1.4.16: `VersionTelemetryService.diagnostics()` added no new cadence, size or count budget — it is a synchronous read of already-persisted state with no polling interval of its own, so the "Version telemetry attempt"/"proposal" rows above are unchanged.

## Relaunch lifecycle budget

The self-relaunch helper is bounded process-lifecycle work, not a recurring service. Its approximately ten-second PID wait is an architectural ceiling: if the old process does not disappear, the helper exits rather than becoming an unbounded poller or starting a second Impuls instance. Any change to `pollLimit`, `pollInterval`, the settle delay or the fail-closed behavior must update this registry and the [Background Work & Concurrency Registry](background-concurrency-registry.md) together.

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

These limits are both performance and security controls. A file-size cap, bounded Web/telemetry response, bounded image decode and capped search surface prevent a convenience utility from allocating arbitrary memory or blocking the interface on an unexpectedly large input.

See also [Threat Model](../06-security/threat-model.md), [Data Classification](../06-security/data-classification.md), [Background Work & Concurrency Registry](background-concurrency-registry.md) and [Schema & Migration Registry](schema-migration-registry.md).
