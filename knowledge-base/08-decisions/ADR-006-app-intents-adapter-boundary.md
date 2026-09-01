---
title: ADR-006 App Intents Adapter Boundary
type: decision
status: accepted
documentation_version: 1.0
app_version: 1.5.0
last_reviewed: 2026-09-01
tags: [impuls, adr, app-intents, shortcuts, automation]
---

# ADR-006: App Intents use the existing runtime owners

- Status: Accepted
- Decision date: 2026-09-01
- Tasks: IMP-53, IMP-54

## Context

System automation needs to open Impuls modules and perform a small number of explicit mutations. The existing application already has authoritative owners for display routing, shared service state and persistence. Creating a separate automation controller or store would duplicate timers, display state and private data ownership, and would make cold-launch behavior diverge from normal app behavior.

## Decision

App Intents are thin adapters over the existing runtime.

`AppDelegate` constructs and installs the normal `NotchController` and shared `NotchViewModel` first, then installs a narrow `ImpulsAutomationRuntime` bridge. A system invocation that arrives during cold launch waits for that bridge for a bounded period. It never constructs replacement owners.

The executable target owns the `AppIntent`, `AppEnum` and `AppShortcutsProvider` types. The core target exposes only typed automation commands, bounded explicit inputs and stable errors.

The first shipping wave contains three intent types only: Show Impuls, parameterized Open Module, and Add Text to Snippets. Module-specific shortcut tiles are preset values of Open Module.

## Rejected alternatives

- A generic executor accepting arbitrary action identifiers.
- Direct App Intent access to `NotchViewModel` or product stores.
- A second `NotchController` or storage graph for background execution.
- A toggle intent whose result depends on hidden presentation state.
- Returning clipboard history through system automation.
- Exposing device identifiers or raw power-provider data before a separate redaction contract exists.

## Consequences

The system automation surface stays intentionally smaller than the in-app feature surface. New intents require an explicit privacy/lifecycle decision rather than automatically inheriting every menu action.

Cold launch has a bounded readiness dependency on normal application composition, but this preserves one owner graph and gives terminated/background/frontmost execution the same semantics.

Because the app is packaged manually from SwiftPM, release packaging must run App Intents metadata extraction and CI must verify `Metadata.appintents` is present before signing/release.
