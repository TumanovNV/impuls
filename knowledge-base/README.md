# IMPULS Engineering Knowledge Base

Documentation version **1.3**, product baseline **1.4.11**.

Эта папка — Markdown-first база знаний проекта. Её можно открыть как отдельный Obsidian vault, читать на GitHub или давать Claude/Codex как structured project context.

Начало: [INDEX.md](INDEX.md). Для coding agents: [10-ai/AI-INDEX.md](10-ai/AI-INDEX.md). Для точного ownership/schema/performance context: [12-reference/README.md](12-reference/README.md). Для реальных сценариев проверки: [13-qa/README.md](13-qa/README.md).

## Почему здесь, а не в `docs/`

`docs/` — production GitHub Pages, release notes и security audits. `knowledge-base/` — engineering source of truth. Причина зафиксирована в [ADR-001](08-decisions/ADR-001-knowledge-base-location.md).

## Что покрывает v1.3

v1.1 зафиксировала lifecycle, state ownership, multi-display, storage, permissions, network boundaries, все shipped modules, release/update pipeline, threat model, ADR и Mermaid-схемы.

v1.2 добавила precision/reference layer: Schema & Migration Registry, Core Type Reference, machine-checked Type → Tests → Docs Map и формальную Public / Private Operations Boundary.

v1.3 добавляет anti-drift и performance/QA слой:

- единый [Background Work & Concurrency Registry](12-reference/background-concurrency-registry.md);
- единый [Input & Resource Budget Registry](12-reference/resource-budget-registry.md);
- [Behavioral QA Matrix](13-qa/behavioral-qa-matrix.md) для multi-display, TCC, hardware, data, media, UI и release edge cases;
- [Documentation Guardian](10-ai/documentation-guardian.md);
- machine-readable semantic rules `Scripts/documentation-guardian-rules.json`;
- diff checker `Scripts/check-documentation-guardian.py`, подключённый к GitHub Actions.

## Автоматические проверки документации

```bash
python3 Scripts/check-knowledge-base.py
python3 Scripts/generate-knowledge-map.py --check
python3 Scripts/check-documentation-guardian.py --base <base-sha>
```

Первая проверка валидирует структуру/frontmatter/links/baseline. Вторая проверяет curated source→tests→docs map. Третья смотрит **изменённые строки кода** и требует review соответствующего канонического документа, если изменились timers/tasks/queues, resource budgets, persisted contracts, networking или permission paths.

Guardian не генерирует текст из кода. Он создаёт обязательство пересмотреть документ и тем самым не даёт документации тихо отстать от реализации.

## Автоматическая карта кода

Источник архитектурного mapping:

```text
Scripts/knowledge-map-manifest.json
```

Генератор:

```text
Scripts/generate-knowledge-map.py
```

`--check` используется GitHub Actions и падает, если source/test/doc ownership изменился, а committed generated map не обновлён.

## Работа в Obsidian

Open folder as vault → выбрать `knowledge-base`. Плагины не обязательны. Mermaid рендерится нативно. Relative Markdown links сохраняют совместимость с GitHub и AI tools.

## Два документационных контура Impuls

Публичный `TumanovNV/impuls` хранит software facts: код, архитектуру, схемы данных, tests, release/update и telemetry software contract.

Фактическая production topology/runtime документация telemetry-контура хранится в private infrastructure vault. Public knowledge base знает только границу и маршрут к private source of truth, но не копирует private IP/VPN/access state.

Подробнее: [Public / Private Operations Boundary](12-reference/operations-boundary.md).

## Правило поддержки

Если change меняет documented architecture/module/data/security/release/performance contract, documentation update входит в тот же change set. `last_reviewed` меняется только после фактической сверки с code/tests/CI.

Если меняется persisted format — сначала проверить [Schema & Migration Registry](12-reference/schema-migration-registry.md).

Если меняется timer/task/queue/cadence — проверить [Background Work & Concurrency Registry](12-reference/background-concurrency-registry.md).

Если меняется лимит, timeout или backpressure — проверить [Input & Resource Budget Registry](12-reference/resource-budget-registry.md).

Если появляется новый user-visible platform/hardware edge — добавить его в [Behavioral QA Matrix](13-qa/behavioral-qa-matrix.md).

Если меняется важный type ownership — обновить manifest, сгенерировать map и пройти CI.
