---
title: IMPULS AI Index
type: ai-index
status: active
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, ai, agents, index]
---

# IMPULS AI Documentation Index

## Обязательный старт

Перед изменением проекта: `AGENTS.md` → этот индекс → relevant subsystem docs → code/tests/CI. Старые handoff/release docs используются как history, не как current source of truth.

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

## Routing

### UI / panel / display
Read state ownership → multi-display → `Theme.swift` → relevant Notch/UI code → tests.

### Module
Read exact page in `02-modules/` → store/service + pane + tests. If data/permission/network changes, include security/threat docs.

### Settings / onboarding / feedback
Read subsystem page + SettingsStore/Onboarding/Feedback implementation. Do not turn Feedback into an implicit network client.

### Persistence
Read storage-persistence + data-classification + affected module. Prove tests cannot touch live user storage.

### Permission
Read permission architecture + macOS TCC + public privacy/security docs.

### Network
Read networking + ADR-003 + threat model. Current model has exactly three Internet network owners.

### Release/signing
Read signing/distribution + release pipeline + update system + ADR-005 + workflows.

### Website
Read website page + `.claude/rules/website.md`; preserve release sync, RU/EN static SEO and theme constraints.

### Version statistics infrastructure
Read collector page + Collector README/code + privacy boundary. Never commit operational secrets/private topology.

### Power/devices
Read power page + ADR-004 + historical Apple device support/QA when hardware detail matters.

## Trust rule

При конфликте сначала code + tests + CI. Затем исправь knowledge base. Documentation describes verified reality and rationale.
