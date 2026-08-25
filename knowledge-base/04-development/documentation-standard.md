---
title: Documentation Standard
type: development-standard
status: active
documentation_version: 1.5
app_version: 1.4.15
last_reviewed: 2026-08-25
tags: [impuls, documentation, obsidian, ai]
---

# Documentation Standard

## Формат

Knowledge base — Markdown-first Obsidian-compatible vault. Используются стандартные relative Markdown links, YAML frontmatter и Mermaid source прямо в Markdown.

## Обязательный frontmatter

Кроме корневого `README.md`, каждый knowledge-base Markdown document содержит:

```yaml
---
title: Human readable title
type: architecture
status: active
documentation_version: 1.4
app_version: 1.4.15
last_reviewed: 2026-08-24
tags: [impuls, ...]
---
```

Пример показывает текущий baseline, а не требование механически переписать старые deep-docs. Все семь ключей обязательны — их проверяет `Scripts/check-knowledge-base.py`.

### `type`

`type` описывает **вид документа**, а не тему. Это свободная строка: валидатор требует, чтобы ключ присутствовал, но не сверяет значение со списком. Так и задумано — vault растёт быстрее любого закрытого перечисления, и механическое расширение валидатора ради одного нового документа добавляет ceremony, не добавляя правды.

Правило вместо перечисления: **возьми `type` уже существующего документа того же вида**, а новый вводи только тогда, когда вида действительно ещё нет.

Практически используемые сегодня значения (для ориентира, не как whitelist):

| Вид | Значения |
| --- | --- |
| Тематические страницы | `module`, `architecture`, `security`, `reference`, `release`, `development`, `platform`, `web`, `operations`, `history` |
| Индексы разделов | `index`, `module-index`, `reference-index`, `decision-index`, `qa-index` |
| Решения | `decision`, `adr` |
| Baseline и статус | `status`, `project`, `project-baseline` |
| AI-слой | `ai-index`, `ai-rules`, `ai-reference`, `ai-map` |
| QA | `qa-reference`, `qa-evidence`, `qa-evidence-template` |
| Генерируемые файлы | `generated-reference`, `generated-history` |
| Прочее специализированное | `development-standard`, `development-sop`, `security-reference`, `architecture-diagrams`, `presentation-module`, `known-limitations` |

Смысл поля — навигация и фильтрация в Obsidian/скриптах: по `type` видно, читать документ как контракт, как индекс, как исторический след или как машинно-сгенерированный артефакт. Документ, который нельзя честно отнести ни к одному существующему виду, скорее всего должен быть частью существующего документа.

### `status`

`status` описывает жизненный цикл: `active` — текущий контракт; `production` — описывает работающую production-поверхность; `accepted` — принятое ADR-решение; `historical` — сохранено как evidence, не как current state; `draft` — ещё не контракт.

### Версии и сверка

`app_version` — версия продукта, на которой документ был фактически сверён. Только baseline entrypoints — `knowledge-base/INDEX.md`, `00-project/project-status.md`, `10-ai/AI-INDEX.md`, `12-reference/README.md`, `13-qa/README.md` — обязаны совпадать с `Scripts/version`; их список зафиксирован в checker'е. Historical/deep documents обновляют review metadata при реальной сверке, а не механически.

`documentation_version` — версия самого стандарта документации. Текущий baseline **1.4** применяется к baseline entrypoints; deep-doc сохраняет предыдущую documentation version, пока его фактически не пересмотрели под новый стандарт.

**Старый `app_version` в deep-doc сам по себе не drift.** Drift — когда active/current документ утверждает, что старая версия является текущей, ссылается на удалённый route/workflow, даёт устаревший owner/locale set или иначе противоречит code/tests/CI. Историческое «эта функция появилась в 1.4.12» должно оставаться историческим фактом.

**`last_reviewed` ставится на UTC-день репозитория, а не на локальный день автора.** `check-documentation-freshness.py` сравнивает дату с `date.today()` на CI-раннере, который работает в UTC. Автор восточнее UTC, правящий документ вечером, локально видит уже следующее число — и такая дата отвергается как «in the future», хотя сверка действительно произошла. Проверяйте `date -u`, а не `date`. Это соглашение, а не обход проверки: правило «дата ревью не может быть в будущем» остаётся в силе.

Обратная сторона того же расхождения календарей решена в самом freshness checker: документ, попавший в один коммит со своим tracked source, дату не сверяет вовсе — они уехали вместе, и историческому разрыву взяться неоткуда.

## Current-state / cold-start entrypoints

Некоторые файлы опаснее обычного deep-doc, потому что их читают **до** того, как агент нашёл canonical owner:

