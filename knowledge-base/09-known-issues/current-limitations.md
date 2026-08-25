---
title: Current Limitations
type: known-limitations
status: active
documentation_version: 1.1
app_version: 1.4.12
last_reviewed: 2026-08-20
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

## Отменяемость файловых операций

Закрыто в 1.4.16 (#101) в той части, которая может быть закрыта честно: у долгих пачек есть явный Cancel, отмена принимается между items (а у PDF — между страницами), уже готовые результаты сохраняются, незавершённый PDF удаляется, а `isWorking` всегда возвращается в false. См. [Shelf](../02-modules/shelf.md).

Что **осталось** осознанной границей:

- отмена не прерывает item, который уже выполняется. Один convert/resize/OCR/background removal — это один синхронный ImageIO/Vision вызов, и публичного API, безопасно прерывающего его на середине без риска обрезанного файла, нет. `VNRequest.cancel()` существует, но Apple не документирует ни безопасность его вызова параллельно с синхронным `VNImageRequestHandler.perform(_:)`, ни то, в каком состоянии остаются `request.results`; полагаться на это ради «мгновенной» отмены — обмен реального риска порчи результата на косметику. Пересмотр — кандидат в 1.4.17+, но только с доказательством, а не с предположением;
- запущенная операция переживает закрытие панели. Это контракт, а не пробел: пользователь запустил её явно, и закрытие панели не должно молча выбрасывать уже сделанную работу;
- завершение процесса во время in-flight item по-прежнему может оставить частично записанный файл. Отмена этого не решает: процесс умирает внутри системного вызова записи.

## Автоматическое возобновление записи после нечитаемого архива буфера

Если зашифрованный архив истории буфера существует, но эта сборка не может его открыть, включение persistence больше не затирает его. Однако следующее пользовательское копирование возобновляет обычную запись и архив всё-таки заменяется. Осознанная граница: исправление закрывает автоматический путь, где пользователь не делал ничего кроме переключения, но не превращает модуль в хранилище, которое перестаёт писать навсегда. См. [Clipboard](../02-modules/clipboard.md).

## Manual QA dependency

External displays/Sidecar, TCC dialogs, VoiceOver, real device batteries и некоторые appearance/hardware cases требуют physical/manual acceptance; automated tests не должны изображать их как hardware verification.

## Address separator normalization в device identity (IMP-10 / B2)

`DeviceIdentityResolver.identity(forRawIdentifier:kind:)` строит HMAC над `kind.rawValue` + `0x1F` + `rawIdentifier.trimmed.lowercased()`. **Separator normalization не выполняется** — только lowercasing. Формально это значит, что `AA:BB:…` и `AA-BB-…` для одного физического устройства дали бы разные identity и, следовательно, две карточки.

**Статус: изменений не вносится, доказательств недостаточно.** Замер на реальном Mac (2026-08-25) показал, что все устройства из `system_profiler` используют один и тот же формат (`:`-separator, uppercase, длина 17) — включая AirPods. Расхождение существует только между live-выводом и одной старой captured-фикстурой в тестах (`-`-separator, lowercase), то есть внутри тестовых данных, а не между двумя production-источниками. Формат `DeviceAddress` из IORegistry проверить не удалось: подключённого Apple-аксессуара с батареей на этом Mac нет.

Почему это не «просто нормализовать»: от `AppleDeviceIdentity.localPreferenceKey` (это и есть HMAC-hex) зависят порядок и скрытые устройства (`appleDevices.presentation.v1`), выбранное устройство Menu Bar, dedup-состояние low-battery уведомлений (`appleDevices.lowBatteryAlerts.v1`) и выбор устройства в Power/Settings. Любое изменение входа HMAC инвалидирует все эти ключи разом. Сырой идентификатор намеренно нигде не хранится, поэтому пересчитать старый ключ «на месте» нельзя — миграция возможна только ленивая, в момент, когда устройство снова появится и сырой адрес снова доступен.

Пересматривать только при реальном доказательстве, что два production-источника отдают одно устройство в разных форматах. Проверяется за секунды при подключённом Magic Mouse/Keyboard/Trackpad.
