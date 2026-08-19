---
title: Release QA Evidence Index
type: qa-index
status: active
documentation_version: 1.3
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, qa, release, evidence, hardware, tcc]
---

# Release QA Evidence

This directory is the **release-specific evidence layer** for the Behavioral QA Matrix.

The matrix answers **what must be exercised**. A file here answers **what was actually exercised for one release, on what environment, with what result and what remains unverified**.

## Why this exists

A row such as `PWR-02 — MacBook charging via MagSafe` in the matrix is not proof that a shipped build was tested on MagSafe. The same is true for Calendar TCC, Apple Music automation, sleep/wake, external displays and connected iPhone states.

Each release evidence record therefore keeps four facts separate:

1. release/build identity;
2. real test environment or an explicit statement that no environment was recorded;
3. one result for every `mixed`, `manual-macos`, `manual-hardware` and `manual-service` matrix row;
4. the release decision: certified, intentionally shipped with known gaps, blocked, or historical/retrospective.

## Files

- [`TEMPLATE.md`](TEMPLATE.md) — starting point for a new version.
- [`1.4.11.md`](1.4.11.md) — retrospective baseline for the release that existed before this evidence system was introduced.
- [`../behavioral-qa-matrix.md`](../behavioral-qa-matrix.md) — canonical scenario inventory.

## Result vocabulary

| Result | Meaning |
| --- | --- |
| `pass` | Scenario was exercised in the referenced environment and matched the contract. |
| `fail` | Scenario was exercised and did not match the contract. |
| `blocked` | The scenario could not complete because of a concrete blocker after testing began. |
| `not-run` | The release team intentionally did not exercise the scenario; Notes must explain why. |
| `not-applicable` | The scenario truly does not apply to this release/environment; Notes must justify this. |
| `not-recorded` | Historical evidence was not preserved. Allowed only before the enforcement baseline. |

## Release decisions

- `certified` — every manual/mixed row is `pass` or justified `not-applicable`, and at least one real Mac environment is recorded.
- `ship-with-known-gaps` — release may proceed, but unresolved rows and a non-empty **Known gaps** section are mandatory.
- `blocked` — release must not ship until the blocking evidence changes.
- `retrospective` — historical record only; forbidden for newly enforced releases.

The policy is machine-readable in [`../../../Scripts/release-qa-policy.json`](../../../Scripts/release-qa-policy.json). Structural validation is performed by [`../../../Scripts/check-release-qa-evidence.py`](../../../Scripts/check-release-qa-evidence.py).

## Enforcement

The first enforced version is **1.4.12**. From that version onward:

- `knowledge-base/13-qa/release-evidence/<version>.md` must exist whenever `Scripts/version` changes;
- `not-recorded` is forbidden;
- a release record may be `certified`, `ship-with-known-gaps` or `blocked`, but a shipping gate must reject `blocked`;
- every non-automated matrix scenario must appear exactly once.

The current CI integration validates structure and the evidence file for the version in `Scripts/version`. It intentionally does **not fabricate hardware results** from hosted CI.

## Test environment privacy

Record enough information to reproduce the test, but do not turn QA evidence into a device inventory.

Good examples:

- `MacBook Pro, Apple Silicon, built-in display + 4K external monitor`;
- `Mac mini, Apple Silicon, 4K display`;
- `macOS 15.x/26.x build family` when exact OS version is known and useful;
- `MagSafe`, `USB-C`, `trusted unlocked iPhone`, `Calendar denied`.

Do **not** record:

- serial numbers;
- UDID or raw device identifiers;
- hostnames/usernames;
- MAC/Bluetooth addresses;
- pairing material;
- private paths containing a user name;
- screenshots/logs containing secrets or user content.

## Evidence rule

A `pass`/`fail`/`blocked` result for `manual-macos`, `manual-hardware` or `mixed` must point to a real Mac environment. `manual-hardware` specifically requires a `real-mac-hardware` environment.

Links to a PR, issue, audit note, screenshot attachment or CI run may supplement the row, but they do not replace the environment description.

## Release workflow for agents

When bumping `Scripts/version`:

1. copy `TEMPLATE.md` to `<version>.md`;
2. set the release commit to the exact candidate SHA once known;
3. enumerate test environments without sensitive device identifiers;
4. exercise or explicitly classify every manual/mixed matrix row;
5. choose the truthful release decision;
6. run `python3 Scripts/check-release-qa-evidence.py --all`;
7. only call the release certified when the checker permits that decision.

Do not convert `not-run` to `pass` merely to satisfy CI. A visible known gap is safer than fictitious release evidence.
