---
title: Localization
type: development
status: active
documentation_version: 1.3
app_version: 1.5.0
last_reviewed: 2026-09-01
tags: [impuls, localization, russian, english, german, french, spanish, chinese, japanese]
---

# Localization

## IMP-54 review

The shipped application-language set remains exactly seven. IMP-54 adds a separate `AppIntents.strings` table to every existing `.lproj` for intent titles, module names, shortcut labels and stable user-facing automation errors; it does not add or remove a locale and does not alter `AppLanguageService`, `AppleLanguages`, `InfoPlist.strings`, website locales or legal locales. `Scripts/bundle.sh` already copies each complete `.lproj`, so the new tables travel with the same bundle localization set. App Intents metadata/phrase extraction is verified separately during bundle packaging; this document does not treat source tables alone as proof that system discovery metadata is valid.

## IMP-11 review

The shipped app-language set remains exactly seven. `NSAppleEventsUsageDescription` now truthfully covers supported native music apps, and Spotify/native-not-installed strings exist in every one of the seven `Localizable.strings` tables; `CFBundleLocalizations` is unchanged.

## Current baseline: three separate localization contracts

Impuls 1.4.15 currently exposes the same seven languages across three different public surfaces:

| Contract | Current locales | Canonical owner |
| --- | --- | --- |
| macOS application | `en`, `ru`, `de`, `fr`, `es`, `zh-Hans`, `ja` | `Resources/*.lproj` + `AppLanguageService` |
| marketing website | `ru`, `en`, `de`, `fr`, `es`, `ja`, `zh-Hans` | `Scripts/site-locales/registry.json` + `knowledge-base/07-web/website.md` |
| privacy / legal website | `ru`, `en`, `de`, `fr`, `es`, `ja`, `zh-Hans` | `privacy_path` in the same registry + `knowledge-base/07-web/legal-privacy.md` |

The sets are equal **on the current baseline, but they are not one contract**. A new app language does not become a website or legal language merely because a new `.lproj` exists. Likewise, a website locale must not be treated as proof that the app ships that localization.

When changing the supported-language set, review all three contracts explicitly and either update them together or document why they intentionally differ.

## Supported application languages

Product resources содержат семь localization tables под `Resources/`:

| `.lproj` | Language |
| --- | --- |
| `en` | English |
| `ru` | Русский |
| `de` | Deutsch |
| `fr` | Français |
| `es` | Español |
| `zh-Hans` | 简体中文 |
| `ja` | 日本語 |

Каждая папка содержит `Localizable.strings` и `InfoPlist.strings`. Вторая — это тексты системных диалогов разрешений: macOS предпочитает значение из подходящей `.lproj/InfoPlist.strings`, когда она существует.

Языки должны быть перечислены в `CFBundleLocalizations` (`Scripts/bundle.sh`). `.lproj` без записи в этом массиве попадёт в bundle, но macOS не сочтёт язык поддерживаемым: он не появится в выборе языка и его нельзя выбрать в настройках Impuls. `build.yml` проверяет и наличие обеих таблиц в собранном `.app`, и объявление каждого языка.

## Key model

`localized("…")` использует English phrase как key. Поэтому missing translation деградирует в readable English, а не opaque identifier.

## Application CI contract

Каждый literal `localized("key")` в Swift должен существовать во **всех** таблицах, и все таблицы обязаны нести одинаковый набор ключей. `Scripts/check-localization.py` берёт таблицы через `Resources/*.lproj/Localizable.strings`, поэтому новый язык попадает под проверку автоматически, как только появляется папка. Частичный перевод технически невозможен: таблица либо полная, либо CI красный.

Проверка на **дублирующиеся** ключи внутри одной таблицы живёт отдельно — в `Tests/PythonTests/test_version_statistics.py`. Сравнение множеств ключей дубликат не ловит, потому что он схлопывается в множество.

## Application change rule

Новый user-facing string добавляется во все семь таблиц в том же change set. Не добавлять direct hard-coded copy в pane, если оно должно локализоваться. Проверять plural/format arguments и визуальную длину: панель узкая, немецкий длиннее английского, а в `PowerPane` уже зафиксирован предел 127 pt.

Порядок и секционные комментарии новых таблиц повторяют `en.lproj`, чтобы диффы между языками читались построчно.

Если добавляется или удаляется **сам язык**, одного изменения `Resources/` недостаточно. Нужно как минимум проверить вместе:

1. `AppLanguage` / `AppLanguageService`;
2. обе таблицы `Localizable.strings` + `InfoPlist.strings`;
3. `CFBundleLocalizations` в `Scripts/bundle.sh`;
4. localization tests/build checks;
5. `knowledge-base/00-project/project-status.md` и этот документ;
6. website и legal contracts ниже — совпадают ли они с новым app set намеренно или должны временно отличаться.

