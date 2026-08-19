---
title: IMPULS AI Index
type: ai-index
status: active
documentation_version: 1.3
app_version: 1.4.12
last_reviewed: 2026-08-19
tags: [impuls, ai, agents, index, qa]
---

# IMPULS AI Documentation Index

## Обязательный старт

Перед изменением проекта: `AGENTS.md` → root `PROJECT-MANIFEST.json` → этот индекс → relevant subsystem/reference docs → code/tests/CI. Manifest — routing-only; старые handoff/release docs используются как history, не как current source of truth.

## Core map

- [Current Status](../00-project/project-status.md)
- [Architecture](../01-architecture/architecture-overview.md)
- [System Diagrams](../01-architecture/system-diagrams.md)
- [Module Catalog](../02-modules/README.md)
- [Security Model](../06-security/security-model.md)
- [Dependency / Supply Chain](../06-security/supply-chain.md)
- [Release Pipeline](../05-release/release-pipeline.md)
- [Release Architecture Ledger](../11-history/release-architecture-ledger.md)
- [Collector](../07-web/version-statistics-collector.md)
- [Current Limitations](../09-known-issues/current-limitations.md)
- [ADRs](../08-decisions/README.md)
- [Change Impact Matrix](change-impact-matrix.md)
- [Documentation Guardian](documentation-guardian.md)

## Precision reference layer

- [Machine-Readable Project Manifest](../12-reference/project-manifest.md)
- [Reference Index](../12-reference/README.md)
- [Schema & Migration Registry](../12-reference/schema-migration-registry.md)
- [Core Type Reference](../12-reference/core-type-reference.md)
- [Generated Type → Tests → Docs Map](../12-reference/generated-type-test-doc-map.md)
- [Background Work & Concurrency Registry](../12-reference/background-concurrency-registry.md)
- [Input & Resource Budget Registry](../12-reference/resource-budget-registry.md)
- [Public / Private Operations Boundary](../12-reference/operations-boundary.md)
- [Behavioral QA Matrix](../13-qa/behavioral-qa-matrix.md)
- [Behavioral QA Change Impact Traceability](../13-qa/change-impact-traceability.md)
- [Release QA Evidence](../13-qa/release-evidence/README.md)

## Routing

### Module
Read exact module page → generated type map → source + mapped tests. Include schema/permission/network/performance/security docs when those contracts change. Before finishing a behavioral source/test diff, run QA impact traceability against the real PR base and review the reported scenario IDs.

### Performance / concurrency / background work
Read Background Work & Concurrency Registry before timers, pollers, debounce/retry, Tasks, observers/sockets or queue/actor changes. For limits/timeouts/backpressure also read Resource Budget Registry. Then use the QA impact checker to see which behavioral contracts inherit the change.

### Persistence / backup / Keychain
Read Schema & Migration Registry first. Compatibility/migration, backup inclusion/exclusion and test isolation must be explicit. Review mapped `DATA-*`/release QA impact after implementation changes.

### Dependency / Package.swift / Package.resolved
Read Supply-Chain Policy + `Scripts/dependency-policy.json` + package files. Every resolved remote Swift package must be approved; direct dependencies use exact versions. Run `python3 Scripts/check-dependency-policy.py`.

### Permission
Read permissions + TCC + Behavioral QA + QA Impact Traceability + public privacy/security docs. Prompts remain explicit/user-contextual. If the task prepares or certifies a release, record the actual TCC result in that version's Release QA Evidence file; the matrix or impact report alone is never pass evidence.

### Network
Read networking + ADR-003 + threat model. Exactly three Internet network owners are established. A fourth is an architecture/security change. If the network change has user-visible service/lifecycle behavior, add or update the appropriate Behavioral QA row and impact route.

### Release/signing
Read signing/distribution + release pipeline + update system + ADR-005 + supply chain + Behavioral QA + QA Impact Traceability + Release QA Evidence. A version bump must travel with `docs/releases/<version>.md` **and** `knowledge-base/13-qa/release-evidence/<version>.md`. Starting with 1.4.12, historical `not-recorded` is forbidden: every manual/mixed scenario must have a truthful result and environment/gap classification.

Run both gates against the real base before calling the candidate ready:

```bash
python3 Scripts/check-qa-impact.py --base <base-sha>
python3 Scripts/check-release-qa-evidence.py --release-gate
```

The first tells you which QA IDs the diff may have affected and confirms impacted non-automated IDs are represented in candidate evidence. The second owns the actual shipping decision. Never convert green unit tests into manual hardware/TCC passes.

If the release changes a durable architecture/privacy/security/performance/ownership contract, also add an entry to `Scripts/architecture-milestones.json`, regenerate the Release Architecture Ledger and create/update an ADR when warranted.

### Version comparison / historical reason
Use [Release Architecture Ledger](../11-history/release-architecture-ledger.md) for the evidence chain release → durable impact → canonical current docs → ADR → release note. Use Release QA Evidence for the independent chain release → real environment → manual result → known gap/decision. Release notes remain user-facing detail, not current architecture or test truth.

### Version statistics production runtime
Current production runtime belongs to the private infrastructure vault. If connected and current-state is required, start from `office-it-docs: Проекты/Impuls.md`; otherwise mark runtime facts unverified.

### Core type ownership change
Update `Scripts/knowledge-map-manifest.json`, regenerate the type map and run `--check`.

### Canonical documentation mapping change
Consider whether `Scripts/documentation-freshness.json` must track a new high-risk owner.

### New behavioral edge
Add/update a Behavioral QA row when deterministic unit tests cannot fully prove a new platform/hardware/TCC/lifecycle path. Then add that ID to the correct source/test rule in `Scripts/qa-impact-rules.json`. The QA impact configuration validator requires every current matrix ID to have a route, and every automated ID to have a mapped test route. Review the current release evidence candidate too: adding a manual/mixed row creates a new evidence obligation. Documentation is not pass evidence.

### Behavioral owner/source change
Read [Behavioral QA Change Impact Traceability](../13-qa/change-impact-traceability.md). A changed tracked production file that matches no QA rule fails closed. Add the correct rule or, only when another explicit verification contract owns the area, a narrow documented exemption. Never add a broad `Sources/**` exemption.

## Trust rule

При конфликте сначала code + tests + CI. Затем исправь knowledge base. For historical architecture questions use the generated ledger as routing evidence, then verify the linked release/canonical sources. For change-impact claims use the machine-readable QA impact map plus the actual Git diff. For release certification claims require the version-specific QA evidence record rather than inferring a pass from tests, screenshots, the impact report or the scenario inventory.
