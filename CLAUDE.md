@AGENTS.md

## Claude Code

The shared instructions above apply.

Before planning or editing, inspect `PROJECT-MANIFEST.json` for a fast machine-readable topology, then read `knowledge-base/10-ai/AI-INDEX.md`. For a whole-repository security/performance audit, also read `knowledge-base/00-project/pre-audit-baseline-1.4.12.md` and use `main` as the only current source branch. The manifest is routing-only: it points to current ownership and canonical docs but never overrides code, tests or the linked reference documents. Historical files under `docs/` remain useful evidence, but they are not automatically current state.

A few things specific to this setup:

- **Path-scoped rules live in `.claude/rules/`.** They load only when you touch the matching files: `website.md` for `docs/`, `swift-ui.md` for the panel code, `localization.md` for the string tables, `release.md` for version/workflow files, and `qa-impact.md` for behavioral source/tests/TCC/release paths.
- **Use plan mode** before editing `Sources/Impuls/Services/UpdateService.swift`, `Scripts/bundle.sh`, `Package.swift` or anything under `.github/workflows/`. Those areas carry security and release guarantees; changes there are never casual one-liners.
- **Read `Sources/Impuls/UI/Theme.swift` before any UI work.** Every size, radius, colour and animation curve is defined there or in the pane itself. Do not invent visual constants without understanding the existing system.
- **Read the v1.3 reference registries before performance-sensitive work.** A timer/poller/debounce/Task/queue/actor change routes through `knowledge-base/12-reference/background-concurrency-registry.md`; a size/count/cadence/timeout/backpressure change routes through `knowledge-base/12-reference/resource-budget-registry.md`; persisted formats still route through the schema registry.
- **Run Behavioral QA impact traceability for behavioral code/test diffs.** Read `knowledge-base/13-qa/change-impact-traceability.md`, then run `python3 Scripts/check-qa-impact.py --base <base-sha>`. Review the reported QA IDs. If a tracked source file is unmapped, add the correct route or a narrow documented exemption; never silence the checker with a broad glob.
- **Update Behavioral QA** when work adds a new display/TCC/hardware/service/update/lifecycle scenario that cannot be fully proven by a deterministic unit test. The new ID must also receive a source/test route in `Scripts/qa-impact-rules.json`.
- **For every version bump, update Release QA Evidence too.** Copy `knowledge-base/13-qa/release-evidence/TEMPLATE.md` to the new version, record only truthful real-Mac/TCC/hardware results, keep gaps explicit, run the QA impact checker against the PR base, and then run `python3 Scripts/check-release-qa-evidence.py --release-gate`. Never infer a manual pass from unit tests or historical screenshots.
- **Run the repository's current test commands yourself** rather than reporting a change as done. Treat a red test as information, not noise.
- The semantic `Documentation Guardian` checks the current diff; the freshness checker checks historical source→doc ordering; QA impact traceability checks source/test→Behavioral QA ownership. If any fires, establish the real contract first. Never touch Markdown, add a broad exemption or change `last_reviewed` merely to make CI green.
- **Keep `PROJECT-MANIFEST.json` routing-only.** Update it when stable module/owner/network/permission/repository topology changes, not for ordinary implementation details. Never copy private runtime addresses or secrets into it.
- When a change alters architecture, module contracts, networking, permissions, persistence, background work, resource budgets, behavioral ownership or release flow, update the corresponding file under `knowledge-base/` and machine-readable map in the same change. Create an ADR for a new long-lived architectural decision.
