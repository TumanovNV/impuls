---
title: Current Limitations
type: known-limitations
status: active
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, limitations, qa]
---

# Current Limitations

Это **known constraints**, а не список всех bugs/issues. Для live bugs использовать GitHub Issues.

## Distribution identity

Пока публичный build идёт по ad-hoc fallback без Developer ID/notarization, first install может требовать ручного Gatekeeper approval, а macOS permissions могут быть менее стабильны между replacement builds. Update signature security остаётся отдельной и не отключается.

## Apple devices

iPhone/iPad battery path остаётся Beta: transport опирается на Apple device protocol, который не является публичным supported app API. Hardware coverage не означает поддержку каждой model/iOS combination. External discovery по умолчанию off.

## Hardware metrics

Power module показывает только данные, которые реально предоставляет конкретный Mac/macOS. Active charging connector, temperature, adapter/current/cycle fields могут отсутствовать. Missing value не угадывается.

## Web music

Web sources зависят от provider websites и их auth/player behavior. Изменение site DOM/Media Session/WKWebView compatibility может потребовать adapter update. Spotify не предлагается из-за Widevine limitation WebKit.

## Translation

Не каждая language pair поддерживается Apple Translation framework напрямую. Требуемый language asset может быть не установлен; module сообщает downloadable/unsupported state вместо бесконечного system prompt.

## Calendar

Без explicit full Calendar access module не читает events. All-day/cancelled events исключаются по product design; join-link detection ограничена known HTTPS providers.

## Statistics

Version statistics opt-in и поэтому не отражает абсолютную аудиторию. GitHub asset download count тоже не эквивалентен unique users/installations.

## Manual QA dependency

External displays/Sidecar, TCC dialogs, VoiceOver, real device batteries и некоторые appearance/hardware cases требуют physical/manual acceptance; automated tests не должны изображать их как hardware verification.
