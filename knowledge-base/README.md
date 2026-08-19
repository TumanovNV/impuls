# IMPULS Engineering Knowledge Base

Documentation version **1.2**, product baseline **1.4.11**.

Эта папка — Markdown-first база знаний проекта. Её можно открыть как отдельный Obsidian vault, читать на GitHub или давать Claude/Codex как structured project context.

Начало: [INDEX.md](INDEX.md). Для coding agents: [10-ai/AI-INDEX.md](10-ai/AI-INDEX.md). Для точного ownership/schema context: [12-reference/README.md](12-reference/README.md).

## Почему здесь, а не в `docs/`

`docs/` — production GitHub Pages, release notes и security audits. `knowledge-base/` — engineering source of truth. Причина зафиксирована в [ADR-001](08-decisions/ADR-001-knowledge-base-location.md).

## Что покрывает v1.2

В v1.1 уже были зафиксированы lifecycle, state ownership, multi-display, storage, permissions, network boundaries, все shipped modules, release/update pipeline, threat model, ADR и Mermaid-схемы.

v1.2 добавляет precision/reference layer:

- единый [Schema & Migration Registry](12-reference/schema-migration-registry.md);
- [Core Type Reference](12-reference/core-type-reference.md) по главным ownership boundaries;
- machine-checked [Type → Tests → Docs Map](12-reference/generated-type-test-doc-map.md);
- manifest + generator для этой карты;
- CI freshness check generated reference;
- формальную [Public / Private Operations Boundary](12-reference/operations-boundary.md);
- интеграцию с private operational vault без копирования production topology в public repository.

## Автоматическая карта кода

Источник архитектурного mapping:

```text
Scripts/knowledge-map-manifest.json
```

Генератор:

```text
Scripts/generate-knowledge-map.py
```

Использование:

```bash
python3 Scripts/generate-knowledge-map.py
python3 Scripts/generate-knowledge-map.py --check
```

`--check` используется GitHub Actions и падает, если source/test/doc ownership изменился, а committed generated map не обновлён.

## Работа в Obsidian

Open folder as vault → выбрать `knowledge-base`. Плагины не обязательны. Mermaid рендерится нативно. Relative Markdown links сохраняют совместимость с GitHub и AI tools.

## Два документационных контура Impuls

Публичный `TumanovNV/impuls` хранит software facts: код, архитектуру, схемы данных, tests, release/update и telemetry software contract.

Фактическая production topology/runtime документация telemetry-контура хранится в private infrastructure vault. Public knowledge base знает только границу и маршрут к private source of truth, но не копирует private IP/VPN/access state.

Подробнее: [Public / Private Operations Boundary](12-reference/operations-boundary.md).

## Правило поддержки

Если change меняет documented architecture/module/data/security/release contract, documentation update входит в тот же change set. `last_reviewed` меняется только после фактической сверки с code/tests/CI.

Если меняется persisted format — сначала проверить [Schema & Migration Registry](12-reference/schema-migration-registry.md).

Если меняется важный type ownership — обновить manifest, сгенерировать map и пройти CI.
