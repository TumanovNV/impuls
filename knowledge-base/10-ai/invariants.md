---
title: Project Invariants
type: ai-rules
status: active
documentation_version: 1.1
app_version: 1.4.14
last_reviewed: 2026-08-22
tags: [impuls, invariants, ai, architecture, security]
---

# Инварианты проекта ИМПУЛЬС

Этот файл — короткая «конституция» проекта для быстрого контекста. Он не заменяет literal CI checks в `AGENTS.md` и `.github/workflows/build.yml`.

## Архитектура

1. Shared stores/services существуют в одном экземпляре на процесс; per-display surfaces отвечают только за представление.
2. Один новый дисплей не означает новый `NotchViewModel`, store, timer или monitor.
3. Stores/services не импортируют SwiftUI; UI panes не выполняют прямой файловый I/O.
4. Один файл по возможности имеет одну ответственность.
5. Новый shipped module должен иметь явный контракт, UI, store/service, строки во **всех** поддерживаемых localization tables и тесты.

## Безопасность и приватность

6. Network access имеет только явно утверждённых владельцев. На baseline 1.4.12 их три: updates, explicit web music, opt-in version statistics.
7. Новая функция не получает сетевой доступ, telemetry или device discovery «по умолчанию».
8. Не использовать private Apple frameworks, MediaRemote или injection.
9. Raw UDID, serial, Bluetooth address, pairing material и аналогичные идентификаторы не попадают в UI, feedback, backup или обычные логи.
10. Missing hardware data остаётся missing; не подставлять 0%, charging state или другие догадки.
11. Потенциально большие inputs читаются bounded-путём.
12. Feedback не собирает пользовательский контент автоматически.

## Permissions и consent

13. System permission запрашивается только для реально используемой пользователем функции.
14. Update consent, version-statistics consent и device-discovery consent — разные границы и не должны незаметно объединяться.
15. Menu Bar и другие presentation surfaces не должны запускать provider, permission prompt, polling loop или network request только ради отображения.

## UI / UX

16. Интерфейс следует system appearance. Семантические цвета идут через дизайн-систему проекта.
17. Hover не равен selection/activation там, где это разделение уже закреплено UX-контрактом.
18. Keyboard ownership между дисплеями должен сохранять намерение пользователя и не перехватываться только из-за hover.
19. Reduce Motion должен сохранять функциональность и избегать лишней geometry animation.

## Локализация

20. Каждый user-facing localization key существует во **всех** поддерживаемых localization tables, и наборы ключей у таблиц совпадают. На 1.4.14 таблиц семь: `en`, `ru`, `de`, `fr`, `es`, `zh-Hans`, `ja`. Правила «RU/EN parity» больше нет.
21. Выбор языка интерфейса имеет одного владельца — `AppLanguageService`; он машинно-локален и не входит в portable backup.

## Release

22. Версия в `Scripts/version` и `docs/releases/<version>.md` изменяются совместно.
23. Sparkle остаётся exact dependency, пока отдельное reviewed решение не изменит этот контракт.
24. Release/tag не создаются вручную при штатном flow; production release идёт через workflow.
25. Signing keys и secrets не коммитятся.

## Документация

26. Значимое изменение архитектуры обновляет knowledge base в том же наборе изменений.
27. Решение с долгосрочными последствиями фиксируется ADR.
28. `project-status.md` — текущий baseline; исторические handoff/release docs не должны использоваться как current-state без проверки.

## Если инвариант нужно нарушить

Не обходить его локальной «исправляющей» конструкцией. Сначала определить, действительно ли контракт устарел. Если да — изменить code/tests/CI/documentation согласованно и зафиксировать решение ADR, когда последствия долгосрочные.
