---
title: macOS Permissions and TCC
type: platform
status: active
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, macos, tcc, permissions]
---

# macOS Permissions and TCC

## Матрица

| Capability | macOS mechanism | Prompt owner | Auto-prompt allowed? |
| --- | --- | --- | --- |
| Calendar | EventKit / TCC | Calendar UI | No |
| Apple Music control | Apple Events Automation / TCC | Music UI | No |
| Low battery notifications | UserNotifications | explicit setting/action | No |
| iPhone/iPad trust | Apple device trust/pairing | device/macOS relationship | Impuls must not trigger pairing blindly |
| Files selected/dropped | normal user-selected filesystem access | user action | N/A |
| Clipboard | NSPasteboard | system API | no TCC prompt |
| Translation | Apple Translation framework | system language assets | not a privacy TCC grant |

## Calendar states

`fullAccess` → allowed; `notDetermined` → not requested; denied/restricted/write-only are not treated as full read access.

## Music Automation

Status check is non-prompting. If not determined, user action may request Automation. If denied, UI opens the Automation pane in System Settings.

## Notifications

`PermissionCenter` treats `.authorized` / `.provisional` as allowed. `notDetermined` is still not granted. Low-battery alert code may ask only when the user enables the feature with request authorization intent.

## Update/reinstall caveat

Without stable Developer ID identity, macOS may treat replaced builds in ways that require permissions to be granted again. Это distribution/signing limitation, а не повод обходить TCC или автоматически повторять prompts.

## Entitlements

CI проверяет calendar and automation entitlements в built app. Изменение entitlement требует security/privacy review.

## Связано

- [Permission Architecture](../01-architecture/permissions.md)
- `Resources/Impuls.entitlements`
- `Resources/Impuls.AdHoc.entitlements`
- `Sources/Impuls/Settings/PermissionCenter.swift`
