---
title: Project Status
type: status
status: active
documentation_version: 1.2
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, status, current]
---

# Текущее состояние проекта

## Baseline

**Current `main` product baseline: 1.4.11.** Источник версии — `Scripts/version`.

**Current documentation baseline: 1.2.**

## Current product surface

- native macOS 15+ Swift/SwiftUI-on-AppKit application;
- 9 panel modules;
- one shared service graph + per-display presentation surfaces;
- configurable Menu Bar workspace;
- onboarding / What's New;
- local backup/restore for portable settings + snippets + notes;
- opt-in signed Sparkle updates;
- separate opt-in version statistics;
- Power/Battery center with explicitly enabled external Apple devices;
- RU/EN localization.

## Documentation coverage 1.2

The knowledge base contains:

- application lifecycle, state ownership and multi-display architecture;
- storage/persistence, permissions and networking boundaries;
- Mermaid system/data/release/security diagrams;
- detailed pages for all 9 modules plus Menu Bar;
- macOS TCC and signing/distribution;
- build/test/module-development SOPs;
- update/release pipeline;
- threat model, data classification and privacy boundaries;
- ADR-001…005;
- AI routing and change-impact matrix;
- formal schema/migration registry;
- core type ownership reference;
- CI-checked generated Type → Tests → Docs map;
- formal split between public software documentation and private production operations documentation.

## Current architectural anchors

1. one `NotchViewModel` per process;
2. exactly one active display surface;
3. three Internet network owners;
4. sensitive permission prompts only after explicit user action;
5. local-first content and bounded reads;
6. raw device identities never cross presentation/privacy boundary;
7. signed update verification independent of Apple Developer ID availability;
8. persisted-format changes require explicit compatibility/migration review;
9. public app/software facts and private production runtime facts have separate canonical owners.

## Documentation automation

Two checks now protect documentation drift:

```text
Scripts/check-knowledge-base.py
Scripts/generate-knowledge-map.py --check
```

The first validates Markdown/frontmatter/local links/fenced diagrams/baseline metadata. The second verifies the committed source→tests→docs reference against the curated manifest and actual repository files.

## Current known schema debt

Collector SQLite DDL is currently idempotent but does not yet have an explicit database schema version. No incompatible collector DB change should ship until a formal migration/version mechanism is introduced and tested. See [Schema & Migration Registry](../12-reference/schema-migration-registry.md).

## Operational documentation

Production telemetry runtime/topology is intentionally not duplicated here. The private infrastructure vault owns current host/network/service/backup/dashboard operational facts; this repository owns the software contract. See [Public / Private Operations Boundary](../12-reference/operations-boundary.md).

## Next documentation work

Future documentation work should be driven by product changes rather than another broad rewrite. The v1.2 baseline is designed to make drift visible: new core ownership, persisted schemas and production-runtime changes now have explicit update paths and CI/reference checks.