## Format specifiers, dates and case

- Состав и порядок спецификаторов сохраняются. Если язык требует другого порядка — позиционные `%1$@`/`%2$@`, а не другое количество аргументов.
- `%%` — литеральный процент. Голый `%` в строке, которую читает только `localized(_:)` без аргументов, безопасен: форматирование там не выполняется.
- Ключи-паттерны даты (`"yyyy-MM-dd 'at' HH.mm.ss"`) остаются валидными для `DateFormatter`: переводится текст в кавычках, не паттерн-символы.
- Countdown-фразы хранятся со строчной буквы — заглавную добавляет `sentenceCased` на месте вызова.
- `ja`/`zh-Hans`: без пробелов между словами, полноширинная пунктуация.

## App Language setting

Settings → General → Language позволяет выбрать язык интерфейса. По умолчанию — «Системный»: Impuls следует `Bundle.main.preferredLocalizations`, то есть выбору macOS.

Канонич­ная схема одна:

```text
Settings UI → AppLanguageService → app.language.v1 → AppleLanguages
```

`AppLanguageService` — единственный владелец: ему принадлежат ключ `app.language.v1`, валидация локали, установка/удаление `AppleLanguages` и вычисление `requiresRelaunch`. `SettingsStore` держит сервис по композиции и **не** хранит второй копии предпочтения.

Различайте два ключа: `app.language.v1` — выбор, сделанный внутри Impuls; `AppleLanguages` — системный механизм per-app языка, тот же самый, который использует macOS в «Настройки → Язык и регион → Программы». Поэтому:

- инициализация сервиса **никогда** не пишет и не удаляет `AppleLanguages`. Отсутствующее, `system` или повреждённое значение `app.language.v1` просто трактуется как «выбора нет»;
- `AppleLanguages` устанавливается только при явном выборе конкретного языка в настройках Impuls;
- удаляется только при явном возврате на «Системный» **после** собственного override Impuls. Если Impuls этот ключ не создавал, он остаётся нетронутым.

Список доступных локализаций инжектится в сервис (по умолчанию из бандла приложения), потому что под `swift test` `Bundle.main` — это xctest-раннер, а не `Impuls.app`.

### Почему переключение применяется после перезапуска

`localized(…)` покрывает 439 ключей, но ещё 108 call sites локализует сам SwiftUI: `Text`, `Button`, `Toggle`, `Section`, `Picker`, `Label` принимают `LocalizedStringKey` и резолвятся через `Bundle.main` внутри SwiftUI. Перенаправление одного только helper'а дало бы интерфейс наполовину на одном языке и наполовину на другом. Достать вторую половину можно лишь подменой класса `Bundle.main` или отказом от литеральной локализации SwiftUI — оба варианта отвергнуты.

Поэтому выбор сохраняется и применяется при следующем запуске. Это шире, чем override внутри helper'а: на выбранный язык переходят и литералы SwiftUI, и `appLanguage` (а с ним форматтеры дат), и `InfoPlist.strings`.

### Безопасный автоматический перезапуск

После выбора языка Impuls показывает подтверждение «Перезапустить Impuls?» с кнопками «Отмена» и «Перезапустить». По подтверждению приложение перезапускает себя само — пользователю не нужно ни закрывать его вручную, ни перезагружать Mac.

Порядок здесь — требование безопасности, а не удобства. Двух одновременно живых экземпляров быть не должно: глобальный хоткей регистрируется однократно через `RegisterEventHotKey` без повторной попытки, защиты от второго экземпляра в проекте нет, а межпроцессной координации записи у сторов тоже нет — два процесса могли бы затереть `notes.json`, историю буфера и полку. Поэтому запрещён порядок «запустить новый → закрыть старый», и `open -n` / `createsNewApplicationInstance` не используются: этот флаг существует ровно для того, чтобы поднять второй экземпляр уже работающего приложения.

`AppRelaunchService` реализует обратный порядок:

1. язык уже сохранён в `app.language.v1` и `AppleLanguages`, запись сброшена на диск;
2. запускается одноразовый helper `/bin/sh` — без login item, launch agent, демона и новых зависимостей;
3. **только если helper стартовал**, текущий процесс вызывает `NSApp.terminate`;
4. helper ждёт исчезновения PID старого процесса через `kill -0`, то есть по фактическому состоянию процесса, а не по таймеру;
5. после короткой паузы на завершение teardown helper выполняет `open` **того самого** bundle URL и выходит.

PID и путь передаются helper'у позиционными аргументами и никогда не интерполируются в текст скрипта. Точный `Bundle.main.bundleURL` важен для разработки: если запущен `build/Impuls.app`, вернуться должен он, а не копия в `/Applications`.

