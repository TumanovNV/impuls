---
title: Architecture Decision Records
type: adr-index
status: active
documentation_version: 1.0
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, adr, decisions]
---

# Architecture Decision Records

ADR фиксируют не только итог решения, но и причину, по которой проект пошёл именно этим путём. Они нужны для решений, которые будущему разработчику или AI-агенту может захотеться «упростить», не понимая последствий.

## Статусы

- `Proposed` — решение обсуждается;
- `Accepted` — действует;
- `Superseded` — заменено новым ADR;
- `Deprecated` — больше не применяется, но сохраняется для истории.

## Индекс

| ADR | Решение | Статус |
| --- | --- | --- |
| [ADR-001](ADR-001-knowledge-base-location.md) | Хранить knowledge base внутри репозитория в `/knowledge-base` | Accepted |

## Когда нужен новый ADR

Создавайте ADR, если меняется хотя бы одна из границ:

- фундаментальная архитектура модулей или дисплеев;
- persistence schema с долгосрочными последствиями;
- новый сетевой владелец;
- новый внешний dependency;
- signing/update architecture;
- security/privacy boundary;
- стратегия совместимости или миграций;
- принципиальная технология, которую будет дорого заменить.

Обычный bug fix ADR не требует, если он не меняет контракт системы.
