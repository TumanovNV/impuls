---
title: Release QA Evidence — TEMPLATE
type: qa-evidence-template
status: active
documentation_version: 1.4
app_version: 0.0.0
last_reviewed: 2026-08-24
tags: [impuls, qa, release, evidence, template]
evidence_schema: 1
release_commit: 0000000000000000000000000000000000000000
release_decision: blocked
---

# Release QA Evidence — TEMPLATE

Copy this file to `<version>.md`, replace the metadata, record real environments without device identifiers, then replace every placeholder result truthfully.

For enforced releases, `not-recorded` is invalid. `not-run` is allowed only as an explicit known gap with a reason.

## Test environments

<!-- qa-environments:start -->
| Environment | Kind | Hardware | macOS | Display / power / devices | TCC state | Evidence note |
| --- | --- | --- | --- | --- | --- | --- |
| MAC-01 | real-mac | Replace with generic Mac model/chip, no serial | Replace | Replace | Replace | Replace with reproducible evidence note |
<!-- qa-environments:end -->

## Scenario results

<!-- qa-results:start -->
| ID | Result | Environment | Evidence | Notes |
| --- | --- | --- | --- | --- |
| DISP-01 | not-run | NONE | pending | Replace with real result or explain gap. |
| DISP-02 | not-run | NONE | pending | Replace with real result or explain gap. |
| DISP-03 | not-run | NONE | pending | Replace with real result or explain gap. |
| DISP-04 | not-run | NONE | pending | Replace with real result or explain gap. |
| DISP-05 | not-run | NONE | pending | Replace with real result or explain gap. |
| DISP-10 | not-run | NONE | pending | Replace with real result or explain gap. |
| PERM-01 | not-run | NONE | pending | Replace with real result or explain gap. |
| PERM-02 | not-run | NONE | pending | Replace with real result or explain gap. |
| PERM-03 | not-run | NONE | pending | Replace with real result or explain gap. |
| PERM-04 | not-run | NONE | pending | Replace with real result or explain gap. |
| PERM-05 | not-run | NONE | pending | Replace with real result or explain gap. |
| PERM-06 | not-run | NONE | pending | Replace with real result or explain gap. |
| PERM-07 | not-run | NONE | pending | Replace with real result or explain gap. |
| PERM-08 | not-run | NONE | pending | Replace with real result or explain gap. |
| PWR-01 | not-run | NONE | pending | Replace with real result or explain gap. |
| PWR-02 | not-run | NONE | pending | Replace with real result or explain gap. |
| PWR-03 | not-run | NONE | pending | Replace with real result or explain gap. |
| PWR-04 | not-run | NONE | pending | Replace with real result or explain gap. |
| PWR-05 | not-run | NONE | pending | Replace with real result or explain gap. |
| PWR-06 | not-run | NONE | pending | Replace with real result or explain gap. |
| PWR-07 | not-run | NONE | pending | Replace with real result or explain gap. |
| PWR-08 | not-run | NONE | pending | Replace with real result or explain gap. |
| PWR-09 | not-run | NONE | pending | Replace with real result or explain gap. |
| PWR-10 | not-run | NONE | pending | Replace with real result or explain gap. |
| DATA-06 | not-run | NONE | pending | Replace with real result or explain gap. |
| TR-01 | not-run | NONE | pending | Replace with real result or explain gap. |
| TR-03 | not-run | NONE | pending | Replace with real result or explain gap. |
| TR-04 | not-run | NONE | pending | Replace with real result or explain gap. |
| MUS-01 | not-run | NONE | pending | Replace with real result or explain gap. |
| MUS-02 | not-run | NONE | pending | Replace with real result or explain gap. |
| MUS-05 | not-run | NONE | pending | Replace with real result or explain gap. |
| MUS-06 | not-run | NONE | pending | Replace with real result or explain gap. |
| UI-01 | not-run | NONE | pending | Replace with real result or explain gap. |
| UI-02 | not-run | NONE | pending | Replace with real result or explain gap. |
| UI-03 | not-run | NONE | pending | Replace with real result or explain gap. |
| UI-04 | not-run | NONE | pending | Replace with real result or explain gap. |
| UI-05 | not-run | NONE | pending | Replace with real result or explain gap. |
| REL-01 | not-run | NONE | pending | Replace with real result or explain gap. |
| REL-04 | not-run | NONE | pending | Replace with real result or explain gap. |
| REL-05 | not-run | NONE | pending | Replace with real result or explain gap. |
| REL-06 | not-run | NONE | pending | Replace with real result or explain gap. |
| REL-07 | not-run | NONE | pending | Replace with real result or explain gap. |
<!-- qa-results:end -->

## Known gaps

- Replace with every material unresolved manual/TCC/hardware/service gap, or use `release_decision: certified` only when the validator permits it.

## Release decision rationale

Explain why the candidate is `certified`, `ship-with-known-gaps` or `blocked`. Do not use `retrospective` for newly enforced releases.

## Supporting evidence

Add links to PRs, issues, audit notes, screenshots or CI runs only when they are safe to publish and actually support the row. Never include user content, credentials or raw device identifiers.
