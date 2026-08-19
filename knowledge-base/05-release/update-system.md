---
title: Update System
type: release
status: active
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, updates, sparkle, security]
---

# Update System

## Контракт

Update channel — opt-in network boundary на Sparkle 2.9.5 с fixed GitHub appcast и signed archive verification.

```mermaid
sequenceDiagram
    participant U as User
    participant I as Impuls / UpdateService
    participant S as Sparkle
    participant G as GitHub Releases

    I->>U: Ask once whether update checks are allowed
    U-->>I: allowed / denied
    alt allowed
        I->>S: enable automaticChecksForUpdates
        S->>G: fetch fixed appcast.xml
        G-->>S: signed feed metadata
        S->>G: download ZIP when update proceeds
        G-->>S: signed archive
        S->>S: verify before extraction
        S->>I: atomic replace + relaunch
    else denied
        I-->>G: no update request
    end
```

## Feed boundary

Точный URL: `https://github.com/TumanovNV/impuls/releases/latest/download/appcast.xml`. `UpdateService.isAllowedFeedURL` проверяет scheme/host/path и отсутствие port/query/fragment/user/password.

## Consent

States: unknown, allowed, denied. Default unknown. Если denied, automatic downloads принудительно off. Automatic installation можно включить только после network consent.

## Sparkle settings

CI проверяет:

- Sparkle exact 2.9.5 + resolved revision;
- `SUVerifyUpdateBeforeExtraction = true`;
- `SURequireSignedFeed = true`;
- system profiling = false;
- automatic checks/downloads default false;
- scheduled interval 86400;
- public Ed25519 key соответствует release signing secret.

## Signing chain

Release workflow использует private Ed25519 seed из GitHub secret для генерации appcast и signature ZIP. Secret никогда не коммитится. Built app содержит только public key.

## Developer ID

`bundle.sh` использует Developer ID, если `IMPULS_DEVELOPER_ID_APPLICATION` настроен; иначе fallback ad-hoc. Sparkle update authenticity и Apple notarization/signing — разные trust layers. Отсутствие Developer ID влияет на Gatekeeper/permission continuity, но не должно ослаблять Sparkle signature checks.

## Инварианты

- never create release/update assets by hand outside established workflow;
- feed URL fixed;
- no update networking without consent;
- signed feed + verify-before-extraction always on;
- system profile always off;
- dependency bump Sparkle требует отдельного security review.

## Связано

- [Release Pipeline](release-pipeline.md)
- [ADR-005](../08-decisions/ADR-005-signed-update-trust-chain.md)
- [Networking](../01-architecture/networking.md)
