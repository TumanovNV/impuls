---
title: Threat Model
type: security
status: active
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, security, threat-model]
---

# Threat Model

## Scope

Модель рассматривает desktop utility, которая читает local user data, открывает selected web providers, обновляется через Internet и взаимодействует с Apple devices.

```mermaid
flowchart LR
    X1[Untrusted pasteboard/file content] --> APP[Impuls]
    X2[Web provider content] --> APP
    X3[Compromised update transport] --> APP
    X4[Malformed backup/snippets] --> APP
    X5[Device transport / stale data] --> APP
    X6[Test/dev environment] --> APP
    APP --> M[Mitigations: bounds, allow-lists, signatures, isolation, explicit consent]
```

## T1 — Oversized/malformed local input

Риски: memory pressure, parser abuse, UI stalls. Mitigations: `BoundedFileReader`, `BoundedData`, `BoundedText`, per-feature byte/item limits, atomic writes, bounded search/link scans.

## T2 — Clipboard privacy leakage

Риски: password-manager content, excluded app, self-capture. Mitigations: concealed type ignored, per-app exclusions, internal marker, persistence off by default, AES-GCM + device-only Keychain.

## T3 — Malicious web navigation/content

Риски: WebKit становится generic browser, bridge reports from wrong origin. Mitigations: WebKit only explicit open, main-frame provider allow-list, state reports only allowed HTTPS provider page, no other source creates `WebMusicPlayer`.

## T4 — Update supply chain

Риски: MITM/modified archive/feed. Mitigations: HTTPS fixed GitHub feed, signed feed, Ed25519 archive signature, verify before extraction, pinned Sparkle version, release secret/public key verification, artifact codesign checks.

## T5 — Telemetry expansion/redirect

Риски: consent scope creep, endpoint redirect, extra fields. Mitigations: separate consent, exact `/v1/heartbeat`, no redirects, allow-listed Codable payload, max once/day attempt, endpoint build-configured not source-hardcoded.

## T6 — Device identifiers / pairing secrets

Риски: raw IDs leak to UI/log/backup/feedback. Mitigations: `AppleDeviceIdentity` opaque boundary, not Codable raw identity, local HMAC-derived keys, selected-device key excluded from backup.

## T7 — Device protocol instability

Риски: undocumented iPhone/iPad path changes, hangs, partial failures. Mitigations: quarantined provider, Beta status, off until explicit external-device switch, I/O off main actor, provider failure isolation, truthful unavailable/stale states.

## T8 — Stale async completion

Риски: old display transition/provider task resurrects state after newer intent. Mitigations: generation counters, stopped-provider guard, task cancellation/coalescing, active-surface single ownership.

## T9 — Test contamination

Риск: tests read/write real notes, snippets or Keychain clipboard key. Mitigations: explicit `StorageEnvironment`, no defaults for sensitive persistence constructors, nil clipboard persistence in tests.

## Security review trigger

Любое изменение network owner, permission, identity, persistence, update verification, file parser limit или hardware transport требует сверки этого threat model.
