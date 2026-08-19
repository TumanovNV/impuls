---
title: Localization
type: development
status: active
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, localization, russian, english]
---

# Localization

## Supported languages

Product resources содержат English и Russian localization tables:

- `Resources/en.lproj/Localizable.strings`
- `Resources/ru.lproj/Localizable.strings`

## Key model

`localized("…")` использует English phrase как key. Поэтому missing translation деградирует в readable English, а не opaque identifier.

## CI contract

Каждый literal `localized("key")` в Swift должен существовать в обеих tables. `build.yml` автоматически собирает keys из source и падает при missing entry.

## Change rule

Новый user-facing string добавляется в RU и EN в том же change set. Не добавлять direct hard-coded copy в pane, если оно должно локализоваться. Проверять plural/format arguments и визуальную длину русского текста.

## Website

Website localization отделена от app string tables. RU page — `docs/index.html`; EN page генерируется/проверяется отдельным site script. Не смешивать две системы автоматического generation.
