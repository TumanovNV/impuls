---
title: IMPULS Knowledge Base
type: index
status: active
documentation_version: 1.0
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, documentation, knowledge-base, obsidian]
---

# IMPULS Knowledge Base v1.0

Эта папка — единая база знаний проекта ИМПУЛЬС. Она хранится рядом с кодом, версионируется Git и открывается в Obsidian как обычный Markdown-vault.

## Зачем она нужна

- единый источник истины для архитектуры, релизов, безопасности и продуктовых решений;
- быстрый вход в проект для ChatGPT, Claude Code, Codex и разработчиков;
- фиксация причин архитектурных решений через ADR;
- снижение риска, что код, README, релизные заметки и агентские инструкции разойдутся;
- сохранение истории проекта без смешивания с публичным сайтом в `docs/`.

## Где находится источник истины

- код: `Sources/`, `Tests/`, `Scripts/`, `.github/`;
- публичный сайт и исторические релизные материалы: `docs/`;
- база знаний проекта: `knowledge-base/`;
- обязательные правила для coding agents: `AGENTS.md` и `CLAUDE.md`;
- юридические и публичные обещания: `PRIVACY.md`, `SECURITY.md`.

## Начать здесь

1. [Главный индекс](INDEX.md)
2. [Текущее состояние проекта](00-project/project-status.md)
3. [Архитектура](01-architecture/architecture-overview.md)
4. [Модули](02-modules/README.md)
5. [Безопасность](06-security/security-model.md)
6. [Релизный процесс](05-release/release-process.md)
7. [Архитектурные решения](08-decisions/README.md)
8. [AI Index](10-ai/AI-INDEX.md)

## Правило актуальности

Любое изменение, которое меняет архитектуру, сетевые границы, разрешения, хранение данных, release flow или контракт модуля, должно сопровождаться обновлением соответствующего документа в `knowledge-base/`. Для нового принципиального решения создаётся ADR.

## Obsidian

В Obsidian можно открыть корень `knowledge-base/` как отдельный vault. Специальные плагины не обязательны: документация использует стандартный Markdown и относительные ссылки, поэтому остаётся совместимой с GitHub и AI-инструментами.
