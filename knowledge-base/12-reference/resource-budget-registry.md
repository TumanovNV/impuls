---
title: Input & Resource Budget Registry
type: reference
status: active
documentation_version: 1.3
app_version: 1.4.11
last_reviewed: 2026-08-19
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
| Clipboard archive save | 750 ms | encryption/disk work on utility queue |
| Version telemetry | max one attempt per 24 h | 10 s request/resource timeout |
| Sparkle scheduled check | 86,400 s | only after user enables automatic checks |

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
