---
title: Testing Strategy
type: development
status: active
documentation_version: 1.1
app_version: 1.4.12
last_reviewed: 2026-08-20
tags: [impuls, development, tests, ci]
---

# Testing Strategy

## Уровни проверки

```mermaid
flowchart TD
    U[Unit / deterministic tests] --> C[CI policy gates]
    C --> B[Release build]
    B --> S[Launch smoke: zero unsolicited sockets]
    S --> A[Artifact verification]
    A --> H[Manual hardware/visual acceptance where required]
```

## XCTest

`Tests/ImpulsTests` проверяет stores, persistence, display topology, device power, media/security helpers, settings/backup и другие domain contracts. Тесты должны использовать injected storage/environment и не читать реальные пользовательские файлы.

Базовая команда: `swift test -c release`.

**Локальная оговорка (проверено 2026-08-20 на 1.4.12).** Голый `swift test -c release` в этом окружении может выполнить **ноль** тестов и всё равно вернуть успех — swift-testing сообщает «0 tests in 0 suites passed», а XCTest-набор не запускается. Явный фильтр запускает его целиком:

```bash
swift test -c release --filter 'ImpulsTests\.'
```

Всегда сверяйтесь со строкой `Executed N tests` в выводе, а не только с кодом возврата. И не заворачивайте команду в пайп (`| tail`, `| grep`) без `PIPESTATUS`: код возврата тогда принадлежит последней команде пайпа, и красный прогон читается как зелёный. Именно так во время аудита 1.4.12 едва не был пропущен flaky-тест.

## Flaky-тесты

Ожидание фиксированным числом `await Task.yield()` — это догадка о том, сколько точек приостановки понадобится, и под нагрузкой она не выдерживает. `LowBatteryAlertPermissionTests` падал примерно раз на пять прогонов именно так. Для утверждения «событие произошло» используйте `XCTestExpectation` + `await fulfillment(of:timeout:)`, как в `MobileDeviceBatteryProviderTests` и `IORegistryAccessoryTests`. Отсутствие события дождаться нельзя, поэтому негативные проверки — единственное оправданное место для короткого spin.

## Python tests

`Tests/PythonTests` покрывает server/site/release helper code. Команда: `python3 -m unittest discover -s Tests/PythonTests -p 'test_*.py'`.

## CI как executable policy

`build.yml` — не только build script. Он literal-check'ами защищает:

- три network owners;
- отсутствие private MediaRemote/injection paths;
- pinned Sparkle 2.9.5;
- signed-feed/update verification flags;
- bounded reads/search budgets;
- feedback privacy boundary;
- adaptive theme;
- Actions hover semantics;
- localization completeness;
- version + release notes pairing;
- bundle identity/entitlements;
- zero unsolicited sockets at launch.

## Hardware/manual QA

Некоторые свойства нельзя честно доказать только CI: реальный external display/Sidecar, Apple device models, TCC dialogs, VoiceOver, appearance, hardware battery fields. Такие пункты должны оставаться явно `manual`, а не получать фиктивный PASS.

## Change-based checklist

- service/store → unit tests;
- persistence → load/save/migration/limits/delete tests;
- permissions → not-requested/denied/granted + no auto-prompt proof;
- networking → allow-list + consent + redirect + launch smoke;
- multi-display → A/B/hot unplug/keyboard ownership;
- release → CI + bundle + DMG/ZIP/appcast verification;
- UI → light/dark, Reduce Motion, keyboard, accessibility when applicable.

## Связано

- [Adding a Module](adding-a-module.md)
- [Project Invariants](../10-ai/invariants.md)
- `.github/workflows/build.yml`
