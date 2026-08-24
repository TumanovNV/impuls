---
title: Machine-Readable Project Manifest
type: reference
status: active
documentation_version: 1.4
app_version: 1.4.15
last_reviewed: 2026-08-24
tags: [impuls, ai, manifest, routing, automation]
---

# Machine-Readable Project Manifest

Root [`PROJECT-MANIFEST.json`](../../PROJECT-MANIFEST.json) is the fastest machine-readable routing map for Claude, Codex and other coding agents.

It is deliberately **routing-only**. The manifest tells an agent where to look; it does not copy implementation facts that already have a canonical owner.

## What it contains

- product/package/version entrypoints;
- canonical app-localization documentation route;
- the 9 shipped module IDs, their canonical module docs and core source owners;
- panel and Menu Bar presentation owners;
- the explicit three Internet network owners;
- permission-domain routes;
- persistence, performance and security reference routes;
- release/workflow routes;
- website architecture, website legal/privacy, locale-registry and collector routes;
- the public/private operations boundary;
- the commands/paths that validate the engineering knowledge system.

The localization/legal additions are deliberate cold-start routes. They do **not** copy the current language list into the manifest. The actual app locale set belongs to resources/bundle/AppLanguageService; the public website locale/path set belongs to `Scripts/site-locales/registry.json`; legal copy belongs to the legal locale configs.

## What it intentionally does not contain

- a copied application version number;
- a copied list of localization codes;
- persisted keys or schema field lists;
- timer intervals and input/resource limits;
- live endpoint URLs or hostnames;
- production IP/VPN/reverse-proxy/service state;
- credentials, tokens or secrets.

Those facts would turn the routing map into another drift-prone database. Version comes from `Scripts/version`; schemas come from the Schema Registry and code; locale sets come from their canonical sources; performance numbers come from the performance registries; production runtime belongs to the private operational source of truth.

## CI guarantees

`Scripts/check-project-manifest.py` verifies:

1. every public repository path referenced by the manifest exists;
2. the manifest module IDs equal the actual shipped IDs parsed from `AppFeatureCatalog`;
3. the Internet owner set remains exactly the established three-owner contract;
4. the localization route points to `knowledge-base/04-development/localization.md`;
5. website legal/privacy and locale-registry routes point to their canonical owners;
6. the version source still contains `VERSION=x.y.z`;
7. the public manifest does not contain a raw IPv4 address;
8. the private operations route remains a textual cross-repository pointer, not copied runtime topology.

`Scripts/check-current-documentation.py` then uses those routes together with actual resource/registry/config sources to verify the high-value current documentation/agent context. Both checkers have focused Python tests and run in the `knowledge-base` GitHub Actions workflow.

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

Language task shortcut:

```text
PROJECT-MANIFEST.product.localization_doc
  ↓
knowledge-base/04-development/localization.md
  ├── app resources / AppLanguageService / bundle
  ├── Website Architecture + locale registry
  └── Website Legal and Privacy Localization
```

For an already-known symbol, the generated Type → Tests → Docs map remains more precise. For a persisted-format change, the Schema Registry remains mandatory. For background/performance work, use the Background/Concurrency and Resource Budget registries.

## Change rule

Update `PROJECT-MANIFEST.json` only when **stable topology or ownership/routing** changes: a shipped module is added/removed, a canonical owner moves, a network owner is intentionally changed, a new permission domain appears, a durable localization/web/legal canonical route is added/moved, or another major repository route changes.

Do not edit the manifest for ordinary implementation details or to copy values already owned elsewhere. Do not weaken either manifest validation or current-documentation validation to make an architectural/documentation drift look routine.
