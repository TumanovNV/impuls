---
title: Machine-Readable Project Manifest
type: reference
status: active
documentation_version: 1.3
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, ai, manifest, routing, automation]
---

# Machine-Readable Project Manifest

Root [`PROJECT-MANIFEST.json`](../../PROJECT-MANIFEST.json) is the fastest machine-readable routing map for Claude, Codex and other coding agents.

It is deliberately **routing-only**. The manifest tells an agent where to look; it does not copy implementation facts that already have a canonical owner.

## What it contains

- product/package/version entrypoints;
- the 9 shipped module IDs, their canonical module docs and core source owners;
- panel and Menu Bar presentation owners;
- the explicit three Internet network owners;
- permission-domain routes;
- persistence, performance and security reference routes;
- release/workflow routes;
- website/collector routes;
- the public/private operations boundary;
- the commands that validate the engineering knowledge system.

## What it intentionally does not contain

- persisted keys or schema field lists;
- timer intervals and input/resource limits;
- live endpoint URLs or hostnames;
- production IP/VPN/reverse-proxy/service state;
- credentials, tokens or secrets;
- a copied application version number.

Those facts would turn the routing map into another drift-prone database. Version comes from `Scripts/version`; schemas come from the Schema Registry and code; performance numbers come from the performance registries; production runtime belongs to the private operational source of truth.

## CI guarantees

`Scripts/check-project-manifest.py` verifies:

1. every public repository path referenced by the manifest exists;
2. the manifest module IDs equal the actual shipped IDs parsed from `AppFeatureCatalog`;
3. the Internet owner set remains exactly the established three-owner contract;
4. the version source still contains `VERSION=x.y.z`;
5. the public manifest does not contain a raw IPv4 address;
6. the private operations route remains a textual cross-repository pointer, not copied runtime topology.

The checker has focused Python tests under `Tests/PythonTests/test_project_manifest.py` and runs in the `knowledge-base` GitHub Actions workflow.

## Agent usage

Recommended cold-start route:

```text
AGENTS.md
  ↓
PROJECT-MANIFEST.json
  ↓
knowledge-base/10-ai/AI-INDEX.md
  ↓
canonical subsystem/reference document
  ↓
source + mapped tests + CI
```

For an already-known symbol, the generated Type → Tests → Docs map remains more precise. For a persisted-format change, the Schema Registry remains mandatory. For background/performance work, use the Background/Concurrency and Resource Budget registries.

## Change rule

Update `PROJECT-MANIFEST.json` only when **stable topology or ownership** changes: a shipped module is added/removed, a canonical owner moves, a network owner is intentionally changed, a new permission domain appears, or a major repository route changes.

Do not edit the manifest for ordinary implementation details. Do not weaken the checker to make an architectural change look routine.
