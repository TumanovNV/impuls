---
title: Agent Workflow
type: ai-rules
status: active
documentation_version: 1.3
app_version: 1.4.15
last_reviewed: 2026-08-25
tags: [impuls, ai, workflow, agents]
---

# Правила работы AI-агентов

## Context budget contract

Canonical owner of how much an agent should read. Measured problem: following the previous root instructions literally cost roughly **101 KB of documentation before a single Swift file was opened**, most of it irrelevant to a local change.

**Route first.** `python3 Scripts/agent-context.py <changed-path>` returns the domain, the canonical document, the owning source and tests, the Behavioral QA IDs and the conditional owners with their triggers. Read that, not the knowledge base.

**Rules**

1. Route before reading; targeted search before opening a file whole.
2. Never read all of `knowledge-base/`, all of `Sources/` or all of `Tests/` for a local task.
3. Historical material — `docs/` handoffs, `knowledge-base/11-history/` — is evidence on demand, never current state.
4. `pre-audit-baseline-1.4.12.md` is for an explicit whole-repository audit only.
5. `project-status.md` only when the shipped baseline actually matters.
6. Release documentation only for release work; `Scripts/version` owns the version.
7. Localization documentation when a user-facing string or the supported-language set is touched.
8. Persistence and schema owners when persisted data changes.
9. Security, networking and concurrency owners when that boundary is touched.
10. Do not re-read a canonical document already in context.
11. Stop expanding once the owner, the implementation and the tests are known.
12. `AI-INDEX.md` is a fallback for an unresolved route or broad exploration — not a cold-start step.

**Escape hatch — this is not optional.** The context budget **never** outranks correctness. If investigating the code reveals a boundary the route did not predict — a new outbound call, a new persisted key, a changed actor boundary, a new user-facing string, a release-affecting file — expand to that boundary's owner immediately and say so. Saving context is worth nothing if the change is wrong.

**Cross-domain diffs** escalate to the union of the affected domains and their conditional owners. They do not disable the budget and they are not a reason to read the whole knowledge base.


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
