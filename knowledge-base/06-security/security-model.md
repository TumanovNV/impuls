---
title: Security Model
type: security
status: active
documentation_version: 1.0
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, security, privacy, network]
---

# Модель безопасности ИМПУЛЬС

Этот документ — навигационное описание границ безопасности. Публичные обязательства задаются [`SECURITY.md`](../../SECURITY.md) и [`PRIVACY.md`](../../PRIVACY.md); при конфликте они и фактический CI имеют приоритет.

## Базовые принципы

- local-first по умолчанию;
- минимальные системные разрешения;
- отсутствие скрытого сетевого поведения;
- отсутствие private Apple frameworks и injection;
- bounded reads для потенциально больших пользовательских данных;
- отсутствие выдуманных или восстановленных «по догадке» аппаратных значений;
- явное согласие перед optional networking/discovery;
- пользовательские identifiers не должны становиться телеметрией.

## Три владельца сети

На baseline 1.4.11 сетевой доступ в Swift-коде имеет три явных владельца:

1. `UpdateService.swift` — opt-in Sparkle update channel;
2. `WebMusicPlayer.swift` — официальный HTTPS-сайт выбранного пользователем музыкального сервиса после явного Open Web Player;
3. `VersionTelemetryService.swift` — отдельно согласованная version-only статистика к build-configured HTTPS endpoint.

Сетевые API в остальных Swift-файлах запрещаются CI-инвариантами. Добавление четвёртого владельца сети является значимым security/architecture change и требует отдельного review, документации и ADR.

## Update security

- Sparkle закреплён на `2.9.5`;
- update checks и automatic installation по умолчанию выключены;
- system profiling выключен;
- feed должен быть подписан;
- архив проверяется до извлечения;
- release/signing material не хранится в репозитории.

## Version statistics

Телеметрия версии отделена от update consent. Без состояния `allowed` запрос не выполняется. Payload ограничен версией приложения, случайным installation pseudonym и, когда это достоверно известно, предыдущей версией. Hardware identifiers не являются источником installation ID.

## Device / battery boundary

Discovery внешних Apple devices выключен до пользовательского opt-in. Raw device identifiers, pairing material и чувствительные аппаратные идентификаторы не должны выходить за внутреннюю identity boundary. Missing data остаётся missing.

## Media boundary

Запрещены private MediaRemote API и code injection. Нативный Apple Music путь должен использовать разрешённые системные интерфейсы. Web content появляется только после явного действия пользователя.

## Feedback boundary

Feedback не должен автоматически собирать пользовательский контент или hardware identifiers. Он формирует локальный отчёт и открывает GitHub/browser flow по явному действию пользователя.

## Bounded data

Потенциально большие данные должны проходить через bounded abstractions проекта (`BoundedFileReader`, `BoundedData`, `BoundedText` и аналогичные ограничения). Нельзя читать произвольные файлы или pasteboard payload целиком в UI-потоке без установленных лимитов.

## Когда обновлять этот документ

Обязательно при изменении:

- сетевых владельцев;
- consent model;
- system permissions;
- persistence пользовательских данных;
- device identity;
- update/signing pipeline;
- feedback/telemetry payload;
- внешних зависимостей с security impact.
