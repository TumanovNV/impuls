---
title: System Diagrams
type: architecture-diagrams
status: active
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, diagrams, mermaid]
---

# System Diagrams

Эта страница — единая карта основных схем. Detailed diagrams живут также в соответствующих документах.

## Component map

```mermaid
flowchart TB
    APP[AppDelegate] --> SET[SettingsStore]
    APP --> NC[NotchController]
    APP --> MB[MenuBarWorkspaceController]
    APP --> UP[UpdateService]
    APP --> TEL[VersionTelemetryService]
    NC --> VM[NotchViewModel]
    NC --> DC[DisplayCoordinator]
    NC --> PW[PointerWatcher]
    DC --> SURF[Per-display surfaces]
    VM --> MOD[9 module stores/services]
    MB -.reads existing state.-> VM
```

## Data boundary map

```mermaid
flowchart LR
    LOCAL[Local data] --> FS[Application Support]
    LOCAL --> UD[UserDefaults]
    LOCAL --> KC[Keychain]
    LOCAL --> PB[Pasteboard]
    LOCAL --> EK[EventKit]
    NET[Network] --> UP[Signed update channel]
    NET --> WEB[Explicit web music]
    NET --> TEL[Opt-in version heartbeat]
```

## Release map

```mermaid
flowchart LR
    DEV[Change] --> PR[Pull Request]
    PR --> CI[build.yml]
    CI --> MAIN[Merge main]
    MAIN -->|Scripts/version changed| REL[release.yml]
    REL --> TEST[Test + security gates]
    TEST --> APP[Bundle]
    APP --> DMG[DMG]
    APP --> ZIP[ZIP]
    ZIP --> AC[Signed appcast]
    DMG --> GH[GitHub Release vX.Y.Z]
    ZIP --> GH
    AC --> GH
    GH --> SITE[Website release sync]
```

## Documentation map

```mermaid
flowchart TD
    INDEX[INDEX.md] --> PROJ[00 Project]
    INDEX --> ARCH[01 Architecture]
    INDEX --> MODS[02 Modules]
    INDEX --> MAC[03 macOS]
    INDEX --> DEV[04 Development]
    INDEX --> REL[05 Release]
    INDEX --> SEC[06 Security]
    INDEX --> ADR[08 Decisions]
    INDEX --> AI[10 AI]
    INDEX --> HIST[11 History]
```

## Правило схем

Mermaid source является source of truth. Не добавлять вручную экспортированные PNG/SVG для схем без отдельной причины: они дрейфуют от Markdown и хуже анализируются агентами.
