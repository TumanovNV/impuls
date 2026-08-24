---
title: Agent Workflow
type: ai-rules
status: active
documentation_version: 1.2
app_version: 1.4.15
last_reviewed: 2026-08-24
tags: [impuls, ai, workflow, agents]
---

# Правила работы AI-агентов

## Перед изменением

1. Прочитать [`AGENTS.md`](../../AGENTS.md).
2. Прочитать root [`PROJECT-MANIFEST.json`](../../PROJECT-MANIFEST.json), затем [AI Index](AI-INDEX.md) и документы по области задачи.
3. Проверить текущую версию через `Scripts/version`, если версия имеет значение; не копировать current release из исторического документа.
4. Найти implementation + tests, а не делать вывод только из README или старого handoff.
5. Для security-sensitive области сверить `SECURITY.md`, `PRIVACY.md` и CI invariants.
6. Для language rollout сначала прочитать [Localization](../04-development/localization.md): app, marketing website и legal/privacy website — три отдельных контракта.

## Во время изменения

- сохранять существующие архитектурные границы;
- не добавлять dependency без явного обоснования;
- не добавлять сеть, permission, persistence или telemetry как побочный эффект UI-функции;
- не придумывать отсутствующие системные данные;
- не дублировать services для нескольких дисплеев;
- добавлять новый user-facing application string во **все** shipped application localization tables одним change set — таблицы обнаруживаются `Scripts/check-localization.py` по `Resources/*.lproj/`;
- не считать новый `.lproj` автоматически website/legal локалью и наоборот;
- generated website/privacy HTML не редактировать напрямую: идти через registry/config/template/generic builder владельца;
- добавлять/обновлять тесты вместе с изменением контракта.

## Документация как часть задачи

Если изменился:

- shipped feature catalog → обновить `02-modules/README.md` и `PROJECT-MANIFEST.json`;
- структура/ownership → обновить architecture/repository map и manifest route;
- текущий baseline → обновить `00-project/project-status.md`; точная версия всё равно принадлежит `Scripts/version`;
- app language set → обновить app localization contract и проверить website/legal intent;
- website locale/routing → обновить Website Architecture/registry и focused site CI;
- privacy/legal locale/policy → обновить Website Legal and Privacy Localization, `PRIVACY.md` when public product commitments change, legal configs/metadata и focused legal CI;
- security/privacy boundary → обновить security model и релевантные публичные документы;
- release flow → обновить release process/pipeline и Release QA contract;
- новый canonical route → обновить `PROJECT-MANIFEST.json`, AI Index и при необходимости cold-start agent entrypoints;
- долгосрочное решение → создать ADR.

## Перед завершением

Проверить:

- тесты релевантной области;
- полный release/build suite согласно текущим repo instructions;
- `python3 Scripts/check-current-documentation.py` для current-state/agent routing;
- полноту application localization tables при изменении строк (`python3 Scripts/check-localization.py`), а не «parity двух языков»;
- site/legal focused checks при изменении соответствующих контрактов;
- отсутствие незапланированного network/permission impact;
- `git diff` на случайные изменения;
- knowledge-base links и актуальность изменённых документов;
- QA impact/release evidence, когда diff или release этого требует.

## Работа с противоречиями

Если vault, agent entrypoint, README, public policy, старый release note и код расходятся:

1. не выбирать самый удобный источник;
2. определить фактическое поведение по code/tests/CI и current repository/release state;
3. проверить, не является ли расхождение осознанным историческим контекстом;
4. определить canonical owner факта через manifest/AI Index;
5. исправить устаревший current-state документ;
6. если drift возник в high-value entrypoint, добавить/усилить machine-check, чтобы класс ошибки не повторился;
7. при существенном расхождении зафиксировать причину в PR.

## Что нельзя утверждать без проверки

- текущую версию;
- наличие Developer ID/notarization у конкретного публичного артефакта;
- текущего владельца/адрес production endpoint;
- точное число тестов;
- текущую поддержку конкретного hardware;
- состав app/website/legal локализаций — они читаются из своих canonical sources и сверяются `check-current-documentation.py`, а не из памяти о прошлом релизе;
- успешность последнего GitHub Actions run.

Эти факты меняются со временем и должны читаться из актуального repository/release/CI состояния. Historical `app_version` в frontmatter deep-doc сам по себе не означает drift: это версия последней фактической сверки. Drift — когда активный документ утверждает устаревший current behavior/version/route.
