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

Knowledge base — Markdown-first Obsidian-compatible vault. Используются стандартные relative Markdown links и YAML frontmatter.

## Обязательный frontmatter

```yaml
---
title: Human readable title
type: module | architecture | security | decision | development | release
status: active | historical | draft
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, ...]
---
```

## Для module docs

Обязательные секции: назначение; user contract; data flow; source map; state; persistence; permissions; network; lifecycle/performance; invariants; tests; change checklist; related docs.

## Схемы

Mermaid хранится прямо в Markdown. Diagram должна объяснять ownership/data/control flow, а не дублировать текст декоративно.

## Актуальность

`app_version` показывает baseline, на котором документ проверен. Историческая release note не превращается в current documentation. При конфликте: сначала code + tests + CI, затем обновление knowledge base.

## ADR

Долгоживущие решения фиксируются ADR, если изменение затрагивает ownership, networking, persistence/security boundary, release trust chain или platform-level policy.

## Change rule

Code changes → docs changes, если изменён documented contract. Не обновлять `last_reviewed` механически, если содержимое не было фактически сверено.
