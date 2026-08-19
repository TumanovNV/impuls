---
title: Documentation Guardian
type: ai-reference
status: active
documentation_version: 1.3
app_version: 1.4.12
last_reviewed: 2026-08-19
tags: [impuls, ai, documentation, ci, drift, guardian]
---

# Documentation Guardian

Documentation Guardian is the anti-drift layer between implementation changes and the engineering knowledge base. It does **not** generate prose from source. It makes contract-sensitive changes visible and requires the agent/engineer to review the canonical owner in the same change set.

The v2 rule set deliberately stays narrow. It guards lines whose meaning is architectural, security/privacy-sensitive or release-critical; it does not require a documentation edit for ordinary UI copy, local refactoring or unrelated Swift changes.

## Six protection layers

1. **Structural validation** — `Scripts/check-knowledge-base.py`
   - required frontmatter;
   - baseline documentation/product versions;
   - local links;
   - fenced diagram closure.
2. **Ownership/reference validation** — `Scripts/generate-knowledge-map.py --check`
   - curated type exists in its source;
   - mapped tests/docs exist;
   - committed generated map equals deterministic output.
3. **Semantic diff guard** — `Scripts/check-documentation-guardian.py --base <sha>`
   - inspects added **and removed** source lines;
   - matches 11 high-risk contract families from `Scripts/documentation-guardian-rules.json`;
   - fails when the corresponding canonical owner was not reviewed in the same diff.
4. **Behavioral QA impact traceability** — `Scripts/check-qa-impact.py --base <sha>`
   - maps changed product source/tests to exact Behavioral QA IDs;
   - fails closed on a changed tracked behavioral source without a QA route;
   - does not convert deterministic tests into manual hardware/TCC pass evidence.
5. **Historical freshness guard** — `Scripts/check-documentation-freshness.py`
   - maps canonical docs to tracked implementation paths via `Scripts/documentation-freshness.json`;
   - compares real Git commit ancestry, not file timestamps;
   - fails when tracked source is newer than the latest document commit or newer than its `last_reviewed` date;
   - weekly scheduled CI additionally enforces periodic 180/365-day review-age policies.
6. **Product CI** — normal Swift/Python/build/security checks prove executable behavior rather than documentation shape.

## Guarded semantic contract families

| Family | What triggers review | Canonical review route |
| --- | --- | --- |
| Background / concurrency | timer, task, queue, delayed work, polling or tolerance contract | [Background Work & Concurrency Registry](../12-reference/background-concurrency-registry.md) |
| Resource budgets | size, item count, cadence, timeout or backpressure limit | [Input & Resource Budget Registry](../12-reference/resource-budget-registry.md) |
| Persisted contract | persisted key/schema, Keychain identity, file contract or collector DB version | [Schema & Migration Registry](../12-reference/schema-migration-registry.md) |
| Network contract | Internet endpoint, host, feed, redirect or heartbeat boundary | [Networking](../01-architecture/networking.md) |
| Permissions | TCC request, entitlement or permission-prompt path | [Permissions](../01-architecture/permissions.md) or [Permissions & TCC](../03-macos/permissions-and-tcc.md) |
| Dependency contract | Swift package source/version/revision pin | [Dependency / Supply Chain](../06-security/supply-chain.md) |
| Privacy / device identity | raw Apple-device identifier handling, derived local identity or device-only Keychain accessibility | [Privacy Boundaries](../06-security/privacy-boundaries.md) or [Data Classification](../06-security/data-classification.md) |
| Telemetry payload / privacy | heartbeat field names/schema, installation identity hashing/storage or collector retention semantics | [Version Statistics Collector](../07-web/version-statistics-collector.md) or [Privacy Boundaries](../06-security/privacy-boundaries.md) |
| Update / signing integrity | Sparkle signed-feed verification, auto-update consent flags, EdDSA/appcast signing, codesign or Developer ID path | [Update System](../05-release/update-system.md), [Release Pipeline](../05-release/release-pipeline.md), [Signing & Distribution](../03-macos/signing-distribution.md) or [Dependency / Supply Chain](../06-security/supply-chain.md) |
| Ownership / actor boundary | `@MainActor`, `@unchecked Sendable`, isolation, actor or lock ownership | [State & Ownership](../01-architecture/state-and-ownership.md) or [Background Work & Concurrency Registry](../12-reference/background-concurrency-registry.md) |
| Module topology | shipped `Tab` cases or feature-catalog membership | root `PROJECT-MANIFEST.json` |

