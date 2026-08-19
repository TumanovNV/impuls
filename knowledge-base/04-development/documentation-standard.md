---
title: Documentation Standard
type: development-standard
status: active
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
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
type: module | architecture | security | decision | development | release
status: active | production | accepted | historical | draft
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, ...]
---
```

`app_version` — версия продукта, на которой документ был фактически сверён. Только baseline entrypoints (`INDEX`, project status, AI index) обязаны всегда совпадать с `Scripts/version`; historical/deep documents обновляют review metadata при реальной сверке, а не механически.

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
