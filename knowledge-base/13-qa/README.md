---
title: Behavioral QA Index
type: qa-index
status: active
documentation_version: 1.3
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, qa, testing, manual, hardware, ai]
---

# 13 — Behavioral QA

This layer defines **what behavior must be exercised** and records **what was actually exercised for a release**. It includes scenarios that unit tests cannot prove on a hosted CI runner: real TCC prompts, sleep/wake, multiple displays, Apple devices, Music/WebKit and release installation behavior.

## Documents

- [Behavioral QA Matrix](behavioral-qa-matrix.md) — canonical scenario inventory with verification mode and expected contract.
- [Release QA Evidence](release-evidence/README.md) — per-version environments, manual/mixed results, known gaps and release decision.
- [Release Evidence Template](release-evidence/TEMPLATE.md) — starting point for the next version.

## Verification vocabulary

- `automated` — expected to be covered deterministically in Swift/Python CI.
- `manual-macos` — needs a real interactive macOS session.
- `manual-hardware` — needs specific display/device/power hardware.
- `manual-service` — depends on Apple Music, a supported web service or another external user-facing service.
- `mixed` — deterministic core is automated, but the final platform/hardware experience still needs a manual pass.

The matrix is an **inventory, not a green release report**. Presence in the table never means the latest release has passed the scenario.

Release-specific manual evidence belongs under `release-evidence/<version>.md`. Starting with **1.4.12**, the evidence file must exist for the version in `Scripts/version`, must account for every manual/mixed row, and may no longer use the historical `not-recorded` result.

## Evidence discipline

A release evidence row must distinguish:

- the scenario ID from the matrix;
- the actual result (`pass`, `fail`, `blocked`, `not-run`, `not-applicable`);
- the real test environment when the scenario was exercised;
- supporting evidence and a concise note;
- unresolved gaps that are intentionally accepted for shipment.

Do not record serial numbers, UDIDs, usernames, hostnames, MAC/Bluetooth addresses, pairing data, secrets or user content merely to prove a hardware test happened.

`certified` means every non-automated row is `pass` or justified `not-applicable`. A release may instead use `ship-with-known-gaps`, but the gaps must stay visible. `blocked` means do not ship.

Validation:

```bash
python3 Scripts/check-release-qa-evidence.py --all
```

Policy: [`../../Scripts/release-qa-policy.json`](../../Scripts/release-qa-policy.json).

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

When a matrix row is added or its verification mode changes, also review the release evidence template and the current candidate evidence file. The validator will reject a candidate that fails to account for the complete manual/mixed set.