Behavioral lifecycle/platform edges remain independently protected by [Behavioral QA Change Impact Traceability](../13-qa/change-impact-traceability.md) and the [Behavioral QA Matrix](../13-qa/behavioral-qa-matrix.md). The semantic Guardian and QA impact checker complement each other: one asks **which canonical engineering contract must be reviewed**, the other asks **which behavior must be re-verified**.

## Why the v2 families exist

The first Guardian generation was intentionally small and caught background work, resource limits, persistence, networking, permissions and dependencies. That left several high-consequence changes dependent on human memory alone:

- replacing HMAC-derived device identity with a weaker raw/deterministic identifier path;
- adding or renaming version-statistics payload fields without reviewing the public privacy/collector contract;
- weakening Sparkle feed/archive verification or changing release-signing behavior;
- moving service/state ownership across `@MainActor`, Sendable or lock boundaries;
- changing the shipped module/tab inventory without updating the machine-readable project topology.

Guardian v2 adds narrow matchers for those boundaries. The matcher still does not decide whether a change is correct; it only makes the required review impossible to overlook.

## How the diff guard works

The JSON rule set contains source globs, contract-sensitive regular expressions and one or more canonical files that satisfy review. The Python checker reads `git diff <base>...HEAD`, including additions and removals. If a matching contract line changed but none of its canonical owners changed, CI fails.

A canonical route is intentionally an **any-of** set. For example, a Sparkle signing change may truthfully belong primarily in signing/distribution or in the update system depending on the exact contract changed. Requiring every adjacent document would encourage meaningless touches rather than accurate ownership.

This intentionally catches **review obligation**, not semantic truth. Regex cannot know whether a new timer is a good idea, whether an HMAC boundary remains private, or whether a changed signing flag is safe. The agent still has to establish the real contract from source/tests/CI and update the smallest truthful canonical owner.

## How freshness works

The freshness manifest is intentionally curated. Each entry names one canonical document and the source paths whose evolution should force that document to be revisited.

For each mapping, CI finds:

1. the latest Git commit touching any tracked source path;
2. the latest Git commit touching the canonical document;
3. the document's `last_reviewed` date.

The source commit must be an ancestor of the document commit. This ancestry check catches same-day drift that a date-only check cannot see. `last_reviewed` must also be at least the date of the latest tracked source change and may never be in the future.

Normal PR/push CI enforces source drift only. The lightweight scheduled knowledge-base workflow runs every Monday and additionally applies each entry's periodic review-age budget. This keeps old but unchanged high-risk documentation from becoming permanently trusted merely because nobody touched its source recently.

## Do not game the guard

A meaningless whitespace touch to a Markdown/JSON owner is not a valid documentation update. If the source change is semantically neutral but hits a guarded pattern, review the canonical contract and make the smallest truthful update — for example clarifying ownership or confirming why the documented behavior is unchanged.

`last_reviewed` has the same rule: change it only after actually checking the mapped source/tests/CI. The freshness checker deliberately uses both Git ancestry and the metadata date so rewriting one field cannot hide that source changed after the document commit.

Do not solve a noisy matcher by adding broad exemptions. First narrow its source globs/patterns to the actual boundary. A deliberately excluded source is acceptable only when another deterministic control owns the contract and that exclusion is itself documented.

Conversely, a source change may alter behavior without matching a regex or a curated freshness mapping. `AGENTS.md`, the change-impact matrix and human/agent review still apply. Guardian is a safety net, not a substitute for architectural judgment.

## Public / private boundary

The public Guardian must never force private runtime facts into `TumanovNV/impuls`. Production host/network/service/backup/access state belongs to `office-it-docs`. If a public software protocol change also changes deployment assumptions, update both canonical owners separately without copying private topology into this repository.

Telemetry rules therefore protect the **public payload/privacy/software contract** only. Actual production addresses, service credentials, VPN topology and deployed runtime state remain private operational facts.

## Agent route

Before editing:

1. `AGENTS.md`
2. `knowledge-base/10-ai/AI-INDEX.md`
3. relevant module/architecture/security/release docs
4. the matching v1.3 registry when background/resource/persistence behavior is involved
5. source + tests + CI

Before reporting completion:

```bash
python3 Scripts/check-knowledge-base.py
python3 Scripts/generate-knowledge-map.py --check
python3 Scripts/check-documentation-guardian.py --base <base-sha>
python3 Scripts/check-qa-impact.py --base <base-sha>
python3 Scripts/check-documentation-freshness.py
```

For a release/version change also run:

```bash
python3 Scripts/check-release-qa-evidence.py --release-gate
```

Then run the repository's normal tests/build checks appropriate to the change.
