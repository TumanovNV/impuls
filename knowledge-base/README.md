# IMPULS Engineering Knowledge Base

Documentation version **1.1**, product baseline **1.4.11**.

Эта папка — Markdown-first база знаний проекта. Её можно открыть как отдельный Obsidian vault, читать на GitHub или давать Claude/Codex как structured project context.

Начало: [INDEX.md](INDEX.md). Для coding agents: [10-ai/AI-INDEX.md](10-ai/AI-INDEX.md).

## Почему здесь, а не в `docs/`

`docs/` — production GitHub Pages, release notes и security audits. `knowledge-base/` — engineering source of truth. Причина зафиксирована в [ADR-001](08-decisions/ADR-001-knowledge-base-location.md).

## Что покрывает v1.1

- product/current status;
- lifecycle, state ownership, multi-display;
- storage/persistence, permissions, networking;
- Mermaid system diagrams;
- подробные contracts всех 9 modules + Menu Bar;
- macOS TCC;
- testing и SOP добавления module;
- update/release trust pipeline;
- data classification, threat model, privacy boundaries;
- ADR-001…005;
- AI routing and change-impact matrix;
- architecture timeline.

## Работа в Obsidian

Open folder as vault → выбрать `knowledge-base`. Плагины не обязательны. Mermaid рендерится нативно. Relative Markdown links сохраняют совместимость с GitHub и AI tools.

## Правило поддержки

Если change меняет documented architecture/module/data/security/release contract, documentation update входит в тот же change set. `last_reviewed` меняется только после фактической сверки с code/tests/CI.
