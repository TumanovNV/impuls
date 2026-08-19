---
title: Reference Layer
type: reference-index
status: active
documentation_version: 1.3
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, reference, schemas, types, performance, ai]
---

# 12 — Reference Layer

This directory is the high-precision reference layer for engineers and AI agents. Architecture documents explain **why** the system is shaped the way it is; this layer answers **which concrete contract, type, test, schema, cadence or resource budget owns a fact**.

## Documents

- [Machine-Readable Project Manifest](project-manifest.md) — routing-only root map for modules, ownership, network/permission boundaries and canonical docs.
- [Schema & Migration Registry](schema-migration-registry.md) — persisted formats, version keys, compatibility rules and migration ownership.
- [Core Type Reference](core-type-reference.md) — responsibilities and boundaries of the most important production types.
- [Generated Type → Tests → Docs Map](generated-type-test-doc-map.md) — CI-checked deterministic route from important types to source, verification and canonical docs.
- [Background Work & Concurrency Registry](background-concurrency-registry.md) — timers, polling, tasks, queues, actor boundaries, cancellation and lifecycle ownership.
- [Input & Resource Budget Registry](resource-budget-registry.md) — centralized size/count/cadence/timeout/backpressure limits.
- [Operations Boundary](operations-boundary.md) — what belongs in this public repository versus the private operational documentation vault.

Behavioral verification that depends on real platform/hardware state lives under [Behavioral QA](../13-qa/README.md).

## Machine-readable cold start

Agents that do not yet know the repository should inspect [`PROJECT-MANIFEST.json`](../../PROJECT-MANIFEST.json) first. It is routing-only and CI-validated against the actual shipped feature catalog and repository paths. It must not be treated as a replacement for the canonical documents it points to.

## Generated map

The generated map is owned by:

- [`Scripts/knowledge-map-manifest.json`](../../Scripts/knowledge-map-manifest.json) — curated architectural mapping;
- [`Scripts/generate-knowledge-map.py`](../../Scripts/generate-knowledge-map.py) — deterministic generator and validator;
- [generated-type-test-doc-map.md](generated-type-test-doc-map.md) — committed output consumed by humans and AI.

Use:

```bash
python3 Scripts/generate-knowledge-map.py
python3 Scripts/generate-knowledge-map.py --check
```

The first command regenerates the map. The second is CI mode and fails if the committed output is stale.

## v1.3 guards

```bash
python3 Scripts/check-project-manifest.py
python3 Scripts/check-documentation-guardian.py --base <base-sha>
python3 Scripts/check-documentation-freshness.py
```

The project-manifest checker protects stable routing/ownership. The semantic Guardian protects contract-sensitive diffs. The freshness checker protects historical source→doc ordering and periodic review age.

## Rule for persisted data

Before changing any stored key, Codable structure, file format, Keychain identity, telemetry payload or collector database shape, read [Schema & Migration Registry](schema-migration-registry.md). A schema change is not a local implementation detail: compatibility, backup/restore, privacy and downgrade/upgrade behavior must be considered explicitly.

## Rule for background work

Before changing any timer, polling cadence, debounce/retry, long-lived task/observer/socket or queue/actor boundary, read [Background Work & Concurrency Registry](background-concurrency-registry.md). A presentation surface must not become a new work owner merely because it needs to show shared state.

## Rule for budgets

Before increasing/deleting a size/count/time/backpressure limit, read [Input & Resource Budget Registry](resource-budget-registry.md). Prefer bounded/lazy/streaming designs over making a utility unbounded.

## Source of truth

Reference documents and the root routing manifest do not override code/tests/CI. Their purpose is to make verified ownership and compatibility constraints discoverable. If implementation and reference disagree, determine the real contract from code + tests + CI and update the stale reference in the same change set.
