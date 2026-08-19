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

## Core

- [Current Project Status](../00-project/project-status.md)
- [Project Overview](../00-project/project-overview.md)
- [Architecture Overview](../01-architecture/architecture-overview.md)
- [Application Lifecycle](../01-architecture/application-lifecycle.md)
- [State and Ownership](../01-architecture/state-and-ownership.md)
- [System Diagrams](../01-architecture/system-diagrams.md)
- [Module Catalog](../02-modules/README.md)
- [Security Model](../06-security/security-model.md)
- [Threat Model](../06-security/threat-model.md)
- [Release Pipeline](../05-release/release-pipeline.md)
- [ADRs](../08-decisions/README.md)
- [Repository Map](repository-map.md)
- [Project Invariants](invariants.md)
- [Change Impact Matrix](change-impact-matrix.md)
- [Agent Rules](agent-rules.md)

## По типу задачи

### UI / panel / display

Read: state ownership → multi-display → Theme.swift → relevant Notch/UI files → tests.

### Module

Read exact page in `02-modules/`, then store/service + pane + tests. If data/permission/network changes, also read security/threat docs.

### Persistence

Read storage-persistence + data-classification + affected module. Verify test environment cannot touch live user storage.

### Permission

Read permission architecture + macOS TCC page + public privacy/security docs.

### Network

Read networking + ADR-003 + threat model. Current model has exactly three Internet network owners.

### Release/update

Read release pipeline + update system + ADR-005 + build/release workflows.

### Power/devices

Read power page + ADR-004 + historical Apple device support/QA docs where hardware details matter.

## Trust rule

При конфликте сначала code + tests + CI. Затем исправь knowledge base. Документация описывает фактический контракт и причины, а не заменяет проверку реализации.
