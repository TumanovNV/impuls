---
title: ADR-004 Local-Only Device Identity
type: decision
status: accepted
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, adr, identity, privacy, devices]
---

# ADR-004 — Local-Only Device Identity

## Status

Accepted.

## Context

Device layer должен deduplicate/remember presentation choices, но raw UDID, serial, Bluetooth address и pairing material слишком чувствительны для UI, logs, feedback, backup или portable settings.

## Decision

`AppleDeviceIdentity` является boundary. Presentation использует opaque/local derived key. Local ordering/hidden state и Menu Bar selected-device key остаются на конкретном Mac и исключаются из export backup.

```mermaid
flowchart LR
    RAW[Raw device identifiers] --> ID[AppleDeviceIdentity boundary]
    ID --> OPAQUE[Opaque local key]
    OPAQUE --> UI[Presentation matching]
    OPAQUE --> LOCAL[Local preferences]
    RAW -.forbidden.-> BACKUP[Backup]
    RAW -.forbidden.-> LOG[Logs/Feedback/UI]
```

## Consequences

Restored backup на другом Mac не пытается выбрать «тот же физический девайс». Это intentionally less portable, но честнее и безопаснее.
