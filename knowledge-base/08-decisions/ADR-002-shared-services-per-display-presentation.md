---
title: ADR-002 Shared Services, Per-Display Presentation
type: decision
status: accepted
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, adr, multi-display, ownership]
---

# ADR-002 — Shared Services, Per-Display Presentation

## Status

Accepted. Introduced by multi-display architecture and binding for current code.

## Context

ИМПУЛЬС должен быть доступен на нескольких displays, но stores/timers/providers представляют одно приложение и один набор пользовательских данных.

## Decision

Создавать один `NotchViewModel` на process. На каждый display создаётся только presentation surface (window/view/geometry). `DisplayCoordinator` не имеет stores/timers.

```mermaid
flowchart LR
    VM[One ViewModel + Services] --> S1[Surface A]
    VM --> S2[Surface B]
    VM --> S3[Surface C]
```

## Alternatives rejected

- ViewModel per display: duplicate clipboard/media/power monitors, diverging state, extra timers.
- Rebuild on screen parameter change: destroys user state and restarts services.

## Consequences

Hot unplug/reconcile не теряет Notes/Translate state. Surface code должен оставаться presentation-only. Exactly one active surface invariant обязателен.

## References

- [Multi-Display Architecture](../01-architecture/multi-display.md)
- `Sources/Impuls/Notch/DisplayCoordinator.swift`
- `Sources/Impuls/Notch/NotchController.swift`
