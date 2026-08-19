---
title: Reference Layer
type: reference-index
status: active
documentation_version: 1.2
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, reference, schemas, types, ai]
---

# 12 — Reference Layer

This directory is the high-precision reference layer for engineers and AI agents. Architecture documents explain **why** the system is shaped the way it is; this layer answers **which concrete contract, type, test or schema owns a fact**.

## Documents

- [Schema & Migration Registry](schema-migration-registry.md) — persisted formats, version keys, compatibility rules and migration ownership.
- [Core Type Reference](core-type-reference.md) — responsibilities and boundaries of the most important production types.
- [Generated Type → Tests → Docs Map](generated-type-test-doc-map.md) — CI-checked deterministic route from important types to source, verification and canonical docs.
- [Operations Boundary](operations-boundary.md) — what belongs in this public repository versus the private operational documentation vault.

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

## Rule for persisted data

Before changing any stored key, Codable structure, file format, Keychain identity, telemetry payload or collector database shape, read [Schema & Migration Registry](schema-migration-registry.md). A schema change is not a local implementation detail: compatibility, backup/restore, privacy and downgrade/upgrade behavior must be considered explicitly.

## Source of truth

Reference documents do not override code/tests/CI. Their purpose is to make verified ownership and compatibility constraints discoverable. If implementation and reference disagree, determine the real contract from code + tests + CI and update the stale reference in the same change set.
