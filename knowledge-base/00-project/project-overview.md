---
title: Project Overview
type: project
status: active
documentation_version: 1.2
app_version: 1.4.15
last_reviewed: 2026-08-24
tags: [impuls, project, product]
related: [architecture, modules, security]
---

# Обзор проекта ИМПУЛЬС

## Назначение

ИМПУЛЬС — нативная утилита для macOS 15+, которая превращает область у верхней кромки экрана в компактное локальное рабочее пространство. На MacBook интерфейс визуально связан с областью «чёлки», а на других Mac и внешних дисплеях используется компактная верхняя панель.

Цель продукта — сократить мелкие переключения контекста: быстро найти локальные данные, управлять выбранным музыкальным источником, временно разместить файлы, работать с буфером, заметками, календарём, переводом и питанием без перехода между множеством приложений.

## Технологическая база

- Swift toolchain 6.0;
- SwiftUI поверх AppKit;
- минимальная платформа: macOS 15;
- Swift Package Manager;
- основной target: `ImpulsCore`;
- executable target: `Impuls`;
- тестовый target: `ImpulsTests`;
- единственная внешняя зависимость продукта — Sparkle `2.9.5`, закреплённая exact-версией.

См. [`Package.swift`](../../Package.swift).

## Принцип local-first

Основные пользовательские данные обрабатываются локально. Сеть имеет строго ограниченных владельцев, перечисленных в [модели безопасности](../06-security/security-model.md). Новая функция не получает права на сетевой доступ автоматически только потому, что ей это удобно.

## Девять текущих модулей

Фактический каталог shipped-функций определяется `AppFeatureCatalog.swift`:

1. Actions;
2. Music;
3. Shelf;
4. Clipboard;
5. Snippets;
6. Calendar;
7. Translate;
8. Notes;
9. Power / Battery.

Подробности: [Каталог модулей](../02-modules/README.md).

## Международная поверхность

Текущий продукт имеет три независимых localization contracts: интерфейс macOS-приложения, marketing website и website privacy/legal pages. На текущем baseline все три покрывают `ru`, `en`, `de`, `fr`, `es`, `ja`, `zh-Hans`, но один набор нельзя выводить из другого. Канонический маршрут — [Localization](../04-development/localization.md); сайт и legal surface дополнительно принадлежат [Website Architecture](../07-web/website.md) и [Website Legal and Privacy Localization](../07-web/legal-privacy.md).

## Модель интерфейса

Сервисы и пользовательское состояние общие для приложения. Представление панели создаётся отдельно для каждого подключённого дисплея. Активной является только одна поверхность, поэтому приложение не должно создавать отдельные копии хранилищ, таймеров или системных мониторов на каждый экран.

## Текущая модель распространения

Точная опубликованная версия не дублируется здесь: её источник — [`Scripts/version`](../../Scripts/version), а текущий release/status summarised in [Project Status](project-status.md). Сборки распространяются через GitHub Releases; встроенный канал обновления использует Sparkle. `bundle.sh` умеет Developer ID path при наличии конфигурации и ad-hoc fallback в её отсутствие; документация не должна считать конкретный публичный артефакт notarized/Developer-ID-signed без отдельной проверки фактического release environment.

Перед релизными работами сверять [Signing and Distribution](../03-macos/signing-distribution.md), [Release Pipeline](../05-release/release-pipeline.md), [`SECURITY.md`](../../SECURITY.md) и фактический workflow/артефакт.

## Источники истины

При конфликте документов использовать следующий приоритет:

1. фактический код, tests и CI-инварианты;
2. `Scripts/version` для точной версии и `PROJECT-MANIFEST.json` для routing;
3. `AGENTS.md`, `SECURITY.md`, `PRIVACY.md` и соответствующие canonical knowledge-base owners;
4. `project-status.md` как current summary;
5. публичные README и сайт;
6. старые release notes, handoff и исторические QA-документы.

Если обнаружено расхождение, исправляется не только текущая задача, но и документ, который начал дрейфовать. `last_reviewed` меняется только после фактической сверки с source/tests/CI.
