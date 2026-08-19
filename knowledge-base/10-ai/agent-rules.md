---
title: Agent Workflow
type: ai-rules
status: active
documentation_version: 1.0
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, ai, workflow, agents]
---

# Правила работы AI-агентов

## Перед изменением

1. Прочитать [`AGENTS.md`](../../AGENTS.md).
2. Прочитать [AI Index](AI-INDEX.md) и документы по области задачи.
3. Проверить текущую версию через `Scripts/version`, если версия имеет значение.
4. Найти implementation + tests, а не делать вывод только из README или старого handoff.
5. Для security-sensitive области сверить `SECURITY.md`, `PRIVACY.md` и CI invariants.

## Во время изменения

- сохранять существующие архитектурные границы;
- не добавлять dependency без явного обоснования;
- не добавлять сеть, permission, persistence или telemetry как побочный эффект UI-функции;
- не придумывать отсутствующие системные данные;
- не дублировать services для нескольких дисплеев;
- обновлять RU/EN локализацию совместно;
- добавлять/обновлять тесты вместе с изменением контракта.

## Документация как часть задачи

Если изменился:

- shipped feature catalog → обновить `02-modules/README.md`;
- структура/ownership → обновить architecture/repository map;
- текущий baseline → обновить `00-project/project-status.md`;
- security/privacy boundary → обновить security model и релевантные публичные документы;
- release flow → обновить release process;
- долгосрочное решение → создать ADR.

## Перед завершением

Проверить:

- тесты релевантной области;
- полный release test suite согласно текущим repo instructions;
- localization parity при изменении строк;
- отсутствие незапланированного network/permission impact;
- `git diff` на случайные изменения;
- knowledge-base links и актуальность изменённых документов.

## Работа с противоречиями

Если этот vault, README, старый release note и код расходятся:

1. не выбирать самый удобный источник;
2. определить фактическое поведение по code/tests/CI и текущему release state;
3. проверить, не является ли расхождение осознанным историческим контекстом;
4. исправить устаревший current-state документ;
5. при существенном расхождении зафиксировать причину в PR.

## Что нельзя утверждать без проверки

- текущую версию;
- наличие Developer ID/notarization;
- текущего владельца production endpoint;
- точное число тестов;
- текущую поддержку конкретного hardware;
- успешность последнего GitHub Actions run.

Эти факты меняются со временем и должны читаться из актуального repository/release/CI состояния.
