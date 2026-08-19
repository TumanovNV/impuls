---
title: IMPULS AI Index
type: ai-index
status: active
documentation_version: 1.3
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, ai, agents, index]
---

# IMPULS AI Documentation Index

## Обязательный старт

Перед изменением проекта: `AGENTS.md` → root `PROJECT-MANIFEST.json` → этот индекс → relevant subsystem/reference docs → code/tests/CI. Manifest — routing-only; старые handoff/release docs используются как history, не как current source of truth.

## Core map

- [Current Status](../00-project/project-status.md)
- [Architecture](../01-architecture/architecture-overview.md)
- [Application Lifecycle](../01-architecture/application-lifecycle.md)
- [State and Ownership](../01-architecture/state-and-ownership.md)
- [System Diagrams](../01-architecture/system-diagrams.md)
- [Module Catalog](../02-modules/README.md)
- [Security Model](../06-security/security-model.md)
- [Threat Model](../06-security/threat-model.md)
- [Dependency / Supply Chain](../06-security/supply-chain.md)
- [Release Pipeline](../05-release/release-pipeline.md)
- [Website](../07-web/website.md)
- [Collector](../07-web/version-statistics-collector.md)
- [Current Limitations](../09-known-issues/current-limitations.md)
- [ADRs](../08-decisions/README.md)
- [Repository Map](repository-map.md)
- [Project Invariants](invariants.md)
- [Change Impact Matrix](change-impact-matrix.md)
- [Agent Rules](agent-rules.md)
- [Documentation Guardian](documentation-guardian.md)

## Precision reference layer — read when applicable

- [Machine-Readable Project Manifest](../12-reference/project-manifest.md)
- [Reference Index](../12-reference/README.md)
- [Schema & Migration Registry](../12-reference/schema-migration-registry.md)
- [Core Type Reference](../12-reference/core-type-reference.md)
- [Generated Type → Tests → Docs Map](../12-reference/generated-type-test-doc-map.md)
- [Background Work & Concurrency Registry](../12-reference/background-concurrency-registry.md)
- [Input & Resource Budget Registry](../12-reference/resource-budget-registry.md)
- [Public / Private Operations Boundary](../12-reference/operations-boundary.md)
- [Behavioral QA Matrix](../13-qa/behavioral-qa-matrix.md)

## Routing

### UI / panel / display
Read state ownership → multi-display → Background Work Registry → Behavioral QA Matrix → Core Type Reference → generated map → source/tests.

### Module
Read exact page in `02-modules/` → generated map for the owning type → store/service + pane + mapped tests. If data/permission/network/performance changes, include the corresponding reference/security docs.

### Performance / concurrency / background work
**Mandatory:** read Background Work & Concurrency Registry before a timer, poller, debounce, retry, `Task`, observer/socket, queue/actor boundary or closed-panel work. For size/count/cadence/timeout/backpressure changes also read Resource Budget Registry.

### Persistence / backup / Keychain
**Mandatory:** read Schema & Migration Registry first. Compatibility/migration, backup inclusion/exclusion and test isolation must be explicit.

### Dependency / Package.swift / Package.resolved
**Mandatory:** read [Dependency and Supply-Chain Policy](../06-security/supply-chain.md), `Scripts/dependency-policy.json`, `Package.swift` and `Package.resolved`. Every resolved remote Swift package must be explicitly approved. Direct dependencies use exact versions. A new package is an architecture/security change and may require an ADR.

Run `python3 Scripts/check-dependency-policy.py` plus normal Swift/security CI.

### Permission
Read permission architecture + macOS TCC + Behavioral QA Matrix + public privacy/security docs. Permission prompts remain user-contextual and explicit.

### Network
Read networking + ADR-003 + threat model. Current app model has exactly three Internet network owners. A fourth owner is an architectural/security change.

### Release/signing
Read signing/distribution + release pipeline + update system + ADR-005 + supply-chain policy + workflows + relevant REL QA rows.

### Website
Read website page + `.claude/rules/website.md`; preserve release sync, RU/EN static SEO and theme constraints.

### Version statistics software
Read collector page + schema registry + operations boundary + Collector README/code + tests. Never commit operational secrets/private topology.

### Version statistics production runtime
Current production host/network/service/backup/dashboard state belongs to the private infrastructure vault. If connected and current-state is required, start from `office-it-docs: Проекты/Impuls.md`. If unavailable, mark runtime/topology facts unverified rather than guessing.

### Power/devices
Read power page + ADR-004 + Background Work Registry + Resource Budget Registry + generated map + PWR QA rows. Device I/O stays off-main and external providers stay user-enabled.

### Core type ownership change
Update `Scripts/knowledge-map-manifest.json`, regenerate with `python3 Scripts/generate-knowledge-map.py`, commit the map and run `--check`.

### Canonical documentation mapping change
Consider whether `Scripts/documentation-freshness.json` must track a new high-risk canonical owner. It is curated, not a map of every Markdown file.

### New behavioral edge
Add/update a Behavioral QA row for a new user-visible failure/lifecycle/topology/TCC/hardware/update path that deterministic unit tests cannot fully prove. Documentation is not pass evidence.

## Trust rule

При конфликте сначала code + tests + CI. Затем исправь knowledge base. Documentation describes verified reality and rationale. For production infrastructure current-state, private operational documents own the fact.
