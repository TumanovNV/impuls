---
title: Menu Bar Workspace
type: presentation-module
documentation_version: 1.3
status: production
app_version: 1.4.12
last_reviewed: 2026-08-21
tags: [impuls, menu-bar, workspace, presentation]
---

# Menu Bar Workspace

## Роль

Menu Bar — presentation client существующего state, а не десятый domain provider. Он не запускает battery provider, player, network request или polling timer ради собственного отображения.

## Flow

```mermaid
flowchart LR
    VM[Existing NotchViewModel state] --> REG[MenuBarWorkspaceResolver]
    SET[MenuBarWorkspaceConfiguration] --> REG
    REG --> PRES[MenuBarStatusItemPresentation]
    PRES --> STATUS[One AppKit status item]
    REG --> W1[Primary widget]
    REG --> W2[Secondary widget]
    REG --> QA[0-4 Quick Actions]
    QA --> NC[Existing NotchController open paths]
```

## Configuration

Presets: Minimal, Batteries, Music, Work, Smart, Custom. Status modes: logo, Mac battery, selected device, lowest battery, player, automatic. Widgets: none, battery variants, player, quick actions, automatic.

Max quick actions: 4. Low-battery threshold normalized 5...50. Unknown future IDs decode defensively. Duplicate primary/secondary widget suppressed.

## Status item presentation — 1.4.12

`MenuBarStatusItemPresentation` is the narrow formatting boundary between resolved workspace content and the AppKit status item. It does **not** choose a provider or fetch data; it only expresses the already-resolved local value.

For battery content:

- the status item uses native SF Symbols, never the Impuls logo as the battery glyph;
- percentage text remains normal system Menu Bar text rather than being recoloured with the battery level;
- charging uses native `bolt.fill` only when the state is actually `.charging`;
- `.charged`, `.pluggedNotCharging`, `.discharging` and unknown states do not invent a charging bolt;
- battery symbol buckets are `0`, `25`, `50`, `75`, `100%` according to the reported percentage;
- semantic level roles are green for 60–100%, orange for 20–59%, red for 0–19%; unknown percentage has no level colour role.

The deterministic threshold/symbol/bolt contract is covered by `MenuBarStatusItemPresentationTests.swift`. The release-specific light/dark + Retina visual acceptance is recorded independently as Behavioral QA `UI-06` in the 1.4.12 Release QA Evidence.

## Стоимость пересборки

Статус-элемент собирается из Combine fan-in, куда входит `media.objectWillChange`, а `MediaController.position` публикуется 4 раза в секунду во время воспроизведения — и только при открытой панели, то есть ровно тогда, когда идут её анимации. Раньше каждое такое уведомление пересобирало весь `NSMenu` и перечитывало PNG иконки с диска.

Иконка — константный ресурс бандла и читается один раз. Пересборка ограничена сравнением `MenuBarMenuFingerprint`: configuration, разрешённое состояние (батарея Mac, видимые устройства, плеер, выбранное устройство), enabled tabs, возможность управлять плеером и доступность проверки обновлений. `position` не входит намеренно — меню его не показывает. `menuWillOpen` пересобирает принудительно, потому что в момент показа правдивость важнее экономии.

Добавление поля в меню обязывает добавить его и в fingerprint, иначе меню окажется устаревшим.

## Persistence


Generic workspace config входит в settings snapshot/backup. Selected physical-device key хранится отдельно local-only и не переносится между Mac.

## Smart policy

Ordered priorities: low battery, active player, charging, neutral. Priority выигрывает only при наличии honest current value; resolver не придумывает data ради заполнения widget.

## Quick Actions

Intentional entrance points: open panel, screenshot folder actions и переходы к enabled modules. Они используют тот же single-surface controller path.

## Source / verification map

- `Sources/Impuls/Services/MenuBarWorkspace.swift` — configuration, state and resolver policy;
- `Sources/Impuls/App/MenuBarStatusItemPresentation.swift` — status-item formatting and battery presentation;
- `Sources/Impuls/App/MenuBarWorkspaceController.swift` — AppKit presentation/controller glue over existing state;
- `Sources/Impuls/Services/AppFeatureCatalog.swift` — shipped quick-action/module catalogue;
- `Sources/Impuls/Settings/SettingsStore.swift` — persisted generic workspace config + local-only selected device preference; оно же держит `AppLanguageService` по композиции, но язык интерфейса не персистит и к Menu Bar отношения не имеет;
- `Tests/ImpulsTests/MenuBarWorkspaceTests.swift` — resolver/configuration/persistence behavior;
- `Tests/ImpulsTests/MenuBarStatusItemPresentationTests.swift` — battery glyph, percentage and charging presentation contract.

## Инварианты

- no new provider/timer/network;
- reads existing published state only;
- one status item presentation path for This Mac and compatible selected Apple devices;
- selected device identity local-only;
- missing values fall back predictably, never fabricated;
- percentage text stays semantically separate from battery level colour;
- quick action не создаёт второй view model/surface owner.
