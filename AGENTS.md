# AGENTS.md

Instructions for coding agents working on Impuls. Read this, then route.

Impuls is a native macOS utility that turns the area around the MacBook notch, or the top edge of another Mac/display, into a local workspace for Actions search, music, file shelf, clipboard history, snippets, calendar, translator, notes and power/device status. Swift 6 toolchain, SwiftUI on top of AppKit, macOS 15 or newer. The product is local-first.

## Start here

```bash
python3 Scripts/agent-context.py <changed-path> [<more-paths>…]
```

It prints the domain, the one canonical document to read first, the source and tests that own the behaviour, the Behavioral QA IDs, and the conditional owners with the trigger that makes each one required. Read what it returns; do not pre-load the rest.

The router reads `PROJECT-MANIFEST.json` and `Scripts/qa-impact-rules.json` itself, so neither has to be pulled into context to find a route. `PROJECT-MANIFEST.json` remains the routing-only source of truth for stable topology; read it directly only when you are changing that topology.

`DOMAIN` names the documentation owners. `QA OVERLAY` names a rule that owns tests and Behavioral QA IDs for paths documented elsewhere — it contributes verification, never a second canonical document, and never an escalation. Only two `DOMAIN` entries mean a genuinely cross-domain change.

If the router prints `UNROUTED`, fall back to `knowledge-base/10-ai/AI-INDEX.md`, and add the missing route. `AI-INDEX.md` is also the right entry for broad architecture exploration or an explicit audit — it is not a cold-start requirement for a local task. `NO PRIMARY DOMAIN` means only an overlay claimed the path: use the triggers it lists, then add a primary route.

Routes name project documentation only. Agent-specific rule files are each agent's own concern and are never routed to here.

## Context budget

Canonical contract: [Agent rules](knowledge-base/10-ai/agent-rules.md).

Route first. Search before opening. Never read all of `knowledge-base/`, `Sources/` or `Tests/` for a local change. Historical material under `docs/` and `knowledge-base/11-history/` is evidence on demand, never current state. `knowledge-base/00-project/project-status.md` is for when the shipped baseline actually matters; `pre-audit-baseline-1.4.12.md` is for an explicit whole-repository audit. Stop expanding once the owner, the implementation and the tests are in hand.

**The budget never outranks correctness.** If the change turns out to cross a network, persistence, concurrency, localization, security or release boundary that the route did not predict, expand to that owner immediately.

## Universal invariants

Terse on purpose, and kept here rather than only behind a link: these must hold even when a route is wrong or absent. The canonical owner carries the detail.

1. **Current state beats history.** Code, tests and CI are the contract; a release handoff is not. → [Agent rules](knowledge-base/10-ai/agent-rules.md)
2. **`Scripts/version` owns the version.** Never restate a version as a second source of truth. → [Project status](knowledge-base/00-project/project-status.md)
3. **Never bump `VERSION`** outside an explicit release task. → [Release process](knowledge-base/05-release/release-process.md)
4. **No private Apple frameworks or APIs**, no process injection, no `/usr/bin/perl`, `MediaRemote`, `dl_load_file`, `DynaLoader`. → [Security model](knowledge-base/06-security/security-model.md)
5. **No new outbound network path.** Internet access has exactly three owners, plus one documented local socket owner. Anything else is an architecture change. → [Networking](knowledge-base/01-architecture/networking.md)
6. **No secrets and no raw hardware identifiers** in the repository, logs, docs, tests, fixtures or telemetry — no MAC, serial, UDID, UUID or pairing material. → [Privacy boundaries](knowledge-base/06-security/privacy-boundaries.md)
7. **Do not weaken an architecture, security or privacy boundary** to make something easier. Establish the real contract first. → [Threat model](knowledge-base/06-security/threat-model.md)
8. **Missing data stays missing.** Never invent a percentage, a state or a category. → [Power](knowledge-base/02-modules/power.md)
9. **Bounded reads everywhere.** Files, pasteboard payloads and peer input go through the bounded abstractions and explicit limits. → [Resource budgets](knowledge-base/12-reference/resource-budget-registry.md)
10. **Slow I/O stays off the main actor**, and background work has an owner, a cadence and a stop path. → [Background & concurrency](knowledge-base/12-reference/background-concurrency-registry.md)
11. **Localization is complete.** Every `localized("…")` key exists in all seven shipped tables. App, website and legal localization are three separate contracts. → [Localization](knowledge-base/04-development/localization.md)
12. **Behaviour, docs, tests and gates travel together.** A behavioural change updates its canonical document and its Behavioral QA route in the same change. → [Documentation Guardian](knowledge-base/10-ai/documentation-guardian.md)
13. **A green unit test is not hardware evidence.** Never turn one into a manual `pass`. → [QA](knowledge-base/13-qa/README.md)

