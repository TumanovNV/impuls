---
title: Project Status
type: status
status: active
documentation_version: 1.3
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, status, current]
---

# Текущее состояние проекта

## Baseline

**Current `main` product baseline: 1.4.11.** Источник версии — `Scripts/version`.

**Current documentation baseline: 1.3.**

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

## Documentation coverage 1.3

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
- formal split between public software documentation and private production operations documentation;
- background work / concurrency registry with cadence, cancellation and MainActor boundaries;
- centralized input/resource/cadence budgets;
- behavioral QA matrix for automated, real-macOS, hardware and service-dependent scenarios;
- semantic Documentation Guardian that detects contract-sensitive source diffs without canonical documentation review.

## Current architectural anchors

1. one `NotchViewModel` per process;
2. exactly one active display surface;
3. three Internet network owners;
4. sensitive permission prompts only after explicit user action;
5. local-first content and bounded reads;
6. raw device identities never cross presentation/privacy boundary;
7. signed update verification independent of Apple Developer ID availability;
8. persisted-format changes require explicit compatibility/migration review;
9. public app/software facts and private production runtime facts have separate canonical owners;
10. presentation surfaces must not multiply timers/providers/services;
11. slow disk/process/device I/O stays off the main actor;
12. performance limits and wake-up cadences are documented review contracts, not anonymous magic numbers.

## Documentation automation

Three checks protect documentation drift:

```text
Scripts/check-knowledge-base.py
Scripts/generate-knowledge-map.py --check
Scripts/check-documentation-guardian.py --base <base-sha>
```

The first validates Markdown/frontmatter/local links/fenced diagrams/baseline metadata. The second verifies the committed source→tests→docs reference against the curated manifest and actual repository files. The third inspects changed source lines for background/concurrency, resource-budget, persistence, networking and permission contracts and requires a matching canonical documentation review in the same diff.

The semantic Guardian is intentionally conservative: it does not pretend regex can understand architecture. Its job is to make high-risk changes impossible to overlook during an AI/PR workflow.

## Current known schema debt

Collector SQLite DDL is currently idempotent but does not yet have an explicit database schema version. No incompatible collector DB change should ship until a formal migration/version mechanism is introduced and tested. See [Schema & Migration Registry](../12-reference/schema-migration-registry.md).

## Operational documentation

Production telemetry runtime/topology is intentionally not duplicated here. The private infrastructure vault owns current host/network/service/backup/dashboard operational facts; this repository owns the software contract. See [Public / Private Operations Boundary](../12-reference/operations-boundary.md).

## Next documentation work

The broad documentation foundation is now in place. Future work should primarily happen as part of product changes. Useful next improvements are expanding the curated type/test map where new core owners appear, adding release-specific evidence for manual hardware/TCC rows, and implementing the already-documented formal collector DB migration mechanism before any incompatible telemetry database change.