Fail-safe важнее автоматики. Если PID не исчез за отведённое время (100 проверок по 0,1 с), helper завершается **не открывая ничего** — второй экземпляр поверх живого хуже, чем несостоявшийся перезапуск. Если helper вообще не удалось запустить, Impuls не завершается и показывает локализованную ошибку; выбранный язык при этом остаётся сохранённым и применится при следующем обычном запуске.

«Отмена» не откатывает выбор языка: он уже сохранён, `requiresRelaunch` остаётся `true`, а в секции Language остаётся кнопка «Перезапустить Impuls», чтобы выполнить перезапуск позже.

`requiresRelaunch` означает «предпочтение изменено в текущей сессии», а не «enum отличается от фактического языка»: под `system` фактическая локаль всегда конкретна, и прямое сравнение показывало бы сообщение о перезапуске после каждого обычного старта. Сервис запоминает `selectionAtLaunch` в памяти процесса — это не второй persistent preference.

Ручной сценарий записан как `UI-07` в [Behavioral QA Matrix](../13-qa/behavioral-qa-matrix.md).

## Marketing website localization

Website localization отделена от app string tables. На baseline 1.4.15 сайт имеет семь реальных static locale URL:

```text
ru       /
en       /en/
de       /de/
fr       /fr/
es       /es/
ja       /ja/
zh-Hans  /zh-hans/
```

Canonical engineering owner: [Website Architecture](../07-web/website.md).

Основные правила:

- `docs/index.html` — canonical RU content/layout source;
- `Scripts/site-locales/registry.json` — единственный canonical список опубликованных website locales и их public `path`;
- `Scripts/build-site-locale.py` — один generic builder для всех non-default locales;
- `Scripts/site-locales/<locale>.json` хранит locale-specific website copy/metadata;
- generated `docs/en/`, `docs/de/`, `docs/fr/`, `docs/es/`, `docs/ja/`, `docs/zh-hans/` не редактируются вручную;
- `zh-Hans` — BCP-47 locale code, но website path — `/zh-hans/`; path всегда читается из registry;
- `.github/workflows/site-localization.yml` проверяет static pages, reciprocal `hreflang`, no-JS behavior и routing;
- `.github/workflows/site-release-sync.yml` после merge/release синхронизирует и коммитит generated website markup.

`Scripts/sync-site-product-facts.py` владеет durable marketing fact о семи языках. Если shipped app locale set меняется, нельзя поправить только текст «7 языков» в HTML: нужно обновить источник факта, соответствующие locale configs/assertions и заново построить страницы.

## Privacy / legal localization

Legal pages — третий отдельный contract. Canonical engineering owner: [Website Legal and Privacy Localization](../07-web/legal-privacy.md).

На текущем baseline опубликованы:

```text
ru       /privacy/
en       /en/privacy/
de       /de/privacy/
fr       /fr/privacy/
es       /es/privacy/
ja       /ja/privacy/
zh-Hans  /zh-hans/privacy/
```

Основные правила:

- Russian `/privacy/` — source policy;
- `privacy_path` для каждой локали принадлежит `Scripts/site-locales/registry.json`;
- `Scripts/site-privacy-locales/<locale>.json` хранит legal copy;
- `Scripts/site-privacy-template.html` + `Scripts/build-site-privacy-locale.py` генерируют все семь legal pages;
- `Scripts/site-privacy-locales/metadata.json` хранит machine-readable policy `revision` и `effective_date`; sitemap `lastmod` legal pages должен происходить из этой даты, а не из wall clock или старого sitemap;
- `/site-privacy.html` — только legacy `noindex,follow` handoff на `/privacy/`;
- `.github/workflows/site-legal-localization.yml` проверяет structure, canonical/hreflang, routes, factual privacy anchors and determinism;
- `.github/workflows/site-release-sync.yml` материализует legal pages в `docs/**/privacy/index.html` после merge.

DE/FR/ES/JA/zh-Hans marketing/legal translations are AI-assisted and technically/structurally reviewed; native-speaker review must never be claimed until it actually happens.

## Adding an eighth language

Do not start from a copied page. Start from the contract being expanded.

### App

Add the `.lproj`, both string tables, `AppLanguage` case and bundle declaration, then pass localization/build tests.

### Website

Add one `Scripts/site-locales/<locale>.json` config and one registry entry with explicit `path`, then let the generic builder/sync workflows create the static page.

### Legal

Add `privacy_path` to the same registry entry plus `Scripts/site-privacy-locales/<locale>.json`; the generic legal builder must generate the page and legal CI must prove reciprocal hreflang/sitemap parity.

If all three surfaces are intended to grow together, the same PR/release train should update all three contracts and their documentation. If only one surface grows, record that divergence explicitly instead of leaving agents to infer it.
