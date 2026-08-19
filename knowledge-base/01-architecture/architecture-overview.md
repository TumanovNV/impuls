---
title: Architecture Overview
type: architecture
status: active
documentation_version: 1.0
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, architecture, swift, macos]
related: [modules, security, repository-map]
---

# Архитектура ИМПУЛЬС

## Общая схема

```text
Impuls executable
        |
        v
App / lifecycle
        |
        v
NotchViewModel + shared stores/services
        |
        +-------------------------+
        |                         |
        v                         v
Per-display presentation      Menu Bar workspace
(Notch surfaces)              (existing local state)
        |
        v
SwiftUI panes
```

## Слои

### `Sources/Impuls/App`

Жизненный цикл приложения, `AppDelegate`, интеграция launcher, Menu Bar controller и локализация.

### `Sources/Impuls/Model`

Центральное состояние панели. `NotchViewModel` содержит tabs, stores и presentation state. Он создаётся один раз; создание второго экземпляра означало бы дублирование сервисов и фоновой работы.

### `Sources/Impuls/Notch`

Инфраструктура представления на дисплеях:

- `DisplayTopology` — модель топологии;
- `ScreenDisplaySource` — чтение реальных экранов;
- `DisplayCoordinator` — координация;
- `NotchController` — orchestration панели;
- `NotchDisplaySurface` — отдельная presentation surface на дисплей;
- `NotchGeometry` — геометрия;
- `PointerWatcher` — единый sampler указателя.

Правило: surface владеет окном, view и геометрией, но не store, monitor или отдельным timer.

### `Sources/Impuls/Services`

Бизнес-логика и системные адаптеры. Сервисный слой не должен импортировать SwiftUI. Сетевые возможности ограничены отдельными владельцами, см. [Security Model](../06-security/security-model.md).

### `Sources/Impuls/Settings`

Нативные настройки и связанные окна. Настройки не должны превращаться в второй источник бизнес-логики модулей.

### `Sources/Impuls/UI`

SwiftUI presentation. Обычно один `*Pane.swift` на модуль. UI не выполняет прямой файловый I/O; операции проходят через stores/services.

## Shared services / per-display presentation

Multi-display архитектура основана на разделении:

- **один набор состояния и сервисов** на весь процесс;
- **одна presentation surface на каждый дисплей**;
- **только одна active surface** в конкретный момент.

Следствия:

- нельзя создавать отдельный `ClipboardStore`, `PowerMonitor`, `CalendarStore` и т. п. для каждого дисплея;
- нельзя добавлять отдельный pointer timer на каждый экран;
- handoff между дисплеями должен переносить presentation/keyboard ownership, а не создавать новую бизнес-сессию;
- ошибки одного presentation layer не должны менять сетевые или data-consent границы.

## Модульный контракт

Новый основной модуль обычно требует:

1. нового `Tab` case;
2. отдельного store/service;
3. отдельного `*Pane.swift`;
4. RU/EN локализации;
5. регистрации в shipped feature catalog, если функция реально доступна пользователю;
6. тестов;
7. обновления [каталога модулей](../02-modules/README.md);
8. security/privacy review при затрагивании сети, разрешений или пользовательских данных.

## UI architecture

Theme и размеры должны браться из существующей дизайн-системы (`Theme.swift`) либо из уже определённой геометрии pane. Нельзя вводить произвольные цвета/размеры, игнорирующие системную appearance.

Панель следует светлой/тёмной теме macOS; collapsed tab намеренно остаётся чёрным, чтобы визуально соединяться с физической «чёлкой».

## Зависимости

Sparkle 2.9.5 — закреплённая exact-версия. Добавление, обновление или замена зависимости — архитектурное изменение и требует отдельного обоснования, тестирования и при необходимости ADR.

## Связанные документы

- [Каталог модулей](../02-modules/README.md)
- [Security Model](../06-security/security-model.md)
- [Repository Map](../10-ai/repository-map.md)
- [Project Invariants](../10-ai/invariants.md)
- историческая multi-display архитектура: [`docs/IMPULS_1_4_7_MULTI_DISPLAY.md`](../../docs/IMPULS_1_4_7_MULTI_DISPLAY.md)
