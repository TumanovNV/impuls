---
title: IMPULS AI Index
type: ai-index
status: active
documentation_version: 1.0
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, ai, agents, index]
---

# IMPULS AI Documentation Index

## Для AI-агента

Перед изменением проекта прочитай этот файл, затем обязательные [`AGENTS.md`](../../AGENTS.md) и инструкции конкретного инструмента. Не считай старый release/handoff документ текущим состоянием только потому, что он подробнее нового.

## Быстрый контекст

- [Что такое ИМПУЛЬС](../00-project/project-overview.md)
- [Текущий baseline](../00-project/project-status.md)
- [Архитектура](../01-architecture/architecture-overview.md)
- [Каталог shipped-модулей](../02-modules/README.md)
- [Security boundaries](../06-security/security-model.md)
- [Release process](../05-release/release-process.md)
- [ADR](../08-decisions/README.md)
- [Repository map](repository-map.md)
- [Hard project invariants](invariants.md)
- [Agent workflow](agent-rules.md)

## Порядок чтения по типу задачи

### UI / panel / multi-display

1. `AGENTS.md`;
2. [Architecture Overview](../01-architecture/architecture-overview.md);
3. [Invariants](invariants.md);
4. `Sources/Impuls/UI/Theme.swift`;
5. relevant `Sources/Impuls/Notch/*` and pane;
6. historical `docs/IMPULS_1_4_7_MULTI_DISPLAY.md`, если нужен контекст multi-display decisions.

### Модуль / service

1. [Module Catalog](../02-modules/README.md);
2. [Repository Map](repository-map.md);
3. store/service + corresponding pane + tests;
4. [Security Model](../06-security/security-model.md), если есть data/permission/network impact.

### Release / updates / dependencies

1. [Release Process](../05-release/release-process.md);
2. [Security Model](../06-security/security-model.md);
3. `AGENTS.md` hard invariants;
4. `.github/workflows/build.yml` and `release.yml`;
5. `Scripts/bundle.sh`, `Scripts/dmg.sh`, `UpdateService.swift` as relevant.

### Privacy / telemetry / device identity

1. `PRIVACY.md`;
2. `SECURITY.md`;
3. [Security Model](../06-security/security-model.md);
4. relevant implementation and tests;
5. latest relevant audit in `docs/audits/`.

## Правило доверия

При расхождении между знаниями и кодом не «подгоняй» код под этот документ автоматически. Сначала установи фактический контракт по code + tests + CI, затем исправь устаревший документ. Документация должна описывать реальность, а не создавать её задним числом.

## Definition of done для AI

Задача не считается полностью завершённой, если она изменила архитектурный контракт, но оставила knowledge base заведомо устаревшей.
