---
title: Local Build and Development
type: development
status: active
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, development, build, swift]
---

# Local Build and Development

## Baseline

Swift Package Manager project, macOS 15+, Swift 6 toolchain with target language mode currently `.v5`. External package: Sparkle exact 2.9.5.

## Standard commands

```bash
swift test -c release
./Scripts/bundle.sh release
./Scripts/dmg.sh
open build/Impuls.app
```

Release-quality change должен запускать tests до build. `bundle.sh` создаёт `build/Impuls.app`; `dmg.sh` формирует distribution image/update material для локальной проверки.

## Environment-sensitive values

- `IMPULS_DEVELOPER_ID_APPLICATION` — optional local/CI signing identity;
- `IMPULS_VERSION_STATISTICS_ENDPOINT` — build-time endpoint; без него telemetry boundary inert;
- Sparkle private signing key **не** является local source setting и в production хранится в GitHub secret.

## Test isolation

Не создавай `NotchViewModel` с implicit live storage в tests. Используй injected `NotchEnvironment` / `StorageEnvironment`; clipboard persistence в tests должна быть explicit and safe, чтобы не затронуть real Keychain key.

## Before commit/PR

- `swift test -c release`;
- relevant Python tests, если затронуты Collector/site/scripts;
- `git diff --check`;
- localization parity для новых strings;
- соответствующий manual QA, если code зависит от real TCC/hardware/display/appearance;
- knowledge-base update, если изменился contract.

## Do not

Не коммить signing keys/tokens/secrets. Не добавляй dependency без review. Не заменяй штатный release pipeline ручным tag/release process.
