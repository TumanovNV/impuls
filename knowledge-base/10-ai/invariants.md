---
title: Project Invariants
type: ai-rules
status: active
documentation_version: 1.2
app_version: 1.4.15
last_reviewed: 2026-08-24
tags: [impuls, invariants, ai, architecture, security]
---

# Инварианты проекта ИМПУЛЬС

Этот файл — короткая «конституция» проекта для быстрого контекста. Он не заменяет literal CI checks в `AGENTS.md` и `.github/workflows/build.yml`. Точный номер текущего release читается из `Scripts/version`, а не закрепляется внутри инвариантов.

## Архитектура

1. Shared stores/services существуют в одном экземпляре на процесс; per-display surfaces отвечают только за представление.
2. Один новый дисплей не означает новый `NotchViewModel`, store, timer или monitor.
3. Stores/services не импортируют SwiftUI; UI panes не выполняют прямой файловый I/O.
4. Один файл по возможности имеет одну ответственность.
5. Новый shipped module должен иметь явный контракт, UI, store/service, строки во **всех** поддерживаемых application localization tables и тесты.

## Безопасность и приватность

6. Internet network access имеет ровно трёх явно утверждённых владельцев: updates, explicit web music и opt-in version statistics. Изменение этого набора — architecture/security decision, а не локальная реализация.
7. Новая функция не получает сетевой доступ, telemetry или device discovery «по умолчанию».
8. Не использовать private Apple frameworks, MediaRemote или injection.
9. Raw UDID, serial, Bluetooth address, pairing material и аналогичные идентификаторы не попадают в UI, feedback, backup или обычные логи.
10. Missing hardware data остаётся missing; не подставлять 0%, charging state или другие догадки.
11. Потенциально большие inputs читаются bounded-путём.
12. Feedback не собирает пользовательский контент автоматически.
13. Project-support eligibility и решения остаются машинно-локальными; они не становятся telemetry и не создают новый network owner.

## Permissions и consent

14. System permission запрашивается только для реально используемой пользователем функции.
15. Update consent, version-statistics consent и device-discovery consent — разные границы и не должны незаметно объединяться.
16. Menu Bar и другие presentation surfaces не должны запускать provider, permission prompt, polling loop или network request только ради отображения.

## UI / UX

17. Интерфейс следует system appearance. Семантические цвета идут через дизайн-систему проекта.
18. Hover не равен selection/activation там, где это разделение уже закреплено UX-контрактом.
19. Keyboard ownership между дисплеями должен сохранять намерение пользователя и не перехватываться только из-за hover.
20. Reduce Motion должен сохранять функциональность и избегать лишней geometry animation.

## Локализация

21. Каждый user-facing application localization key существует во **всех** shipped application localization tables, и наборы ключей у таблиц совпадают. Current app set читается из `Resources/*.lproj` и сверяется CI с `AppLanguageService`/bundle; правила «RU/EN parity» больше нет.
22. Выбор языка интерфейса имеет одного владельца — `AppLanguageService`; он машинно-локален и не входит в portable backup.
23. App, marketing website и privacy/legal website — три независимых localization contracts. Их наборы могут совпадать, но один нельзя выводить из другого; canonical owner — [Localization](../04-development/localization.md).

## Release

24. Версия в `Scripts/version`, `docs/releases/<version>.md` и `knowledge-base/13-qa/release-evidence/<version>.md` изменяются совместно.
25. Sparkle остаётся exact dependency, пока отдельное reviewed решение не изменит этот контракт.
26. Release/tag не создаются вручную при штатном flow; production release идёт через workflow.
27. Signing keys и secrets не коммитятся.

## Документация

28. Значимое изменение архитектуры обновляет knowledge base в том же наборе изменений.
29. Решение с долгосрочными последствиями фиксируется ADR.
30. `project-status.md` — current summary; точная версия принадлежит `Scripts/version`; исторические handoff/release docs не должны использоваться как current-state без проверки.
31. `PROJECT-MANIFEST.json` остаётся routing-only и должен вести cold-start agents к актуальным canonical owners, включая localization и website legal/privacy routes.
32. `Scripts/check-current-documentation.py` защищает current-state/agent entrypoints от тихого расхождения с version/locale/routing sources.

## Если инвариант нужно нарушить

Не обходить его локальной «исправляющей» конструкцией. Сначала определить, действительно ли контракт устарел. Если да — изменить code/tests/CI/documentation согласованно и зафиксировать решение ADR, когда последствия долгосрочные.
