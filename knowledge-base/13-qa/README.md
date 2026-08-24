---
title: Behavioral QA Index
type: qa-index
status: active
documentation_version: 1.4
app_version: 1.4.15
last_reviewed: 2026-08-24
tags: [impuls, qa, testing, manual, hardware, ai, traceability]
---

# 13 — Behavioral QA

This layer defines **what behavior must be exercised**, determines **which QA contracts a code/test diff may affect**, and records **what was actually exercised for a release**. It includes scenarios that unit tests cannot prove on a hosted CI runner: real TCC prompts, sleep/wake, multiple displays, Apple devices, Music/WebKit and release installation behavior.

Documentation/current-state consistency checks are complementary and do not turn into QA evidence. `Scripts/check-current-documentation.py` can prove that an agent/public entrypoint routes to the current owner or locale set; it cannot prove that a real Mac, TCC dialog, Apple device or service scenario passed.

## Documents

- [Behavioral QA Matrix](behavioral-qa-matrix.md) — canonical scenario inventory with verification mode and expected contract.
- [Behavioral QA Change Impact Traceability](change-impact-traceability.md) — diff → source/test ownership → affected QA IDs → release-evidence obligation.
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

## Automatic change-impact traceability

The source/test ownership map lives in [`../../Scripts/qa-impact-rules.json`](../../Scripts/qa-impact-rules.json). The checker is [`../../Scripts/check-qa-impact.py`](../../Scripts/check-qa-impact.py).

```bash
python3 Scripts/check-qa-impact.py
python3 Scripts/check-qa-impact.py --base <base-sha>
```

For a diff-aware run, the checker reports the exact impacted QA IDs and why they were selected. Production source and associated tests converge on the same Behavioral QA IDs.

A changed tracked behavioral source file that matches neither a QA rule nor a narrow documented exemption fails CI. This is deliberate: new behavioral ownership must not appear without a QA route.

When the same diff changes `Scripts/version`, the checker also verifies that every impacted non-automated ID is present in `release-evidence/<version>.md`. It never promotes unit tests, documentation checks or current-state consistency assertions to manual passes; the result in release evidence remains a truthful `pass`, `fail`, `blocked`, `not-run` or justified `not-applicable`.

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
python3 -m unittest discover -s Tests/PythonTests -p 'test_qa_impact.py'
python3 Scripts/check-qa-impact.py --base <base-sha>
python3 Scripts/check-release-qa-evidence.py --all
```

Policies:

- [`../../Scripts/qa-impact-rules.json`](../../Scripts/qa-impact-rules.json) — code/test → QA IDs;
- [`../../Scripts/release-qa-policy.json`](../../Scripts/release-qa-policy.json) — release-specific evidence and shipping decision.

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

When a matrix row is added or its verification mode changes, update the QA impact map so the new ID has an explicit source/test route, then review the release evidence template and current candidate evidence file. CI validates both traceability coverage and release-specific classification.

When a documentation/current-state guard is added, keep its scope separate: it may protect route/version/locale/public-policy consistency, but it must never be used as evidence that a manual Behavioral QA scenario passed.
