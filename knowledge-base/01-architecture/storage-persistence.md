---
title: Storage and Persistence
type: architecture
status: active
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-20
tags: [impuls, storage, persistence, privacy]
---

# Storage and Persistence

## Карта данных

```mermaid
flowchart TD
    UD[UserDefaults] --> SET[SettingsStore]
    UD --> SH[Shelf URL references]
    UD --> MEDIA[Selected music source]
    UD --> TR[Translation language pair]

    AS[Application Support / Impuls] --> NOTES[notes.json]
    AS --> SNIP[snippets.json]
    AS --> CLIP[clipboard-history.v1 encrypted]

    KC[macOS Keychain] --> CK[AES-GCM clipboard key\nThisDeviceOnly]
    KC --> VID[Version statistics random UUID\nThisDeviceOnly]
    KC --> DID[Device identity local secret / opaque keys]

    FS[User-selected files] --> SHELF[Shelf references only]
```

## StorageEnvironment

`StorageEnvironment` делает пути file-backed stores явной зависимостью `NotchViewModel`. Production использует `.live`; tests передают temporary paths. Это защищает реальные пользовательские notes/snippets от тестов.

Разрешение пути (`ApplicationSupport.file`) не создаёт директорию. Parent folder создаётся только непосредственно перед записью.

## Settings

`SettingsStore` хранит persisted preferences в UserDefaults. Export snapshot включает переносимые настройки, но **не включает local-only device keys** и selected physical device identity.

## Notes

`notes.json` — внутреннее хранилище scratchpad. Запись debounce ~0.8 s на utility queue, atomic write; при shutdown используется synchronous final flush. Лимит файла 10 MiB, максимум 5 000 notes.

## Snippets

`snippets.json` намеренно user-editable. Store проверяет file signature, re-read'ит перед записью и ограничивает файл 10 MiB / 5 000 элементов. JSON pretty-printed.

## Clipboard history

`load()` различает «архива нет» и «архив есть, но открыть его не удалось». Включение persistence записывает поверх только в первом случае; подробности и осознанная граница — в [Clipboard](../02-modules/clipboard.md). Keychain service/account инжектируемы (по образцу `DeviceIdentityResolver`), чтобы тест пути записи не мог создать или удалить ключ, которым шифруется настоящий архив; значения по умолчанию не изменились.


По умолчанию persistent history выключена. При opt-in:

- archive `clipboard-history.v1`;
- JSON payload шифруется AES-GCM;
- случайный 256-bit key находится только в Keychain;
- Keychain accessibility: `AfterFirstUnlockThisDeviceOnly`;
- архив ограничен 64 MiB;
- отключение persistence удаляет archive и key.

## Shelf

Shelf не копирует исходные файлы. В UserDefaults хранятся пути до максимум 60 карточек. Если исходный файл исчез, он фильтруется при load. Результаты file tools создаются отдельно и могут быть добавлены на shelf.

## Backup

Backup schema v2 содержит:

- portable settings snapshot;
- snippets;
- notes;
- metadata schema/app version/date.

Не содержит clipboard history, encrypted keys, raw device identities, local selected-device key или содержимое Shelf files. Максимум backup — 10 MiB.

## Правило

Новый persisted datum должен документировать: location, schema/versioning, limit, portability, deletion semantics, privacy class и migration behavior.

## Связано

- [Data Classification](../06-security/data-classification.md)
- [Clipboard](../02-modules/clipboard.md)
- [Notes](../02-modules/notes.md)
- [Snippets](../02-modules/snippets.md)
