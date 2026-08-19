---
title: IMPULS AI Index
type: ai-index
status: active
documentation_version: 1.2
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, ai, agents, index]
---

# IMPULS AI Documentation Index

## Обязательный старт

Перед изменением проекта: `AGENTS.md` → этот индекс → relevant subsystem/reference docs → code/tests/CI. Старые handoff/release docs используются как history, не как current source of truth.

## Core map

- [Current Status](../00-project/project-status.md)
- [Architecture](../01-architecture/architecture-overview.md)
- [Application Lifecycle](../01-architecture/application-lifecycle.md)
- [State and Ownership](../01-architecture/state-and-ownership.md)
- [System Diagrams](../01-architecture/system-diagrams.md)
- [Module Catalog](../02-modules/README.md)
- [Settings/Onboarding/Feedback](../01-architecture/settings-onboarding-feedback.md)
- [Security Model](../06-security/security-model.md)
- [Threat Model](../06-security/threat-model.md)
- [Release Pipeline](../05-release/release-pipeline.md)
- [Website](../07-web/website.md)
- [Collector](../07-web/version-statistics-collector.md)
- [Current Limitations](../09-known-issues/current-limitations.md)
- [ADRs](../08-decisions/README.md)
- [Repository Map](repository-map.md)
- [Project Invariants](invariants.md)
- [Change Impact Matrix](change-impact-matrix.md)
- [Agent Rules](agent-rules.md)

## Precision reference layer — read when applicable

- [Reference Index](../12-reference/README.md)
- [Schema & Migration Registry](../12-reference/schema-migration-registry.md)
- [Core Type Reference](../12-reference/core-type-reference.md)
- [Generated Type → Tests → Docs Map](../12-reference/generated-type-test-doc-map.md)
- [Public / Private Operations Boundary](../12-reference/operations-boundary.md)

The generated map is the fastest path from an important production type to source, mapped tests and canonical docs. It is checked by CI against `Scripts/knowledge-map-manifest.json`.

## Routing

### UI / panel / display

Read state ownership → multi-display → Core Type Reference → generated map → `Theme.swift` / relevant Notch/UI code → mapped tests.

### Module

Read exact page in `02-modules/` → generated map for the owning type → store/service + pane + mapped tests. If data/permission/network changes, include schema/security/threat docs.

### Settings / onboarding / feedback

Read subsystem page + [Schema & Migration Registry](../12-reference/schema-migration-registry.md) + SettingsStore/Onboarding/Feedback implementation. Do not turn Feedback into an implicit network client.

### Persistence / backup / Keychain

**Mandatory:** read [Schema & Migration Registry](../12-reference/schema-migration-registry.md) before editing. Then storage-persistence + data-classification + affected module + migration/storage tests.

A persisted-format change is not complete until compatibility/migration behavior, backup inclusion/exclusion and test isolation are explicit.

### Permission

Read permission architecture + macOS TCC + public privacy/security docs. Permission prompts must remain user-contextual and explicit.

### Network

Read networking + ADR-003 + threat model. Current app model has exactly three Internet network owners. A fourth owner is an architectural/security change, not an ordinary implementation detail.

### Release/signing

Read signing/distribution + release pipeline + update system + ADR-005 + workflows.

### Website

Read website page + `.claude/rules/website.md`; preserve release sync, RU/EN static SEO and theme constraints.

### Version statistics software

Read collector page + schema registry + operations boundary + Collector README/code + tests. Never commit operational secrets/private topology.

### Version statistics production runtime

Current production host/network/service/backup/dashboard state belongs to the private infrastructure vault, not this repository.

If `TumanovNV/office-it-docs` is connected and the task explicitly requires runtime current-state, start from:

```text
office-it-docs: Проекты/Impuls.md
```

Then follow that vault's navigation/source-of-truth rules.

If the private vault is unavailable, mark runtime/topology facts as **unverified** rather than guessing from source defaults or historical public audits.

### Power/devices

Read power page + ADR-004 + generated map + historical Apple-device support/QA when hardware detail matters.

### Core type ownership change

1. Read [Core Type Reference](../12-reference/core-type-reference.md).
2. Edit `Scripts/knowledge-map-manifest.json` if ownership/source/test/doc mapping changes.
3. Run `python3 Scripts/generate-knowledge-map.py`.
4. Commit the generated map.
5. Run `python3 Scripts/generate-knowledge-map.py --check` plus normal tests/CI.

## Trust rule

При конфликте сначала code + tests + CI. Затем исправь knowledge base. Documentation describes verified reality and rationale.

For production infrastructure current-state, private operational documents own the fact. Do not copy private current-state into this public knowledge base merely to make AI navigation easier.