- `AGENTS.md`;
- `CLAUDE.md`;
- `PROJECT-MANIFEST.json`;
- `knowledge-base/README.md` и baseline indexes/status;
- публичные `README.md` / `README.ru.md`;
- root `PRIVACY.md` / `SECURITY.md`;
- locale registry и public privacy routes.

Для таких входных точек действует отдельное правило: **не копировать mutable current fact, если можно маршрутизировать к владельцу**. Например, точный релиз принадлежит `Scripts/version`, module set — `AppFeatureCatalog`, website path — locale registry, а production topology — private operations source. Когда entrypoint всё-таки обязан показать current fact пользователю (например, число языков в README), он должен быть machine-checkable против source of truth.

`Scripts/check-current-documentation.py` — focused guard для этого слоя. Он сейчас проверяет:

- отсутствие duplicate current-release database в AGENTS/KB overview/readme entrypoints;
- app locale set по `Resources/*.lproj`, `AppLanguageService` и `CFBundleLocalizations`;
- текущую parity app/website/legal locale sets на baseline, включая registry-owned `zh-Hans` paths;
- наличие canonical localization/legal routes в manifest/AI/Claude entrypoints;
- `/privacy/` как canonical public policy route вместо legacy `/site-privacy.html`;
- текущий locale count/privacy route в public EN/RU README;
- ключевые stale-patterns, уже вызывавшие реальные drift incidents (RU/EN-only module routing, version-anchored current invariants, Release QA Evidence omission).

Guard намеренно **не сканирует все исторические release/audit docs на старые версии**: это уничтожило бы доказательную ценность истории. Новый assertion добавляется, когда реальный drift показывает повторяемый класс ошибки; checker не должен превращаться в repository-wide grep случайных слов.

## Module docs

Обязательные темы: назначение; user contract; data/control flow; source map; state; persistence; permissions; network; lifecycle/performance; invariants; validation/change checklist.

## Схемы

Mermaid diagram должна объяснять ownership/data/control/trust flow. Source хранится в `.md`; не экспортировать параллельный PNG/SVG без отдельной причины, иначе возникает второй источник истины.

## Links

Для repository content используются relative Markdown links. Obsidian-only `[[wikilinks]]` не являются основным форматом, потому что GitHub и coding agents должны разрешать те же references.

## Automated validation

Документация защищается несколькими слоями, которые отвечают на разные вопросы:

1. `Scripts/check-project-manifest.py` — существует ли routing и совпадает ли stable topology с machine owners;
2. `Scripts/check-current-documentation.py` — не устарели ли mutable cold-start/public facts/routes;
3. `Scripts/check-knowledge-base.py` — корректны ли Markdown/frontmatter/baseline metadata/links/fences;
4. `Scripts/generate-knowledge-map.py --check` — совпадает ли curated source→tests→docs ownership;
5. `Scripts/check-documentation-guardian.py --base <base-sha>` — вызвал ли diff обязательный semantic doc review;
6. `Scripts/check-documentation-freshness.py` — не стал ли curated canonical owner исторически старее tracked source;
7. `Scripts/check-qa-impact.py --base <base-sha>` — какие Behavioral QA contracts затронуты source/test diff;
8. `Scripts/check-release-qa-evidence.py --release-gate` — есть ли truthful version-specific manual/mixed evidence и разрешено ли shipping decision.

`.github/workflows/knowledge-base.yml` запускает эти checks по релевантным source/doc/agent/public-policy/locale paths. Он также имеет weekly scheduled freshness run с review-age policy.

Ни один слой не заменяет другой: syntactically valid Markdown может быть семантически stale; свежий canonical doc может не отражать manual hardware result; old historical evidence может быть корректным и не нуждаться в version bump.

## Актуальность

При конфликте сначала устанавливается фактический contract по code + tests + CI и актуальному repository/release state, затем canonical owner определяется через `Scripts/agent-context.py`, а при `UNROUTED` — через AI Index. Исправляется canonical doc **и** stale current entrypoint, если он дублировал факт. Historical release note не становится current documentation только потому, что она детальнее.

Если drift обнаружен в cold-start/public файле и класс ошибки можно проверить детерминированно, исправление должно рассмотреть новый assertion в `check-current-documentation.py`, а не надеяться, что следующий агент запомнит инцидент.

## ADR

ADR требуется для долгоживущих изменений ownership, networking, persistence/security boundary, release trust chain или platform-level policy. Добавление validation checker само по себе не требует ADR, если оно лишь машинно фиксирует уже существующий source-of-truth contract.

## Change rule

Code changes → docs changes, если изменён documented contract. Stable routing change → manifest/AI route changes. Public/current fact change → соответствующий entrypoint + current-documentation assertion, когда факт machine-checkable. `last_reviewed` нельзя обновлять автоматически без фактической сверки содержимого.
