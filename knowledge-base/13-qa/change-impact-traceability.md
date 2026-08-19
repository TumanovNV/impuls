---
title: Behavioral QA Change Impact Traceability
type: qa-reference
status: active
documentation_version: 1.3
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, qa, traceability, ci, ai, release]
---

# Behavioral QA Change Impact Traceability

This layer connects a Git diff to the scenario IDs in the [Behavioral QA Matrix](behavioral-qa-matrix.md).

It solves a different problem from the matrix and Release QA Evidence:

- the matrix defines **what behavior exists to verify**;
- QA impact traceability determines **which scenario IDs a code/test change may affect**;
- release evidence records **what was actually exercised for a specific version**;
- the release gate decides whether that version may be treated as shippable.

## Machine-readable source of truth

The curated map is [`../../Scripts/qa-impact-rules.json`](../../Scripts/qa-impact-rules.json).

Each rule contains:

- a stable rule ID and description;
- production `source_globs`;
- associated `test_globs`;
- one or more Behavioral QA IDs.

The checker is [`../../Scripts/check-qa-impact.py`](../../Scripts/check-qa-impact.py).

```bash
python3 Scripts/check-qa-impact.py
python3 Scripts/check-qa-impact.py --base <base-sha>
```

The first form validates the map itself. The second analyzes the actual diff from `<base-sha>` to `HEAD`.

## What CI enforces

The `knowledge-base` workflow runs the checker on pull requests and pushes.

It enforces five contracts:

1. every QA ID referenced by the impact map must exist in the Behavioral QA Matrix;
2. every current matrix scenario must be reachable from at least one impact rule;
3. every `automated` scenario must have at least one mapped test route;
4. a changed production file under the tracked behavioral source roots must match a rule or a narrow documented exemption;
5. when the diff changes `Scripts/version`, every impacted non-automated QA ID must be present in that version's Release QA Evidence record.

The checker deliberately does **not** turn a mapped test into a manual pass. It only establishes traceability and review obligation.

## Diff model

A changed production file contributes **source impact**. A changed mapped test contributes **test impact**. Both resolve to the same QA IDs.

Example:

```text
NotchController.swift
        |
        v
rule: display-lifecycle
        |
        +--> DISP-01 ... DISP-10
        +--> UI-05

MultiDisplayControllerTests.swift
        |
        +--> the same rule / QA family
```

This gives a reviewer or AI agent a direct path from the changed file to the relevant behavioral contract instead of relying on memory.

## Release-candidate integration

For an ordinary implementation PR, the checker reports the impacted IDs and their modes.

If the same diff changes `Scripts/version`, the current version becomes a release candidate for impact purposes. The checker then opens:

```text
knowledge-base/13-qa/release-evidence/<version>.md
```

and verifies that every impacted `mixed`, `manual-macos`, `manual-hardware` or `manual-service` ID is classified there.

The result may still truthfully be `pass`, `fail`, `blocked`, `not-run` or justified `not-applicable` according to the release-evidence policy. QA impact traceability does not decide whether a gap is acceptable; [`check-release-qa-evidence.py`](../../Scripts/check-release-qa-evidence.py) owns the shipping decision.

This separation is intentional:

```text
changed code/test
      |
      v
QA impact checker
      |
      v
impacted Behavioral QA IDs
      |
      v
version-specific evidence
      |
      v
release QA shipping gate
```

## Fail-closed rule for new behavioral code

The tracked source roots include the Impuls Swift implementation, entitlements, package/build plumbing that affects release behavior, and the release workflow.

If a changed tracked production file matches no impact rule, CI fails with an `unmapped behavioral source change` message.

The correct response is to do one of two things:

1. add the file to an existing/new impact rule and map it to the affected QA IDs; or
2. if the file genuinely has no Behavioral QA contract, add a **narrow exemption with a written reason**.

Do not add a broad exemption such as `Sources/**/*.swift`. Exemptions are reviewable architecture statements, not a bypass mechanism.

## Current narrow exemptions

The initial map exempts only implementation areas whose verification belongs to another explicit contract and that currently have no Behavioral QA scenario:

- version-only telemetry — version-statistics tests + network/privacy/operations contracts;
- feedback URL construction — FeedbackService tests + privacy boundary;
- localization key plumbing — localization CI.

If one of these areas later gains a user-visible lifecycle/TCC/hardware behavior, remove or narrow the exemption and add the appropriate Behavioral QA route.

## GitHub Actions summary

With `--github-summary`, the checker appends a compact report to `GITHUB_STEP_SUMMARY` containing:

- number of changed files considered;
- triggered rule families;
- impacted QA IDs and verification modes;
- exact source/test trigger files;
- release-candidate evidence results for impacted manual/mixed rows;
- any narrow exemptions used.

This report is informational when the contract is valid; structural or unmapped-source violations still fail CI.

## Maintenance rule

When changing a behaviorally important source owner:

1. identify the affected Behavioral QA IDs;
2. update `Scripts/qa-impact-rules.json` if the ownership route changed;
3. add/update deterministic tests where appropriate;
4. add/update the Behavioral QA Matrix if a genuinely new behavior was introduced;
5. if preparing a release, update the version-specific Release QA Evidence truthfully;
6. run:

```bash
python3 -m unittest discover -s Tests/PythonTests -p 'test_qa_impact.py'
python3 Scripts/check-qa-impact.py --base <base-sha>
```

The impact map should stay conservative. A small amount of over-reporting is safer than silently missing a real display, permission, power, persistence or release regression.
