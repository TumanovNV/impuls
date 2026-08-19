---
title: Repository Map
type: ai-map
status: active
documentation_version: 1.0
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, repository, map, ai]
---

# Карта репозитория

## Корень

| Путь | Назначение |
| --- | --- |
| `Package.swift` | SPM targets, platform, dependency contract |
| `AGENTS.md` | обязательные правила coding agents |
| `CLAUDE.md` | Claude-specific entrypoint |
| `README.md`, `README.ru.md` | публичное описание продукта |
| `PRIVACY.md` | privacy promises |
| `SECURITY.md` | security promises |
| `knowledge-base/` | текущая структурированная база знаний |
| `docs/` | GitHub Pages, releases, audits, historical technical docs |

## Исходный код

```text
Sources/
├── Impuls/
│   ├── App/       lifecycle, app glue, Menu Bar controller, strings
│   ├── Model/     shared application/panel state
│   ├── Notch/     multi-display presentation and geometry
│   ├── Services/  stores, system adapters, business logic
│   ├── Settings/  settings UI/window infrastructure
│   └── UI/        SwiftUI panes and Theme
└── ImpulsLauncher/ executable entry target
```

## Ключевые точки входа

- `Sources/Impuls/App/AppDelegate.swift` — lifecycle orchestration;
- `Sources/Impuls/Model/NotchViewModel.swift` — shared panel/module state;
- `Sources/Impuls/Notch/NotchController.swift` — presentation orchestration;
- `Sources/Impuls/Notch/NotchDisplaySurface.swift` — per-display surface;
- `Sources/Impuls/UI/Theme.swift` — визуальные токены и motion policy;
- `Sources/Impuls/Services/AppFeatureCatalog.swift` — фактический shipped feature catalog;
- `Sources/Impuls/App/MenuBarWorkspaceController.swift` — Menu Bar presentation controller.

## Данные и пользовательские функции

| Область | Основные файлы |
| --- | --- |
| Actions | `ImpulsActionsStore.swift` + Actions UI |
| Clipboard | `ClipboardStore.swift`, `ClipboardContent.swift`, `ClipboardHistoryPersistence.swift` |
| Shelf / files | `ShelfStore.swift`, `FileToolsCoordinator.swift`, `FileToolsService.swift` |
| Notes | `NoteStore.swift` |
| Snippets | `SnippetStore.swift` |
| Calendar | `CalendarStore.swift` |
| Translate | `Translator.swift`, `TranslationScript.swift` |
| Music | `MediaController.swift`, `PlayerBridge.swift`, `MusicSource.swift`, `WebMusicPlayer.swift` |
| Power | `PowerMonitor.swift`, `PowerSnapshot.swift`, `DevicePowerCenter.swift`, device providers |
| Backup | `BackupService.swift`, migration/storage helpers |

## Security-sensitive точки

- `UpdateService.swift` — network owner / updates;
- `WebMusicPlayer.swift` — network owner / explicit web music;
- `VersionTelemetryService.swift` — network owner / opt-in version statistics;
- `AppleDeviceIdentity.swift` — device identity boundary;
- `LockdownTLSChannel.swift` and mobile-device transport — paired Apple device communication;
- `BoundedData.swift`, `BoundedText.swift` and bounded readers — memory/input limits;
- `FeedbackService.swift` — feedback data boundary.

## Build / release

```text
Scripts/version       version source
Scripts/bundle.sh     app bundle
Scripts/dmg.sh        DMG packaging
.github/workflows/build.yml
.github/workflows/release.yml
docs/releases/        bilingual release notes
```

## Tests

Основной Swift test target находится в `Tests/ImpulsTests`. При изменении service/store сначала искать соответствующий test file по имени сущности. Дополнительные Python-тесты покрывают вспомогательную server/site инфраструктуру.

## Как пользоваться картой

Не рассматривайте этот файл как замену code search. Он нужен, чтобы сузить область поиска и не начинать каждую задачу с полного обхода repository. При добавлении новой крупной подсистемы карта должна обновляться в том же PR.
