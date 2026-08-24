---
title: Repository Map
type: ai-map
status: active
documentation_version: 1.1
app_version: 1.4.15
last_reviewed: 2026-08-24
tags: [impuls, repository, map, ai]
---

# Карта репозитория

## Корень

| Путь | Назначение |
| --- | --- |
| `Package.swift` | SPM targets, platform, dependency contract |
| `AGENTS.md` | обязательные правила coding agents и cold-start routing |
| `CLAUDE.md` | Claude-specific entrypoint поверх shared agent rules |
| `PROJECT-MANIFEST.json` | routing-only machine-readable map canonical owners |
| `README.md`, `README.ru.md` | публичное описание продукта |
| `PRIVACY.md` | public product privacy contract |
| `SECURITY.md` | public security contract |
| `.claude/rules/` | path-scoped rules для website, legal/privacy, localization, Swift UI, release, QA |
| `knowledge-base/` | текущая структурированная база знаний |
| `docs/` | production GitHub Pages, releases, audits, historical technical docs |

## Исходный код

```text
Sources/
├── Impuls/
│   ├── App/       lifecycle, app glue, Menu Bar controller
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
- `Sources/Impuls/Services/AppLanguageService.swift` — единственный владелец explicit app-language preference;
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
| Project support / feedback | `ProjectSupportPromptService.swift`, `FeedbackService.swift`, Settings/AppDelegate presentation glue |

## Localization / public web

Три localization surfaces маршрутизируются отдельно; canonical overview — [Localization](../04-development/localization.md).

```text
Resources/*.lproj/                    application strings + InfoPlist.strings
Sources/Impuls/Services/AppLanguageService.swift
Scripts/bundle.sh                     CFBundleLocalizations

Scripts/site-locales/registry.json    public website code/path/privacy_path registry
Scripts/site-locales/*.json           marketing locale data
Scripts/build-site-locale.py          generic marketing locale builder
docs/index.html                       canonical RU marketing layout/content

Scripts/site-privacy-locales/*.json   legal/privacy locale copy
Scripts/site-privacy-locales/metadata.json policy revision/effective date
Scripts/site-privacy-template.html    legal page presentation source
Scripts/build-site-privacy-locale.py  generic legal locale builder

.github/workflows/site-localization.yml
.github/workflows/site-legal-localization.yml
.github/workflows/site-release-sync.yml
```

Generated `docs/<locale>/index.html` and `docs/**/privacy/index.html` не являются authoring source. Public route для `zh-Hans` намеренно `/zh-hans/`; code и public path всегда читаются из registry, а не выводятся друг из друга.

## Security-sensitive точки

- `UpdateService.swift` — network owner / updates;
- `WebMusicPlayer.swift` — network owner / explicit web music;
- `VersionTelemetryService.swift` — network owner / opt-in version statistics;
- `AppleDeviceIdentity.swift` — device identity boundary;
- `LockdownTLSChannel.swift` and mobile-device transport — paired Apple device communication;
- `BoundedData.swift`, `BoundedText.swift` and bounded readers — memory/input limits;
- `FeedbackService.swift` — feedback data boundary;
- `PRIVACY.md` + `knowledge-base/07-web/legal-privacy.md` — public/legal privacy routing; neither may invent private runtime facts.

## Build / release / documentation validation

```text
Scripts/version                       version source
Scripts/bundle.sh                     app bundle
Scripts/dmg.sh                        DMG packaging
Scripts/check-project-manifest.py     machine routing validation
Scripts/check-current-documentation.py current-state/agent/locale consistency
Scripts/check-knowledge-base.py       KB structure/baseline validation
Scripts/check-documentation-guardian.py semantic diff obligations
Scripts/check-documentation-freshness.py historical source→doc freshness
Scripts/check-qa-impact.py            diff→Behavioral QA routing
Scripts/check-release-qa-evidence.py  release evidence/shipping gate
.github/workflows/build.yml
.github/workflows/knowledge-base.yml
.github/workflows/release.yml
docs/releases/                        user-facing bilingual release notes
knowledge-base/13-qa/release-evidence/ version-specific manual/mixed evidence
```

## Tests

Основной Swift test target находится в `Tests/ImpulsTests`. При изменении service/store сначала искать соответствующий test file по имени сущности. `Tests/PythonTests` покрывает collector/site/documentation/release вспомогательные контракты, включая machine-readable project routes и current-documentation consistency.

## Как пользоваться картой

Не рассматривайте этот файл как замену code search. Он нужен, чтобы сузить область поиска и не начинать каждую задачу с полного обхода repository. Cold-start route: `AGENTS.md` → `PROJECT-MANIFEST.json` → `AI-INDEX.md` → canonical owner → source/tests/CI. При добавлении новой крупной подсистемы или durable repository route карта должна обновляться в том же PR.
