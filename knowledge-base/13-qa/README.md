---
title: Behavioral QA Index
type: qa-index
status: active
documentation_version: 1.3
app_version: 1.4.12
last_reviewed: 2026-08-19
tags: [impuls, qa, testing, manual, hardware, ai]
---

# 13 — Behavioral QA

This layer defines **what behavior must be exercised**, including scenarios that unit tests cannot prove on a hosted CI runner: real TCC prompts, sleep/wake, multiple displays, Apple devices, Music/WebKit and release installation behavior.

## Documents

- [Behavioral QA Matrix](behavioral-qa-matrix.md) — canonical scenario inventory with verification mode and expected contract.

## Verification vocabulary

- `automated` — expected to be covered deterministically in Swift/Python CI.
- `manual-macos` — needs a real interactive macOS session.
- `manual-hardware` — needs specific display/device/power hardware.
- `manual-service` — depends on Apple Music, a supported web service or another external user-facing service.
- `mixed` — deterministic core is automated, but the final platform/hardware experience still needs a manual pass.

The matrix is an **inventory, not a green release report**. Presence in the table never means the latest release has passed the scenario. Release-specific evidence belongs in CI runs, release notes and explicit QA/audit records.

## Maintenance rule

Add or update a scenario when a change introduces a new:

- user-visible state or failure mode;
- permission/TCC path;
- display/topology transition;
- sleep/wake or lifecycle edge;
- local persistence/migration path;
- hardware/provider state;
- update/install path;
- accessibility/appearance behavior that cannot be proven by a narrow unit test.
