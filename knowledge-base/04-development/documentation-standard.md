---
title: Documentation Standard
type: development-standard
status: active
documentation_version: 1.2
app_version: 1.4.14
last_reviewed: 2026-08-21
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
documentation_version: 1.3
app_version: 1.4.14
last_reviewed: 2026-08-21
tags: [impuls, ...]
---
```

Все семь ключей обязательны — их проверяет `Scripts/check-knowledge-base.py`.

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

`documentation_version` — версия самого стандарта документации; текущий baseline `1.3` проверяется checker'ом у тех же baseline entrypoints.

**`last_reviewed` ставится на UTC-день репозитория, а не на локальный день автора.** `check-documentation-freshness.py` сравнивает дату с `date.today()` на CI-раннере, который работает в UTC. Автор восточнее UTC, правящий документ вечером, локально видит уже следующее число — и такая дата отвергается как «in the future», хотя сверка действительно произошла. Проверяйте `date -u`, а не `date`. Это соглашение, а не обход проверки: правило «дата ревью не может быть в будущем» остаётся в силе, и ослаблять его в checker'е ради одного часового пояса не нужно.

Обратная сторона того же расхождения календарей решена в самом checker'е: документ, попавший в один коммит со своим tracked source, дату не сверяет вовсе — они уехали вместе, и историческому разрыву взяться неоткуда.

## Module docs

Обязательные темы: назначение; user contract; data/control flow; source map; state; persistence; permissions; network; lifecycle/performance; invariants; validation/change checklist.

## Схемы

Mermaid diagram должна объяснять ownership/data/control/trust flow. Source хранится в `.md`; не экспортировать параллельный PNG/SVG без отдельной причины, иначе возникает второй источник истины.

## Links

Для repository content используются relative Markdown links. Obsidian-only `[[wikilinks]]` не являются основным форматом, потому что GitHub и coding agents должны разрешать те же references.

## Automated validation

`Scripts/check-knowledge-base.py` без сторонних dependencies проверяет:

- required frontmatter;
- baseline version metadata;
- local Markdown links;
- выход ссылок за repository boundary;
- закрытие fenced code/Mermaid blocks.

`.github/workflows/knowledge-base.yml` запускает checker при изменениях knowledge base, checker/workflow или `Scripts/version`.

## Актуальность

При конфликте сначала устанавливается фактический contract по code + tests + CI, затем исправляется knowledge base. Historical release note не становится current documentation только потому, что она детальнее.

## ADR

ADR требуется для долгоживущих изменений ownership, networking, persistence/security boundary, release trust chain или platform-level policy.

## Change rule

Code changes → docs changes, если изменён documented contract. `last_reviewed` нельзя обновлять автоматически без фактической сверки содержимого.
