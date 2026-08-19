---
title: Release Pipeline
type: release
status: active
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, release, github-actions, artifacts]
---

# Release Pipeline

## End-to-end

```mermaid
flowchart TD
    A[Feature/fix branch] --> PR[Pull Request]
    PR --> BUILD[build.yml]
    BUILD --> T1[Swift + Python tests]
    BUILD --> POL[Security/policy grep gates]
    BUILD --> BUNDLE[Build app + codesign verify]
    BUILD --> SMOKE[Launch: zero unsolicited sockets]
    T1 --> MERGE[Merge to main]
    POL --> MERGE
    BUNDLE --> MERGE
    SMOKE --> MERGE
    MERGE -->|Scripts/version changed| REL[release.yml]
    REL --> VERIFY[Repeat security + tests]
    VERIFY --> APP[Impuls.app]
    APP --> DMG[Impuls-X.Y.Z.dmg]
    APP --> ZIP[Impuls-X.Y.Z.zip]
    ZIP --> APPCAST[Signed appcast.xml]
    DMG --> SHA[SHA-256]
    ZIP --> SHA
    APPCAST --> SHA
    SHA --> GH[GitHub Release vX.Y.Z]
    GH --> SITE[Site release metadata sync]
```

## Release source of truth

- version: `Scripts/version`;
- release notes: `docs/releases/<version>.md`;
- product source: `main` after merge;
- workflow: `.github/workflows/release.yml`.

Version и release notes должны путешествовать вместе.

## Build CI

Pull requests against `main`/`release/**` запускают build. Markdown-only push в main может быть ignored через `paths-ignore`, но PR policy checks зависят от changed paths/workflow rules.

## Release trigger

`release.yml` запускается на push в main, когда изменён `Scripts/version` или сам `release.yml`, а также вручную. Workflow умеет reissue existing version metadata, что использовалось для исправления release pipeline без фиктивного bump.

## Artifact verification

Pipeline проверяет bundle identity, version, Sparkle linkage, entitlements, codesign, DMG verify, ZIP extraction + codesign, appcast XML/signature/length, SHA-256.

## Production telemetry endpoint

Release env получает `IMPULS_VERSION_STATISTICS_ENDPOINT` из repository variable. Pipeline fail-closed требует HTTPS host и exact `/v1/heartbeat`, затем проверяет value внутри built `Info.plist`.

## Website

`docs/` GitHub Pages не должен hardcode current release как единственный источник. Site sync обновляет static fallback/SEO metadata, а runtime release API остаётся отдельным current-release source для browser page.

## Rollback / failure

Не «чинить» сломанный release ручной загрузкой произвольных assets. Исправляется workflow/branch, проверки повторяются, затем release reissue через штатный pipeline.

## Связано

- [Release Process](release-process.md)
- [Update System](update-system.md)
- `.github/workflows/build.yml`
- `.github/workflows/release.yml`
