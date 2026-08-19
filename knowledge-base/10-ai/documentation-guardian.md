---
title: Documentation Guardian
type: ai-reference
status: active
documentation_version: 1.3
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, ai, documentation, ci, drift, guardian]
---

# Documentation Guardian

Documentation Guardian is the anti-drift layer between implementation changes and the engineering knowledge base. It does **not** generate prose from source. It makes contract-sensitive changes visible and requires the agent/engineer to review the canonical document in the same change set.

## Four protection layers

1. **Structural validation** — `Scripts/check-knowledge-base.py`
   - required frontmatter;
   - baseline documentation/product versions;
   - local links;
   - fenced diagram closure.
2. **Ownership/reference validation** — `Scripts/generate-knowledge-map.py --check`
   - curated type exists in its source;
   - mapped tests/docs exist;
   - committed generated map equals deterministic output.
3. **Semantic diff guard** — `Scripts/check-documentation-guardian.py --base <sha>`
   - inspects changed source lines;
   - matches high-risk contract patterns from `Scripts/documentation-guardian-rules.json`;
   - fails when the corresponding canonical documentation was not reviewed in the same diff.
4. **Product CI** — normal Swift/Python/build/security checks prove executable behavior rather than documentation shape.

## Guarded contract families

| Family | Canonical review route |
| --- | --- |
| Timer / polling / task / queue / debounce / background lifecycle | [Background Work & Concurrency Registry](../12-reference/background-concurrency-registry.md) |
| Size / count / cadence / timeout / backpressure budgets | [Input & Resource Budget Registry](../12-reference/resource-budget-registry.md) |
| Persisted keys / formats / schema / Keychain / collector DB | [Schema & Migration Registry](../12-reference/schema-migration-registry.md) |
| Internet endpoint / host / network owner contract | [Networking](../01-architecture/networking.md) |
| TCC / entitlement / permission prompt path | [Permissions](../01-architecture/permissions.md) and [Permissions & TCC](../03-macos/permissions-and-tcc.md) |
| New user-visible lifecycle/platform edge | [Behavioral QA Matrix](../13-qa/behavioral-qa-matrix.md) |

## How the diff guard works

The JSON rule set contains source globs, contract-sensitive regular expressions and one or more documentation files that satisfy review. The Python checker reads `git diff <base>...HEAD`, including additions and removals. If a matching contract line changed but none of its canonical docs changed, CI fails.

This intentionally catches **review obligation**, not semantic truth. Regex cannot know whether a new timer is a good idea or whether a changed limit is safe. The agent still has to establish the real contract from source/tests and document the rationale.

## Do not game the guard

A meaningless whitespace touch to a Markdown file is not a valid documentation update. If the source change is semantically neutral but hits a guarded pattern, review the canonical contract and make the smallest truthful update — for example clarifying ownership or confirming why the documented behavior is unchanged.

Conversely, a source change may alter behavior without matching a regex. `AGENTS.md`, the change-impact matrix and human/agent review still apply. The Guardian is a safety net, not a substitute for architectural judgment.

## Public / private boundary

The public Guardian must never force private runtime facts into `TumanovNV/impuls`. Production host/network/service/backup/access state belongs to `office-it-docs`. If a public software protocol change also changes deployment assumptions, update both canonical owners separately without copying private topology into this repository.

## Agent route

Before editing:

1. `AGENTS.md`
2. `knowledge-base/10-ai/AI-INDEX.md`
3. relevant module/architecture docs
4. the matching v1.3 registry if background/resource/persistence behavior is involved
5. source + tests + CI

Before reporting completion:

```bash
python3 Scripts/check-knowledge-base.py
python3 Scripts/generate-knowledge-map.py --check
python3 Scripts/check-documentation-guardian.py --base <base-sha>
```

Then run the repository's normal tests/build checks appropriate to the change.