## Commands

```bash
swift test -c release
./Scripts/bundle.sh release
./Scripts/dmg.sh
python3 Scripts/agent-context.py <path>
python3 Scripts/check-project-manifest.py
python3 Scripts/check-current-documentation.py
python3 Scripts/check-agent-context.py
python3 Scripts/check-knowledge-base.py
python3 Scripts/generate-knowledge-map.py --check
python3 Scripts/check-documentation-freshness.py
python3 Scripts/check-localization.py
python3 Scripts/check-dependency-policy.py
python3 Scripts/check-qa-impact.py --base <base-sha>
python3 Scripts/check-documentation-guardian.py --base <base-sha>
python3 Scripts/check-release-qa-evidence.py --all
open build/Impuls.app
```

## Validation workflow

Run the repository's real commands rather than reporting a change as done. A red test is information.

1. Focused tests for what you changed, then `swift test -c release`.
2. `python3 -m unittest discover -s Tests/PythonTests -p 'test_*.py'` when scripts or documentation contracts changed.
3. **Commit, then run the documentation gates.** `check-documentation-freshness.py`, `check-documentation-guardian.py` and `check-qa-impact.py` compare committed state; running them before the commit reports a tree that is not the one being pushed.
4. Answer a firing gate by establishing the real contract and making the smallest truthful update. Never a Markdown touch, a broad exemption, or a `last_reviewed` moved without an actual review.

## Layout

| Path | What lives there |
| --- | --- |
| `PROJECT-MANIFEST.json` | routing-only map of stable topology, and the router's domain table |
| `Scripts/agent-context.py` | documentation router — the entry point for a local task |
| `Sources/Impuls/App` | lifecycle, app glue, Menu Bar controller, localization |
| `Sources/Impuls/Model` | shared application/panel state |
| `Sources/Impuls/Notch` | display topology, per-display windows, geometry, pointer tracking |
| `Sources/Impuls/Services` | stores, system adapters and business logic; no UI |
| `Sources/Impuls/Settings` | native settings and related windows |
| `Sources/Impuls/UI` | module panes and `Theme.swift` |
| `Tests/ImpulsTests` | Swift tests |
| `Tests/PythonTests` | documentation, routing and release-contract tests |
| `Resources` | localization and entitlements/resources |
| `Scripts` | build, packaging, versioning and maintenance scripts |
| `docs` | public website, release notes, audits and historical technical material |
| `knowledge-base` | current structured project knowledge for humans and AI |

## Conventions

Comments are in English and explain **why** — trade-offs and rejected approaches. UI numbers come from the existing theme/geometry system, not taste. Stores and services do not import SwiftUI; panes do not touch the filesystem directly. Shared services, per-display presentation: `NotchViewModel` and stores are shared, and no store, timer or monitor is created per display.

A new shipped module needs a tab/destination, store/service, pane, strings in every supported localization, tests, and an update to the module catalog, `PROJECT-MANIFEST.json` and the router's domain table. → [Adding a module](knowledge-base/04-development/adding-a-module.md)
