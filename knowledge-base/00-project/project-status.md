---
title: Project Status
type: status
status: active
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, status, current]
---

# Текущее состояние проекта

## Baseline

**Current `main` product baseline: 1.4.11.** Источник версии — `Scripts/version`. Documentation baseline: **1.1**.

## Current product surface

- native macOS 15+ Swift/SwiftUI-on-AppKit application;
- 9 panel modules;
- one shared service graph + per-display presentation surfaces;
- configurable Menu Bar workspace;
- onboarding / What's New;
- local backup/restore for portable settings + snippets + notes;
- opt-in signed Sparkle updates;
- separate opt-in version statistics;
- Power/Battery center with explicitly enabled external Apple devices;
- RU/EN localization.

## Documentation coverage 1.1

Current knowledge base now contains application lifecycle, state ownership, multi-display, persistence, permissions, networking, system diagrams, detailed pages for every module, Menu Bar, macOS TCC, testing/SOPs, update/release pipeline, threat model, data classification, privacy boundaries, ADR-001…005 and AI impact routing.

## Current architectural anchors

1. one `NotchViewModel` per process;
2. exactly one active display surface;
3. three Internet network owners;
4. sensitive permission prompts only after explicit user action;
5. local-first content and bounded reads;
6. raw device identities never cross presentation/privacy boundary;
7. signed update verification independent of Apple Developer ID availability.

## Next documentation work

Documentation 1.2 should focus on API/type-level reference where useful, generated cross-link validation, per-subsystem test matrix, operational collector/dashboard runbooks and formal migration/schema registry as those areas evolve.
