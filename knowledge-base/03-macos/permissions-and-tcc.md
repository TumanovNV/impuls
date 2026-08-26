---
title: macOS Permissions and TCC
type: platform
status: active
documentation_version: 1.2
app_version: 1.4.16
last_reviewed: 2026-08-26
tags: [impuls, macos, tcc, permissions]
---

# macOS Permissions and TCC

## Матрица

| Capability | macOS mechanism | Prompt owner | Auto-prompt allowed? |
| --- | --- | --- | --- |
| Calendar | EventKit / TCC | Calendar UI | No |
| Apple Music / Spotify control | Apple Events Automation / TCC per target app | Music UI | No |
| Low battery notifications | UserNotifications | explicit setting/action | No |
| iPhone/iPad trust | Apple device trust/pairing | device/macOS relationship | Impuls must not trigger pairing blindly |
| Files selected/dropped | normal user-selected filesystem access | user action | N/A |
| Clipboard | NSPasteboard | system API | no TCC prompt |
| Translation | Apple Translation framework | system language assets | not a privacy TCC grant |

## Calendar states

`fullAccess` → allowed; `notDetermined` → not requested; denied/restricted/write-only are not treated as full read access.

IMP-21 reviews this boundary: both strict local Teams URL forms run only after the existing Calendar read access and do not alter EventKit fields, TCC state mapping or prompt ownership.

## Music Automation

Status check is non-prompting. If not determined, user action may request Automation. If denied, UI opens the Automation pane in System Settings. Apple Music and Spotify have independent target-app TCC states; an absent Spotify app is unavailable without a prompt.

## Notifications

`PermissionCenter` treats `.authorized` / `.provisional` as allowed. `notDetermined` is still not granted. Low-battery alert code may ask only when the user enables the feature with request authorization intent.

## Prompt text and language

Тексты usage description живут в `Resources/<lang>.lproj/InfoPlist.strings` — по одной таблице на каждый из семи поставляемых языков. macOS предпочитает значение из подходящей `.lproj/InfoPlist.strings`, когда она существует, поэтому строка, которую пользователь читает в системном диалоге, следует языку приложения, включая выбор в Settings → General → Language (он применяется со следующего запуска).

Границу нужно понимать точно: Impuls владеет **своей** строкой usage description, но не остальной частью диалога. Кнопки, заголовки и прочий chrome остаются на языке macOS, и это не дефект Impuls. Дефект — отсутствие локализованной usage description или показ строки не той локали. Ручная проверка записана как `UI-07` в [Behavioral QA Matrix](../13-qa/behavioral-qa-matrix.md).

Добавление языка требует новой `InfoPlist.strings` **и** записи в `CFBundleLocalizations` (`Scripts/bundle.sh`); CI проверяет и то, и другое в собранном `.app`.

## Update/reinstall caveat

Without stable Developer ID identity, macOS may treat replaced builds in ways that require permissions to be granted again. Это distribution/signing limitation, а не повод обходить TCC или автоматически повторять prompts.

## Изменения 1.4.12-hardening

TCC-контракт не менялся. Правка в `PlayerBridge` касалась только безопасного преобразования позиции воспроизведения; ни один вызов, вызывающий системный запрос, не добавлен и не перемещён.

IMP-11: `NativeMusicBridging`/`LivePlayerBridge` передаёт явно выбранный `PlayerApp` в `automationAuthorization(for: app, prompt:)`: Apple Music использует `.music`, Spotify — `.spotify`. TCC status и denial остаются независимыми per target application; автоматические проверки используют `prompt: false`, а prompt доступен только после явного user action. Отсутствующий Spotify unavailable без prompt.

Перепроверено после исправления Spotify script wire format и native fallback guard: ни одно из этих изменений не добавляет Apple Events target, не меняет момент запроса TCC и не переводит automatic check в prompting режим.

Статусы Automation теперь различают шесть ситуаций target app вместо четырёх: `allowed`, `denied`, `notRequested` и `restricted` — вердикты TCC; `appNotRunning` (`procNotFound`, приложение установлено, но закрыто) и `notInstalled` — не вердикты и никогда не должны выглядеть как policy restriction. `notInstalled` определяется до обращения к TCC, поэтому для отсутствующего приложения Automation-запрос не отправляется. Ни один из новых случаев не запускает приложение и не показывает prompt: оба разрешаются повторным `refresh()` после того, как пользователь сам откроет приложение.

## Entitlements


CI проверяет calendar and automation entitlements в built app. Изменение entitlement требует security/privacy review.

## Связано

- [Permission Architecture](../01-architecture/permissions.md)
- `Resources/Impuls.entitlements`
- `Resources/Impuls.AdHoc.entitlements`
- `Sources/Impuls/Settings/PermissionCenter.swift`
