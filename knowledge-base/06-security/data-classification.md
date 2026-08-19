---
title: Data Classification
type: security
status: active
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, security, privacy, data]
---

# Data Classification

## Классы

| Data | Class | Location | Network | Backup |
| --- | --- | --- | --- | --- |
| Settings/preferences | local configuration | UserDefaults | No | portable subset: Yes |
| Notes | user content | `notes.json` | No | Yes |
| Snippets | user content | `snippets.json` | No | Yes |
| Clipboard history | sensitive transient content | memory; optional encrypted archive | No | No |
| Clipboard encryption key | secret | Keychain ThisDeviceOnly | No | No |
| Shelf paths | local references | UserDefaults | No | No file contents |
| Calendar events | sensitive system data | EventKit/runtime only | No product network | No |
| Translation input/output | user content | runtime | No Impuls network | No |
| Music metadata | contextual media state | runtime | web provider only when explicitly opened | No |
| Web music cookies/session | provider web data | WebKit subsystem | provider domains | No Impuls backup |
| Local Mac battery | device/system data | runtime | No | No |
| External device battery | device/system data | runtime | No Internet product network | No |
| Raw UDID/serial/pairing material | restricted identifier/secret | device transport boundary only | Never product telemetry | Never |
| Opaque device preference key | local pseudonymous identity | UserDefaults local-only | No | No |
| Version-statistics installation UUID | pseudonymous identifier | Keychain ThisDeviceOnly | Only opt-in heartbeat | No |
| App version / previous version | product metadata | runtime/UserDefaults | Only opt-in heartbeat | N/A |

## Правила

1. User content по умолчанию local.
2. Secret/identity material не должен попадать в UI, logs, feedback, backup или telemetry.
3. Любой новый persisted field получает location, retention, deletion, backup и migration policy.
4. Любой новый outbound field требует privacy/security review и allow-list payload.
5. Missing hardware data не превращается в synthetic user data.

## Backup boundary

Backup v2 специально узкий: settings snapshot + snippets + notes. Clipboard, device identities, Keychain secrets, Shelf file contents и telemetry identity excluded.

## Связано

- [Storage and Persistence](../01-architecture/storage-persistence.md)
- [Privacy Boundaries](privacy-boundaries.md)
- `PRIVACY.md`
