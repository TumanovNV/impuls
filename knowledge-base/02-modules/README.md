---
title: Module Catalog
type: modules
status: active
documentation_version: 1.0
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, modules, features]
---

# Каталог модулей ИМПУЛЬС

Источник фактического списка shipped-модулей: [`Sources/Impuls/Services/AppFeatureCatalog.swift`](../../Sources/Impuls/Services/AppFeatureCatalog.swift).

| Модуль | Назначение | Ключевая логика / источники |
| --- | --- | --- |
| Actions | Единый локальный поиск и действия | `ImpulsActionsStore.swift`, UI Actions pane |
| Music | Управление явно выбранным музыкальным источником | `MediaController.swift`, `PlayerBridge.swift`, `MusicSource.swift`, `WebMusicPlayer.swift` |
| Shelf | Временная полка файлов и файловые инструменты | `ShelfStore.swift`, `FileToolsCoordinator.swift`, `FileToolsService.swift` |
| Clipboard | История буфера обмена | `ClipboardStore.swift`, `ClipboardContent.swift`, `ClipboardHistoryPersistence.swift` |
| Snippets | Повторно используемые текстовые заготовки | `SnippetStore.swift` |
| Calendar | Ближайшие события после системного разрешения | `CalendarStore.swift` |
| Translate | Явно запускаемый перевод текста | `Translator.swift`, `TranslationScript.swift` |
| Notes | Локальные быстрые заметки | `NoteStore.swift` |
| Power / Battery | Питание Mac и явно включённые Apple devices | `PowerMonitor.swift`, `DevicePowerCenter.swift`, device providers |

## Общие правила модулей

- store/service не должен импортировать SwiftUI;
- pane не должен выполнять прямой файловый I/O;
- отсутствующие данные не подменяются придуманными значениями;
- новая сеть не появляется как скрытая деталь реализации модуля;
- новый системный permission должен иметь понятную пользовательскую причину и явный lifecycle;
- настройки и persisted identifiers должны сохранять обратную совместимость либо иметь миграцию;
- все пользовательские строки должны существовать и в RU, и в EN;
- новый shipped-модуль добавляется в `AppFeatureCatalog`, только когда его destination реально существует.

## Power / Battery — особые инварианты

Внутренний идентификатор `.power` не переименовывать: настройки, backup и migration зависят от него. Raw UDID, serial, Bluetooth address и pairing material не должны попадать в UI, feedback, backup или обычные логи. Discovery внешних устройств начинается только после явного opt-in пользователя. Отсутствующее значение остаётся отсутствующим.

См. также:

- [`docs/APPLE_DEVICE_BATTERY_SUPPORT.md`](../../docs/APPLE_DEVICE_BATTERY_SUPPORT.md)
- [`docs/IMPULS_1_4_6_CODEMAP.md`](../../docs/IMPULS_1_4_6_CODEMAP.md)

## Music — особая граница

Нативный Apple Music adapter использует разрешённые системные механизмы. Web player может открывать официальный HTTPS-сайт только после явного действия пользователя. Запуск приложения или простой выбор источника не должен создавать `WKWebView` или сетевое соединение.

## Menu Bar

Menu Bar — не десятый независимый модуль, а отдельная presentation/workspace поверхность над уже существующим локальным состоянием и quick actions. Он не должен запускать новый provider, polling loop или сетевой запрос только ради отображения виджета.

## Расширение каталога

При добавлении нового модуля создать отдельный документ `02-modules/<module>.md`, если его архитектура выходит за рамки простого store + pane либо у него есть собственные permissions, persistence, networking или критические ограничения.
