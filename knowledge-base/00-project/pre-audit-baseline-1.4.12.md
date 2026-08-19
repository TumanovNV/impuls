---
title: Pre-Audit Baseline — Impuls 1.4.12
type: project-baseline
status: active
documentation_version: 1.3
app_version: 1.4.12
last_reviewed: 2026-08-19
tags: [impuls, audit, security, performance, codex, claude, baseline]
---

# Pre-Audit Baseline — Impuls 1.4.12

## Purpose

This is the trusted starting point for the next whole-repository security and performance audit. It prevents Codex, Claude or a human reviewer from reconstructing current state from historical branches, old release handoffs or stale subsystem audits.

## Source-of-truth order

1. `main` — the only current source branch after the pre-audit branch cleanup.
2. `Scripts/version` — current product baseline, `1.4.12`.
3. `PROJECT-MANIFEST.json` — routing-only map to canonical owners.
4. `knowledge-base/00-project/project-status.md` — current architecture/documentation status.
5. code + tests + current CI contracts for the subsystem being reviewed.
6. current canonical knowledge-base document linked by the manifest/type map.
7. release-specific QA evidence when a claim depends on real macOS/TCC/hardware behavior.

Historical `docs/` audits, release handoffs and old branch names are evidence only. They do not override current code/tests/CI.

## Repository hygiene

For the audit, `main` is the single current source branch. The pre-audit cleanup removes obsolete merged/abandoned development branches after this baseline passes the normal pull-request checks. Release tags are retained: tags are immutable historical release identities and are not competing source branches.

A future audit must not switch to an old `agent/*`, `docs/*`, `fix/*`, `release/*` or backup branch to resolve ambiguity. If history is needed, use commits/tags/merged PRs as evidence and return to `main` for current truth.

## Release / main relationship

Published product release: **Impuls 1.4.12**.

The tag `v1.4.12` identifies the released product code. `main` may be ahead of that tag because post-release documentation, QA traceability and anti-drift protections were strengthened without changing `Scripts/version` or product Swift behavior. Do not treat documentation-only commits after the tag as a newer product version.

The 1.4.12 Release QA Evidence decision is `ship-with-known-gaps`. `UI-06` has real-Mac visual evidence; unperformed manual/hardware/TCC rows remain explicit `not-run`. Green deterministic CI must never be converted into a manual hardware/TCC pass.

## Current architecture anchors

- one shared `NotchViewModel` / service graph per process;
- per-display presentation surfaces with exactly one active surface;
- nine shipped panel modules; Menu Bar is a presentation workspace, not a tenth provider module;
- exactly three Internet owners: updates, explicit web music, opt-in version statistics;
- sensitive permissions only after explicit user action;
- local-first content, bounded reads and bounded background work;
- raw Apple-device identifiers stay inside the identity/transport boundary;
- blocking disk/process/socket/device I/O stays off the main actor;
- Sparkle update authenticity remains independent from current Apple Developer ID availability;
- persisted-format, network, permission, privacy, actor/ownership and module-topology changes are documentation-review events.

## Security audit starting routes

Read before reporting findings:

- `knowledge-base/06-security/security-model.md`
- `knowledge-base/06-security/threat-model.md`
- `knowledge-base/06-security/data-classification.md`
- `knowledge-base/06-security/privacy-boundaries.md`
- `knowledge-base/06-security/supply-chain.md`
- `knowledge-base/01-architecture/networking.md`
- `knowledge-base/01-architecture/permissions.md`
- `knowledge-base/03-macos/permissions-and-tcc.md`
- `knowledge-base/03-macos/signing-distribution.md`
- `knowledge-base/05-release/update-system.md`
- `knowledge-base/12-reference/schema-migration-registry.md`

Priority review surfaces: update trust/signing, WebKit navigation/message bridge, optional telemetry payload/consent/collector boundary, Keychain use, encrypted clipboard persistence, backup/restore, raw device identity, usbmuxd/lockdown/TLS parsing, subprocess invocation, file transforms, URL opening and permission prompts.

## Performance audit starting routes

Read before changing cadence/ownership/limits:

- `knowledge-base/01-architecture/state-and-ownership.md`
- `knowledge-base/01-architecture/multi-display.md`
- `knowledge-base/12-reference/background-concurrency-registry.md`
- `knowledge-base/12-reference/resource-budget-registry.md`
- `knowledge-base/12-reference/generated-type-test-doc-map.md`
- `knowledge-base/13-qa/change-impact-traceability.md`

Priority review surfaces: MainActor occupancy, timer/poller duplication, display reconciliation, hover/animation invalidation, clipboard polling/persistence, notes/snippets disk I/O, media refresh/artwork, WebKit lifetime, Calendar cadence, translation tasks, external-device discovery, process/socket timeouts, sleep/wake and teardown.

## Deterministic validation before and after optimization

```bash
swift test -c release
./Scripts/bundle.sh release
python3 Scripts/check-project-manifest.py
python3 Scripts/check-dependency-policy.py
python3 Scripts/generate-architecture-ledger.py --check
python3 Scripts/check-knowledge-base.py
python3 Scripts/generate-knowledge-map.py --check
python3 Scripts/check-documentation-freshness.py
python3 Scripts/check-qa-impact.py --base <base-sha>
python3 Scripts/check-release-qa-evidence.py --all
python3 Scripts/check-documentation-guardian.py --base <base-sha>
```

CI additionally verifies the three-owner Internet boundary, forbidden implementation paths, security/performance budgets, feedback privacy, adaptive UI, pointer lifecycle, bundle identity, localization, unsolicited-network smoke behavior and update artifacts.

## Audit reporting contract

For every finding record:

- severity and confidence;
- exact owner/source path;
- trigger/precondition;
- user/security/performance impact;
- whether the issue is demonstrated, strongly inferred or defense-in-depth;
- existing test/CI/documentation coverage;
- smallest safe remediation;
- regression test or measurable acceptance criterion.

Do not mix optimization and feature work. Do not remove limits, consent boundaries, signature verification or safety checks merely to reduce CPU/memory. Preserve animation quality while eliminating unnecessary work ownership, wakeups, allocations and main-thread blocking.

## Private operations boundary

This public repository is the source of truth for software behavior and contracts. Live production host/network/VPN/reverse-proxy/backup/dashboard state belongs to the private `TumanovNV/office-it-docs` operational vault. Do not copy private topology or secrets into this repository during the audit.